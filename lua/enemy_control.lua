-- Enemy Control: host-only filter on vanilla enemy spawning.
-- Every vanilla enemy is produced by ElementSpawnEnemyDummy:produce, reached from:
--   GroupAIStateBesiege:_perform_group_spawning  (queued by _spawn_in_group)       group AI waves
--   GroupAIStateBesiege:_respawn_unit_for_group   (timed groups, during assaults)    group AI
--   ElementSpawnEnemyDummy:on_executed            (mission scripts: placed snipers,
--                                                  helicopter rappel SWAT, scripted specials)
--   ElementSpawnEnemyGroup:on_executed -> force_spawn_group                        mission scripts
-- _spawn_in_group callers (groupaistatebesiege.lua):
--   _upd_assault_task / _spawn_timed_group  ai_task = self._task_data.assault       ASSAULT
--   _upd_recon_tasks                        grp_objective.type = "recon_area"       RECON
--   _upd_reenforce_tasks                    grp_objective.type = "reenforce_area"   REENFORCE
--   force_spawn_group / _spawn_phalanx / snowman / piggydozer                       OTHER
-- QES spawns with World:spawn_unit and never goes through any of these functions; the
-- QuickEnemySpawner._manual_spawn_in_progress flag is still honoured everywhere.
-- Civilians (ElementSpawnCivilian), team AI (ElementSpawnTeamAI), players, loot and vehicles use
-- other elements and are never touched.
local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")

EnemyControl = EnemyControl or {}
local EC = EnemyControl

-- V18: three independent switches instead of one mode (V17 only exposed NORMAL <-> HARD, the
-- waves switch was lost):
--   EC.vanilla  "Ennemis vanilla"  OFF: no new vanilla group-AI spawns (assault, recon,
--                                  reenforce, task events). Enemies already there stay.
--   EC.waves    "Vagues"           OFF: no new assault wave spawns (assault groups, timed
--                                  respawns, phalanx). Recon / reenforce and present enemies stay.
--   EC.hard     "Blocage total"    ON: everything above + mission-scripted enemy spawns
--                                  (can break scripted objectives).
-- EC.mode / get_mode / set_mode are kept (derived) for older callers.
EC.MODES = { "NORMAL", "NO_ASSAULT", "NO_VANILLA_SPAWNS", "NO_ENEMIES_HARD" }
EC.LABELS = {
	NORMAL = "Normal",
	NO_ASSAULT = "Sans vagues d'assaut",
	NO_VANILLA_SPAWNS = "Sans spawns vanilla",
	NO_ENEMIES_HARD = "Aucun ennemi vanilla"
}

-- Never persisted: every level (new heist, restart, next day) starts with vanilla enemies ON and
-- waves ON, because a switch active while the level loads would block the guards and scripted
-- enemies it needs.
if not EC._level_reset_done then
	EC._level_reset_done = true
	EC.vanilla, EC.waves, EC.hard = true, true, false
	EC.mode = "NORMAL"
	log("[EnemyControl] Nouveau niveau -> ennemis vanilla ON, vagues ON")
end

-- Teams that are not hostile to the players; scripted spawns on these teams are never blocked.
EC.FRIENDLY_TEAMS = {
	criminal1 = true,
	converted_enemy = true,
	neutral1 = true,
	hacked_turret = true
}

function EC.is_host()
	return NET.is_host()
end

local function derive_mode()
	if EC.hard then
		return "NO_ENEMIES_HARD"
	elseif EC.vanilla == false then
		return "NO_VANILLA_SPAWNS"
	elseif EC.waves == false then
		return "NO_ASSAULT"
	end
	return "NORMAL"
end

local function changed(label, state)
	EC.mode = derive_mode()
	EC._suppressed_logged = {}
	log("[EnemyControl] " .. label .. " -> " .. (state and "ON" or "OFF") .. " (mode " .. EC.mode .. ")")
	return true
end

function EC.vanilla_enabled()
	return EC.vanilla ~= false
end

function EC.waves_enabled()
	return EC.waves ~= false
end

function EC.hard_enabled()
	return EC.hard == true
end

function EC.set_vanilla(state)
	if not EC.is_host() then
		log("[EnemyControl] Change refused: not host")
		return false
	end
	EC.vanilla = state and true or false
	return changed("Ennemis vanilla", EC.vanilla)
end

function EC.set_waves(state)
	if not EC.is_host() then
		log("[EnemyControl] Change refused: not host")
		return false
	end
	EC.waves = state and true or false
	return changed("Vagues", EC.waves)
end

function EC.set_hard(state)
	if not EC.is_host() then
		log("[EnemyControl] Change refused: not host")
		return false
	end
	EC.hard = state and true or false
	return changed("Blocage total ennemis", EC.hard)
end

function EC.get_mode()
	return derive_mode()
end

-- Old single-mode API: sets the three switches.
function EC.set_mode(mode)
	if not EC.is_host() then
		log("[EnemyControl] Mode change refused: not host")
		return false
	end
	if not table.contains(EC.MODES, mode) then
		return false
	end
	EC.hard = mode == "NO_ENEMIES_HARD"
	EC.vanilla = mode ~= "NO_VANILLA_SPAWNS" and not EC.hard
	EC.waves = mode == "NORMAL"
	return changed("Mode " .. EC.LABELS[mode], true)
end

local function qes_manual_spawn()
	local qes = rawget(_G, "QuickEnemySpawner")
	return qes and qes._manual_spawn_in_progress and true or false
end

local function assault_task(state)
	return state._task_data and state._task_data.assault
