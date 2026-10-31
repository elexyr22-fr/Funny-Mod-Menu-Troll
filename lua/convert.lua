-- FunnyMod.Convert (alias EnemyConvert): turn living enemies into Jokers (host only).
--
-- Native path, verified in 248.2 lib/managers/group_ai_states/groupaistatebase.lua
-- GroupAIStateBase:convert_hostage_to_criminal(unit, nil). It does everything the game needs so
-- GroupAI stays consistent (a bare brain:convert_to_criminal() does not):
--   removes the unit from its assault group (_remove_group_member), clears set_enemy_assigned,
--   u_data.is_converted, CopBrain:convert_to_criminal (logic idle, team_enemy_cbt attention,
--   criminal access, enemy slotmask, weapon re-added with TeamAIInventory, slot 16),
--   death / destroy listeners (clbk_minion_dies / clbk_minion_destroyed), "friendly" contour,
--   _set_converted_police, player's minions table, team "converted_enemy", network
--   "mark_minion" (UnitNetworkHandler:mark_minion converts the husk on every client),
--   count_up_player_minions, OnMinionAdded modifiers.
-- The only thing lifted: the minion limit. That function refuses when
--   managers.player:upgrade_value("player", "convert_enemies_max_minions", 0) <= #minions
-- (0 without the Joker skill). For the duration of that single call, upgrade_value returns a
-- large value for that one key; everything else is the vanilla function. There is no unit-type
-- filter in convert_hostage_to_criminal (the Dozer / special restriction is in the intimidation
-- interaction, which is not used here).
--
-- Pre-checks before calling it (the vanilla code would error otherwise):
--   unit registered in GroupAIState._police, not dead, not already converted, hostile to the
--   criminals (civilians are never in _police), has a ContourExt, a "mover_blocker" body and a
--   default weapon name (used by CopBrain:convert_to_criminal).
-- Convert all is batched (CONVERT_PER_FRAME per GameSetupUpdate) to avoid a network burst.
local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")

FunnyMod = FunnyMod or {}
EnemyConvert = EnemyConvert or {}
FunnyMod.Convert = EnemyConvert
local EC = EnemyConvert

EC.CONVERT_PER_FRAME = 6
EC.AIM_CONE_DEG = 12
EC.UNLIMITED_MINIONS = 100000
EC._queue = EC._queue or {}

local function state()
	return managers.groupai and managers.groupai:state()
end

local function local_player()
	local player = managers.player and managers.player:player_unit()
	return alive(player) and player or nil
end

local function is_dead(unit)
	local dmg = unit:character_damage()
	return not dmg or (type(dmg.dead) == "function" and dmg:dead()) and true or false
end

-- nil when convertible, otherwise a short reason string.
function EC.reject_reason(unit)
	if not alive(unit) then
		return "gone"
	end
	local gs = state()
	if not gs then
		return "no groupai"
	end
	local key = unit:key()
	if not (gs._police and gs._police[key]) then
		return "not an enemy"
	end
	if gs._converted_police and alive(gs._converted_police[key]) then
		return "already converted"
	end
	if is_dead(unit) then
		return "dead"
	end
	local movement = unit:movement()
	local team = movement and type(movement.team) == "function" and movement:team()
	if not (team and team.foes and team.foes.criminal1) then
		return "not hostile"
	end
	if not unit:contour() then
		return "no contour ext"
	end
	if not unit:body("mover_blocker") then
		return "no mover_blocker body"
	end
	local base = unit:base()
	if not base or type(base.default_weapon_name) ~= "function" or not base:default_weapon_name() then
		return "no default weapon"
	end
	return nil
end

local function tweak_name(unit)
	local base = unit:base()
	return base and base._tweak_table or tostring(unit:name())
end

