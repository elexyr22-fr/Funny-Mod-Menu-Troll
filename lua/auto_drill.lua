-- FunnyMod.AutoDrill (V15): mission devices close to the local player are PLACED and RESTARTED
-- through the game's own code, via the common engine FunnyMod.AutoActions (auto_actions.lua)
-- and FunnyMod.RealInteract (real_interact.lua). Verified in the 248.2 source:
--
--   V14 never worked in game: `local RI = FunnyMod.RealInteract or dofile(...)` was nil (SuperBLT
--   dofile returns nothing) -> "auto_drill.lua:286: attempt to index upvalue 'RI'" every 0.3 s
--   (log 2026-09-30, 4377 times). V15 reads FunnyMod.RealInteract at call time.
--
--   Devices: units with a TimerGui (lib/units/props/timergui.lua). Drill = class(UnitBase)
--   (lib/units/props/drill.lua) is the base of drills, saws (is_saw) and hacking devices
--   (is_hacking_device). Before placement the device already exists on the door / computer
--   (hidden) with its placement interaction active: MissionDoorDeviceInteractionExt
--   (interactionext.lua:2571; tweak ids drill, lance, apartment_saw, hack_ipad, ...). Mission C4 /
--   shaped charges on doors use the same MissionDoorDeviceInteractionExt without TimerGui.
--
--   AUTO PLACE ("drill_place" system): the real placement interaction (RealInteract):
--     MissionDoorDeviceInteractionExt:interact -> host: server_place_mission_door_device (skill
--     upgrades, "interact" sequence -> TimerGui:start, sync_interacted, placed()) / client:
--     send_to_host("server_place_mission_door_device"), the consumption comes back in
--     result_place_mission_door_device. Timer devices without it (computers) use their
--     UseInteractionExt (sync_interacted). Works as client too.
--     Refused: device already started / done / jammed / unpowered, *_jammed and upgrade ids.
--     Confirmed: TimerGui started, or the placement interaction deactivated / changed (on a client:
--     when the host's sync_interacted arrives).
--
--   AUTO RESTART ("drill_restart" system): a jam is TimerGui:set_jammed(true) (timergui.lua:555,
--   host decides, synced): the timer stops, the *_jammed interaction is activated.
--     host + Drill base -> Drill:on_autorepair() (drill.lua:671, Kickstarter path).
--     otherwise (client, hack computer) -> the real *_jammed interaction (RealInteract), exactly the
--       manual repair.
--     Confirmed: TimerGui no longer jammed. An unpowered TimerGui (mission power cut) is never
--     touched: TimerGui:start would power it back on (timergui.lua:476).
--
-- Candidates: managers.interaction._interactive_units (active interactions only), no world scan.
-- Rate, radius, cooldown, single action per tick: the engine (auto_actions.lua).
FunnyMod = FunnyMod or {}
AutoDrill = AutoDrill or {}
FunnyMod.AutoDrill = AutoDrill
local AD = AutoDrill

AD.RADII = { 2, 5, 10, 20, 0 }
-- No second placement for this long after one (a door offering drill + saw would otherwise get
-- both before the host's answer reaches a client).
AD.PLACE_GLOBAL_DELAY = 3

local function RI()
	return FunnyMod.RealInteract or FunnyMod.require_api and FunnyMod.require_api("RealInteract", "real_interact.lua")
end

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

local function setting(key, default)
	local q = rawget(_G, "QuickEnemySpawner")
	local value = q and q.settings and q.settings[key]
	if value == nil then
		return default
	end
	return value
end

local function set_setting(key, value)
	local q = rawget(_G, "QuickEnemySpawner")
	if q and type(q.set_setting) == "function" then
		q.set_setting(key, value)
	end
end

local function net()
	return FunnyMod.Network
end

local function dlog(msg)
	local aa = FunnyMod.AutoActions
	if aa and aa.debug() then
		log("[AutoDrill] " .. msg)
	end
end

-- "auto_drill" is the V13 key: it means "Auto restart".
function AD:restart_enabled()
	return setting("auto_drill", true) and true or false
end

function AD:place_enabled()
	return setting("auto_drill_place", true) and true or false
end

function AD:is_enabled()
	return self:restart_enabled() or self:place_enabled()
end

function AD:set_restart_enabled(state)
	set_setting("auto_drill", state and true or false)
	log("[AutoDrill] Auto restart -> " .. (state and "ON" or "OFF"))
end
AD.set_enabled = AD.set_restart_enabled

function AD:set_place_enabled(state)
	set_setting("auto_drill_place", state and true or false)
	log("[AutoDrill] Auto place -> " .. (state and "ON" or "OFF"))
end

function AD:radius()
	return tonumber(setting("auto_drill_radius", 5)) or 5
end

function AD:set_radius(meters)
	set_setting("auto_drill_radius", meters)
end

local function timer_gui(unit)
	return type(unit.timer_gui) == "function" and unit:timer_gui() or nil
end

-- TimerGui state only: started, still counting, jammed, powered.
local function is_jammed_device(unit)
	local tg = timer_gui(unit)
	if not tg or not tg._jammed or not tg._started or tg._done or tg._powered == false then
		return false
	end
	return true
end
AD.is_jammed_device = is_jammed_device

local function bad_id(id, tg)
	return type(id) ~= "string" or id:find("_jammed", 1, true) or id:find("upgrade", 1, true) or (tg and id == tg._upgrade_tweak_data)
end

-- Placement interaction of a device / mission charge that has not been started yet.
-- true | false, reason
local function is_placement(unit, interaction)
	interaction = interaction or unit:interaction()
	local id = interaction and interaction.tweak_data
	local tg = timer_gui(unit)
	if tg then
		if tg._started then
			return false, "device already started"
		elseif tg._done then
			return false, "device done"
		elseif tg._jammed then
			return false, "device jammed"
		elseif tg._powered == false then
			return false, "device unpowered (mission)"
		end
		if bad_id(id, tg) then
			return false, "not a placement interaction (" .. tostring(id) .. ")"
		end
		return true
	end
	-- Mission C4 / shaped charge / door device without TimerGui.
	local ri = RI()
	if ri and ri.is_a(interaction, "MissionDoorDeviceInteractionExt") and not bad_id(id) then
		return true
	end
	return false, "no TimerGui and not a mission door device"
end
AD.is_placement = is_placement

local function has_native_repair(unit)
	local base = unit:base()
	if not base or type(base.on_autorepair) ~= "function" then
		return false, "no Drill base"
	end
	local dmg = unit:damage()
	if not dmg or type(dmg.has_sequence) ~= "function" or not dmg:has_sequence("interact") then
		return false, "no interact sequence"
	end
	-- Drill:on_autorepair ends with int_ext:check_for_upgrade(), only defined by
	-- MissionDoorDeviceInteractionExt (interactionext.lua:2669): refuse before running anything.
	local int_ext = unit:interaction()
	if not int_ext or type(int_ext.check_for_upgrade) ~= "function" then
		return false, "no device interaction"
	end
	return true
end

local function device_label(unit)
	local base = unit:base()
	if base and base.is_saw then
		return "saw"
	elseif base and base.is_hacking_device then
		return "hack"
	end
	local interaction = unit:interaction()
	local id = interaction and type(interaction.tweak_data) == "string" and interaction.tweak_data or ""
	local td = interaction and interaction._tweak_data
	if id:find("saw", 1, true) then
		return "saw"
	elseif id:find("hack", 1, true) then
		return "hack"
	elseif id:find("lance", 1, true) then
		return "thermal drill"
	elseif id:find("c4", 1, true) or id:find("shape", 1, true) or (type(td) == "table" and (td.special_equipment == "c4" or td.required_deployable == "trip_mine")) then
		return "c4"
	elseif not timer_gui(unit) then
		return "device"
	end
	return "drill"
end
AD.device_label = device_label

local function interactive_units()
	local units = managers.interaction and managers.interaction._interactive_units
	return type(units) == "table" and units or {}
end

-- Engine systems ------------------------------------------------------------------------------

local function detect_place(ctx)
	local list = {}
	if AD._place_block_t and ctx.t < AD._place_block_t then
		return list
	end
	for _, unit in ipairs(interactive_units()) do
		if alive(unit) then
			local interaction = unit:interaction()
			if interaction and interaction:active() and is_placement(unit, interaction) then
				table.insert(list, { unit = unit, priority = 1 })
			end
		end
	end
	return list
end

local function detect_restart(ctx)
	local list = {}
	for _, unit in ipairs(interactive_units()) do
		if alive(unit) and is_jammed_device(unit) then
			table.insert(list, { unit = unit, priority = 1 })
		end
	end
	return list
end

local function log_phase(kind)
	return function(phase, entry, data)
		local unit = entry.unit
		if phase == "detect" then
			dlog(string.format("%s candidate found: %s", kind, device_label(unit)))
			dlog(string.format("distance=%.1f m", entry.distance or -1))
			dlog("interaction=" .. tostring(entry.tweak))
		elseif phase == "validate" then
			dlog("can_interact=" .. tostring(data and data.result) .. (data and data.reason and (" (" .. tostring(data.reason) .. ")") or ""))
		elseif phase == "start" then
			dlog("started=" .. tostring(entry.label) .. (type(data) == "number" and string.format(" timer=%.2fs", data) or (data and (" " .. tostring(data)) or "")))
		elseif phase == "confirmed" then
			log("[AutoDrill] confirmed=" .. tostring(entry.label) .. " (" .. kind .. ", " .. tostring(data) .. ")")
		elseif phase == "failed" then
			dlog("confirmed=false " .. tostring(entry.label) .. " reason=" .. tostring(data))
		end
	end
end

AD.place_system = {
	id = "drill_place",
	mission_action = true,
	enabled = function()
		return AD:place_enabled()
	end,
	radius = function()
		return AD:radius()
	end,
	detect = detect_place,
	validate = function(unit)
		-- SecretLogger / SecretAuto (uno_5): never place a hacking device on / next to a turret.
		local secret_auto = rawget(_G, "SecretAuto")
		local interaction = alive(unit) and unit:interaction()
		if secret_auto and secret_auto.active and type(secret_auto.blocks_interaction) == "function" and secret_auto:blocks_interaction(unit, interaction and interaction.tweak_data) then
			return false, "SecretAuto: turret hack refused (uno_5)"
		end
		return is_placement(unit)
	end,
	confirmed = function(entry)
		local tg = alive(entry.unit) and timer_gui(entry.unit)
		if tg and tg._started then
			return true, "TimerGui started"
		end
		return false
	end,
	on_phase = function(phase, entry, data)
		if phase == "complete" then
			AD._place_block_t = (FunnyMod.AutoActions._t or 0) + AD.PLACE_GLOBAL_DELAY
		end
		log_phase("place")(phase, entry, data)
	end
}

AD.restart_system = {
	id = "drill_restart",
	mission_action = true,
	enabled = function()
		return AD:restart_enabled()
	end,
	radius = function()
		return AD:radius()
	end,
	detect = detect_restart,
	-- Custom START + COMPLETE: host native repair, otherwise the vanilla repair interaction.
	act = function(unit, ctx)
		local ri = RI()
		local n = net()
		if n and n.is_host() then
			local native, why = has_native_repair(unit)
			if native then
				local ok, err = pcall(unit:base().on_autorepair, unit:base())
				if not ok then
					return false, "Drill:on_autorepair error: " .. tostring(err)
				end
				return true, "host Drill:on_autorepair"
			end
			dlog("native repair unavailable (" .. tostring(why) .. "), using the repair interaction")
		end
		local can, why = ri.can_interact(unit, ctx.player)
		dlog("can_interact=" .. tostring(can) .. (can and "" or (" (" .. tostring(why) .. ")")))
		if not can then
			return false, "repair interaction: " .. tostring(why)
		end
		local ok, err = ri.trigger(unit, ctx.player)
		if not ok then
			return false, "repair interaction: " .. tostring(err)
		end
		return true, "repair interaction " .. tostring(ri.tweak_id(unit))
	end,
	generic_confirm = false,
	confirmed = function(entry)
		if not alive(entry.unit) then
			return true, "unit removed"
		end
		local tg = timer_gui(entry.unit)
		if tg and not tg._jammed then
			return true, "TimerGui unjammed"
		end
		return false
	end,
	on_phase = log_phase("restart")
}

local aa = AA()
if aa then
	aa.register(AD.place_system)
	aa.register(AD.restart_system)
end

-- V13 / V14 compatibility --------------------------------------------------------------------

-- Closest jammed device and closest placeable device in range: { unit, d } or nil each.
function AD.find(pos, max_sq, t, want_restart, want_place)
	local jam, place
	local ri = RI()
	for _, unit in ipairs(interactive_units()) do
		if alive(unit) and unit:interaction() and unit:interaction():active() then
			local d = mvector3.distance_sq(pos, ri.position(unit))
			if not max_sq or d <= max_sq then
				if want_restart and is_jammed_device(unit) then
					if not jam or d < jam.d then
						jam = { unit = unit, d = d }
					end
				elseif want_place and is_placement(unit) then
					if not place or d < place.d then
						place = { unit = unit, d = d }
					end
				end
			end
		end
	end
	return jam, place
end

function AD.candidates(pos, max_sq)
	local jam = AD.find(pos, max_sq, 0, true, false)
	return jam and { jam } or {}
end

function AD.reset()
	AD._place_block_t = nil
	local e = FunnyMod.AutoActions
	if e then
		e.reset("drill_place")
		e.reset("drill_restart")
	end
end

return AD
