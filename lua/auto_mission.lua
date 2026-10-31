-- FunnyMod.AutoMission (V18): system "mission" of the common engine FunnyMod.AutoActions.
-- "Actions de mission automatiques": the mission interactions that ALREADY exist, are ACTIVE and
-- are in range are run through their real interaction (FunnyMod.RealInteract), exactly like the
-- local player holding the interact key. Nothing is invented, spawned or deleted.
--
-- Strict classification (whitelist, everything else is ignored):
--   MISSION_C4        MissionDoorDeviceInteractionExt, C4 / shaped charge slot
--   MISSION_DRILL     MissionDoorDeviceInteractionExt / TimerGui placement: drill, saw, thermal
--   MISSION_HACK      hacking device placement, hack interactions (UseInteractionExt)
--   MISSION_DOOR      other MissionDoorDeviceInteractionExt placements (ECM on ATM, ...)
--   MISSION_DEVICE    TimerGui placement without door device (computers), install / connect /
--                     plug / attach ids (UseInteractionExt)
--   MISSION_INSERT    UseInteractionExt that consumes a special equipment (keycard slot, insert
--                     an item) or insert / place ids
--   MISSION_TERMINAL  UseInteractionExt computer / laptop / terminal / keypad / server ids
-- Never: loot bags (carry), pickups (Auto Steal), weapons, civilians / enemies / hostages,
-- deployables, cameras, vehicles, revive, keep_active interactions (would be re-triggered),
-- and ANY escape / extraction id (never ends the mission).
--
-- Network (248.2): MissionDoorDeviceInteractionExt:interact -> client: send_to_host
-- "server_place_mission_door_device" (the host places, consumption comes back); UseInteractionExt
-- -> "interact" sequence + sync_interacted. Both are the manual client paths: works as client, the
-- host decides. Mission C4 timer: the placement timer is already 0.05 s when "Instant placement"
-- is ON (instant_place.lua, BaseInteractionExt:_get_timer for placement interactions).
-- When Auto drill "place" is ON, drill / C4 / door placements stay with that system (its global
-- delay); this system then only does the rest.
FunnyMod = FunnyMod or {}
AutoMission = AutoMission or {}
FunnyMod.AutoMission = AutoMission
local AM = AutoMission

AM.RADII = { 2, 5, 10, 20, 0 }
-- Seconds between two mission actions (a mission sequence gets time to run / sync).
AM.GLOBAL_DELAY = 1.5
AM.LOCKPICK_DELAY = 0.1
AM.PRIORITY = {
	MISSION_C4 = 1,
	MISSION_DRILL = 1,
	MISSION_HACK = 1,
	MISSION_DOOR = 1,
	MISSION_DEVICE = 2,
	MISSION_INSERT = 2,
	MISSION_TERMINAL = 3,
	MISSION_LOCKPICK = 2
}

