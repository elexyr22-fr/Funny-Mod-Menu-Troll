-- FunnyMod.AutoToolbag (V18.4): mission TOOL bags (thermal drill bag, equipment / C4 bags...).
--   PICKUP  system "toolbag_pickup" of the common engine FunnyMod.AutoActions: the bag is taken
--           through its real CarryInteractionExt interaction (FunnyMod.RealInteract), only when
--           the player carries nothing and a delivery zone that accepts that bag exists.
--   DROP    while carrying such a bag, it is dropped INTO the zone that accepts it, through the
--           vanilla PlayerManager:drop_carry (client: "server_drop_carry" RPC to the host, host:
--           server_drop_carry). Only the spawn position / direction of that vanilla throw is moved
--           to the zone (camera position / forward are read by drop_carry); the host spawns the bag
--           there and the mission's own area trigger does the rest. Nothing is spawned or
--           deleted by the mod.
--
-- Verified in 248.2:
--   lib/tweak_data/carrytweakdata.lua      tool bag carry ids (TOOL_IDS below).
--   lib/managers/mission/elementareatrigger.lua + core/.../coreelementarea.lua: a delivery zone is
--     an ElementAreaTrigger with instigator "loot"; its rules elements (ElementInstigatorRule,
--     _values.rules.loot.carry_ids, restructured to { [carry_id] = true }) say which bag it takes.
--     Only zones with an EXPLICIT carry_ids rule containing the bag are used (never a generic
--     "any loot" zone such as the secure / escape van).
--   lib/managers/playermanager.lua:5250   drop_carry -> camera position / rotation / forward.
--   PlayerManager:server_drop_carry (5299) does not check the position (verify_carry only).
-- Both parts are mission actions (mission_action / AutoActions.allow_mission_actions): host
-- always, client only once loud.
FunnyMod = FunnyMod or {}
AutoToolbag = AutoToolbag or {}
FunnyMod.AutoToolbag = AutoToolbag
local AT = AutoToolbag

AT.RADII = { 5, 10, 20, 50, 0 }
AT.ZONE_REFRESH = 3
AT.DROP_INTERVAL = 0.5
AT.DROP_COOLDOWN = 4
AT.TOOL_IDS = {
	lance_bag = true,
	lance_bag_large = true,
	equipment_bag = true,
	equipment_bag_global_event = true,
	breaching_charges = true,
	winch_part = true,
	winch_part_2 = true,
	winch_part_3 = true,
	turret_part = true,
	drk_bomb_part = true
}

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

local function AA()
	return FunnyMod.AutoActions
end

local function dlog(msg)
	local aa = AA()
	if aa and aa.debug() then
		log("[AutoToolbag] " .. msg)
	end
end

function AT:is_enabled()
	return setting("auto_toolbag", true) and true or false
end

function AT:set_enabled(state)
	set_setting("auto_toolbag", state and true or false)
	log("[AutoToolbag] -> " .. (state and "ON" or "OFF"))
	if not state and AA() then
		AA().reset("toolbag_pickup")
	end
end

function AT:radius()
	return tonumber(setting("auto_toolbag_radius", 0)) or 0
end

function AT:set_radius(meters)
	set_setting("auto_toolbag_radius", meters)
end

-- ZONES ----------------------------------------------------------------------------------------

local function all_elements()
	local list = {}
	local mm = managers.mission
	if not mm then
		return list
	end
	local scripts = type(mm.scripts) == "function" and mm:scripts() or mm._scripts or {}
	for _, script in pairs(scripts) do
		local elements = type(script.elements) == "function" and script:elements() or script._elements or {}
		for _, element in pairs(elements) do
			table.insert(list, element)
		end
	end
	return list
end

-- { [carry_id] = true } accepted by an area trigger through explicit carry_ids rules, or nil.
local function accepted_ids(element)
	local rules = element._rules_elements
	if type(rules) ~= "table" or #rules == 0 then
		return nil
	end
	local ids
	for _, rule in ipairs(rules) do
		local v = rule._values
		local loot = v and v.enabled ~= false and type(v.rules) == "table" and v.rules.loot
		local carry = type(loot) == "table" and loot.carry_ids
		if type(carry) == "table" then
			for id, on in pairs(carry) do
				if on and AT.TOOL_IDS[id] then
					ids = ids or {}
					ids[id] = true
				end
			end
		end
	end
	return ids