-- Converts one unit through the native function. Returns true or false + reason.
function EC.convert(unit)
	if not NET.is_host() then
		return false, "host_only"
	end
	local player = local_player()
	if not player then
		return false, "no player"
	end
	local reason = EC.reject_reason(unit)
	if reason then
		return false, reason
	end
	local gs = state()
	local pm = managers.player
	local own_field = rawget(pm, "upgrade_value")
	local original = pm.upgrade_value
	pm.upgrade_value = function(self, category, upgrade, default)
		if category == "player" and upgrade == "convert_enemies_max_minions" then
			return EC.UNLIMITED_MINIONS
		end
		return original(self, category, upgrade, default)
	end
	local ok, err = pcall(gs.convert_hostage_to_criminal, gs, unit, nil)
	pm.upgrade_value = own_field
	if not ok then
		log("[Convert] " .. tweak_name(unit) .. " failed: " .. tostring(err))
		return false, "error"
	end
	if not (gs._converted_police and alive(gs._converted_police[unit:key()])) then
		return false, "refused"
	end
	log("[Convert] " .. tweak_name(unit) .. " -> Joker")
	return true
end

-- Every living hostile enemy (vanilla + QES). Civilians, players, bots, converted: skipped.
function EC.candidates()
	local list = {}
	local all = managers.enemy and managers.enemy:all_enemies()
	for _, data in pairs(all or {}) do
		if alive(data.unit) and not EC.reject_reason(data.unit) then
			table.insert(list, data.unit)
		end
	end
	return list
end

function EC.convert_all()
	if not NET.is_host() then
		log("[Convert] Convert all refused: host only")
		return 0
	end
	local list = EC.candidates()
	for _, unit in ipairs(list) do
		table.insert(EC._queue, unit)
	end
	log("[Convert] Convert all queued=" .. #list)
	return #list
end

-- The enemy under the crosshair (raycast), else the one closest to the screen center within
-- AIM_CONE_DEG.
function EC.aimed_enemy()
	local player = local_player()
	if not player then
		return nil
	end
	local cam = player:camera()
	local from, fwd = cam:position(), cam:forward()
	local to = from + fwd * 20000
	local ray = World:raycast("ray", from, to, "slot_mask", managers.slot:get_mask("bullet_impact_targets"))
	if ray and alive(ray.unit) and not EC.reject_reason(ray.unit) then
		return ray.unit
	end
	local best, best_angle
	local limit = math.cos(EC.AIM_CONE_DEG)
	for _, unit in ipairs(EC.candidates()) do
		local dir = unit:movement():m_head_pos() - from
		local dist = dir:length()
		if dist > 0 then
			local dot = mvector3.dot(fwd, dir / dist)
			if dot >= limit and (not best_angle or dot > best_angle) then
				best, best_angle = unit, dot
			end
		end
	end
	return best
end

function EC.convert_aimed()
	local unit = EC.aimed_enemy()
	if not unit then
		log("[Convert] No convertible enemy aimed")
		return false, "no target"
	end
	return EC.convert(unit)
end

function EC.pending()
	return #EC._queue
end

function EC.update()
	if #EC._queue == 0 then
		return
	end
	if not NET.is_host() then
		EC._queue = {}
		return
	end
	local done, converted = 0, 0
	while done < EC.CONVERT_PER_FRAME and #EC._queue > 0 do
		local unit = table.remove(EC._queue, 1)
		done = done + 1
		if alive(unit) then
			local ok = EC.convert(unit)
			if ok then
				converted = converted + 1
			end
		end
	end
	EC._converted_total = (EC._converted_total or 0) + converted
	if #EC._queue == 0 then
		log("[Convert] Convert all done: converted=" .. tostring(EC._converted_total))
		EC._converted_total = 0
	end
end

function EC.reset()
	EC._queue = {}
	EC._converted_total = 0
end

if not EC._update_hooked and Hooks then
	EC._update_hooked = true
	Hooks:Add("GameSetupUpdate", "FMMT_ConvertUpdate", function(t, dt)
		if #EC._queue > 0 then
			local ok, err = pcall(EC.update)
			if not ok then
				log("[Convert] update error: " .. tostring(err))
				EC._queue = {}
			end
		end
	end)
end

return EC
