-- FunnyMod.InstantPlace (V15): "Pose instantanée objets". Only the DURATION of a placement the
-- player starts on purpose is shortened to INSTANT_TIMER (0.05 s); the placement itself stays the
-- game's own code (no unit is spawned by the mod). Verified in the 248.2 source:
--
--   Deployables (ammo bag, doctor bag, first aid kit, ECM, sentry, trip mine, body bags, grenade
--   case...): PlayerStandard:_start_action_use_item (playerstandard.lua:3281) reads
--   PlayerManager:selected_equipment_deploy_timer() (playermanager.lua:4488); when the timer ends
--   PlayerStandard:_update_use_item_timers -> _end_action_use_item(valid) ->
--   PlayerManager:use_selected_equipment (placement check, deployable ownership, network request
--   to the host, count). Hooked: selected_equipment_deploy_timer only (min(timer, 0.05)); the
--   progress bar, placement validity, sounds and sync_teammate_progress stay vanilla.
--
--   Mission devices (drill, saw, thermal drill, hacking device, mission C4 / shaped charge, other
--   door devices): their placement is an interaction (MissionDoorDeviceInteractionExt, or a
--   TimerGui device's placement interaction). Its hold time is BaseInteractionExt:_get_timer
--   (interactionext.lua:497): wrapped for placement interactions only, min(timer, 0.05). 0.05, not
--   0: a timer of exactly 0 makes interact_start skip _at_interact_start (mission callbacks).
--   The rest (can_interact, interact, server_place_mission_door_device / sync_interacted, skill
--   upgrades, consumption, ownership) is untouched.
--
-- Network: both timers run on the local player's game only (the host never re-checks a placement
-- duration), so this works as client too ("local"). Independent from "Instant interactions"
-- (interactions.lua), which shortens every interaction.
FunnyMod = FunnyMod or {}
InstantPlace = InstantPlace or {}
FunnyMod.InstantPlace = InstantPlace
local IP = InstantPlace

IP.INSTANT_TIMER = 0.05

local function setting(key, default)
	local q = rawget(_G, "QuickEnemySpawner")
	local value = q and q.settings and q.settings[key]
	if value == nil then
		return default
	end
	return value
end

function IP:is_enabled()
	return setting("instant_place", true) and true or false
end

function IP:set_enabled(state)
	local q = rawget(_G, "QuickEnemySpawner")
	if q and type(q.set_setting) == "function" then
		q.set_setting("instant_place", state and true or false)
	end
	log("[InstantPlace] -> " .. (state and "ON" or "OFF"))
end

local function is_a(object, class_name)
	local ri = FunnyMod.RealInteract
	if ri and ri.is_a then
		return ri.is_a(object, class_name)
	end
	local class = rawget(_G, class_name)
	local mt = getmetatable(object)
	while type(mt) == "table" do
		if mt == class then
			return true
		end
		mt = rawget(mt, "super")
	end
	return false
end

-- Placement interaction of a mission device (not a repair / upgrade).
function IP.is_placement_interaction(interaction)
	local id = type(interaction.tweak_data) == "string" and interaction.tweak_data or ""
	if id:find("_jammed", 1, true) or id:find("upgrade", 1, true) then
		return false
	end
	if is_a(interaction, "MissionDoorDeviceInteractionExt") then
		return true
	end
	local unit = interaction._unit
	local tg = alive(unit) and type(unit.timer_gui) == "function" and unit:timer_gui()
	return tg and not tg._started and not tg._done and id ~= tg._upgrade_tweak_data and true or false
end

if RequiredScript == "lib/managers/playermanager" and PlayerManager and not IP._deploy_hooked then
	IP._deploy_hooked = true
	local original_deploy_timer = PlayerManager.selected_equipment_deploy_timer
	function PlayerManager:selected_equipment_deploy_timer(...)
		local timer = original_deploy_timer(self, ...)
		if type(timer) == "number" and timer > IP.INSTANT_TIMER and IP:is_enabled() then
			return IP.INSTANT_TIMER
		end
		return timer
	end
end

if RequiredScript == "lib/units/interactions/interactionext" and BaseInteractionExt and not IP._interaction_hooked then
	IP._interaction_hooked = true
	local original_get_timer = BaseInteractionExt._get_timer
	function BaseInteractionExt:_get_timer(...)
		local timer = original_get_timer(self, ...)
		if type(timer) == "number" and timer > IP.INSTANT_TIMER and IP:is_enabled() then
			local ok, placement = pcall(IP.is_placement_interaction, self)
			if ok and placement then
				return IP.INSTANT_TIMER
			end
		end
		return timer
	end
end

return IP