end

local function shapes_of(element)
	local list = {}
	for _, s in ipairs(element._shapes or {}) do
		table.insert(list, s)
	end
	for _, se in ipairs(element._shape_elements or {}) do
		if type(se.get_shapes) == "function" then
			for _, s in ipairs(se:get_shapes()) do
				table.insert(list, s)
			end
		end
	end
	return list
end

local function inside(element, pos)
	if type(element._is_inside) == "function" then
		return element:_is_inside(pos)
	end
	return type(element.is_inside) == "function" and element:is_inside(pos)
end

-- A point inside the zone, near its floor (ShapeBox: position = corner, extents along x/y/z).
local function drop_point(element)
	for _, shape in ipairs(shapes_of(element)) do
		local pos = type(shape.position) == "function" and shape:position()
		local p = shape._properties or {}
		if pos then
			local candidates = {}
			if p.width and p.depth then
				local rot = type(shape.rotation) == "function" and shape:rotation() or Rotation()
				local c = pos + rot:x() * (p.width / 2) + rot:y() * (p.depth / 2) + rot:z() * math.min((p.height or 100) / 2, 40)
				table.insert(candidates, c)
			end
			table.insert(candidates, pos + Vector3(0, 0, 30))
			table.insert(candidates, pos)
			for _, c in ipairs(candidates) do
				if inside(element, c) then
					return c
				end
			end
		end
	end
	return nil
end

-- Enabled delivery zones: { element, ids, point }. Cached for ZONE_REFRESH seconds.
function AT.zones(t)
	if AT._zones and t and AT._zones_t and t < AT._zones_t then
		return AT._zones
	end
	local zones = {}
	for _, element in ipairs(all_elements()) do
		local v = element._values
		if v and v.instigator == "loot" and (v.enabled or (type(element.enabled) == "function" and element:enabled())) then
			local ids = accepted_ids(element)
			if ids then
				local point = drop_point(element)
				if point then
					table.insert(zones, { element = element, ids = ids, point = point, id = element._id })
				end
			end
		end
	end
	AT._zones = zones
	AT._zones_t = (t or 0) + AT.ZONE_REFRESH
	local sig = #zones
	if AT._zones_logged ~= sig then
		AT._zones_logged = sig
		for _, z in ipairs(zones) do
			local names = {}
			for id in pairs(z.ids) do
				table.insert(names, id)
			end
			log(string.format("[AutoToolbag] delivery zone element=%s accepts=%s at %s", tostring(z.id), table.concat(names, ","), tostring(z.point)))
		end
	end
	return zones
end

function AT.zone_for(carry_id, t)
	for _, z in ipairs(AT.zones(t)) do
		if z.ids[carry_id] then
			return z
		end
	end
	return nil
end

local function in_accepting_zone(unit, carry_id, t)
	local pos = unit:position()
	for _, z in ipairs(AT.zones(t)) do
		if z.ids[carry_id] and inside(z.element, pos) then
			return true
		end
	end
	return false
end

-- PICKUP ---------------------------------------------------------------------------------------

local function bag_id(unit)
	local cd = alive(unit) and type(unit.carry_data) == "function" and unit:carry_data()
	return cd and type(cd.carry_id) == "function" and cd:carry_id() or nil
end

