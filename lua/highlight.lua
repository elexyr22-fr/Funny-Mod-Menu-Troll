-- FunnyMod.Highlight (alias ObjectHighlight): local highlight of collectibles, mission objects
-- and loot. Nothing is synced: contours are added without the sync flag and waypoints use
-- no_sync. Verified in the 248.2 source:
--
--   Gage packages are NOT interaction-only units. GageAssignmentBase = class(Pickup)
--   (lib/units/pickups/gageassignmentbase.lua). Each package registers itself in
--   GageAssignmentManager:on_unit_spawned (lib/managers/gageassignmentmanager.lua:332), into
--   managers.gage_assignment._spawned_units, or _queued_spawned_units before the assignments
--   are activated. That runs on the host AND on clients (the client list is created by
--   _activate_assignments_client). Pickups live in slot 23 (host) / 20 (client, Pickup:init),
--   so World:find_units_quick("all", 23, 20) filtered on GageAssignmentBase is the fallback
--   (same call as MenuManager, lib/managers/menumanager.lua:2158).
--   The V11 scan only read managers.interaction._interactive_units, where a package is only
--   present while its interaction is active and registered: that is why nothing was found.
--
--   Map collectibles (turtles, horseshoes...) are interactions with fixed tweak ids.
--   Mission objects: pickup_*, gen_pku_*, take_*, hold_take_*, press_pick_up*, pku_* ids, or an
--   interaction that gives a special equipment. Loot: units with carry_data() or interactions
--   blocked by "carry_block" (they give a bag).
--
-- Marking: unit:contour():add("highlight") (ContourExt._types.highlight, lib/units/contourext.lua)
-- when the unit has a ContourExt, otherwise the interaction material contour
-- (BaseInteractionExt:set_contour("selected_color", 1)) held with set_contour_override so the
-- vanilla select/unselect does not reset it. Collectibles also get a local HUD waypoint
-- (managers.hud:add_waypoint, no_sync), because a material contour is only drawn in line of
-- sight and packages are hidden on purpose.
--
-- Scan: at level start, then every SCAN_INTERVAL seconds (GameSetupUpdate), never every frame.
-- Stopped and cleared at level unload.
--
-- Instant removal (V13): every marker is tracked in OH._tracked[unit_key] = { unit, contour_id,
-- waypoint_id, ... } and removed at once, without waiting for the rescan, from the game's own
-- callbacks (248.2):
--   GageAssignmentManager:on_unit_interact(unit)  package picked up, host AND client
--                                                 (GageAssignmentBase:sync_pickup / sync_net_event)
--   Pickup:set_active(false)                      client side delete_unit (package hidden)
--   Pickup:destroy(unit)                          unit destroyed (host consume -> set_slot(0),
--                                                 World:delete_unit, or any script removal)
--   BaseInteractionExt:set_active(false)          interaction collectibles / objectives picked
--                                                 up or disabled (also called by
--                                                 BaseInteractionExt:destroy)
-- The periodic rescan stays as a fallback for stale references.
--
-- Auto pickup (V15): system "pickup" of the common engine FunnyMod.AutoActions
-- (auto_actions.lua). The closest collectible in range is picked up through its REAL interaction
-- (FunnyMod.RealInteract: interact_start -> vanilla timer -> interact_interupt(complete) ->
-- interact), never by deleting the unit. Gage package: GageAssignmentInteractionExt:interact (interactionext.lua:1370)
-- -> GageAssignmentBase:pickup -> _pickup: host = sync_pickup (on_unit_interact, progress,
-- sync_unit_event_id_16 to clients, pickup message, consume) / client = send_to_host("sync_pickup")
-- and the host validates it (UnitNetworkHandler:sync_pickup -> is_unit_an_assignment) then sends
-- the event back. So it works as client: only the vanilla request is sent, the client state
-- changes when the host's answer arrives (GageAssignmentBase:sync_net_event).
-- Map collectibles (turtle, horseshoe) are UseInteractionExt: interact + sync_interacted.
-- Strict classification: Gage packages that are real assignment units and the AUTO_PICKUP_IDS
-- below only. pick_up_item is highlighted but never auto picked (generic mission id); keycards,
-- crowbars, bags, loot, weapons, ammo are never in the collectible category.
-- V15 fixes (log + save file 2026-09-30):
--   * V14 took its candidates from OH._tracked, i.e. only when "Highlight collectibles" was ON
--     (the save had highlight_collectibles=false: no marker AND no auto pickup). V15 detects the
--     collectibles itself (OH.find_collectibles: Gage lists + interaction ids), independent of the
--     highlight option.
--   * the marker is NEVER removed when the request is sent: only when the game confirms it
--     (GageAssignmentManager:on_unit_interact / Pickup:set_active(false) / Pickup:destroy /
--     BaseInteractionExt:set_active(false), or the engine's confirmation: unit removed /
--     interaction deactivated). Host refusal / no answer -> timeout, marker kept, retry later.
--   * `local RI = ... or dofile(...)` was nil (SuperBLT's dofile returns nothing): RealInteract is
--     read at call time now.
local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")

FunnyMod = FunnyMod or {}
ObjectHighlight = ObjectHighlight or {}
FunnyMod.Highlight = ObjectHighlight
local OH = ObjectHighlight

OH.SCAN_INTERVAL = 4
OH.WAYPOINT_PREFIX = "fmmt_hl_"
OH.marked = OH.marked or {}
OH._tracked = OH.marked
OH.logged = OH.logged or {}
-- Radius choices in meters; 0 = MAX (no distance restriction).
OH.PICKUP_RADII = { 2, 5, 10, 20, 0 }

local OBJECTIVE_PREFIXES = { "pickup_", "gen_pku_", "take_", "hold_take_", "press_pick_up", "pku_", "hold_pku_" }
-- Hidden map collectibles (interaction tweak ids, lib/tweak_data/interactiontweakdata.lua).
local COLLECTIBLE_IDS = {
	gage_assignment = true,
	hold_pick_up_turtle = true,
	ranc_press_pickup_horseshoe = true,
	pick_up_item = true
}
-- Interaction collectibles that may be picked up automatically (Gage packages are recognised by
-- their GageAssignmentBase).
local AUTO_PICKUP_IDS = {
	gage_assignment = true,
	hold_pick_up_turtle = true,
	ranc_press_pickup_horseshoe = true
}

local function qes_setting(key, default)
	local qes = rawget(_G, "QuickEnemySpawner")
	local value = qes and qes.settings and qes.settings[key]
	if value == nil then
		return default
	end
	return value
end

local function set_setting(key, state)
	local qes = rawget(_G, "QuickEnemySpawner")
	if qes and type(qes.set_setting) == "function" then
		qes.set_setting(key, state and true or false)
	end
end

local function dlog(msg)
	if qes_setting("show_qes_logs", true) ~= false then
		log("[Highlight] " .. msg)
	end
end

function OH:collectibles_enabled()
	return qes_setting("highlight_collectibles", true) and true or false
end

function OH:objectives_enabled()
	return qes_setting("highlight_objectives", true) and true or false
end

function OH:loot_enabled()
	return qes_setting("highlight_loot", false) and true or false
end

function OH:auto_pickup_enabled()
	return qes_setting("auto_pickup_collectibles", true) and true or false
end

function OH:set_auto_pickup_enabled(state)
	set_setting("auto_pickup_collectibles", state)
	log("[AutoPickup] -> " .. (state and "ON" or "OFF"))
end

function OH:pickup_radius()
	return tonumber(qes_setting("auto_pickup_radius", 5)) or 5
end

function OH:set_pickup_radius(meters)
	local qes = rawget(_G, "QuickEnemySpawner")
	if qes and type(qes.set_setting) == "function" then
		qes.set_setting("auto_pickup_radius", meters)
	end
end

function OH:set_collectibles_enabled(state)
	set_setting("highlight_collectibles", state)
	OH.refresh_now()
end

function OH:set_objectives_enabled(state)
	set_setting("highlight_objectives", state)
	OH.refresh_now()
end

function OH:set_loot_enabled(state)
	set_setting("highlight_loot", state)
	OH.refresh_now()
end

local function is_gage_unit(unit)
	local gage_class = rawget(_G, "GageAssignmentBase")
	local base = unit:base()
	if not gage_class or not base then
		return false
	end
	-- Same class table, or the class' own methods (safe with any class() implementation).
	return getmetatable(base) == gage_class or (base.assignment ~= nil and base.assignment == gage_class.assignment and base.sync_pickup == gage_class.sync_pickup)
end

local function gage_available(unit)
	local base = unit:base()
	if base and (base._picked_up or base._active == false) then
		return false
	end
	return type(unit.enabled) ~= "function" or unit:enabled()
end

local function interaction_id(unit)
	local interaction = unit:interaction()
	if not interaction then
		return nil
	end
	return type(interaction.tweak_data) == "string" and interaction.tweak_data or nil, interaction
end

-- "collectible" | "objective" | "loot" | nil (units coming from the interaction list only).
local function interaction_category(unit)
	local id, interaction = interaction_id(unit)
	if not id or (type(interaction.active) == "function" and not interaction:active()) then
		return nil
	end
	if COLLECTIBLE_IDS[id] or is_gage_unit(unit) then
		return "collectible"
	end
	local td = interaction._tweak_data
	if (type(unit.carry_data) == "function" and unit:carry_data()) or (type(td) == "table" and td.blocked_hint == "carry_block") then
		return "loot"
	end
	for _, prefix in ipairs(OBJECTIVE_PREFIXES) do
		if id:sub(1, #prefix) == prefix then
			return "objective"
		end
	end
	if type(td) == "table" and td.special_equipment_block then
		return "objective"
	end
	return nil
end

local function add_waypoint(unit, key)
	if not managers.hud or type(managers.hud.add_waypoint) ~= "function" then
		return nil
	end
	local id = OH.WAYPOINT_PREFIX .. tostring(key)
	local ok = pcall(managers.hud.add_waypoint, managers.hud, id, {
		icon = "pd2_generic_look",
		distance = true,
		no_sync = true,
		present_timer = 0,
		state = "present",
		radius = 50,
		blend_mode = "add",
		color = Color(1, 0.2, 1, 0.4),
		position = unit:position()
	})
	return ok and id or nil
end

local function mark(unit, kind)
	local key = unit:key()
	if OH.marked[key] then
		return
	end
	local entry = { unit = unit, category = kind, gage = is_gage_unit(unit) }
	local contour = unit:contour()
	if contour and type(contour.add) == "function" then
		-- ContourExt:add returns the setup table, which remove_by_id takes back.
		entry.contour_id = contour:add("highlight")
		entry.kind = "contour"
	else
		local interaction = unit:interaction()
		if interaction and type(interaction.set_contour) == "function" then
			interaction:set_contour("selected_color", 1)
			if type(interaction.set_contour_override) == "function" then
				interaction:set_contour_override(true)
			end
			entry.kind = "interaction"
		end
	end
	if kind == "collectible" then
		entry.waypoint = add_waypoint(unit, key)
		entry.waypoint_id = entry.waypoint
	end
	OH.marked[key] = entry
	if not OH.logged[key] then
		OH.logged[key] = true
		if kind == "collectible" then
			dlog("Tracking collectible " .. tostring(interaction_id(unit) or (entry.gage and "gage_package") or unit:name()) .. " key=" .. tostring(key) .. (entry.waypoint and " (contour + waypoint)" or ""))
		end
		dlog("Contour added: " .. tostring(kind) .. " via " .. tostring(entry.kind or "waypoint only") .. (entry.waypoint and " + waypoint" or ""))
	end
end

local function unmark(key, entry)
	if alive(entry.unit) then
		if entry.kind == "contour" and entry.unit:contour() then
			local contour = entry.unit:contour()
			if entry.contour_id and type(contour.remove_by_id) == "function" then
				pcall(contour.remove_by_id, contour, entry.contour_id)
			else
				pcall(contour.remove, contour, "highlight")
			end
		elseif entry.kind == "interaction" and entry.unit:interaction() then
			local interaction = entry.unit:interaction()
			if type(interaction.set_contour_override) == "function" then
				pcall(interaction.set_contour_override, interaction, false)
			end
			pcall(interaction.set_contour, interaction, "standard_color")
		end
	end
	if entry.waypoint and managers.hud and type(managers.hud.remove_waypoint) == "function" then
		pcall(managers.hud.remove_waypoint, managers.hud, entry.waypoint)
	end
	OH.marked[key] = nil
end

-- { [unit_key] = { unit, kind } } of every unit that should be highlighted right now.
function OH.collect()
	local wanted = {}
	local want_c, want_o, want_l = OH:collectibles_enabled(), OH:objectives_enabled(), OH:loot_enabled()

	if want_c then
		local gm = managers.gage_assignment
		if gm then
			for _, list in ipairs({ gm._spawned_units or {}, gm._queued_spawned_units or {} }) do
				for _, unit in ipairs(list) do
					if alive(unit) and gage_available(unit) then
						wanted[unit:key()] = { unit = unit, kind = "collectible" }
					end
				end
			end
		end
		local ok, pickups = pcall(World.find_units_quick, World, "all", 23, 20)
		if ok and type(pickups) == "table" then
			for _, unit in ipairs(pickups) do
				if alive(unit) and not wanted[unit:key()] and is_gage_unit(unit) and gage_available(unit) then
					wanted[unit:key()] = { unit = unit, kind = "collectible" }
				end
			end
		end
	end

	local units = managers.interaction and managers.interaction._interactive_units
	if type(units) == "table" and (want_c or want_o or want_l) then
		for _, unit in ipairs(units) do
			if alive(unit) and not wanted[unit:key()] then
				local ok, kind = pcall(interaction_category, unit)
				if ok and kind and ((kind == "collectible" and want_c) or (kind == "objective" and want_o) or (kind == "loot" and want_l)) then
					wanted[unit:key()] = { unit = unit, kind = kind }
				end
			end
		end
	end
	return wanted
end

-- Adds new units, removes the ones that are gone, picked up or whose category was turned off.
function OH.scan_new_units()
	local wanted = OH.collect()
	for key, data in pairs(wanted) do
		local entry = OH.marked[key]
		if entry and entry.category ~= data.kind then
			unmark(key, entry)
		end
		local ok, err = pcall(mark, data.unit, data.kind)
		if not ok then
			dlog("mark failed: " .. tostring(err))
		end
	end
	for key, entry in pairs(OH.marked) do
		if not wanted[key] then
			unmark(key, entry)
		end
	end
	return wanted
end

function OH.scan_initial()
	local wanted = OH.scan_new_units()
	local collectibles = 0
	for _, data in pairs(wanted) do
		if data.kind == "collectible" then
			collectibles = collectibles + 1
		end
	end
	dlog("Total collectibles=" .. collectibles)
end

-- Compatibility with V11 callers.
OH.scan = OH.scan_new_units

local function count_collectibles()
	local n = 0
	for _, e in pairs(OH.marked) do
		if e.category == "collectible" then
			n = n + 1
		end
	end
	return n
end

-- Immediate removal of one unit's marker (reason: "picked up" | "removed"). O(1), no scan.
function OH.on_unit_gone(unit, reason)
	if not unit or not OH.marked then
		return
	end
	local ok, key = pcall(unit.key, unit)
	if not ok or key == nil then
		return
	end
	-- An automatic request is waiting for exactly this callback: confirm it first (logs
	-- "[AutoPickup] Confirmed"), its on_phase removes the marker.
	local aa = FunnyMod.AutoActions
	if aa and aa.is_pending(key) and aa.confirm_unit(unit, "game callback: " .. tostring(reason)) then
		return
	end
	local entry = OH.marked[key]
	if not entry then
		return
	end
	local ok_unmark, err = pcall(unmark, key, entry)
	if not ok_unmark then
		OH.marked[key] = nil
		dlog("unmark failed: " .. tostring(err))
	end
	if entry.category == "collectible" then
		if reason == "picked up" then
			dlog("Collectible picked up -> marker removed (collectibles=" .. count_collectibles() .. ")")
		else
			dlog("Collectible removed -> marker removed (collectibles=" .. count_collectibles() .. ")")
		end
	end
end

-- Marker removal after an automatic request was confirmed by the game.
function OH.marker_confirmed(unit, key)
	local entry = key and OH.marked[key]
	if not entry then
		return
	end
	local ok_unmark, err = pcall(unmark, key, entry)
	if not ok_unmark then
		OH.marked[key] = nil
		dlog("unmark failed: " .. tostring(err))
	end
	dlog("Marker removed after confirmed pickup (collectibles=" .. count_collectibles() .. ")")
end

function OH.refresh_now()
	OH._next_scan_t = 0
end

function OH.clear_all()
	for key, entry in pairs(OH.marked) do
		unmark(key, entry)
	end
end
OH.clear = OH.clear_all

function OH.reset()
	OH.clear_all()
	OH.marked = {}
	OH._tracked = OH.marked
	OH.logged = {}
	OH._next_scan_t = nil
	OH._initial_done = nil
	local aa = FunnyMod.AutoActions
	if aa then
		aa.reset("pickup")
	end
end

if not OH._update_hooked and Hooks then
	OH._update_hooked = true
	Hooks:Add("GameSetupUpdate", "FMMT_ObjectHighlight", function(t, dt)
		if not managers.interaction or not managers.player or not managers.player:player_unit() then
			return
		end
		if not OH._next_scan_t or t >= OH._next_scan_t then
			OH._next_scan_t = t + OH.SCAN_INTERVAL
			local ok, err = pcall(OH._initial_done and OH.scan_new_units or OH.scan_initial)
			OH._initial_done = true
			if not ok then
				log("[Highlight] scan error: " .. tostring(err))
			end
		end
	end)
end

if RequiredScript == "lib/setups/gamesetup" and GameSetup and not OH._unload_hooked then
	OH._unload_hooked = true
	Hooks:PreHook(GameSetup, "destroy", "FMMT_ObjectHighlightUnload", function()
		OH.marked = {}
		OH._tracked = OH.marked
		OH.logged = {}
		OH._next_scan_t = nil
		OH._initial_done = nil
		local aa = FunnyMod.AutoActions
		if aa then
			aa.reset()
		end
	end)
end

-- AUTO PICKUP ---------------------------------------------------------------------------------

-- Collectible that may be picked up automatically (strict classification, see header).
-- true | false, reason
local function auto_pickup_allowed_unit(unit)
	if not alive(unit) then
		return false, "unit gone"
	end
	if is_gage_unit(unit) then
		local gm = managers.gage_assignment
		if not gage_available(unit) then
			return false, "gage package already picked up / inactive"
		end
		-- Same check as the host (GageAssignmentBase:sync_pickup): a unit that is not an
		-- assignment would be consumed without any reward.
		if not (gm and type(gm.is_unit_an_assignment) == "function" and gm:is_unit_an_assignment(unit)) then
			return false, "not an active Gage assignment"
		end
		return true
	end
	local id = interaction_id(unit)
	if id and AUTO_PICKUP_IDS[id] then
		return true
	end
	return false, "not an auto-pickup collectible (" .. tostring(id) .. ")"
end
OH.auto_pickup_allowed_unit = auto_pickup_allowed_unit

-- V14 name (entry of OH._tracked).
function OH.auto_pickup_allowed(entry)
	return entry and entry.category == "collectible" and auto_pickup_allowed_unit(entry.unit) and true or false
end

-- Every collectible of the level, highlight option ON or OFF: { [key] = unit }.
-- Gage packages: managers.gage_assignment lists (host and client). Map collectibles: active
-- interactions with an AUTO_PICKUP_IDS tweak id.
function OH.find_collectibles()
	local found = {}
	local gm = managers.gage_assignment
	if gm then
		for _, list in ipairs({ gm._spawned_units or {}, gm._queued_spawned_units or {} }) do
			for _, unit in ipairs(list) do
				if alive(unit) and gage_available(unit) then
					found[unit:key()] = unit
				end
			end
		end
	end
	local units = managers.interaction and managers.interaction._interactive_units
	if type(units) == "table" then
		for _, unit in ipairs(units) do
			if alive(unit) and not found[unit:key()] then
				local id, interaction = interaction_id(unit)
				if id and (AUTO_PICKUP_IDS[id] or is_gage_unit(unit)) and interaction:active() then
					found[unit:key()] = unit
				end
			end
		end
	end
	return found
end

local function pickup_label(unit)
	return tostring(interaction_id(unit) or (is_gage_unit(unit) and "gage_package") or unit:name())
end
OH.pickup_label = pickup_label

OH.pickup_system = {
	id = "pickup",
	enabled = function()
		return OH:auto_pickup_enabled()
	end,
	radius = function()
		return OH:pickup_radius()
	end,
	detect = function(ctx)
		local list = {}
		for _, unit in pairs(OH.find_collectibles()) do
			table.insert(list, { unit = unit, priority = 1 })
		end
		return list
	end,
	validate = function(unit)
		return auto_pickup_allowed_unit(unit)
	end,
	on_phase = function(phase, entry, data)
		local unit = entry.unit
		if phase == "detect" then
			-- The unit may be deleted before the confirmation (host consume): keep its key.
			entry.unit_key = alive(unit) and unit:key() or nil
		elseif phase == "complete" then
			log(string.format("[AutoPickup] Request sent %s at %.1f m (%s) - marker kept until confirmation", alive(unit) and pickup_label(unit) or tostring(entry.label), entry.distance or -1, NET.mode()))
		elseif phase == "confirmed" then
			log("[AutoPickup] Confirmed " .. tostring(entry.label) .. " (" .. tostring(data) .. ")")
			OH.marker_confirmed(unit, entry.unit_key)
		elseif phase == "failed" then
			if entry.unit_key and OH.marked[entry.unit_key] then
				dlog("Marker kept (pickup not confirmed: " .. tostring(data) .. ")")
			end
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
		aa.register(OH.pickup_system)
	end
end

-- Instant removal hooks (see header). Each one is a table lookup when the unit is not marked.
local function has_pending_auto_action()
	local aa = FunnyMod.AutoActions
	return aa and aa._pending and next(aa._pending) ~= nil
end

local function gone(unit, reason)
	if alive(unit) and ((OH.marked and next(OH.marked) ~= nil) or has_pending_auto_action()) then
		OH.on_unit_gone(unit, reason)
	end
end

if RequiredScript == "lib/managers/gageassignmentmanager" and GageAssignmentManager and not OH._gage_hooked then
	OH._gage_hooked = true
	Hooks:PostHook(GageAssignmentManager, "on_unit_interact", "FMMT_HighlightGagePickup", function(self, unit)
		gone(unit, "picked up")
	end)
end

if RequiredScript == "lib/units/pickups/pickup" and Pickup and not OH._pickup_hooked then
	OH._pickup_hooked = true
	Hooks:PostHook(Pickup, "set_active", "FMMT_HighlightPickupInactive", function(self, active)
		if not active then
			gone(self._unit, self._picked_up and "picked up" or "removed")
		end
	end)
	Hooks:PreHook(Pickup, "destroy", "FMMT_HighlightPickupDestroy", function(self)
		gone(self._unit, self._picked_up and "picked up" or "removed")
	end)
end

if RequiredScript == "lib/units/interactions/interactionext" and BaseInteractionExt and not OH._interaction_hooked then
	OH._interaction_hooked = true
	Hooks:PostHook(BaseInteractionExt, "set_active", "FMMT_HighlightInteractionInactive", function(self, active)
		if active or not alive(self._unit) then
			return
		end
		local key = self._unit:key()
		local entry = OH.marked and OH.marked[key]
		local aa = FunnyMod.AutoActions
		-- Gage packages are followed through the Pickup / GageAssignmentManager hooks only.
		if entry and not entry.gage then
			OH.on_unit_gone(self._unit, "picked up")
		elseif not entry and aa and aa.is_pending(key) and not is_gage_unit(self._unit) then
			-- Automatic request without marker (highlight OFF, Auto Steal item): same confirmation.
			aa.confirm_unit(self._unit, "interaction deactivated by the game")
		end
	end)
end

return OH
