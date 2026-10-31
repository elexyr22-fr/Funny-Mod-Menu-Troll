-- FunnyMod.PlayerInvisibility (V16): the visual half of Vanish. The local player becomes
-- invisible to the OTHER HUMAN PLAYERS that also run Funny Mod Menu Troll. The AI half (AI
-- ignores you, detection reset) stays in lua/vanish.lua and is unchanged.
--
-- Verified in the 248.2 source (network architecture):
--   A) Host hiding its unit from vanilla clients: NOT POSSIBLE. Each client spawns and renders its
--      own HuskPlayer unit for every remote player; visibility is a local engine state
--      (Unit:set_visible). No UnitNetworkHandler / ConnectionNetworkHandler RPC carries a
--      visibility command (only sync_show_hint / sync_show_action_message, both HUD text).
--   B) A client hiding itself on the others: same answer, no RPC in either direction.
--   C) Visibility sync: none. HuskPlayerBase.set_force_invisible (= CopBase:set_force_invisible,
--      huskplayerbase.lua:8) exists but nothing in the game ever calls it for a husk, and nothing
--      syncs it. The only synced hide is the "clean"/civilian movement state, which hides the
--      husk's weapons only (HuskPlayerMovement:4435 -> HuskPlayerInventory:set_visibility_state),
--      never the body, and it changes gameplay: not usable.
--   D) So the hide must run on EACH observing client: custom message through the BLT hidden chat
--      channel (NetworkHelper, channel 4, send_chat_message RPC). A vanilla client has no receiver
--      on channel 4 (ChatManager:_receive_message returns when _receivers[4] is nil): it ignores
--      the message and KEEPS SEEING YOU. Host and client work the same way (full mesh peers).
--
-- Protocol (message id "FMMT_VAN", sender id comes from the network, never from the payload, so a
-- peer can only hide ITSELF):
--   hello  "I have the mod" (level start / new peer). Answer: ack (+ hide if we are hidden).
--   ack    "I have the mod".
--   hide   hide my husk on your side.   show   show it again.
-- V18: hello / ack carry the mod version and a small feature bitmask: "hello|1.6|3". Old builds
-- send a bare "hello" / "ack" (version shown "?"), and still parse fine here. The same handshake
-- fills FunnyMod.CompatPeers (players that have Funny Mod Menu Troll): no second protocol. It is
-- invisible in the chat (BLT hidden channel), unrelated to the "Funny Game lol" join message.
--   FunnyMod.CompatPeers[peer_id] = { name, version, features = { vanish_players, custom_sync },
--                                     last_seen, user_id }
--   removed when the peer leaves (or its id is reused), cleared on a new session / level.
--
-- Receiving side (hidden husk of peer X):
--   * the husk unit and EVERY unit linked under it (weapons + weapon parts, mask + mask parts,
--     shield, headwear, melee prop, carried bag, deployable props...) -> set_visible(false), done
--     every frame so a weapon switch / reload / new melee prop never shows, even for one frame;
--   * HuskPlayerBase._update_visibility_state and HuskPlayerInventory:set_visibility_state are
--     forced to false while hidden (LOD / mask-on / state changes cannot re-show anything);
--   * name label hidden, muzzle flash / bullet trails / shell ejection of its weapon suppressed
--     (gunshot SOUND kept: it is part of the network sync and harmless);
--   * never set_slot(0) / delete: the unit stays present, networked, shootable, synced.
--   Show: the units we hid are made visible again, then the game's own
--   _update_visibility_state(true) has the last word (holstered weapons, hidden parts...).
-- Custody / respawn: the peer's new unit is read from peer:unit() every frame and hidden again.
FunnyMod = FunnyMod or {}
PlayerInvisibility = PlayerInvisibility or {}
FunnyMod.PlayerInvisibility = PlayerInvisibility
local PI = PlayerInvisibility

PI.MSG_ID = "FMMT_VAN"
PI.RESEND_INTERVAL = 10
PI.HELLO_CHECK_INTERVAL = 2

-- peer_id -> user_id, filled by the receiving side for every peer that told us to hide.
PI._hidden_peers = PI._hidden_peers or {}
-- peer_id -> user_id of peers that answered / sent anything with the mod.
PI._modded_peers = PI._modded_peers or {}
-- unit key -> { unit = hidden husk, hid = { [key] = unit } } (units WE made invisible).
FunnyMod.CompatPeers = FunnyMod.CompatPeers or {}
PI.FEATURE_BITS = { vanish_players = 1, custom_sync = 2 }
PI._hidden_units = PI._hidden_units or {}