local NEVER_CLASSES = {
	"CarryInteractionExt",
	"SpecialEquipmentInteractionExt",
	"SpecialEquipmentGiveAndTakeInteractionExt",
	"GageAssignmentInteractionExt",
	"SmallLootInteractionExt",
	"MoneyWrapInteractionExt",
	"DiamondInteractionExt",
	"ReviveInteractionExt",
	"IntimitateInteractionExt",
	"AmmoBagInteractionExt",
	"DoctorBagBaseInteractionExt",
	"GrenadeCrateInteractionExt",
	"BodyBagsBagInteractionExt",
	"C4BagInteractionExt",
	"MultipleEquipmentBagInteractionExt",
	"SentryGunInteractionExt",
	"SentryGunFireModeInteractionExt",
	"TripMineInteractionExt",
	"ECMJammerInteractionExt",
	"SecurityCameraInteractionExt",
	"AccessCameraInteractionExt",
	"ZipLineInteractionExt",
	"DrivingInteractionExt",
	"PlayerTurretInteractionExt",
	"LootBankInteractionExt",
	"CivilianHeisterInteractionExt",
	"SafehouseNPCInteractionExt",
	"MultipleChoiceInteractionExt"
}
-- Substrings of tweak ids that are never touched (escape / end of mission, loot, people, weapons).
local NEVER_IDS = {
	"escape", "extract", "exit", "leave", "getaway", "end_", "finish", "secure",
	"bag", "loot", "carry", "pku", "pickup", "pick_up", "take_", "grab",
	"weapon", "gun", "ammo", "hostage", "civ", "corpse", "body", "revive", "free_", "pager",
	"answer", "intimidate", "vehicle", "drive", "zipline", "camera"
}
local TERMINAL_IDS = { "computer", "laptop", "terminal", "keyboard", "keypad", "server", "pc_", "_pc", "monitor" }
local HACK_IDS = { "hack" }
local INSERT_IDS = { "insert", "place_", "put_", "use_key", "keycard_slot", "card_reader" }
-- Breakin' Feds:
--   open_axis_rvd  opens a security box panel (invisible_interaction_open_axis_rvd) before
--   cut_wire       hold_cut_wires (objective "disable the security boxes")
--   relay / phone / email   the ways to lure Garrett out (hold_relay_locke = cut the power)
--   turn_off_light hold_turn_off_light
--   disable_alarm / remove_cover / hold_open_door   Garrett's code lock, the cover hiding his safe, its door
-- No Mercy: check_file   hold_check_file (find the right patient's file)
local DEVICE_IDS = { "install", "connect", "plug", "attach", "hook_", "setup", "set_up", "cut_wire", "turn_off_light", "open_axis_rvd", "relay", "phone", "email", "disable_alarm", "remove_cover", "hold_open_door", "check_file" }

local function RI()
	return FunnyMod.RealInteract or FunnyMod.require_api and FunnyMod.require_api("RealInteract", "real_interact.lua")
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

local function dlog(msg)
	local aa = FunnyMod.AutoActions
	if aa and aa.debug() then
		log("[AutoMission] " .. msg)
	end
end

function AM:is_enabled()
	return setting("auto_mission", true) and true or false
end

function AM:set_enabled(state)
	set_setting("auto_mission", state and true or false)
	log("[AutoMission] Actions de mission automatiques -> " .. (state and "ON" or "OFF"))
	if not state and FunnyMod.AutoActions then
		FunnyMod.AutoActions.reset("mission")
	end
end

function AM:radius()
	return tonumber(setting("auto_mission_radius", 5)) or 5
end

function AM:set_radius(meters)
	set_setting("auto_mission_radius", meters)
end

local function contains_any(id, list)
	for _, part in ipairs(list) do
		if id:find(part, 1, true) then
			return true
		end
	end
	return false
end

local function is_any(ri, interaction, classes)
	for _, name in ipairs(classes) do
		if ri.is_a(interaction, name) then
			return true, name
		end
	end
	return false
end

local function door_device_category(unit)
	local ad = FunnyMod.AutoDrill
	local label = ad and type(ad.device_label) == "function" and ad.device_label(unit) or "device"
	if label == "c4" then
		return "MISSION_C4"
	elseif label == "hack" then
		return "MISSION_HACK"
	elseif label == "drill" or label == "saw" or label == "thermal drill" then
		return "MISSION_DRILL"
	end
	return "MISSION_DOOR"
end

-- "Find the right computer" (Car Shop): several identical active interactions, the mission picked
-- ONE at random. A wrong one is re-enabled by the mission after use, the right one starts the hack.
AM.PICK_ONE_IDS = { security_station_keyboard = true }
AM.PICK_ONE_STATIC_LEVELS = { cage = true }
AM.PICK_ONE_SETTLE = 5

local function now()
	return FunnyMod.AutoActions and FunnyMod.AutoActions._t or 0
end

local function pick_state()
	if AM._pick_owner ~= managers.mission or not AM._pick then
		AM._pick_owner = managers.mission
		AM._pick = { tried = {}, found = nil, diag = {}, trig_index = nil, last_right = nil }
	end
	return AM._pick
end

-- unit editor id -> { { el = ElementUnitSequenceTrigger, seq = "interact" }, ... }
local function trigger_index(P)
	if P.trig_index then
		return P.trig_index
	end
	local index = {}
	for _, script in pairs(managers.mission and managers.mission._scripts or {}) do
		for _, el in pairs(script._elements or {}) do
			local v = type(el) == "table" and el._values
			if type(v) == "table" and type(v.sequence_list) == "table" then
				for _, d in ipairs(v.sequence_list) do
					if d.unit_id then
						index[d.unit_id] = index[d.unit_id] or {}
						table.insert(index[d.unit_id], { el = el, seq = d.sequence })
					end
				end
			end
		end
	end
	P.trig_index = index
	return index
end

local function unit_editor_id(unit)
	local ud = unit.unit_data and unit:unit_data()
	return ud and ud.unit_id
end

local function element_label(el)
	return string.format("%s#%s(%s)", tostring(el._editor_name), tostring(el._id), el._values and el._values.enabled and "on" or "off")
end

-- Score of a computer from the mission triggers on its interaction: enabled triggers, and the
-- editor names (correct / right vs wrong / fake) when the level designer named them.
local function pc_score(P, unit)
	local list = trigger_index(P)[unit_editor_id(unit)] or {}
	local enabled, named = 0, 0
	for _, t in ipairs(list) do
		if t.el._values and t.el._values.enabled then
			enabled = enabled + 1
			local name = tostring(t.el._editor_name):lower()
			if name:find("incorrect", 1, true) or name:find("wrong", 1, true) or name:find("fake", 1, true) then
				named = named - 1
			elseif name:find("correct", 1, true) or name:find("right", 1, true) then
				named = named + 1
			end
		end
	end
	return named * 100 + enabled, list
end

local function group_units(id)
	local out = {}
	for _, u in ipairs(managers.interaction and managers.interaction._interactive_units or {}) do
		local i = alive(u) and u:interaction()
		if i and type(i.tweak_data) == "string" and i.tweak_data:lower() == id then
			table.insert(out, u)
		end
	end
	return out
end

-- unit key of the computer the mission picked, or nil when the data does not single one out.
function AM.find_right_pc(id)
	local P = pick_state()
	local units = group_units(id)
	if #units < 2 then
		return nil
	end
	local best, best_score, second = nil, -math.huge, -math.huge
	for _, u in ipairs(units) do
		local score, list = pc_score(P, u)
		if not P.diag[u:key()] then
			P.diag[u:key()] = true
			local parts = {}
			for _, t in ipairs(list) do
				local nexts = {}
				for _, p in ipairs(t.el._values.on_executed or {}) do
					local target = t.el._mission_script and t.el._mission_script:element(p.id)
					table.insert(nexts, target and element_label(target) or tostring(p.id))
				end
				table.insert(parts, string.format("%s seq=%s -> [%s]", element_label(t.el), tostring(t.seq), table.concat(nexts, ", ")))
			end
			log(string.format("[AutoMission] pick-one %s unit=%s editor_id=%s score=%d triggers: %s", id, tostring(u:key()), tostring(unit_editor_id(u)), score, #parts > 0 and table.concat(parts, " | ") or "none"))
		end
		if score > best_score then
			best, second, best_score = u, best_score, score
		elseif score > second then
			second = score
		end
	end
	local right = best and best_score > second and best:key() or nil
	if right ~= P.last_right then
		P.last_right = right
		log(string.format("[AutoMission] pick-one %s: %s", id, right and ("right computer = " .. tostring(right) .. " at " .. tostring(best:position())) or "mission data does not single one out, learning mode"))
	end
	return right
end

-- true | false, reason
function AM.pick_one_allowed(unit, id)
	local P = pick_state()
	local key = unit:key()
	local t = now()
	for k, tried in pairs(P.tried) do
		local i = alive(tried.unit) and tried.unit:interaction()
		if i and (not i:active() or tostring(i.tweak_data):lower() ~= tried.id) and t - tried.t > AM.PICK_ONE_SETTLE and not P.found then
			P.found = k
			log("[AutoMission] pick-one " .. id .. ": right computer confirmed (stayed used) unit=" .. tostring(k))
		end
	end
	if P.found then
		return false, "right computer already found"
	end
	if P.tried[key] then
		return false, "wrong computer (re-enabled by the mission after use)"
	end
	local level = managers.job and managers.job:current_level_id()
	if AM.PICK_ONE_STATIC_LEVELS[level] then
		local right = AM.find_right_pc(id)
		if right and right ~= key then
			return false, "not the computer picked by the mission"
		end
	end
	return true
end

function AM.pick_one_used(unit)
	local i = alive(unit) and unit:interaction()
	local id = i and type(i.tweak_data) == "string" and i.tweak_data:lower()
	if id and AM.PICK_ONE_IDS[id] then
		pick_state().tried[unit:key()] = { unit = unit, id = id, t = now() }
	end
end

-- category | nil, reason
function AM.classify(unit)
	local ri = RI()
	local interaction = alive(unit) and unit:interaction()
	if not ri or not interaction then
		return nil, "no interaction"
	end
	local id = type(interaction.tweak_data) == "string" and interaction.tweak_data:lower() or ""
	local td = type(interaction._tweak_data) == "table" and interaction._tweak_data or {}
	if contains_any(id, { "escape", "extract", "getaway" }) then
		return nil, "escape / extraction"
	end
	-- SecretLogger / SecretAuto (uno_5): turrets must be destroyed, never hacked.
	local secret_auto = rawget(_G, "SecretAuto")
	if secret_auto and secret_auto.active and type(secret_auto.blocks_interaction) == "function" and secret_auto:blocks_interaction(unit, id) then
		return nil, "SecretAuto: turret hack refused (uno_5)"
	end
	-- Diagnostic: each computer interaction type once (which ones are decoys on this map).
	if id:find("computer", 1, true) then
		AM._seen_computer_ids = AM._seen_computer_ids or {}
		if not AM._seen_computer_ids[id] then
			AM._seen_computer_ids[id] = true
			log(string.format("[AutoMission] computer interaction type: %s (special_equipment=%s)", id, tostring(td.special_equipment)))
		end
	end
	-- No Mercy: taking the blood sample (SpecialEquipmentInteractionExt, hold_take_sample) is a
	-- mission step, not loot: allowed before the class exclusion below.
	if id:find("take_sample", 1, true) then
		return "MISSION_DEVICE"
	end
	local never, class_name = is_any(ri, interaction, NEVER_CLASSES)
	if never then
		return nil, "excluded class " .. tostring(class_name)
	end
	if (type(unit.carry_data) == "function" and unit:carry_data()) or td.blocked_hint == "carry_block" then
		return nil, "loot bag"
	end
	if id:find("_jammed", 1, true) or id:find("upgrade", 1, true) then
		return nil, "repair / upgrade (Auto drill restart)"
	end
	-- Decoys: the game locks the wrong computers (Car Shop / Big Bank "find the right PC":
	-- big_computer_not_hackable) with special_equipment "nothing". Only the right one is run.
	if td.special_equipment == "nothing" or id:find("not_hackable", 1, true) or id:find("unhackable", 1, true) then
		return nil, "decoy (wrong computer)"
	end
	if id:find("computer_hackable", 1, true) and not (AM._right_pc_logged and AM._right_pc_logged[unit:key()]) then
		AM._right_pc_logged = AM._right_pc_logged or {}
		AM._right_pc_logged[unit:key()] = true
		log(string.format("[AutoMission] right computer found (%s) at %s", id, tostring(unit:position())))
	end
	-- Placements (door devices, TimerGui devices).
	local ad = FunnyMod.AutoDrill
	local placement = ad and type(ad.is_placement) == "function" and ad.is_placement(unit, interaction)
	if ri.is_a(interaction, "MissionDoorDeviceInteractionExt") then
		return placement and door_device_category(unit) or nil, "door device not placeable"
	end
	if placement then
		return contains_any(id, HACK_IDS) and "MISSION_HACK" or "MISSION_DEVICE"
	end
	-- V18.3: lock picking (doors, lockers, safes...). 248.2 interactiontweakdata: every lockpick tweak
	-- has is_lockpicking = true (pick_lock_easy / _hard / _no_skill / _30 / _deposit_transport,
	-- lockpick_locker, man_trunk_picklock, ...), plus the *pick_lock* clones of later heists.
	-- cant_pick_lock / lockpick_int_off / no_interact are "locked" hints, never picked.
	if td.is_lockpicking or ((id:find("pick_lock", 1, true) or id:find("picklock", 1, true)) and not id:find("cant_", 1, true)) then
		return "MISSION_LOCKPICK"
	end
	-- Plain mission interactions: UseInteractionExt only, one-shot (keep_active would re-trigger).
	if not ri.is_a(interaction, "UseInteractionExt") then
		return nil, "not a mission interaction class"
	end
	if td.keep_active then
		return nil, "keep_active interaction"
	end
	if contains_any(id, NEVER_IDS) then
		return nil, "excluded id " .. id
	end
	if AM.PICK_ONE_IDS[id] then
		local allowed, why = AM.pick_one_allowed(unit, id)
		if not allowed then
			return nil, why
		end
	end
	if td.special_equipment and (td.equipment_consume or contains_any(id, INSERT_IDS)) then
		return "MISSION_INSERT"
	end
	if contains_any(id, HACK_IDS) then
		return "MISSION_HACK"
	end
	if contains_any(id, TERMINAL_IDS) then
		return "MISSION_TERMINAL"
	end
	if contains_any(id, INSERT_IDS) then
		return "MISSION_INSERT"
	end
	if contains_any(id, DEVICE_IDS) then
		return "MISSION_DEVICE"
	end
	return nil, "not classified (" .. id .. ")"
end

-- Placements handled by Auto drill "place" when that option is ON.
local function owned_by_drill_system(unit, category)
	local ad = FunnyMod.AutoDrill
	if not ad or type(ad.place_enabled) ~= "function" or not ad:place_enabled() then
		return false
	end
	return category == "MISSION_C4" or category == "MISSION_DRILL" or category == "MISSION_DOOR"
		or ((category == "MISSION_HACK" or category == "MISSION_DEVICE") and type(ad.is_placement) == "function" and ad.is_placement(unit) == true)
end

AM.system = {
	id = "mission",
	mission_action = true,
	-- V18.5: scan more often (lock picks); other categories stay paced by AM.GLOBAL_DELAY.
	interval = 0.15,
	enabled = function()
		return AM:is_enabled()
	end,
	radius = function()
		return AM:radius()
	end,
	detect = function(ctx)
		local list = {}
		if AM._block_t and ctx.t < AM._block_t then
			return list
		end
		local units = managers.interaction and managers.interaction._interactive_units
		if type(units) ~= "table" then
			return list
		end
		local ri = RI()
		for _, unit in ipairs(units) do
			if alive(unit) then
				local interaction = unit:interaction()
				if interaction and interaction:active() and (not ctx.max_sq or mvector3.distance_sq(ctx.pos, ri.position(unit)) <= ctx.max_sq) then
					local category = AM.classify(unit)
					if category and not owned_by_drill_system(unit, category) then
						table.insert(list, { unit = unit, priority = AM.PRIORITY[category] or 3, info = category })
					end
				end
			end
		end
		return list
	end,
	validate = function(unit, ctx, candidate)
		local category, why = AM.classify(unit)
		return category ~= nil, why
	end,
	confirmed = function(entry)
		local unit = entry.unit
		local tg = alive(unit) and type(unit.timer_gui) == "function" and unit:timer_gui()
		if tg and tg._started then
			return true, "TimerGui started"
		end
		return false
	end,
	on_phase = function(phase, entry, data)
		if phase == "detect" then
			local n = FunnyMod.Network
			entry.mode = n and n.mode() or "?"
			dlog(string.format("candidate %s unit=%s at %.1f m (%s)", tostring(entry.info), tostring(entry.label), entry.distance or -1, entry.mode))
		elseif phase == "complete" then
			AM.pick_one_used(entry.unit)
			-- V18.5: lock picks chain fast (no mission sequence to wait for); other actions keep 1.5 s.
			local delay = entry.info == "MISSION_LOCKPICK" and AM.LOCKPICK_DELAY or AM.GLOBAL_DELAY
			AM._block_t = (FunnyMod.AutoActions._t or 0) + delay
			log(string.format("[AutoMission] %s %s unit=%s (%s)", entry.mode == "CLIENT" and "client request sent" or "action", tostring(entry.info), tostring(entry.label), tostring(entry.mode)))
		elseif phase == "confirmed" then
			log(string.format("[AutoMission] confirmed %s unit=%s (%s)", tostring(entry.info), tostring(entry.label), tostring(data)))
		end
	end
}

do
	local aa = FunnyMod.AutoActions
	if not aa then
		local base = ModPath or (FunnyModMenu and FunnyModMenu.path) or ""
		if not FunnyMod.RealInteract then
			pcall(dofile, base .. "lua/real_interact.lua")
		end
		pcall(dofile, base .. "lua/auto_actions.lua")
		aa = FunnyMod.AutoActions
	end
	if aa then
		aa.register(AM.system)
	end
end

function AM.reset()
	AM._block_t = nil
	local e = FunnyMod.AutoActions
	if e then
		e.reset("mission")
	end
end

return AM
