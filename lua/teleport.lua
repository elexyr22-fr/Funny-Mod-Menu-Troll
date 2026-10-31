-- Teleport, follow and "everyone to me", using only the game's own relocation calls:
--   local player -> managers.player:warp_to(pos, rot) (PlayerManager:warp_to -> PlayerMovement:warp_to
--                   -> unit:warp_to), then the native "action_teleport" message, exactly what
--                   PlayerMovement:update_teleport sends after a mission teleport, so the other
--                   peers move our husk at once (HuskPlayerMovement:sync_action_teleport).
--   team AI      -> unit:movement():set_position(pos), what GroupAIStateBase:update does when a bot
--                   is too far from the players (also moves the nav tracker). Host only.
--   placement    -> a nav tracker around the destination: tracker:field_position() gives the
--                   nearest navmesh point (same call as ElementLootPile), so bots land on the
--                   navmesh in a small circle, never on the same Vector3.
-- Moving ANOTHER human player is not possible: in 248.2 no host-to-client message relocates a
-- client. ElementTeleportPlayer only teleports the local player of each machine
-- (on_executed: instigator must be managers.player:player_unit()), "action_teleport" is sent by
-- the owner of the unit and only HuskPlayerMovement handles it, and the client's own position
-- is authoritative (player_action_walk_nav_point). No local-only position hack is done.
--
-- Follow: every follow_delay() seconds (menu choice 1-30 s, saved, default 3; GameSetupUpdate,
-- game time) the local player is teleported next to the chosen target. A new delay applies to
-- the next cycle at once. Placement: FOLLOW_OFFSET cm from the target on the side of the player
-- (never inside its hitbox); snapped to the navmesh unless Fly / No Clip is on. Stops when the target leaves, dies, its peer becomes
-- invalid, or the level ends (reset() is called by core.lua).
local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")

Teleport = Teleport or {}
local TP = Teleport

TP.FOLLOW_INTERVAL = 3
TP.FOLLOW_DELAYS = { 1, 2, 3, 5, 10, 15, 20, 30 }
TP.FOLLOW_OFFSET = 100
TP.RING_RADIUS = 120
TP.NEAR_RADIUS = 90

local function L(key)
	local fmm = rawget(_G, "FunnyModMenu")
	return fmm and fmm.L(key) or key
end

local function is_authority()
	return NET.is_host()
end

local function local_player()
	local player = managers.player and managers.player:player_unit()
	return alive(player) and player or nil
end

local function bot_name(unit)
	if managers.criminals and type(managers.criminals.character_name_by_unit) == "function" then
		local ok, name = pcall(managers.criminals.character_name_by_unit, managers.criminals, unit)
		if ok and name then
			return L("fmmt_bot") .. " " .. tostring(name)
		end
	end
	return L("fmmt_bot")
end

-- Nearest navmesh point to pos (pos itself when navigation is not available).
function TP.navmesh_pos(pos)
	local nav = managers.navigation
	if not nav or type(nav.create_nav_tracker) ~= "function" then
		return pos
	end
	local ok, tracker = pcall(nav.create_nav_tracker, nav, pos, false)
	if not ok or not tracker then
		return pos
	end
	local ok_pos, field = pcall(tracker.field_position, tracker)
	pcall(nav.destroy_nav_tracker, nav, tracker)
	return ok_pos and field or pos
end

-- Point i of n on a circle of radius r around center, snapped to the navmesh.
function TP.ring_pos(center, i, n, r)
	local angle = (i - 1) * 360 / math.max(n, 1)
	local offset = Vector3(math.cos(angle) * r, math.sin(angle) * r, 0)
	return TP.navmesh_pos(center + offset)
end

-- { { kind = "self"|"human"|"bot", name, unit, peer_id } }
function TP.get_targets()
	local list = {}
	local session = NET.session()
	if session then
		local local_peer = session:local_peer()
		for id, peer in pairs(session:all_peers()) do
			local unit = type(peer.unit) == "function" and peer:unit() or nil
			table.insert(list, {
				kind = peer == local_peer and "self" or "human",
				name = peer == local_peer and (L("fmmt_me") .. " (" .. peer:name() .. ")") or peer:name(),
				unit = alive(unit) and unit or nil,
				peer_id = id
			})
		end
	end
	local state = managers.groupai and managers.groupai:state()
	if state and type(state.all_AI_criminals) == "function" then
		for _, data in pairs(state:all_AI_criminals()) do
			if alive(data.unit) then
				table.insert(list, { kind = "bot", name = bot_name(data.unit), unit = data.unit })
			end
		end
	end
	return list
end

local function warp_local(pos)
	local player = local_player()
	if not player then
		return false
	end
	managers.player:warp_to(pos, player:rotation())
	local network = player:network()
	if network and type(network.send) == "function" then
		pcall(network.send, network, "action_teleport", pos)
	end
	return true
end

local function flying()
	local fm = rawget(_G, "FlyMode")
	if type(fm) ~= "table" then
		return false
	end
	local ok_f, fly = pcall(fm.is_fly, fm)
	local ok_n, noclip = pcall(fm.is_noclip, fm)
	return (ok_f and fly) or (ok_n and noclip) or false
end

function TP.follow_delay()
	local qes = rawget(_G, "QuickEnemySpawner")
	local value = qes and qes.settings and tonumber(qes.settings.follow_delay)
	return value and value > 0 and value or TP.FOLLOW_INTERVAL