local function setting(key, default)
	local q = rawget(_G, "QuickEnemySpawner")
	local value = q and q.settings and q.settings[key]
	if value == nil then
		return default
	end
	return value
end

local function net_helper()
	local nh = rawget(_G, "NetworkHelper") or rawget(_G, "LuaNetworking")
	return type(nh) == "table" and type(nh.SendToPeers) == "function" and nh or nil
end

local function session()
	local n = FunnyMod.Network
	return n and n.session() or nil
end

local function peer_user_id(peer)
	local ok, uid = pcall(peer.user_id, peer)
	return ok and uid or tostring(peer)
end

-- Other peers of the session, keyed by id.
local function other_peers()
	local s = session()
	local peers = s and type(s.peers) == "function" and s:peers() or {}
	return peers
end

-- SENDING SIDE ---------------------------------------------------------------------------------

function PI:is_enabled()
	return setting("vanish_players", false) == true
end

local function send(data, peer_id)
	local nh = net_helper()
	if not nh or not session() then
		return false
	end
	local ok, err
	if peer_id then
		ok, err = pcall(nh.SendToPeer, nh, peer_id, PI.MSG_ID, data)
	else
		ok, err = pcall(nh.SendToPeers, nh, PI.MSG_ID, data)
	end
	if not ok then
		log("[Vanish][net] send '" .. tostring(data) .. "' failed: " .. tostring(err))
	end
	return ok
end

function PI:set_enabled(state)
	state = state and true or false
	local q = rawget(_G, "QuickEnemySpawner")
	if q and type(q.set_setting) == "function" then
		q.set_setting("vanish_players", state)
	end
	PI._next_resend_t = nil
	send(state and "hide" or "show")
	local compatible, total = PI.compatible_count()
	log(string.format("[Vanish][net] player invisibility -> %s (mod detected on %d / %d other players, the others still see you)", state and "ON" or "OFF", compatible, total))
end

-- Number of other players that answered with the mod, and number of other players.
function PI.compatible_count()
	local compatible, total = 0, 0
	for id, peer in pairs(other_peers()) do
		total = total + 1
		if PI.peer_compat and PI.peer_compat(id) then
			compatible = compatible + 1
		end
	end
	return compatible, total
end

-- COMPATIBLE PEERS (V18) -----------------------------------------------------------------------

function PI.mod_version()
	local fmm = rawget(_G, "FunnyModMenu")
	return fmm and fmm.VERSION and tostring(fmm.VERSION) or "?"
end

local function local_features()
	local bits = 0
	for _, bit in pairs(PI.FEATURE_BITS) do
		bits = bits + bit
	end
	return bits
end

-- "hello" -> "hello|1.6|3"
local function handshake(cmd)
	return cmd .. "|" .. PI.mod_version() .. "|" .. tostring(local_features())
end

-- "cmd|version|features" -> cmd, version | nil, features | nil
local function parse(data)
	data = tostring(data or "")
	local cmd, version, features = data:match("^([^|]+)|([^|]*)|?(%d*)$")
	if not cmd then
		return data
	end
	return cmd, version ~= "" and version or nil, tonumber(features)
end

local function decode_features(bits)
	local out = {}
	for name, bit in pairs(PI.FEATURE_BITS) do
		out[name] = bits ~= nil and math.floor(bits / bit) % 2 == 1 or nil
	end
	return out
end

local function now()
	return Application and Application:time() or os.clock()
end

local function mark_modded(peer_id, version, features)
	local peer = other_peers()[peer_id]
	if not peer then
		return
	end
	local uid = peer_user_id(peer)
	PI._modded_peers[peer_id] = uid
	local entry = FunnyMod.CompatPeers[peer_id]
	if not entry or entry.user_id ~= uid then
		entry = { user_id = uid }
		FunnyMod.CompatPeers[peer_id] = entry
		local ok, name = pcall(peer.name, peer)
		entry.name = ok and name or ("peer " .. peer_id)
		log("[FunnyMod][compat] " .. tostring(entry.name) .. " (peer " .. peer_id .. ") has Funny Mod Menu Troll v" .. tostring(version or "?"))
	end
	if version then
		entry.version = version
	end
	if features then
		entry.features = decode_features(features)
	end
	entry.version = entry.version or "?"
	entry.features = entry.features or {}
	entry.last_seen = now()
