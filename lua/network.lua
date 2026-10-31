-- FunnyMod.Network: the ONLY place where Funny Mod Menu Troll decides what the current network
-- context allows. Every module and the menu go through it. Nothing is cached: each call reads
-- the live state, so solo / host / client / main menu / lobby / level change are picked up at
-- once without restarting (PAYDAY 2 has no host migration: when the host leaves, the session ends).
-- Safe with no session (main menu, lobby loading): every accessor is guarded.
--
-- Capability classes (verified in the 248.2 source, see README "Compatibilité réseau"):
--   local                works as host AND as client (only the local player / local game)
--   host                 host-authoritative: available in solo and as host, greyed as client
--   mp_host              host of an online session only (kick / ban)
--   client_partial       works as client, but only part of it (tag "CLIENT LIMITÉ")
--   client_experimental  works as client with no rollback, others see an approximation
--                        (tag "CLIENT EXPÉRIMENTAL")
--   needs_mod            works as host AND as client, but only on the other players that also run
--                        Funny Mod Menu Troll (no vanilla sync: tag "NÉCESSITE LE MOD")
--   unsupported          no safe network path in the game

FunnyMod = FunnyMod or {}
FunnyMod.Network = FunnyMod.Network or {}
local NET = FunnyMod.Network

function NET.is_singleplayer()
	return Global and Global.game_settings and Global.game_settings.single_player and true or false
end

function NET.session()
	local network = managers and managers.network
	if not network or type(network.session) ~= "function" then
		return nil
	end
	local ok, session = pcall(network.session, network)
	return ok and session or nil
end

function NET.has_session()
	return NET.session() ~= nil
end

-- Authority over the world: solo, or the server of the session.
function NET.is_host()
	if NET.is_singleplayer() then
		return true
	end
	if not Network or type(Network.is_server) ~= "function" then
		return false
	end
	local ok, server = pcall(Network.is_server, Network)
	return ok and server and true or false
end

function NET.is_client()
	if NET.is_singleplayer() or not Network or type(Network.is_client) ~= "function" then
		return false
	end
	local ok, client = pcall(Network.is_client, Network)
	return ok and client and true or false
end

-- "SOLO", "HOST", "CLIENT" (or "MENU" before any session exists).
function NET.mode()
	if NET.is_singleplayer() then
		return "SOLO"
	end
	if NET.is_client() then
		return "CLIENT"
	end
	if NET.has_session() and NET.is_host() then
		return "HOST"
	end
	return "MENU"
end

function NET.local_peer_id()
	local session = NET.session()
	local peer = session and type(session.local_peer) == "function" and session:local_peer()
	return peer and type(peer.id) == "function" and peer:id() or nil
end

function NET.can_host_action()
	return NET.is_host()
end

function NET.can_local_action()
	return true
end

-- Enemy / bag / QES units are spawned by the server and synced (World:spawn_unit on a client
-- would create a unit nobody else has).
function NET.can_spawn_network_units()
	return NET.is_host()
end

-- GroupAIState (waves, enemy registration, alerts) only runs on the server.
function NET.can_control_group_ai()
	return NET.is_host()
end

-- Mission elements, TimerGui jams and custody trades are executed by the server.
function NET.can_modify_mission_elements()
	return NET.is_host()
end

-- Team AI is simulated by the server (TeamAIDamage / TeamAIMovement vs Husk* on clients).
function NET.can_move_team_ai()
	return NET.is_host()
end

-- Kick / ban: host of a real online session.
function NET.can_affect_remote_players()
	return NET.is_host() and not NET.is_singleplayer() and NET.has_session()
end

