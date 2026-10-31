-- Movement for the LOCAL player only (PlayerStandard / PlayerCarry are the local player states).
--   Speed mode        : PlayerStandard:_get_max_walk_speed result multiplied (walk, run, crouch...).
--                       No time scale, nothing global.
--   Ignore bag weight : PlayerCarry applies three penalties (_check_action_run, _perform_jump,
--                       _get_max_walk_speed). The game already removes all three when the player
--                       owns carry.movement_penalty_nullifier; this does exactly the same thing.
--                       Bag value, type and throwing are untouched.

PlayerSpeed = PlayerSpeed or {}
local PS = PlayerSpeed

PS.MULTIPLIERS = { 1, 1.5, 2, 3 }

local function setting(key, default)
	local qes = rawget(_G, "QuickEnemySpawner")
	if qes and qes.settings and qes.settings[key] ~= nil then
		return qes.settings[key]
	end
	return default
end

local function set_setting(key, value)
	local qes = rawget(_G, "QuickEnemySpawner")
	if qes and type(qes.set_setting) == "function" then
		qes.set_setting(key, value)
	end
end

function PS:is_enabled()
	return setting("speed_enabled", true) and true or false
end

function PS:set_enabled(state)
	set_setting("speed_enabled", state and true or false)
	log("[ModMenu] Mode vitesse -> " .. (state and "ON" or "OFF"))
end

function PS:multiplier()
	local m = setting("speed_multiplier", 1.5)
	return type(m) == "number" and m > 0 and m or 1
end

function PS:set_multiplier(m)
	set_setting("speed_multiplier", m)
	log("[ModMenu] Vitesse -> x" .. tostring(m))
end

function PS:ignores_bag_weight()
	return setting("ignore_bag_weight", true) and true or false
end

function PS:set_ignore_bag_weight(state)
	set_setting("ignore_bag_weight", state and true or false)
	log("[ModMenu] Ignorer poids des sacs -> " .. (state and "ON" or "OFF"))
end

if RequiredScript == "lib/units/beings/player/states/playerstandard" and PlayerStandard and not PS._standard_hooked then
	PS._standard_hooked = true
	local original_speed = PlayerStandard._get_max_walk_speed

	function PlayerStandard:_get_max_walk_speed(...)
		local speed = original_speed(self, ...)
		if PS:is_enabled() then
			speed = speed * PS:multiplier()
		end
		return speed
	end
end

if RequiredScript == "lib/units/beings/player/states/playercarry" and PlayerCarry and not PS._carry_hooked then
	PS._carry_hooked = true
	local original_run = PlayerCarry._check_action_run
	local original_jump = PlayerCarry._perform_jump
	local original_carry_speed = PlayerCarry._get_max_walk_speed

	function PlayerCarry:_check_action_run(...)
		if PS:ignores_bag_weight() then
			return PlayerCarry.super._check_action_run(self, ...)
		end
		return original_run(self, ...)
	end

	function PlayerCarry:_perform_jump(...)
		if PS:ignores_bag_weight() then
			return PlayerCarry.super._perform_jump(self, ...)
		end
		return original_jump(self, ...)
	end

	function PlayerCarry:_get_max_walk_speed(...)
		if PS:ignores_bag_weight() then
			return PlayerCarry.super._get_max_walk_speed(self, ...)
		end
		return original_carry_speed(self, ...)
	end
end