end

-- Peers that left (or whose id now belongs to somebody else) are removed.
local function prune_compat()
	local peers = other_peers()
	for peer_id, entry in pairs(FunnyMod.CompatPeers) do
		local peer = peers[peer_id]
		if not peer or peer_user_id(peer) ~= entry.user_id then
			FunnyMod.CompatPeers[peer_id] = nil
			PI._modded_peers[peer_id] = nil
			log("[FunnyMod][compat] " .. tostring(entry.name) .. " (peer " .. peer_id .. ") left")
		end
	end
end
PI.prune_compat = prune_compat

-- The compat entry of one peer (nil = not detected). The local player is always "installed".
function PI.peer_compat(peer_id)
	if peer_id and peer_id == (FunnyMod.Network and FunnyMod.Network.local_peer_id()) then
		return { name = "", version = PI.mod_version(), features = decode_features(local_features()), is_local = true }
	end
	local entry = peer_id and FunnyMod.CompatPeers[peer_id]
	local peer = entry and other_peers()[peer_id]
	if not peer or peer_user_id(peer) ~= entry.user_id then
		return nil
	end
	return entry
end

-- Every player of the session that has the mod, local player first: { {peer_id, name, version,
-- is_local}, ... }, and the number of players in the session (local player included).
function PI.compat_list()
	local list, total = {}, 1
	local n = FunnyMod.Network
	local my_id = n and n.local_peer_id()
	local s = session()
	local me = s and type(s.local_peer) == "function" and s:local_peer()
	local ok, my_name = pcall(function() return me:name() end)
	table.insert(list, { peer_id = my_id, name = ok and my_name or "?", version = PI.mod_version(), is_local = true })
	local rest = {}
	for peer_id, peer in pairs(other_peers()) do
		total = total + 1
		local entry = PI.peer_compat(peer_id)
		if entry then
			table.insert(rest, { peer_id = peer_id, name = entry.name, version = entry.version })
		end
	end
	table.sort(rest, function(a, b)
		return a.peer_id < b.peer_id
	end)
	for _, e in ipairs(rest) do
		table.insert(list, e)
	end
	return list, total
end

-- RECEIVING SIDE -------------------------------------------------------------------------------

local function descendants(unit, out)
	local ok, children = pcall(unit.children, unit)
	if ok and type(children) == "table" then
		for _, child in ipairs(children) do
			if alive(child) then
				out[#out + 1] = child
				descendants(child, out)
			end
		end
	end
	return out
end

-- Hides the husk and everything linked under it (every frame while hidden).
local function enforce_hidden(unit)
	local key = unit:key()
	local entry = PI._hidden_units[key]
	if not entry then
		entry = { unit = unit, hid = {} }
		PI._hidden_units[key] = entry
		local base = unit:base()
		if base then
			base._fmmt_invisible = true
		end
	end
	if unit:visible() then
		unit:set_visible(false)
		entry.hid[key] = unit
	end
	for _, child in ipairs(descendants(unit, {})) do
		if child:visible() then
			child:set_visible(false)
			entry.hid[child:key()] = child
		end
	end
end

local function restore_unit(key)
	local entry = PI._hidden_units[key]
	PI._hidden_units[key] = nil
	if not entry or not alive(entry.unit) then
		return
	end
	local unit = entry.unit
	local base = unit:base()
	if base then
		base._fmmt_invisible = nil
	end
	-- Only the units still attached to the husk (a dropped / destroyed unit is not touched).
	local attached = { [unit:key()] = true }
	for _, child in ipairs(descendants(unit, {})) do
		attached[child:key()] = true
	end
	for k, u in pairs(entry.hid) do
		if attached[k] and alive(u) then
			u:set_visible(true)
		end
	end
	-- The game's own visibility logic has the last word (holstered weapons, hidden parts, clean
	-- state weapons, off-screen LOD).
	if base and type(base._update_visibility_state) == "function" then
		pcall(base._update_visibility_state, base, base._lod_stage and true or false)
	end
end

function PI.is_unit_hidden(unit)
	return alive(unit) and PI._hidden_units[unit:key()] ~= nil
end

