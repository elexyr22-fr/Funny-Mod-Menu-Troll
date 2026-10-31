-- FunnyMod.Aimbot: local camera aim at the valid target closest to the screen center, plus an
-- optional Auto Kill through the game's own damage functions. Both OFF by default.
--
-- Camera (LOCAL, verified 248.2): FPCameraPlayerBase keeps the look direction as polar angles in
-- _camera_properties.spin / .pitch and exposes set_spin / set_pitch
-- (lib/units/cameras/fpcameraplayerbase.lua:2034). PlayerDriving uses exactly
-- camera_unit():base():set_spin(rot:y():to_polar().spin) and set_pitch(). Mouse input is added on
-- top every frame by _update_rot, so the aim is re-applied each frame while a target is held.
-- Only in the standard / carry / bipod player states.
--
-- Targets:
--   "enemies"  registered enemies (vanilla + QES) hostile to the criminals, not converted,
--              not surrendered / tied (CopBrain:is_hostage)
--   "npc"      enemies + Jokers (converted) + team AI bots
--   "all"      npc + human players' units
--   Civilians are never in these lists. Dead units, units without character_damage and units
--   hidden behind world geometry (World:raycast "report" on the world_geometry mask from the
--   camera to the head, like EnemyManager's visibility check) are skipped.
-- Head: unit:movement():m_head_pos() (CopMovement / TeamAIMovement / HuskPlayerMovement).
--
-- Auto Kill (needs Aimbot): one kill per target, then AUTO_KILL delay before the next one.
--   HOST   CopDamage units (enemies, QES, Jokers): damage_mission (the call ElementSpawnEnemyDummy
--          :kill_all_units and the QES kill use): die(), death listeners, ragdoll, GroupAI
--          callbacks, network death sync. Mission invulnerability is respected (not forced).
--          Bots: TeamAIDamage:force_custody (ElementTeamAICommands), same as One Shot.
--   CLIENT enemies only, through CopDamage:damage_bullet with the local player as attacker and the
--          equipped weapon: the same call a real bullet makes on a client; the client computes the
--          hit and sends "damage_bullet" with the death flag (_send_bullet_attack_result), the
--          host applies it. Units with a bullet damage clamp may need several hits.
--          Jokers / bots are simulated by the host: skipped on a client (not faked).
--   Human players are never auto-killed (no friendly-damage path outside the Friendly Fire
--   mutator, see oneshot.lua).
local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")

FunnyMod = FunnyMod or {}
Aimbot = Aimbot or {}
FunnyMod.Aimbot = Aimbot
local AB = Aimbot

AB.TARGET_MODES = { "enemies", "npc", "all" }
AB.FOVS = { 30, 60, 90, 180 }
AB.DISTANCES = { 25, 50, 100, 0 }
AB.KILL_DELAYS = { 0.1, 0.5, 1, 2 }
AB.RESELECT_INTERVAL = 0.1
AB.KILL_IGNORE_TIME = 2
AB.AIM_STATES = { standard = true, carry = true, bipod = true }

AB._ignored = AB._ignored or {}

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

local function save(key, value)
	local q = qes()
	if q and type(q.set_setting) == "function" then
		q.set_setting(key, value)
	end
end

function AB:is_enabled()
	return setting("aimbot_enabled", false) and true or false
end

function AB:set_enabled(state)
	save("aimbot_enabled", state and true or false)
	if not state then
		AB._target = nil
	end
	log("[Aimbot] -> " .. (state and "ON" or "OFF"))
end

function AB:auto_kill_enabled()
	return setting("auto_kill", false) and true or false
end

function AB:set_auto_kill(state)
	save("auto_kill", state and true or false)
	log("[Aimbot] Auto Kill -> " .. (state and "ON" or "OFF"))
end

function AB:target_mode()
	local mode = setting("aimbot_targets", "enemies")
	return table.contains(AB.TARGET_MODES, mode) and mode or "enemies"
end

function AB:set_target_mode(mode)
	save("aimbot_targets", mode)
	AB._target = nil
end

function AB:fov()
	return tonumber(setting("aimbot_fov", 60)) or 60
end

function AB:set_fov(v)
	save("aimbot_fov", v)
end

-- meters, 0 = unlimited
function AB:max_distance()
	return tonumber(setting("aimbot_distance", 50)) or 50
end

function AB:set_max_distance(v)
	save("aimbot_distance", v)
end

function AB:kill_delay()
	return tonumber(setting("auto_kill_delay", 0.5)) or 0.5
end

function AB:set_kill_delay(v)
	save("auto_kill_delay", v)
end

local function local_player()
	local player = managers.player and managers.player:player_unit()
	return alive(player) and player or nil
end

local function is_dead(unit)
	local dmg = unit:character_damage()
	if not dmg then
		return true
	end
	return type(dmg.dead) == "function" and dmg:dead() and true or false
end

local function head_pos(unit)
	local movement = unit:movement()
	if movement and type(movement.m_head_pos) == "function" then
		return movement:m_head_pos()
	end
	return nil
end

local function converted_set()
	local gs = managers.groupai and managers.groupai:state()
	return gs and type(gs.all_converted_enemies) == "function" and gs:all_converted_enemies() or {}
end

local function hostile(unit)
	local movement = unit:movement()
	local team = movement and type(movement.team) == "function" and movement:team()
	return team and team.foes and team.foes.criminal1 and true or false
end

local function is_hostage(unit)
	local brain = unit:brain()
	if brain and type(brain.is_hostage) == "function" and brain:is_hostage() then
		return true
	end
	local anim = unit:anim_data()
	return anim and (anim.hands_tied or anim.surrender) and true or false
end

-- { { unit, kind = "enemy"|"joker"|"bot"|"human" } }
function AB.candidates(player)
	local mode = AB:target_mode()
	local list = {}
	local converted = converted_set()
	for key, data in pairs(managers.enemy and managers.enemy:all_enemies() or {}) do
		local unit = data.unit
		if alive(unit) then
			if converted[key] then
				if mode ~= "enemies" then
					table.insert(list, { unit = unit, kind = "joker" })
				end
			elseif hostile(unit) and not is_hostage(unit) then
				table.insert(list, { unit = unit, kind = "enemy" })
			end
		end
	end
	if mode ~= "enemies" then
		local gs = managers.groupai and managers.groupai:state()
		if gs and type(gs.all_AI_criminals) == "function" then
			for _, data in pairs(gs:all_AI_criminals()) do
				if alive(data.unit) then
					table.insert(list, { unit = data.unit, kind = "bot" })
				end
			end
		end
	end
	if mode == "all" then
		local session = NET.session()
		if session then
			for _, peer in pairs(session:all_peers()) do
				local unit = type(peer.unit) == "function" and peer:unit() or nil
				if alive(unit) and unit ~= player then
					table.insert(list, { unit = unit, kind = "human" })
				end
			end
		end
	end
	return list
end

local function visible(from, to)
	local ray = World:raycast("ray", from, to, "slot_mask", managers.slot:get_mask("world_geometry"), "report")
	return not ray
end

-- dot product with the view direction (1 = center), or nil when the target is not valid.
local function score(entry, from, fwd, min_dot, max_sq)
	local unit = entry.unit
	if AB._ignored[unit:key()] or is_dead(unit) then
		return nil
	end
	local head = head_pos(unit)
	if not head then
		return nil
	end
	local dir = head - from
	local dist_sq = mvector3.length_sq(dir)
	if dist_sq < 1 or (max_sq and dist_sq > max_sq) then
		return nil
	end
	local dot = mvector3.dot(fwd, dir / math.sqrt(dist_sq))
	if dot < min_dot then
		return nil
	end
	if not visible(from, head) then
		return nil
	end
	return dot
end

function AB.select_target(player, t)
	local cam = player:camera()
	local from, fwd = cam:position(), cam:forward()
	local min_dot = math.cos(AB:fov() / 2)
	local max_m = AB:max_distance()
	local max_sq = max_m > 0 and (max_m * 100) ^ 2 or nil

	-- Keep the current target while it stays valid: no jitter between two close targets.
	local current = AB._target
	if current and alive(current.unit) and score(current, from, fwd, min_dot, max_sq) then
		return current
	end
	local best, best_dot
	for _, entry in ipairs(AB.candidates(player)) do
		local dot = score(entry, from, fwd, min_dot, max_sq)
		if dot and (not best_dot or dot > best_dot) then
			best, best_dot = entry, dot
		end
	end
	if best and (not current or current.unit ~= best.unit) then
		AB._target_changed_t = t
	end
	return best
end

local function aim_at(player, target)
	local head = head_pos(target.unit)
	if not head then
		return
	end
	local cam = player:camera()
	local camera_unit = cam and cam:camera_unit()
	local fp_base = camera_unit and camera_unit:base()
	if not fp_base or type(fp_base.set_spin) ~= "function" or type(fp_base.set_pitch) ~= "function" then
		return
	end
	local dir = head - cam:position()
	if mvector3.length_sq(dir) < 1 then
		return
	end
	mvector3.normalize(dir)
	local rot = Rotation(dir, math.UP)
	fp_base:set_spin(dir:to_polar().spin)
	fp_base:set_pitch(math.clamp(rot:pitch(), -85, 85))
end

-- Auto Kill ------------------------------------------------------------------------------------

local function kill_host(target, player)
	local dmg = target.unit:character_damage()
	if target.kind == "bot" then
		if type(dmg.force_custody) == "function" then
			dmg:force_custody()
			return true
		end
		return false, "no force_custody"
	end
	if type(dmg.damage_mission) ~= "function" then
		return false, "no damage_mission"
	end
	dmg:damage_mission({
		damage = 1000,
		attacker_unit = player
	})
	return true
end

local function kill_client(target, player)
	if target.kind ~= "enemy" then
		return false, "client: host-simulated unit"
	end
	local unit = target.unit
	local dmg = unit:character_damage()
	local weapon = player:inventory() and player:inventory():equipped_unit()
	if not alive(weapon) or type(dmg.damage_bullet) ~= "function" then
		return false, "no weapon"
	end
	local from = player:camera():position()
	local head = head_pos(unit) or unit:position()
	local dir = head - from
	local distance = dir:length()
	mvector3.normalize(dir)
	local body = dmg._head_body_name and unit:body(dmg._head_body_name) or nil
	dmg:damage_bullet({
		damage = math.max((dmg._HEALTH_INIT or 1000) * 10, 100000),
		attacker_unit = player,
		weapon_unit = weapon,
		origin = from,
		armor_piercing = true,
		col_ray = {
			unit = unit,
			body = body,
			position = head,
			ray = dir,
			normal = -dir,
			distance = distance
		}
	})
	return true
end

function AB.try_kill(target, player, t)
	if target.kind == "human" then
		if not AB._human_logged then
			AB._human_logged = true
			log("[Aimbot] Auto Kill skips human players (no native friendly damage path)")
		end
		AB._ignored[target.unit:key()] = t + AB.KILL_IGNORE_TIME
		return
	end
	local ok, done, reason
	if NET.is_host() then
		ok, done, reason = pcall(kill_host, target, player)
	else
		ok, done, reason = pcall(kill_client, target, player)
	end
	if not ok then
		log("[Aimbot] Auto Kill error: " .. tostring(done))
	elseif not done and not AB._reason_logged then
		AB._reason_logged = true
		log("[Aimbot] Auto Kill skipped: " .. tostring(reason))
	end
	-- One attempt per target: if it survived (mission invulnerable, clamp...), move on.
	AB._ignored[target.unit:key()] = t + AB.KILL_IGNORE_TIME
	AB._target = nil
end

function AB.update(t, dt)
	if not AB:is_enabled() then
		AB._target = nil
		return
	end
	local player = local_player()
	if not player then
		AB._target = nil
		return
	end
	local state = managers.player:current_state()
	if not AB.AIM_STATES[state] then
		return
	end
	for key, until_t in pairs(AB._ignored) do
		if t >= until_t then
			AB._ignored[key] = nil
		end
	end
	if not AB._next_select_t or t >= AB._next_select_t or (AB._target and not alive(AB._target.unit)) then
		AB._next_select_t = t + AB.RESELECT_INTERVAL
		AB._target = AB.select_target(player, t)
	end
	local target = AB._target
	if not target or not alive(target.unit) then
		AB._target = nil
		return
	end
	aim_at(player, target)
	if AB:auto_kill_enabled() and NET.available("auto_kill") and (not AB._next_kill_t or t >= AB._next_kill_t) then
		AB._next_kill_t = t + AB:kill_delay()
		AB.try_kill(target, player, t)
	end
end

function AB.reset()
	AB._target = nil
	AB._ignored = {}
	AB._next_kill_t = nil
	AB._next_select_t = nil
end

if not AB._update_hooked and Hooks then
	AB._update_hooked = true
	Hooks:Add("GameSetupUpdate", "FMMT_AimbotUpdate", function(t, dt)
		if not AB:is_enabled() then
			return
		end
		local ok, err = pcall(AB.update, t, dt)
		if not ok and not AB._error_logged then
			AB._error_logged = true
			log("[Aimbot] error: " .. tostring(err))
		end
	end)
end

return AB