end

function TP.set_follow_delay(seconds)
	local qes = rawget(_G, "QuickEnemySpawner")
	if qes and type(qes.set_setting) == "function" then
		qes.set_setting("follow_delay", seconds)
	end
	local f = TP._follow
	if f and f.last_t then
		f.next_t = f.last_t + seconds
	end
	log("[FunnyMod] Follow delay -> " .. tostring(seconds) .. " s")
end

-- Point FOLLOW_OFFSET cm from the target, on the side of the player (never inside the target).
local function near_pos(center, from)
	local offset = from and (from - center) or Vector3(1, 0, 0)
	mvector3.set_z(offset, 0)
	if mvector3.length(offset) < 1 then
		offset = Vector3(1, 0, 0)
	end
	mvector3.normalize(offset)
	return center + offset * TP.FOLLOW_OFFSET
end

function TP.me_to(unit)
	local player = local_player()
	if not player or not alive(unit) or unit == player then
		return false
	end
	local center = unit:position()
	local pos = near_pos(center, player:position())
	if not flying() then
		pos = TP.navmesh_pos(pos)
		-- Target off the navmesh (roof, vehicle...): land next to the target rather than far away.
		if mvector3 and mvector3.distance(pos, center) > TP.NEAR_RADIUS * 3 then
			pos = near_pos(center, player:position())
		end
	end
	warp_local(pos)
	log("[Teleport] Moi -> " .. tostring(unit:name()))
	return true
end

function TP.bot_to_me(bot, pos)
	if not is_authority() then
		log("[Teleport] Bot teleport refused: host only")
		return false
	end
	local player = local_player()
	if not player or not alive(bot) or not bot:movement() or type(bot:movement().set_position) ~= "function" then
		return false
	end
	bot:movement():set_position(pos or TP.ring_pos(player:position(), 1, 1, TP.RING_RADIUS))
	return true
end

function TP.all_bots_to_me()
	return TP.all_to_me()
end

-- Bots are moved (host). Humans cannot be moved over the network: counted as skipped.
function TP.all_to_me()
	if not is_authority() then
		log("[Teleport] Teleport all refused: host only")
		return 0, 0
	end
	local player = local_player()
	if not player then
		return 0, 0
	end
	local bots, humans = {}, 0
	for _, target in ipairs(TP.get_targets()) do
		if target.kind == "bot" then
			table.insert(bots, target.unit)
		elseif target.kind == "human" then
			humans = humans + 1
		end
	end
	local center, moved = player:position(), 0
	for i, bot in ipairs(bots) do
		if TP.bot_to_me(bot, TP.ring_pos(center, i, #bots, TP.RING_RADIUS)) then
			moved = moved + 1
		end
	end
	log("[Teleport] Tous -> moi : bots=" .. moved .. " humains non supportés=" .. humans)
	return moved, humans
end

-- Follow ------------------------------------------------------------------------------------

-- target: { kind = "human", peer_id } or { kind = "bot", unit }
function TP.follow(target)
	if not target or (target.kind ~= "human" and target.kind ~= "bot") then
		return false
	end
	TP._follow = { kind = target.kind, peer_id = target.peer_id, unit = target.unit, name = target.name, next_t = nil }
	log("[FunnyMod] Follow target -> " .. tostring(target.name))
	return true
end

function TP.stop_follow(reason)
	if TP._follow then
		TP._follow = nil
		log("[FunnyMod] Follow stopped" .. (reason and (" (" .. reason .. ")") or ""))
	end
end

function TP.follow_name()
	return TP._follow and TP._follow.name or nil
end

function TP.is_following(target)
	local f = TP._follow
	if not f or not target then
		return false
	end
	if f.kind == "human" then
		return target.kind == "human" and target.peer_id == f.peer_id
	end
	return target.kind == "bot" and target.unit == f.unit
end

local function follow_unit(f)
	if f.kind == "human" then
		local session = NET.session()
		local peer = session and session:peer(f.peer_id)
		if not peer then
			return nil, "peer left"
		end
		local unit = type(peer.unit) == "function" and peer:unit() or nil
		if not alive(unit) then
			return nil, "player dead or in custody"
		end
		return unit
	end
	if not alive(f.unit) then
		return nil, "bot gone"
	end
	local dmg = f.unit:character_damage()
	if dmg and type(dmg.dead) == "function" and dmg:dead() then
		return nil, "bot dead"
	end
	return f.unit
end

function TP.update_follow(t)
	local f = TP._follow
	if not f then
		return
	end
	local unit, reason = follow_unit(f)
	if not unit then
		TP.stop_follow(reason)
		return
	end
	if f.next_t and t < f.next_t then
		return
	end
	f.last_t = t
	f.next_t = t + TP.follow_delay()
	if local_player() then
		TP.me_to(unit)
	end
end

-- Level unload / mission end / restart / lobby.
function TP.reset()
	TP.stop_follow("level reset")
	TP._follow = nil
end

if not TP._update_hooked and Hooks then
	TP._update_hooked = true
	Hooks:Add("GameSetupUpdate", "FMMT_FollowUpdate", function(t, dt)
		if TP._follow then
			local ok, err = pcall(TP.update_follow, t)
			if not ok then
				log("[FunnyMod] Follow error: " .. tostring(err))
				TP._follow = nil
			end
		end
	end)
end