local function on_message(data, sender)
	sender = tonumber(sender)
	if not sender then
		return
	end
	local cmd, version, features = parse(data)
	mark_modded(sender, version, features)
	local peer = other_peers()[sender]
	if cmd == "hello" then
		send(handshake("ack"), sender)
		if PI:is_enabled() then
			send("hide", sender)
		end
	elseif cmd == "hide" then
		if peer and not PI._hidden_peers[sender] then
			log("[Vanish][net] peer " .. sender .. " (" .. tostring(peer:name()) .. ") is now invisible on this client")
		end
		PI._hidden_peers[sender] = peer and peer_user_id(peer) or true
	elseif cmd == "show" then
		if PI._hidden_peers[sender] then
			log("[Vanish][net] peer " .. sender .. " is visible again on this client")
		end
		PI._hidden_peers[sender] = nil
	end
end

-- Keeps every hidden husk hidden and restores those that must reappear.
local function update_receivers()
	local peers = other_peers()
	local want = {}
	for peer_id, uid in pairs(PI._hidden_peers) do
		local peer = peers[peer_id]
		if not peer or (uid ~= true and peer_user_id(peer) ~= uid) then
			-- The peer left (the id may be reused by somebody else): forget it.
			PI._hidden_peers[peer_id] = nil
		else
			local unit = type(peer.unit) == "function" and peer:unit()
			if alive(unit) and unit ~= (managers.player and managers.player:player_unit()) then
				want[unit:key()] = true
				enforce_hidden(unit)
			end
		end
	end
	for key in pairs(PI._hidden_units) do
		if not want[key] then
			restore_unit(key)
		end
	end
	-- V16.1 temporary diagnostic: only when the number of hidden husks changes (never per frame).
	local n = 0
	for _ in pairs(PI._hidden_units) do
		n = n + 1
	end
	if n ~= PI._last_logged_count then
		PI._last_logged_count = n
		log("[Vanish] visibility update: " .. n .. " remote player(s) hidden on this client")
	end
end