end

local function spawn_category(state, grp_objective, ai_task)
	local assault = assault_task(state)
	if ai_task ~= nil and ai_task == assault then
		return "assault"
	end
	local objective_type = grp_objective and grp_objective.type
	if objective_type == "recon_area" then
		return "recon"
	elseif objective_type == "reenforce_area" then
		return "reenforce"
	end
	return "other"
end

local function blocked(category)
	if not EC.is_host() or qes_manual_spawn() then
		return false
	end
	if EC.hard then
		return true
	end
	if category == "assault" then
		return EC.waves == false or EC.vanilla == false
	end
	if EC.vanilla == false then
		return category == "recon" or category == "reenforce" or category == "event"
	end
	return false
end

-- One line per category per assault wave, never one per unit.
local function log_suppressed(state, category)
	EC._suppressed_logged = EC._suppressed_logged or {}
	local wave = state and state._assault_number or 0
	local key = tostring(category) .. ":" .. tostring(wave)
	if not EC._suppressed_logged[key] then
		EC._suppressed_logged[key] = true
		log("[EnemyControl] " .. tostring(category) .. " spawning suppressed (mode " .. derive_mode() .. ")")
	end
end

if RequiredScript == "lib/managers/group_ai_states/groupaistatebesiege" and GroupAIStateBesiege and not EC._groupai_hooked then
	EC._groupai_hooked = true

	local original_spawn_in_group = GroupAIStateBesiege._spawn_in_group
	local original_perform_group_spawning = GroupAIStateBesiege._perform_group_spawning
	local original_respawn_unit_for_group = GroupAIStateBesiege._respawn_unit_for_group
	local original_check_spawn_phalanx = GroupAIStateBesiege._check_spawn_phalanx
	local original_try_spawn_event = GroupAIStateBesiege._try_use_task_spawn_event

	-- Returning nil is a native outcome of _spawn_in_group (special-unit limit branch), and every
	-- caller already handles it.
	function GroupAIStateBesiege:_spawn_in_group(spawn_group, spawn_group_type, grp_objective, ai_task, ...)
		local category = spawn_category(self, grp_objective, ai_task)
		if blocked(category) then
			log_suppressed(self, category)
			return nil
		end
		local group = original_spawn_in_group(self, spawn_group, spawn_group_type, grp_objective, ai_task, ...)
		local task = self._spawning_groups and self._spawning_groups[#self._spawning_groups]
		if task and task.spawn_group == spawn_group then
			task.qes_category = category
		end
		return group
	end

	-- Groups queued before the mode changed are closed the way the game closes a finished task:
	-- has_spawned = true, removed from _spawning_groups, empty group deleted.
	function GroupAIStateBesiege:_perform_group_spawning(spawn_task, force, use_last, ...)
		if spawn_task and blocked(spawn_task.qes_category or "other") then
			log_suppressed(self, spawn_task.qes_category or "other")
			local list = self._spawning_groups
			for i = #list, 1, -1 do
				if list[i] == spawn_task then
					table.remove(list, i)
					break
				end
			end
			if spawn_task.group then
				spawn_task.group.has_spawned = true
				if spawn_task.group.size <= 0 then
					self._groups[spawn_task.group.id] = nil
				end
			end
			return
		end
		return original_perform_group_spawning(self, spawn_task, force, use_last, ...)
	end

	-- false is the native "no spawn group found" result.
	if original_respawn_unit_for_group then
		function GroupAIStateBesiege:_respawn_unit_for_group(...)
			if blocked("assault") then
				log_suppressed(self, "assault")
				return false
			end
			return original_respawn_unit_for_group(self, ...)
		end
	end

	function GroupAIStateBesiege:_check_spawn_phalanx(...)
		if blocked("assault") then
			return
		end
		return original_check_spawn_phalanx(self, ...)
	end

	if original_try_spawn_event then
		function GroupAIStateBesiege:_try_use_task_spawn_event(t, target_area, task_type, ...)
			local category = task_type == "assault" and "assault" or "event"
			if blocked(category) then
				log_suppressed(self, category)
				return
			end
			return original_try_spawn_event(self, t, target_area, task_type, ...)
		end
	end
end

-- Hard mode only: mission-scripted enemy spawns. Returning early is what these elements do
-- themselves when disabled or when AI is off.
local function scripted_spawn_blocked(element)
	if not EC.hard or not EC.is_host() or qes_manual_spawn() then
		return false
	end
	local team = element._values and element._values.team
	if team and EC.FRIENDLY_TEAMS[team] then
		return false
	end
	return true
end

if RequiredScript == "lib/managers/mission/elementspawnenemydummy" and ElementSpawnEnemyDummy and not EC._dummy_hooked then
	EC._dummy_hooked = true
	local original_on_executed = ElementSpawnEnemyDummy.on_executed

	function ElementSpawnEnemyDummy:on_executed(...)
		if scripted_spawn_blocked(self) then
			log_suppressed(nil, "scripted enemy")
			return
		end
		return original_on_executed(self, ...)
	end
end

if RequiredScript == "lib/managers/mission/elementspawnenemygroup" and ElementSpawnEnemyGroup and not EC._group_hooked then
	EC._group_hooked = true
	local original_on_executed = ElementSpawnEnemyGroup.on_executed

	function ElementSpawnEnemyGroup:on_executed(...)
		if scripted_spawn_blocked(self) then
			log_suppressed(nil, "scripted enemy group")
			return
		end
		return original_on_executed(self, ...)
	end
end
