-- No Pagers (host / solo, stealth only). The pager is created by CopBrain:begin_alarm_pager,
-- which the game only calls when unit_data().has_alarm_pager is true:
--   CopLogicInactive._set_interaction       dead guard in whisper mode
--   CopLogicIntimidated._chk_begin_alarm_pager  surrendered guard in whisper mode
-- When the flag is false, _set_interaction gives the corpse the "corpse_dispose" (body bag)
-- interaction instead, the game's own outcome for guards without a pager (the melee
-- "snatch pager" skill sets the same flag). Clearing the flag right before those two checks
-- stops the pager at the source: no pager call, no timer, no pager count used, no alarm.
-- The AI runs on the host, so the host's choice applies to the whole session. In loud
-- (whisper mode off) the game starts no pager anyway and nothing is changed.
local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")

NoPagers = NoPagers or {}
local NP = NoPagers

NP.suppressed = NP.suppressed or 0

local function setting(key, default)
	local qes = rawget(_G, "QuickEnemySpawner")
	if qes and qes.settings and qes.settings[key] ~= nil then
		return qes.settings[key]
	end
	return default
end

local function has_authority()
	return NET.is_host()
end

local function whisper_mode()
	local state = managers.groupai and managers.groupai:state()
	return state and type(state.whisper_mode) == "function" and state:whisper_mode() or false
end

function NP:is_enabled()
	return setting("no_pagers", true) and true or false
end

function NP:set_enabled(state)
	local qes = rawget(_G, "QuickEnemySpawner")
	if qes and type(qes.set_setting) == "function" then
		qes.set_setting("no_pagers", state and true or false)
	end
	log("[ModMenu] Pagers désactivés -> " .. (state and "ON" or "OFF"))
end

function NP:status()
	if not self:is_enabled() then
		return "OFF"
	end
	if not has_authority() then
		return "ON (NO EFFECT - CLIENT)"
	end
	if not whisper_mode() then
		return "BYPASSED (LOUD)"
	end
	return "ON"
end

local function suppress(unit)
	if not NP:is_enabled() or not has_authority() or not alive(unit) then
		return
	end
	if not whisper_mode() then
		if not NP._loud_logged then
			NP._loud_logged = true
			log("[NoPagers] Loud detected - bypassed")
		end
		return
	end
	local unit_data = unit:unit_data()
	if unit_data and unit_data.has_alarm_pager then
		unit_data.has_alarm_pager = false
		NP.suppressed = NP.suppressed + 1
		if NP.suppressed == 1 then
			log("[NoPagers] Pager suppressed")
		end
	end
end

if not NP._enabled_logged then
	NP._enabled_logged = true
	log("[NoPagers] Enabled")
end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicinactive" and CopLogicInactive and not NP._inactive_hooked then
	NP._inactive_hooked = true
	local original_set_interaction = CopLogicInactive._set_interaction

	CopLogicInactive._set_interaction = function(data, ...)
		if data and data.unit then
			suppress(data.unit)
		end
		return original_set_interaction(data, ...)
	end
end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicintimidated" and CopLogicIntimidated and not NP._intimidated_hooked then
	NP._intimidated_hooked = true
	local original_chk = CopLogicIntimidated._chk_begin_alarm_pager

	CopLogicIntimidated._chk_begin_alarm_pager = function(data, ...)
		if data and data.unit then
			suppress(data.unit)
		end
		return original_chk(data, ...)
	end
end