local function update_sender(t)
	local s = session()
	if not s then
		return
	end
	-- Mod detection: a hello whenever the set of peers changes (join / leave / level start).
	if not PI._next_hello_check or t >= PI._next_hello_check then
		PI._next_hello_check = t + PI.HELLO_CHECK_INTERVAL
		local sig = {}
		for id, peer in pairs(other_peers()) do
			sig[#sig + 1] = id .. ":" .. tostring(peer_user_id(peer))
		end
		table.sort(sig)
		sig = table.concat(sig, ",")
		if sig ~= PI._peer_signature then
			PI._peer_signature = sig
			prune_compat()
			if sig ~= "" then
				send(handshake("hello"))
			end
		end
	end
	-- Safety resend while ON (a peer that loaded late / missed the first message).
	if PI:is_enabled() and (not PI._next_resend_t or t >= PI._next_resend_t) then
		PI._next_resend_t = t + PI.RESEND_INTERVAL
		if PI._peer_signature and PI._peer_signature ~= "" then
			send("hide")
		end
	end
end

function PI.update(t, dt)
	if not session() then
		return
	end
	update_sender(t)
	update_receivers()
end

-- Level unload / lobby / mission change: everything visible again, option OFF.
function PI.reset()
	for key in pairs(PI._hidden_units) do
		pcall(restore_unit, key)
	end
	PI._hidden_units = {}
	PI._hidden_peers = {}
	PI._modded_peers = {}
	FunnyMod.CompatPeers = {}
	PI._peer_signature = nil
	PI._next_hello_check = nil
	PI._next_resend_t = nil
	if PI:is_enabled() then
		pcall(send, "show")
		local q = rawget(_G, "QuickEnemySpawner")
		if q and q.settings then
			q.settings.vanish_players = false
			if type(q.save_settings) == "function" then
				pcall(q.save_settings)
			end
		end
		log("[Vanish][net] player invisibility reset OFF (level change)")
	end
end

-- HOOKS ----------------------------------------------------------------------------------------

if RequiredScript == "lib/managers/playermanager" and not PI._update_hooked and Hooks then
	PI._update_hooked = true
	Hooks:Add("GameSetupUpdate", "FMMT_PlayerInvisibilityUpdate", function(t, dt)
		local ok, err = pcall(PI.update, t, dt)
		if not ok and not PI._error_logged then
			PI._error_logged = true
			log("[Vanish][net] error: " .. tostring(err))
		end
	end)
	local nh = net_helper()
	if nh and type(nh.AddReceiveHook) == "function" then
		nh:AddReceiveHook(PI.MSG_ID, "FMMT_PlayerInvisibilityReceive", function(data, sender)
			local ok, err = pcall(on_message, data, sender)
			if not ok then
				log("[Vanish][net] receive error: " .. tostring(err))
			end
		end)
	else
		log("[Vanish][net] BLT NetworkHelper missing: player invisibility disabled")
	end
end

-- LOD / game code cannot re-show a hidden husk.
if RequiredScript == "lib/units/beings/player/huskplayerbase" and HuskPlayerBase and not PI._base_hooked then
	PI._base_hooked = true
	local original_update_visibility_state = HuskPlayerBase._update_visibility_state
	function HuskPlayerBase:_update_visibility_state(state, ...)
		if self._fmmt_invisible then
			state = false
		end
		return original_update_visibility_state(self, state, ...)
	end
end

-- Mask on / clean state / weapon visibility refresh of a hidden husk stay hidden.
if RequiredScript == "lib/units/beings/player/huskplayerinventory" and HuskPlayerInventory and not PI._inventory_hooked then
	PI._inventory_hooked = true
	local original_set_visibility_state = HuskPlayerInventory.set_visibility_state
	function HuskPlayerInventory:set_visibility_state(state, ...)
		local base = alive(self._unit) and self._unit:base()
		if base and base._fmmt_invisible then
			state = false
		end
		return original_set_visibility_state(self, state, ...)
	end
end

-- Magazine dropped during a reload (spawned free in the world, not linked to the husk).
if RequiredScript == "lib/units/beings/player/huskplayermovement" and HuskPlayerMovement and not PI._movement_hooked then
	PI._movement_hooked = true
	local original_spawn_magazine_unit = HuskPlayerMovement._spawn_magazine_unit
	function HuskPlayerMovement:_spawn_magazine_unit(...)
		local mag = original_spawn_magazine_unit(self, ...)
		if alive(mag) and PI.is_unit_hidden(self._unit) then
			mag:set_visible(false)
		end
		return mag
	end
end

-- Name label above the hidden husk.
if RequiredScript == "lib/managers/hudmanager" and HUDManager and not PI._label_hooked then
	PI._label_hooked = true
	local original_update_name_labels = HUDManager._update_name_labels
	function HUDManager:_update_name_labels(...)
		local result = original_update_name_labels(self, ...)
		if next(PI._hidden_units) and self._hud and self._hud.name_labels then
			for _, data in ipairs(self._hud.name_labels) do
				local unit = data.movement and data.movement._unit
				if unit and PI.is_unit_hidden(unit) and data.panel and data.panel:visible() then
					data.panel:set_visible(false)
				end
			end
		end
		return result
	end
end

-- Muzzle flash, bullet trails and shell ejection of a hidden husk's weapon (sound kept).
if RequiredScript == "lib/units/weapons/newnpcraycastweaponbase" and NewNPCRaycastWeaponBase and not PI._weapon_hooked then
	PI._weapon_hooked = true
	local function owner_hidden(weapon)
		local user = weapon._setup and weapon._setup.user_unit
		return user and PI.is_unit_hidden(user)
	end
	local function wrap_blank(name)
		local original = NewNPCRaycastWeaponBase[name]
		if type(original) ~= "function" then
			return
		end
		NewNPCRaycastWeaponBase[name] = function(self, ...)
			if not owner_hidden(self) then
				return original(self, ...)
			end
			local trails, shells = self._use_trails, self._use_shell_ejection_effect
			self._use_trails = false
			self._use_shell_ejection_effect = false
			self._fmmt_no_muzzle = true
			local ok, a, b = pcall(original, self, ...)
			self._use_trails, self._use_shell_ejection_effect = trails, shells
			self._fmmt_no_muzzle = nil
			if not ok then
				error(a)
			end
			return a, b
		end
	end
	wrap_blank("fire_blank")
	wrap_blank("auto_fire_blank")
	local original_muzzle = NewNPCRaycastWeaponBase._spawn_muzzle_effect
	function NewNPCRaycastWeaponBase:_spawn_muzzle_effect(...)
		if self._fmmt_no_muzzle then
			return
		end
		return original_muzzle(self, ...)
	end
end

return PI