NET.FEATURES = {
	-- COMBAT
	god_personal = "local",
	god_all = "host",
	one_shot = "client_partial",
	ammo = "local",
	no_reload = "local",
	throwables = "local",
	sentry_ammo = "host",
	-- INTERACTIONS
	instant_interactions = "local",
	ignore_requirements = "local",
	unbreakable_drills = "host",
	-- V14: real interactions run by the local player (client: server_place_mission_door_device /
	-- sync_interacted / send_to_host sync_pickup, validated by the host as a manual interaction).
	auto_drill_place = "local",
	auto_drill_restart = "local",       -- host: Drill:on_autorepair; client: vanilla repair interaction
	auto_pickup_collectibles = "local",
	-- V15 (verified 248.2): Auto Steal = the vanilla pickup interactions (client: sync_pickup /
	-- sync_interacted requests, the host decides); Instant place = local timers only
	-- (PlayerManager:selected_equipment_deploy_timer, BaseInteractionExt:_get_timer).
	-- V18: per-type result as client (AutoSteal.status); the tag says CLIENT LIMITÉ until every
	-- type is confirmed by the host in game.
	auto_steal = "client_partial",
	-- V18: mission interactions (server_place_mission_door_device / sync_interacted, manual path).
	auto_mission = "local",
	instant_place = "local",
	c4_helper = "local",
	infinite_cable_ties = "local",
	no_pagers = "host",
	-- PLAYER
	speed = "local",
	ignore_bag_weight = "local",
	fly = "client_experimental",
	noclip = "client_experimental",
	deployables = "host",
	body_bags = "local",
	-- V15: AI detection / targeting run on the server (AIAttentionObject, CopLogicBase): host only.
	vanish = "host",
	-- V16 (verified 248.2): no visibility RPC exists, each client renders its own husk: custom BLT
	-- message, applied only by the players that have the mod (lua/player_invisibility.lua).
	vanish_players = "needs_mod",
	-- WORLD
	never_detected = "host",
	cameras_blind = "host",
	noise_alerts = "host",
	gun_alerts = "host",
	highlight = "local",
	-- V12 (verified in 248.2, see README "Compatibilité réseau"):
	highlight_collectibles = "local",   -- local contours / no_sync waypoints
	aimbot = "local",                   -- local camera (FPCameraPlayerBase set_spin / set_pitch)
	auto_kill = "client_partial",       -- host: damage_mission / force_custody; client: enemies via damage_bullet
	convert_target = "host",            -- GroupAIStateBase:convert_hostage_to_criminal is server-side
	convert_all = "host",
	instant_trade = "host",             -- TradeManager trades run on the server only
	force_respawn = "host",             -- TradeManager:criminal_respawn / spawn_member_by_id
	auto_revive = "local",              -- ReviveInteractionExt:interact: revive_player RPC / send_to_host revive_unit
	follow_player = "local",            -- local warp + action_teleport (confirmed as client)
	enemy_control = "host",
	kill_remove = "host",
	loot = "host",
	-- SPAWNER
	spawner = "host",
	-- PLAYERS
	tp_me = "local",
	follow = "local",
	tp_bots = "host",
	tp_all = "host",
	tp_player_to_me = "unsupported",
	kick_ban = "mp_host",
	custody = "host",
	-- SETTINGS
	language = "local",
	seamless_input_switch = "local"
}

-- { available = bool, class = string, tag = localization key or nil }
function NET.capability(feature)
	local class = NET.FEATURES[feature] or "local"
	local client = NET.is_client()
	if class == "local" then
		return { available = true, class = class }
	elseif class == "host" then
		local ok = NET.is_host()
		return { available = ok, class = class, tag = not ok and "fmmt_tag_host_only" or nil }
	elseif class == "mp_host" then
		local ok = NET.can_affect_remote_players()
		local tag = nil
		if not ok then
			tag = NET.is_singleplayer() and "fmmt_tag_online_only" or "fmmt_tag_host_only"
		end
		return { available = ok, class = class, tag = tag }
	elseif class == "client_partial" then
		return { available = true, class = class, tag = client and "fmmt_tag_client_limited" or nil }
	elseif class == "needs_mod" then
		return { available = true, class = class, tag = "fmmt_tag_needs_mod" }
	elseif class == "client_experimental" then
		return { available = true, class = class, tag = client and "fmmt_tag_client_experimental" or nil }
	end
	return { available = false, class = class, tag = "fmmt_tag_unsupported" }
end

function NET.available(feature)
	return NET.capability(feature).available
end

-- Main-menu log line, written once per mode change (level load, joining, hosting...).
function NET.log_mode_change()
	local mode = NET.mode()
	if NET._last_logged_mode ~= mode then
		NET._last_logged_mode = mode
		log("[FunnyMod] Network mode -> " .. mode)
	end
end

return NET