AT.pickup_system = {
	id = "toolbag_pickup",
	mission_action = true,
	enabled = function()
		return AT:is_enabled()
	end,
	radius = function()
		return AT:radius()
	end,
	detect = function(ctx)
		local list = {}
		if not managers.player or managers.player:is_carrying() then
			return list
		end
		local units = managers.interaction and managers.interaction._interactive_units
		if type(units) ~= "table" then
			return list
		end
		local ri = FunnyMod.RealInteract
		for _, unit in ipairs(units) do
			local carry_id = bag_id(unit)
			if carry_id and AT.TOOL_IDS[carry_id] then
				local ix = unit:interaction()
				if ix and ix:active() and ri.is_a(ix, "CarryInteractionExt")
					and (not ctx.max_sq or mvector3.distance_sq(ctx.pos, ri.position(unit)) <= ctx.max_sq)
					and AT.zone_for(carry_id, ctx.t) and not in_accepting_zone(unit, carry_id, ctx.t) then
					table.insert(list, { unit = unit, priority = 1, info = carry_id })
				end
			end
		end
		return list
	end,
	validate = function(unit, ctx)
		if managers.player:is_carrying() then
			return false, "already carrying"
		end
		local carry_id = bag_id(unit)
		return carry_id ~= nil and AT.TOOL_IDS[carry_id] == true, "not a tool bag"
	end,
	confirmed = function(entry)
		if managers.player:is_carrying() and managers.player:current_carry_id() == entry.info then
			return true, "carrying " .. tostring(entry.info)
		end
		return false
	end,
	on_phase = function(phase, entry, data)
		if phase == "complete" then
			log(string.format("[AutoToolbag] pickup request sent bag=%s at %.1f m", tostring(entry.info), entry.distance or -1))
		elseif phase == "confirmed" then
			log("[AutoToolbag] picked up bag=" .. tostring(entry.info) .. " (" .. tostring(data) .. ")")
		elseif phase == "failed" then
			dlog("pickup not done bag=" .. tostring(entry.info) .. " reason=" .. tostring(data))
		end
	end
}

-- DROP -----------------------------------------------------------------------------------------

-- Vanilla drop_carry with the camera position / forward of this one call moved to the zone.
local function drop_into(point)
	local player = managers.player:player_unit()
	local cam = alive(player) and player:camera()
	if not cam then
		return false, "no camera"
	end
	local down = Vector3(0, 0, -1)
	local had_pos, had_fwd = rawget(cam, "position"), rawget(cam, "forward")
	cam.position = function()
		return point
	end
	cam.forward = function()
		return down
	end
	local ok, err = pcall(managers.player.drop_carry, managers.player)
	cam.position, cam.forward = had_pos, had_fwd
	return ok, err
end

function AT.update(t)
	if not AT:is_enabled() or (AT._next_drop_t and t < AT._next_drop_t) then
		return
	end
	AT._next_drop_t = t + AT.DROP_INTERVAL
	local pm = managers.player
	if not pm or not pm:is_carrying() then
		return
	end
	local carry_id = pm:current_carry_id()
	if not carry_id or not AT.TOOL_IDS[carry_id] then
		return
	end
	local aa = AA()
	if aa and type(aa.allow_mission_actions) == "function" and not aa.allow_mission_actions() then
		return
	end
	if AT._drop_block_t and t < AT._drop_block_t then
		return
	end
	local zone = AT.zone_for(carry_id, t)
	if not zone then
		if AT._no_zone_logged ~= carry_id then
			AT._no_zone_logged = carry_id
			log("[AutoToolbag] carrying " .. carry_id .. ": no enabled delivery zone accepts it (kept)")
		end
		return
	end
	local player = pm:player_unit()
	local radius = AT:radius()
	if radius > 0 and alive(player) and mvector3.distance(player:position(), zone.point) > radius * 100 then
		return
	end
	AT._no_zone_logged = nil
	AT._drop_block_t = t + AT.DROP_COOLDOWN
	local ok, err = drop_into(zone.point)
	log(string.format("[AutoToolbag] drop bag=%s into zone element=%s %s", carry_id, tostring(zone.id), ok and "(vanilla drop_carry sent)" or ("FAILED " .. tostring(err))))
end

function AT.reset()
	AT._zones, AT._zones_t, AT._zones_logged = nil, nil, nil
	AT._next_drop_t, AT._drop_block_t, AT._no_zone_logged = nil, nil, nil
	if AA() then
		AA().reset("toolbag_pickup")
	end
end

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
		aa.register(AT.pickup_system)
	end
end

if not AT._update_hooked and Hooks then
	AT._update_hooked = true
	Hooks:Add("GameSetupUpdate", "FMMT_AutoToolbagUpdate", function(t, dt)
		if not managers.player or not managers.player:player_unit() or not (FunnyMod.AutoActions and FunnyMod.AutoActions.in_active_game()) then
			return
		end
		local ok, err = pcall(AT.update, t)
		if not ok and not AT._error then
			AT._error = true
			log("[AutoToolbag] error: " .. tostring(err))
		end
	end)
end

return AT
