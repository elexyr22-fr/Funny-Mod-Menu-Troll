-- FunnyMod.AutoRevive (V15): downed teammates (human players and bots) close to the local player
-- are revived through their REAL revive interaction, via the common engine FunnyMod.AutoActions
-- and FunnyMod.RealInteract: interact_start (-> ReviveInteractionExt:_at_interact_start,
-- "start_revive_player" to a husk / pause_bleed_out for a bot) -> vanilla timer ->
-- interact_interupt(complete) -> ReviveInteractionExt:interact (interactionext.lua:1263):
--   human player (husk)  -> send_to_unit("revive_player"): the victim's own game revives them
--   bot, as host         -> TeamAIDamage:revive(reviving_unit)
--   bot, as client       -> HuskTeamAIDamage:revive -> send_to_host("revive_unit")
-- Same path as a client reviving by hand: network-safe as client.
--
-- V14 log "Revive of X refused by can_interact": V14 called interact() and then checked at once
-- whether the teammate was still downed. For a human teammate the revive is an RPC answered by
-- the victim's game, so right after the call the interaction is always still active: the message
-- was a false negative, the real result was never checked. V15 waits for the game's
-- confirmation (revive interaction deactivated / changed) with a network timeout.
-- Only "revive" (downed). Cuffed ("free") is not touched. Distance only, no crosshair.
local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")

FunnyMod = FunnyMod or {}
AutoRevive = AutoRevive or {}
FunnyMod.AutoRevive = AutoRevive
local AR = AutoRevive

-- Radius choices in meters; 0 = MAX (no distance restriction).
AR.RADII = { 2, 5, 10, 20, 0 }
-- A revive waits for the victim's game: longer than a pickup.
AR.TIMEOUT = 6

local function AA()
	if not FunnyMod.AutoActions then
		local base = ModPath or (FunnyModMenu and FunnyModMenu.path) or ""
		if not FunnyMod.RealInteract then
			pcall(dofile, base .. "lua/real_interact.lua")
		end
		pcall(dofile, base .. "lua/auto_actions.lua")
	end
	return FunnyMod.AutoActions
end

local function qes()
	return rawget(_G, "QuickEnemySpawner")
end

local function setting(key, default)
	local q = qes()
	local value = q and q.settings and q.settings[key]
	if value == nil then
		return default
	end
	return value
end

function AR:is_enabled()
	return setting("auto_revive", true) and true or false
end

function AR:set_enabled(state)
	local q = qes()
	if q and type(q.set_setting) == "function" then
		q.set_setting("auto_revive", state and true or false)
	end
	log("[AutoRevive] -> " .. (state and "ON" or "OFF"))
end

function AR:radius()
	return tonumber(setting("auto_revive_radius", 5)) or 5
end

function AR:set_radius(meters)
	local q = qes()
	if q and type(q.set_setting) == "function" then
		q.set_setting("auto_revive_radius", meters)
	end
end

local function player_can_help(player)
	local dmg = player:character_damage()
	if dmg and ((type(dmg.need_revive) == "function" and dmg:need_revive()) or (type(dmg.arrested) == "function" and dmg:arrested())) then
		return false
	end
	return true
end

local function unit_label(unit)
	if managers.criminals and type(managers.criminals.character_name_by_unit) == "function" then
		local ok, name = pcall(managers.criminals.character_name_by_unit, managers.criminals, unit)
		if ok and name then
			return tostring(name)
		end
	end
	return tostring(unit:name())
end

-- Human teammates' units and team AI units (never the local player, never enemies).
function AR.teammates(player)
	local list = {}
	local session = NET.session()
	if session then
		for _, peer in pairs(session:all_peers()) do
			local unit = type(peer.unit) == "function" and peer:unit() or nil
			if alive(unit) and unit ~= player then
				table.insert(list, { unit = unit, name = peer:name() })
			end
		end
	end
	local gs = managers.groupai and managers.groupai:state()
	if gs and type(gs.all_AI_criminals) == "function" then
		for _, data in pairs(gs:all_AI_criminals()) do
			if alive(data.unit) then
				table.insert(list, { unit = data.unit, name = unit_label(data.unit) })
			end
		end
	end
	return list
end

local function is_downed(unit)
	local interaction = unit:interaction()
	if not interaction or interaction.tweak_data ~= "revive" then
		return false
	end
	return type(interaction.active) == "function" and interaction:active() and true or false
end
AR.is_downed = is_downed

AR.system = {
	id = "revive",
	mission_action = false,
	timeout = AR.TIMEOUT,
	enabled = function()
		return AR:is_enabled()
	end,
	radius = function()
		return AR:radius()
	end,
	detect = function(ctx)
		local list = {}
		if not player_can_help(ctx.player) then
			return list
		end
		for _, mate in ipairs(AR.teammates(ctx.player)) do
			if is_downed(mate.unit) then
				table.insert(list, { unit = mate.unit, priority = 1, info = mate.name })
			end
		end
		return list
	end,
	on_phase = function(phase, entry, data)
		local name = tostring(entry.info or entry.label)
		if phase == "complete" then
			log("[AutoRevive] Revive request sent: " .. name .. " (" .. NET.mode() .. ")")
		elseif phase == "confirmed" then
			log("[AutoRevive] Revived " .. name .. " (confirmed: " .. tostring(data) .. ")")
		elseif phase == "failed" then
			log("[AutoRevive] Revive of " .. name .. " not done: " .. tostring(data))
		end
	end
}

local aa = AA()
if aa then
	aa.register(AR.system)
end

function AR.reset()
	local e = FunnyMod.AutoActions
	if e then
		e.reset("revive")
	end
end

return AR
