--[[
	SecretAuto - AUTO COMPLETE - SECRET ACHIEVEMENT (generic, one handler per achievement).

	Common facts (decompiled game code):
	  * uno_5 and tag_10 are not in tweak_data.achievement: each level's mission script awards them
	    with an ElementAwardAchievment (_values.achievment) -> managers.achievment:award(). The mission
	    script is binary level data, so it is read at runtime: the award element is found, every
	    element that executes / targets it is logged, and its "enabled" flag is watched.
	  * Nothing here calls award(), changes achievement data or skips mission elements.

	uno_5 (Henry's Rock, level "des", OVERKILL+):
	  SentryGunDamage:die() -> parent sequence "done_turret_destroyed"; disable() (hack) ->
	  "done_turret_disabled". Turrets are destroyed with the real player gunshot path
	  (SentryGunDamage:damage_bullet) and FunnyMod automation may not hack near them.

	tag_10 (Breakin' Feds, level "tag"):
	  ContourExt:add/remove of a contour type with trigger_marked_event (mark_unit, mark_enemy, ...)
	  calls ContourExt:_chk_mission_marked_events -> unit_data().mission_element:event("marked" /
	  "unmarked"), heard by ElementEnemyDummyTrigger elements (_values.event). "unmarked" is only sent
	  when the LAST marking contour goes away; re-adding the same type only pushes its fadeout_t.
	  Garrett = the unit whose spawn element is watched by a marked / unmarked trigger. The mark is
	  added when the tracking starts (trigger armed or Garrett leaves his spot) and refreshed before
	  its fadeout, so the game never sends "unmarked". A real "unmarked" is detected and pauses all.
]]

SecretAuto = SecretAuto or {}
local SA = SecretAuto

local function say(msg)
	msg = "[SecretAuto] " .. tostring(msg)
	log(msg)

	local f = io.open((SecretLogger and SecretLogger.debug_path) or "mods/SecretLogger/logs/debug.txt", "a")

	if f then
		f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. msg .. "\n")
		f:close()
	end
end

local function hint(msg)
	if managers.hud then
		pcall(managers.hud.show_hint, managers.hud, { text = msg, time = 4 })
	end
end

SA.say, SA.hint = say, hint

-- ---------------------------------------------------------------------------------------------
-- Observer hooks (loaded with the game files they hook). They only log / set flags.
-- ---------------------------------------------------------------------------------------------
local required = type(RequiredScript) == "string" and RequiredScript:lower() or ""

if required == "lib/units/equipment/sentry_gun/sentrygundamage" then
	if SentryGunDamage and not SA._sgd_hooked then
		SA._sgd_hooked = true

		Hooks:PreHook(SentryGunDamage, "disable", "SecretAuto_SentryGunDamage_disable", function(self)
			if SA.active then
				SA.state.turret_disabled = (SA.state.turret_disabled or 0) + 1
				say("ATTENTION: a turret was DISABLED (hack path, done_turret_disabled) - uno_5 may be lost")
			end
		end)

		Hooks:PostHook(SentryGunDamage, "die", "SecretAuto_SentryGunDamage_die", function(self, attacker_unit, variant, options)
			if SA.active then
				say("Turret died: sequence_done=" .. tostring(options and options.sequence_done or "done_turret_destroyed") .. " variant=" .. tostring(variant))
			end
		end)
	end

	return
elseif required == "lib/managers/lootmanager" then
	if LootManager and not SA._loot_hooked then
		SA._loot_hooked = true

		-- Observer: the game's own loot securing (ElementCarry "secure" -> LootManager:secure).
		Hooks:PostHook(LootManager, "secure", "SecretAuto_LootManager_secure", function(self, carry_id)
			local h = SA.active and SA.handler

			if h and h.on_loot_secured then
				pcall(h.on_loot_secured, h, SA.state, carry_id)
			end
		end)
	end

	return
elseif required == "lib/units/contourext" then
	if ContourExt and not SA._contour_hooked then
		SA._contour_hooked = true

		-- Same test as the game: the event is sent only when no other marking contour remains.
		Hooks:PreHook(ContourExt, "_chk_mission_marked_events", "SecretAuto_ContourExt_marked_events", function(self, added_setup)
			if not SA.active or not SA.on_marked_event then
				return
			end

			local others = false

			for _, setup in ipairs(self._contour_list or {}) do
				if (not added_setup or setup ~= added_setup) and setup.data and setup.data.trigger_marked_event then
					others = true

					break
				end
			end

			if not others then
				pcall(SA.on_marked_event, SA, self._unit, added_setup and "marked" or "unmarked")
			end
		end)
	end

	return
end

if SA._loaded then
	return
end

SA._loaded = true
SA.TICK = 0.1
SA.active = false
SA.state = {}

-- ---------------------------------------------------------------------------------------------
-- Mission script helpers
-- ---------------------------------------------------------------------------------------------
local CLASS_OF = setmetatable({}, { __mode = "k" })

function SA.all_elements()
	local list = {}

	for _, script in pairs(managers.mission and managers.mission._scripts or {}) do
		for id, el in pairs(script._elements or {}) do
			list[id] = el
		end

		for class, group in pairs(script._element_groups or {}) do
			for _, el in ipairs(group) do
				CLASS_OF[el] = class
			end
		end
	end

	return list
end

function SA.class_of(el)
	return CLASS_OF[el] or "?"
end

function SA.describe(el)
	local v = el._values or {}
	local extra = {}

	for _, k in ipairs({ "achievment", "event", "toggle", "operation", "counter_target", "needed_to_execute", "value", "check_type", "amount", "chance", "difficulty", "sequence", "trigger_type", "global_event", "state", "objective" }) do
		if v[k] ~= nil then
			table.insert(extra, k .. "=" .. tostring(v[k]))
		end
	end

	if type(v.sequence_list) == "table" then
		for _, d in ipairs(v.sequence_list) do
			table.insert(extra, "seq[" .. tostring(d.unit_id) .. "]=" .. tostring(d.sequence))
		end
	end

	if type(v.elements) == "table" and #v.elements > 0 then
		local ids = {}

		for _, id in ipairs(v.elements) do
			table.insert(ids, tostring(id))
		end

		table.insert(extra, "elements={" .. table.concat(ids, ",") .. "}")
	end

	return string.format("#%s %s '%s' enabled=%s %s", tostring(el._id), SA.class_of(el), tostring(el._editor_name), tostring(v.enabled), table.concat(extra, " "))
end

-- Award element of the achievement + log of what executes / targets it (3 levels up).
function SA:analyze(achievement)
	local elements = self.all_elements()
	local award

	for _, el in pairs(elements) do
		if type(el._values) == "table" and el._values.achievment == achievement then
			award = el

			break
		end
	end

	if not award then
		say("Mission element awarding " .. achievement .. " NOT FOUND on this level")

		return nil, elements
	end

	local callers = {}

	for _, el in pairs(elements) do
		local v = el._values

		if type(v) == "table" then
			for _, p in ipairs(type(v.on_executed) == "table" and v.on_executed or {}) do
				callers[p.id] = callers[p.id] or {}
				table.insert(callers[p.id], { el = el, how = "executes" })
			end

			for _, id in ipairs(type(v.elements) == "table" and v.elements or {}) do
				callers[id] = callers[id] or {}
				table.insert(callers[id], { el = el, how = "targets (" .. tostring(v.toggle or v.operation or v.event or "elements") .. ")" })
			end
		end
	end

	say(achievement .. " award element: " .. self.describe(award))

	local seen = {}

	local function walk(id, depth)
		if depth > 6 then
			return
		end

		for _, c in ipairs(callers[id] or {}) do
			say(string.rep("  ", depth) .. "<- " .. c.how .. " by " .. self.describe(c.el))

			if not seen[c.el._id] then
				seen[c.el._id] = true
				walk(c.el._id, depth + 1)
			end
		end
	end

	walk(award._id, 1)
	seen[award._id] = true

	return award, elements, seen
end

-- ---------------------------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------------------------
SA.HANDLERS = {}

local OVERKILL_PLUS = { overkill_145 = "OVERKILL", easy_wish = "MAYHEM", overkill_290 = "DEATH WISH", sm_wish = "DEATH SENTENCE" }

-- uno_5 ---------------------------------------------------------------------------------------
local UNO5 = {
	id = "uno_5",
	level = "des",
	heist = "Henry's Rock",
	difficulties = OVERKILL_PLUS,
	HIT_INTERVAL = 0.2
}

SA.HANDLERS.uno_5 = UNO5

function UNO5:start(st)
	st.turrets_seen, st.next_hit, st.turret_disabled, st.turret_logged = {}, {}, 0, false
end

local function damageable_body(unit, cd)
	for i = 0, unit:num_bodies() - 1 do
		local body = unit:body(i)

		if body and body:enabled() then
			local name = body:name()

			if name ~= cd._shield_body_name_ids and not (cd._invulnerable_bodies and cd._invulnerable_bodies[name:key()]) then
				return body
			end
		end
	end
end

-- One real gunshot from the local player (SentryGunDamage:damage_bullet).
local function shoot_turret(turret)
	local cd = turret:character_damage()
	local player = managers.player:player_unit()

	if not cd or cd:dead() or cd._invulnerable or not alive(player) then
		return false
	end

	local body = damageable_body(turret, cd)

	if not body then
		return false
	end

	local from = player:movement():m_head_pos()
	local to = body:position()
	local dir = to - from

	mvector3.normalize(dir)

	local weapon = managers.player:equipped_weapon_unit()

	cd:damage_bullet({
		damage = 10000,
		attacker_unit = player,
		weapon_unit = alive(weapon) and weapon or nil,
		origin = from,
		variant = "bullet",
		armor_piercing = true,
		col_ray = { unit = turret, body = body, position = to, ray = dir, normal = -dir }
	})

	return true
end

function UNO5:tick(st, t)
	local turrets = managers.groupai:state():turrets() or {}
	local any_alive = false

	for key, turret in pairs(turrets) do
		if alive(turret) and turret:character_damage() and not turret:character_damage():dead() then
			any_alive = true
			st.turrets_seen[key] = true

			if not st.turret_logged then
				st.turret_logged = true
				say("Turret objective detected")
				say("Destroying turrets - DO NOT HACK")
			end

			if (st.next_hit[key] or 0) <= t then
				st.next_hit[key] = t + self.HIT_INTERVAL

				local ok, err = pcall(shoot_turret, turret)

				if not ok then
					say("ERROR shooting turret: " .. tostring(err))
				end
			end
		end
	end

	if not st.condition_ok and next(st.turrets_seen) and not any_alive and st.award_enabled ~= false and st.turret_disabled == 0 then
		st.condition_ok = true
		say("uno_5 condition satisfied (turrets destroyed, award element still enabled)")
		say("Continuing heist...")
	end

	st.valid = st.award_enabled ~= false and st.turret_disabled == 0
end

function UNO5:blocks_interaction(st, unit, id)
	if tostring(id or ""):lower():find("turret", 1, true) then
		return true
	end

	local pos = alive(unit) and unit:position()

	if pos then
		for _, turret in pairs(managers.groupai:state():turrets() or {}) do
			if alive(turret) and mvector3.distance(pos, turret:position()) < 250 then
				return true
			end
		end
	end

	return false
end

function UNO5:status(st)
	local n = 0

	for _ in pairs(st.turrets_seen or {}) do
		n = n + 1
	end

	return { "Tourelles vues : " .. n, "Tourelles piratees : " .. tostring(st.turret_disabled or 0) }
end

-- tag_10 --------------------------------------------------------------------------------------
-- Real map logic (logged 2026-10-01): award #135732 starts disabled and runs on "input_open_safe";
-- toggle 'enable' (Garrett leaves his office) arms the marked / unmarked triggers on Garrett's
-- spawn element and runs two CounterFilters on the "marked" counter: 1 -> enable_achievement_tag_10,
-- 0 -> disable_achievement_tag_10. 'unmarked' -> set_0 -> disable. So Garrett must ALREADY be
-- marked when he leaves, and no "unmarked" may reach an enabled trigger until the safe opens.
local TAG10 = {
	id = "tag_10",
	level = "tag",
	heist = "Breakin' Feds",
	REFRESH_MARGIN = 2.0,
	LOST_GRACE = 5
}

SA.HANDLERS.tag_10 = TAG10

-- Security boxes: their panel is only enabled by the mission when the player is near.
TAG10.SEEK = {
	objective = "heist_tag06",
	label = "security box",
	ids = { invisible_interaction_open_axis_rvd = true }
}

function TAG10:start(st, elements)
	st.watched, st.unmarked_by_spawn, st.unmarked_triggers = {}, {}, {}
	st.counters, st.counter_vals, st.known, st.types = {}, {}, {}, {}

	for _, el in pairs(elements) do
		local v = el._values

		if SA.class_of(el) == "ElementEnemyDummyTrigger" and type(v) == "table" and (v.event == "marked" or v.event == "unmarked") then
			say("Mark trigger: " .. SA.describe(el))

			for _, id in ipairs(v.elements or {}) do
				st.watched[id] = true

				if v.event == "unmarked" then
					st.unmarked_by_spawn[id] = st.unmarked_by_spawn[id] or {}
					table.insert(st.unmarked_by_spawn[id], el)
				end
			end

			if v.event == "unmarked" then
				table.insert(st.unmarked_triggers, el)
			end
		end
	end

	-- Counters read / written by the award chain (CounterFilter / CounterOperator targets).
	for id in pairs(st.chain or {}) do
		local el = elements[id]
		local class = el and SA.class_of(el)

		if class == "ElementCounterFilter" or class == "ElementCounterOperator" then
			for _, cid in ipairs(el._values.elements or {}) do
				if elements[cid] then
					st.counters[cid] = elements[cid]
				end
			end
		end
	end

	if not next(st.watched) then
		say("No marked / unmarked mission trigger found: cannot identify Garrett safely")
	end
end

function TAG10:find_units(st)
	local found = {}

	for _, getter in ipairs({ "all_civilians", "all_enemies" }) do
		local ok, list = pcall(managers.enemy[getter], managers.enemy)

		for _, data in pairs(ok and list or {}) do
			local unit = data.unit
			local ud = alive(unit) and unit:unit_data()
			local el = ud and ud.mission_element

			if el and st.watched[el._id] and not (unit:character_damage() and unit:character_damage():dead()) then
				table.insert(found, unit)
			end
		end
	end

	return found
end

local function contour_type_for(unit)
	local ok, contour_type = pcall(function()
		if managers.enemy:is_enemy(unit) then
			local base = unit:base()

			return managers.player:get_contour_for_marked_enemy(base and base.get_type and base:get_type())
		end
	end)

	return ok and contour_type or "mark_unit"
end

SA.contour_type_for = contour_type_for

local function is_marked(unit)
	local contour = alive(unit) and unit:contour()

	for _, setup in ipairs(contour and contour._contour_list or {}) do
		if setup.data and setup.data.trigger_marked_event then
			return true
		end
	end

	return false
end

-- Adds / refreshes a mark before its fadeout (ContourExt:add, synced like the player's mark).
-- Re-adding the same type only pushes fadeout_t: no "unmarked" / "marked" event in between.
local function maintain_mark(unit, contour_type, margin)
	local contour = unit:contour()

	if not contour then
		return false
	end

	local now = TimerManager:game():time()
	local current

	for _, setup in ipairs(contour._contour_list or {}) do
		if setup.type == contour_type then
			current = setup
		end
	end

	if not current or (current.fadeout_t and current.fadeout_t - now < margin) then
		contour:add(contour_type, true)
	end

	return is_marked(unit)
end

SA.maintain_mark = maintain_mark

function TAG10:tick(st, t)
	local units = self:find_units(st)

	if #units == 0 then
		if st.garrett and not st.lost_t then
			st.lost_t = t
			say("Garrett unit changed / despawned - searching...")
		end

		if st.lost_t and st.armed and not st.done and t - st.lost_t > self.LOST_GRACE and not st.paused then
			say("ERROR: Garrett not found for " .. self.LOST_GRACE .. " s during the tracking window - automation PAUSED")
			SA:pause(true)
		end

		st.garrett = nil
	else
		if st.lost_t then
			st.lost_t = nil

			if st.paused and not st.failed then
				SA:pause(false)
			end
		end

		for _, unit in ipairs(units) do
			local key = unit:key()

			if not st.known[key] then
				st.known[key] = true
				st.types[key] = contour_type_for(unit)
				say("Garrett found (spawn element #" .. tostring(unit:unit_data().mission_element._id) .. ", contour " .. st.types[key] .. ") - marking now and keeping him marked")
			end

			if not st.done then
				maintain_mark(unit, st.types[key], self.REFRESH_MARGIN)
			end
		end

		st.garrett = units[1]
	end

	-- The mission arms the tracking window by enabling the unmarked trigger(s).
	if not st.armed then
		for _, el in ipairs(st.unmarked_triggers) do
			if el._values.enabled then
				st.armed = el
			end
		end

		if st.armed then
			say("Garrett tracking started (mission armed trigger #" .. tostring(st.armed._id) .. ", Garrett marked = " .. tostring(is_marked(st.garrett)) .. ")")
		end
	end

	for id, counter in pairs(st.counters) do
		local value = counter._values.counter_target

		if value ~= st.counter_vals[id] then
			st.counter_vals[id] = value
			say("tag_10 counter #" .. tostring(id) .. " ('" .. tostring(counter._editor_name) .. "') = " .. tostring(value))
		end
	end

	local marked = st.garrett and is_marked(st.garrett) or false

	if marked ~= st.last_marked or t - (st.last_mark_log or 0) > 5 then
		st.last_marked, st.last_mark_log = marked, t
		say("Garrett marked = " .. (marked and "TRUE" or "FALSE") .. (st.armed and " (tracking)" or ""))
	end

	if st.award_enabled then
		if not st.award_ever then
			st.award_ever = true
			say("tag_10 armed by the mission (award element enabled) - condition valid, maintaining mark until the safe opens")
		end
	elseif st.award_ever and not st.done and not st.failed then
		st.failed = true
		say("FAIL: the mission disabled the tag_10 award element - condition lost")
		hint("SecretAuto : tag_10 echoue - automatisation en pause")
		SA:pause(true)
	end

	st.valid = not st.failed
end

-- Called (ContourExt hook) with the event the game is about to send for that unit.
function TAG10:on_marked_event(st, unit, event)
	local ud = alive(unit) and unit:unit_data()
	local spawn = ud and ud.mission_element

	if not spawn or not st.watched[spawn._id] then
		return
	end

	local armed = false

	for _, el in ipairs(st.unmarked_by_spawn[spawn._id] or {}) do
		if el._values.enabled then
			armed = true
		end
	end

	say("Game event on Garrett: " .. event .. (event == "unmarked" and (armed and " (unmarked trigger ENABLED)" or " (unmarked trigger disabled, no effect)") or ""))

	if event == "unmarked" and armed and not st.done then
		st.failed = true
		say("FAIL: Garrett was UNMARKED while the mission watched him - tag_10 condition lost")
		hint("SecretAuto : tag_10 echoue (Garrett n'est plus marque) - automatisation en pause")
		SA:pause(true)
	end
end

function TAG10:on_awarded(st)
	st.done = true
	say("Safe opened: the game awarded tag_10")
	say("tag_10 condition preserved")
end

function TAG10:status(st)
	return {
		"Garrett detecte : " .. (alive(st.garrett) and "OUI" or "NON"),
		"Garrett marque : " .. (is_marked(st.garrett) and "OUI" or "NON"),
		"Suivi arme par la mission : " .. (st.armed and "OUI" or "NON"),
		"Condition tag_10 encore valide : " .. ((not st.failed) and "OUI" or "NON")
	}
end

-- uno_2 ---------------------------------------------------------------------------------------
-- Diamond Store (level "family"), OVERKILL+. Awarded by the level mission script (award element
-- found and its chain logged at start). Civilians are only handled with the game's own calls:
--   intimidate  unit:brain():on_intimidated(amount, player) (PlayerStandard's shout call)
--   tie         the civilian's IntimitateInteractionExt through FunnyMod RealInteract (cable tie)
-- Loot: a store bag is picked up through its real CarryInteractionExt (RealInteract) and thrown
-- with the vanilla PlayerManager:drop_carry into the mission's secure zone (ElementAreaTrigger
-- instigator "loot" -> ElementCarry operation "secure" -> managers.loot:secure), exactly what a
-- player throwing the bag into the van does. Bags made by FunnyMod LootSpawner are ignored and
-- LootSpawner is blocked while running.
local UNO2 = {
	id = "uno_2",
	level = "family",
	heist = "Diamond Store",
	difficulties = OVERKILL_PLUS,
	CIV_INTERVAL = 0.5,
	LOOT_INTERVAL = 1.0,
	FAR_FROM_SPAWN = 2000
}

SA.HANDLERS.uno_2 = UNO2

-- Secure zones: area triggers on loot that execute an ElementCarry "secure" / "secure_silent".
local function secure_zones(elements)
	local zones = {}

	for _, el in pairs(elements) do
		local v = el._values

		if type(v) == "table" and v.instigator == "loot" then
			for _, p in ipairs(v.on_executed or {}) do
				local target = elements[p.id]
				local tv = target and target._values

				if tv and (tv.operation == "secure" or tv.operation == "secure_silent") then
					table.insert(zones, { element = el, carry = target })
				end
			end
		end
	end

	return zones
end

local function zone_point(element)
	for _, shape in ipairs(element._shapes or {}) do
		local pos = type(shape.position) == "function" and shape:position()
		local p = shape._properties or {}

		if pos then
			local candidates = {}

			if p.width and p.depth then
				local rot = type(shape.rotation) == "function" and shape:rotation() or Rotation()

				table.insert(candidates, pos + rot:x() * (p.width / 2) + rot:y() * (p.depth / 2) + rot:z() * math.min((p.height or 100) / 2, 40))
			end

			table.insert(candidates, pos + Vector3(0, 0, 30))

			for _, c in ipairs(candidates) do
				local ok, inside = pcall(element.is_inside or element._is_inside, element, c)

				if ok and inside then
					return c
				end
			end
		end
	end

	local v = element._values

	if v and v.position then
		return v.position + Vector3(0, 0, 30)
	end
end

function UNO2:start(st, elements)
	st.civs, st.civ_failed, st.loot_secured, st.known_bags = {}, nil, 0, {}

	say("Diagnosing existing hooks...")

	local ls = rawget(_G, "LootSpawner")

	if ls and type(ls.count) == "function" then
		local n = ls.count()

		say("FunnyMod LootSpawner bags on the map: " .. tostring(n) .. (n > 0 and " (NOT store loot, they are ignored)" or ""))

		-- Spawned bags are not store loot: block new ones while uno_2 runs (restored at stop).
		if type(ls.spawn) == "function" and not st.ls_spawn then
			st.ls_spawn = ls.spawn
			ls.spawn = function(...)
				say("LootSpawner blocked during uno_2 (spawned bags would mix with the store loot)")

				return false
			end
		end
	end

	for _, entry in ipairs(SA.AUTOMATION) do
		local obj = entry.obj()
		local ok, on = false, nil

		if obj and type(obj[entry.get]) == "function" then
			if entry.key then
				ok, on = pcall(obj[entry.get], obj, entry.key)
			else
				ok, on = pcall(obj[entry.get], obj)
			end
		end

		say("  FunnyMod " .. entry.label .. " = " .. tostring(ok and on))
	end

	st.zones = secure_zones(elements)

	for _, z in ipairs(st.zones) do
		local ok_point, point = pcall(zone_point, z.element)

		z.point = ok_point and point or nil
		say("Secure zone: " .. SA.describe(z.element) .. " -> " .. SA.describe(z.carry) .. " point=" .. tostring(z.point))
	end

	if #st.zones == 0 then
		say("No secure zone (loot area -> ElementCarry secure) found: bags must be thrown in the van by hand")
	end
end

function UNO2:cleanup(st)
	local ls = rawget(_G, "LootSpawner")

	if ls and st.ls_spawn then
		ls.spawn = st.ls_spawn
		st.ls_spawn = nil
	end
end

local function civ_state(unit)
	local anim = unit:anim_data() or {}
	local brain = unit:brain()
	local tied = brain and brain.is_tied and brain:is_tied()

	if tied or anim.tied then
		return "tied"
	elseif anim.drop then
		return "down"
	elseif anim.hands_up or anim.hands_back then
		return "hands_up"
	end

	return "free"
end

function UNO2:fail(st, why)
	if st.civ_failed then
		return
	end

	st.civ_failed = why
	st.valid = false
	say("UNO_2 FAILED - RESTART REQUIRED (" .. why .. ")")
	hint("UNO_2 FAILED - RESTART REQUIRED")
	SA:pause(true)
end

-- With the award element known, the mission decides (warning only, the tick fails when the
-- element gets disabled); without it, any dead / vanished civilian is a fail.
function UNO2:civ_event(st, why)
	if st.award then
		st.civ_warnings = (st.civ_warnings or 0) + 1
		say("WARNING: " .. why .. " - watching the uno_2 award element (enabled = " .. tostring(st.award._values.enabled) .. ")")
		hint("SecretAuto uno_2 : " .. why)
	else
		self:fail(st, why)
	end
end

function UNO2:civilians(st, t)
	if (st.next_civ or 0) > t then
		return
	end

	st.next_civ = t + self.CIV_INTERVAL

	local player = managers.player:player_unit()
	local ok, list = pcall(managers.enemy.all_civilians, managers.enemy)
	local seen, counts = {}, { total = 0, ok = 0, tied = 0, down = 0, hands_up = 0, free = 0 }
	local ri = FunnyMod and FunnyMod.RealInteract

	for key, data in pairs(ok and list or {}) do
		local unit = data.unit

		if alive(unit) then
			seen[key] = true

			local c = st.civs[key]

			if not c then
				c = { unit = unit, spawn = mvector3.copy(unit:position()) }
				st.civs[key] = c
			end

			c.dead = unit:character_damage() and unit:character_damage():dead()

			if c.dead then
				if not c.dead_logged then
					c.dead_logged = true
					self:civ_event(st, "a civilian died")
				end
			else
				counts.total = counts.total + 1

				local state = civ_state(unit)

				counts[state] = counts[state] + 1
				c.state = state
				c.dist = mvector3.distance(unit:position(), c.spawn)

				if c.dist > self.FAR_FROM_SPAWN and not c.far_logged then
					c.far_logged = true
					say(string.format("Civilian moved %.1f m from where he spawned (state %s) - controlling him", c.dist / 100, state))
				end

				-- Keep everyone down: shout (same call as the player's), then tie when possible.
				if state == "free" or state == "hands_up" then
					if alive(player) then
						pcall(unit:brain().on_intimidated, unit:brain(), 1, player)
					end
				elseif state == "down" and ri and ri.trigger then
					local interaction = unit:interaction()

					if interaction and interaction:active() and tostring(interaction.tweak_data):find("intimidate", 1, true) then
						pcall(ri.trigger, unit)
					end
				end

				if state ~= "free" then
					counts.ok = counts.ok + 1
				end
			end
		end
	end

	-- A civilian that disappears without dying left the map (escaped).
	for key, c in pairs(st.civs) do
		if not seen[key] and not c.gone then
			c.gone = true

			local why = (c.dead or (alive(c.unit) and c.unit:character_damage() and c.unit:character_damage():dead())) and "a civilian died" or "a civilian escaped / left the map"

			self:civ_event(st, why)
		end
	end

	local sig = counts.total .. "/" .. counts.ok

	if sig ~= st.civ_sig or t - (st.civ_log_t or 0) > 10 then
		st.civ_sig, st.civ_log_t = sig, t
		say("Civilians detected : " .. counts.total .. " (tied " .. counts.tied .. ", down " .. counts.down .. ", hands up " .. counts.hands_up .. ", free " .. counts.free .. ")")
		say("Civilian state OK : " .. counts.ok .. "/" .. counts.total)
		say("Civilian dead / escaped warnings : " .. tostring(st.civ_warnings or 0) .. " - uno_2 condition valid : " .. (st.civ_failed and "FALSE (" .. st.civ_failed .. ")" or "TRUE"))
	end
end

local function carry_id_of(unit)
	local cd = alive(unit) and unit.carry_data and unit:carry_data()

	return cd and cd.carry_id and cd:carry_id() or nil
end

local function spawned_by_mod(unit)
	local ls = rawget(_G, "LootSpawner")

	return ls and ls.spawned and ls.spawned[unit:key()] ~= nil
end

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

function UNO2:loot(st, t)
	if st.civ_failed or (st.next_loot or 0) > t then
		return
	end

	st.next_loot = t + self.LOOT_INTERVAL

	local zone

	for _, z in ipairs(st.zones or {}) do
		if z.point and z.element._values.enabled then
			zone = z

			break
		end
	end

	if not zone then
		return
	end

	local pm = managers.player

	if pm:is_carrying() then
		local carried = pm:current_carry_id()
		local ok, err = drop_into(zone.point)

		say("Securing loot: bag " .. tostring(carried) .. " thrown into secure zone #" .. tostring(zone.element._id) .. (ok and "" or (" FAILED " .. tostring(err))))

		return
	end

	local ri = FunnyMod and FunnyMod.RealInteract

	if not ri or not ri.trigger then
		return
	end

	-- Closest store bag not lying in the secure zone already.
	local player = pm:player_unit()
	local best, best_d

	for _, unit in ipairs(managers.interaction and managers.interaction._interactive_units or {}) do
		local interaction = alive(unit) and unit:interaction()
		local carry = interaction and interaction:active() and ri.is_a(interaction, "CarryInteractionExt") and carry_id_of(unit)

		if carry and not spawned_by_mod(unit) then
			local ok_in, inside = pcall(zone.element.is_inside or zone.element._is_inside, zone.element, unit:position())

			if not (ok_in and inside) then
				local d = mvector3.distance(player:position(), unit:position())

				if not best or d < best_d then
					best, best_d = unit, d
				end
			end
		end
	end

	if best then
		local ok, res, why = pcall(ri.trigger, best)

		say(string.format("Securing loot: pick up %s at %.1f m -> %s", tostring(carry_id_of(best)), best_d / 100, tostring(ok and res) .. (why and (" (" .. tostring(why) .. ")") or "")))
	end
end

-- Guards / cops: killed through FunnyMod's QES kill (CopDamage:damage_mission, the call
-- ElementSpawnEnemyDummy:kill_all_units uses: real death, listeners, sync). Civilians are never
-- in that list (managers.enemy:all_enemies) and SecretAuto-protected units are skipped.
UNO2.GUARD_INTERVAL = 3

function UNO2:guards(st, t)
	if (st.next_guard_kill or 0) > t then
		return
	end

	st.next_guard_kill = t + self.GUARD_INTERVAL

	local qes = rawget(_G, "QuickEnemySpawner")
	local ok, list = pcall(managers.enemy.all_enemies, managers.enemy)
	local n = 0

	for _, data in pairs(ok and list or {}) do
		local unit = data.unit

		if alive(unit) and unit:character_damage() and not unit:character_damage():dead() then
			n = n + 1
		end
	end

	if n > 0 and qes and type(qes.kill_vanilla) == "function" and not qes._job then
		say("Guards / enemies alive: " .. n .. " - killing them (FunnyMod kill, real death path)")
		pcall(qes.kill_vanilla)
	end
end

-- uno_2 is awarded by 'all_bags_secured' as soon as the store bag counter reaches 0, before the
-- escape. Escaping earlier ends the heist without it.
function UNO2:bag_counter(st)
	for id, counter in pairs(st.chain_counters or {}) do
		if tostring(counter._editor_name) == "logic_counter_004" or id == 102150 then
			return counter._values.counter_target
		end
	end

	return nil
end

function UNO2:tick(st, t)
	self:civilians(st, t)
	self:loot(st, t)
	pcall(self.guards, self, st, t)

	if st.escape_available and not st.awarded and t - (st.escape_hint_t or 0) > 8 then
		st.escape_hint_t = t

		local left = self:bag_counter(st)

		say("Escape is open but uno_2 is not awarded yet (store bag counter = " .. tostring(left) .. ") - DO NOT ESCAPE yet")
		hint("uno_2 : NE PARS PAS - sacs du magasin restants : " .. tostring(left))
	end
	st.valid = not st.civ_failed and st.award_enabled ~= false

	if st.award_enabled == false and st.award_was_on and not st.civ_failed then
		self:fail(st, "the mission disabled the uno_2 award element")
	end

	st.award_was_on = st.award_was_on or st.award_enabled == true
end

function UNO2:on_awarded(st)
	st.awarded = true
	say("The game awarded uno_2 (all store bags secured, no civilian left) - you can escape now")
	hint("uno_2 obtenu ! Tu peux t'enfuir")
end

function UNO2:on_loot_secured(st, carry_id)
	st.loot_secured = (st.loot_secured or 0) + 1
	say("Loot secured by the game (managers.loot:secure): " .. tostring(carry_id) .. " - total this run " .. st.loot_secured)
end

function UNO2:status(st)
	local total, ok = 0, 0

	for _, c in pairs(st.civs or {}) do
		if not c.gone and not c.dead then
			total = total + 1

			if c.state ~= "free" then
				ok = ok + 1
			end
		end
	end

	return {
		"Civils controles : " .. ok .. "/" .. total,
		"Sacs securises (cette course) : " .. tostring(st.loot_secured or 0),
		"Compteur sacs du magasin (uno_2) : " .. tostring(self:bag_counter(st)),
		"Condition uno_2 encore valide : " .. (st.civ_failed and ("NON (" .. st.civ_failed .. ")") or "OUI")
	}
end

-- No Mercy full auto (after the ICU) ----------------------------------------------------------
-- Blood test: the chance rolls the mission runs after a sample is put in the machine
-- (ElementLogicChance reachable through on_executed from the sequence triggers of the
-- press_insert_sample unit) are forced to 100 % so the first sample is validated. This changes the
-- heist's luck only; nmh_10 (no alarm before the ICU) is untouched.
SA.FORCED_CHANCE = SA.FORCED_CHANCE or {}

local function sequence_triggers_of(editor_id, elements)
	local list = {}

	for _, el in pairs(elements) do
		local v = el._values

		if type(v) == "table" and type(v.sequence_list) == "table" then
			for _, d in ipairs(v.sequence_list) do
				if d.unit_id == editor_id then
					table.insert(list, el)
				end
			end
		end
	end

	return list
end

function SA:find_blood_chances()
	local elements = self.all_elements()
	local starts, seen, found = {}, {}, {}

	local ok_units, all_units = pcall(World.find_units_quick, World, "all")

	for _, unit in ipairs(ok_units and all_units or {}) do
		local ok_i, interaction = pcall(function()
			return alive(unit) and unit:interaction()
		end)
		local id = ok_i and interaction and tostring(interaction.tweak_data) or ""

		-- Post-ICU luck steps: sample machine, taking the sample, the ICU doors to saw open.
		if id:find("insert_sample", 1, true) or id:find("take_sample", 1, true) or id:find("int_saw", 1, true) then
			local ud = unit:unit_data()

			for _, el in ipairs(sequence_triggers_of(ud and ud.unit_id, elements)) do
				table.insert(starts, { el = el, depth = 0 })
			end
		end
	end

	-- Breadth-first along on_executed, 12 steps.
	local start_count = #starts
	local queue, head = starts, 1

	while queue[head] do
		local item = queue[head]

		head = head + 1

		local el = item.el

		if el and not seen[el._id] then
			seen[el._id] = true

			if self.class_of(el) == "ElementLogicChance" then
				found[el._id] = el
			end

			if item.depth < 12 then
				for _, p in ipairs(type(el._values.on_executed) == "table" and el._values.on_executed or {}) do
					table.insert(queue, { el = elements[p.id], depth = item.depth + 1 })
				end
			end
		end
	end

	-- Fallback: chance elements named after the blood test.
	if not next(found) then
		for _, el in pairs(elements) do
			local name = tostring(el._editor_name):lower()

			if self.class_of(el) == "ElementLogicChance" and (name:find("blood", 1, true) or name:find("sample", 1, true) or name:find("infect", 1, true) or name:find("virus", 1, true) or name:find("test", 1, true)) then
				found[el._id] = el
			end
		end
	end

	return found, start_count
end

function SA:install_chance_hook()
	if self._chance_hooked then
		return
	end

	for _, el in pairs(self.all_elements()) do
		if self.class_of(el) == "ElementLogicChance" then
			local cls = getmetatable(el)

			if type(cls) == "table" and type(cls.on_executed) == "function" then
				self._chance_hooked = true

				Hooks:PreHook(cls, "on_executed", "SecretAuto_LogicChance_on_executed", function(element)
					if not SA.active or not element._values or not element._values.enabled then
						return
					end

					if SA.FORCED_CHANCE[element._id] then
						say(string.format("Luck roll #%s '%s': chance %s%% -> forced to 100%% (first try validated)", tostring(element._id), tostring(element._editor_name), tostring(element._chance)))
						element._chance = 100
					elseif SA.handler and SA.handler.id == "nmh_10" then
						say(string.format("Mission chance roll #%s '%s' at %s%% (not forced)", tostring(element._id), tostring(element._editor_name), tostring(element._chance)))
					end
				end)

				return
			end
		end
	end
end

-- Observer of ElementRandom (random picks among on_executed): logs which branch the mission took.
function SA:install_random_hook()
	if self._random_hooked then
		return
	end

	for _, el in pairs(self.all_elements()) do
		if self.class_of(el) == "ElementRandom" then
			local cls = getmetatable(el)

			if type(cls) == "table" and type(cls.on_executed) == "function" then
				self._random_hooked = true

				Hooks:PostHook(cls, "on_executed", "SecretAuto_Random_on_executed", function(element)
					if SA.active and SA.handler and SA.handler.id == "nmh_10" and element._values and element._values.enabled then
						say(string.format("Mission random pick #%s '%s' (amount %s of %d)", tostring(element._id), tostring(element._editor_name), tostring(element._values.amount or 1), #(element._original_on_executed or element._values.on_executed or {})))
					end
				end)

				return
			end
		end
	end
end

function SA:prepare_blood_test(st, t)
	if (st.blood_next or 0) > t then
		return
	end

	st.blood_next = t + 5

	local found, starts = self:find_blood_chances()
	local n = 0

	for id, el in pairs(found) do
		if not SA.FORCED_CHANCE[id] then
			SA.FORCED_CHANCE[id] = true
			say("Luck roll forced to 100%: " .. self.describe(el) .. " (from " .. starts .. " door / sample trigger(s))")
		end

		n = n + 1
	end

	-- Always installed after the ICU: every roll is logged (forced or not).
	self:install_chance_hook()
	self:install_random_hook()

	if n == 0 and not st.no_roll_logged then
		st.no_roll_logged = true
		say("No luck roll reachable from the doors / sample machine yet (watching every mission roll)")
	end
end

-- Player moved into the mission area trigger that leads (on_executed, up to 5 steps back) to the
-- element named target_name: the same area the player would walk into.
function SA:warp_to_area_leading_to(target_name)
	local elements = self.all_elements()
	local target

	for _, el in pairs(elements) do
		if el._editor_name == target_name then
			target = el
		end
	end

	if not target then
		return false, "no element '" .. target_name .. "'"
	end

	local callers = {}

	for _, el in pairs(elements) do
		for _, p in ipairs(type(el._values) == "table" and type(el._values.on_executed) == "table" and el._values.on_executed or {}) do
			callers[p.id] = callers[p.id] or {}
			table.insert(callers[p.id], el)
		end
	end

	local queue, seen, head = { { el = target, depth = 0 } }, {}, 1

	while queue[head] do
		local item = queue[head]

		head = head + 1

		if not seen[item.el._id] then
			seen[item.el._id] = true

			if item.el ~= target and self.class_of(item.el) == "ElementAreaTrigger" and item.el._values.enabled then
				local ok, point = pcall(zone_point, item.el)
				local player = managers.player:player_unit()

				if ok and point and alive(player) then
					say("Moving the player into area '" .. tostring(item.el._editor_name) .. "' #" .. tostring(item.el._id) .. " (leads to '" .. target_name .. "') at " .. tostring(point))
					pcall(managers.player.warp_to, managers.player, point, player:rotation())

					return true
				end
			end

			if item.depth < 5 then
				for _, c in ipairs(callers[item.el._id] or {}) do
					table.insert(queue, { el = c, depth = item.depth + 1 })
				end
			end
		end
	end

	return false, "no enabled area trigger leads to '" .. target_name .. "'"
end

-- Escape: the player is moved (PlayerManager:warp_to) into the mission's escape area, the
-- 'area_all_player_in_escape_basement' / 'area_all_player_in_roof_escape' triggers that give nmh_10.
SA.ESCAPE_AREAS = { "area_all_player_in_escape_basement", "area_all_player_in_roof_escape" }

function SA:auto_escape(st, t)
	if not st.escape_available or (st.escape_next or 0) > t then
		return
	end

	st.escape_next = t + 10

	for _, name in ipairs(self.ESCAPE_AREAS) do
		local area = self:chain_element_named(name)

		if area and area._values.enabled then
			local ok, point = pcall(zone_point, area)
			local player = managers.player:player_unit()

			if ok and point and alive(player) then
				say("Escape: moving the player into '" .. name .. "' at " .. tostring(point))
				pcall(managers.player.warp_to, managers.player, point, player:rotation())

				return
			end
		end
	end
end

-- Cameras: destroyed through the gunshot path (body damage_bullet / damage_damage, as
-- InstantBulletBase:on_collision does). The camera's own sequence then calls
-- SecurityCamera:generate_cooldown (statistics, mission element on_destroyed). No weapon is drawn.
SA.CAMERA_INTERVAL = 0.3

local function shoot_bodies(unit, player)
	local hit = false

	for i = 0, unit:num_bodies() - 1 do
		local body = unit:body(i)
		local ext = body and body:extension() and body:extension().damage

		if ext then
			local pos = body:position()
			local from = alive(player) and player:movement():m_head_pos() or pos + Vector3(0, 0, 100)
			local dir = pos - from

			mvector3.normalize(dir)

			local normal = -dir

			if unit:id() ~= -1 and managers.network:session() and InstantBulletBase then
				pcall(function()
					local ny, np = InstantBulletBase._get_vector_sync_yaw_pitch(normal, 128, 64)
					local dy, dp = InstantBulletBase._get_vector_sync_yaw_pitch(dir, 128, 64)

					managers.network:session():send_to_peers_synched("sync_body_damage_bullet", body, alive(player) and player:id() ~= -1 and player or nil, ny, np, pos, dy, dp, 16384)
				end)
			end

			ext:damage_bullet(player, normal, pos, dir, 1)

			if unit:alive() then
				ext:damage_damage(player, normal, pos, dir, 100)
			end

			hit = true
		end
	end

	return hit
end

function SA:destroy_cameras(t)
	local st = self.state

	if (st.next_camera or 0) > t then
		return
	end

	st.next_camera = t + self.CAMERA_INTERVAL

	local cameras = rawget(_G, "SecurityCamera") and SecurityCamera.cameras or {}
	local player = managers.player:player_unit()
	local total, destroyed, target = 0, 0, nil

	for _, unit in ipairs(cameras) do
		local base = alive(unit) and unit:base()

		if base and base.destroyed then
			total = total + 1

			if base:destroyed() then
				destroyed = destroyed + 1
			elseif not target then
				target = unit
			end
		end
	end

	if target then
		local ok, err = pcall(shoot_bodies, target, player)

		if not ok then
			say("ERROR destroying a camera: " .. tostring(err))
		end
	end

	if destroyed ~= st.cameras_destroyed or total ~= st.cameras_total then
		st.cameras_destroyed, st.cameras_total = destroyed, total
		say("Cameras destroyed : " .. destroyed .. "/" .. total)
	end
end

function SA:chain_element_named(name)
	for _, el in pairs(self.state.chain_elements or {}) do
		if el._editor_name == name then
			return el
		end
	end

	local all = self.all_elements()

	for _, el in pairs(all) do
		if el._editor_name == name then
			return el
		end
	end
end

-- nmh_10 --------------------------------------------------------------------------------------
-- No Mercy (level "nmh"), HARD+. Not in tweak_data.achievement: the level mission script awards
-- it (award element + chain logged at start, every chain element / counter watched live).
-- Alarm = GroupAIStateBase:whisper_mode() turning false (the game's own stealth flag), only READ.
-- AUTO STEALTH: Auto Mission (real interactions) with the loud placements (C4 / drill / saw) off
-- and FunnyMod's detection helpers on. Secured when the game awards nmh_10, or when an ICU
-- objective is active while still in stealth and the award element is still enabled.
-- Then AUTO COMPLETE: loud placements back on, guards handled like uno_2.
local HARD_PLUS = {
	hard = "HARD",
	overkill = "VERY HARD",
	overkill_145 = "OVERKILL",
	easy_wish = "MAYHEM",
	overkill_290 = "DEATH WISH",
	sm_wish = "DEATH SENTENCE"
}

local NMH10 = {
	id = "nmh_10",
	level = "nmh",
	heist = "No Mercy",
	difficulties = HARD_PLUS,
	ICU_WORDS = { "icu", "intensive", "soins intensifs", "unité de soins", "unite de soins" }
}

SA.HANDLERS.nmh_10 = NMH10

-- Civilians: every civilian is neutralized at once (same calls as uno_2: the player's shout
-- brain:on_intimidated, then the cable-tie interaction through RealInteract), every 0.2 s.
NMH10.CIV_INTERVAL = 0.2
NMH10.FAR_FROM_SPAWN = 2000

-- Called by the shared civilian routine: for nmh_10 a dead / vanished civilian is only logged,
-- the alarm itself (whisper mode) is what decides.
function NMH10:civ_event(st, why)
	st.civ_warnings = (st.civ_warnings or 0) + 1
	say("WARNING: " .. why)
end

local function whisper()
	local ok, gs = pcall(function()
		return managers.groupai:state()
	end)

	return ok and gs and gs.whisper_mode and gs:whisper_mode() or false
end

-- FunnyMod stealth helpers (detection side only): { get, set } on their globals.
local function stealth_helpers()
	local list = {}
	local nd = rawget(_G, "NeverDetectedV212")

	if nd and nd.set_enabled then
		table.insert(list, { label = "Never Detected", get = function() return nd.enabled end, set = function(v) nd:set_enabled(v) end })
	end

	for _, name in ipairs({ "NoStealthNoiseAlerts", "NoPlayerGunAlerts", "NoPagers" }) do
		local obj = rawget(_G, name)

		if obj and obj.set_enabled and obj.is_enabled then
			table.insert(list, { label = name, get = function() return obj:is_enabled() end, set = function(v) obj:set_enabled(v) end })
		end
	end

	return list
end

local function drill_place(state)
	local ad = FunnyMod and FunnyMod.AutoDrill

	if ad and ad.place_enabled and ad.set_place_enabled then
		local prev = ad:place_enabled()

		if state ~= nil then
			ad:set_place_enabled(state)
		end

		return prev
	end
end

function NMH10:start(st, elements)
	st.mode = "AUTO STEALTH"
	st.civs = {}
	st.alarm = not whisper()

	if st.alarm then
		local disabler = SA:chain_element_named("disable_achievement_no_alarm")
		local noalarm = SA:chain_element_named("achievement_noalarm")

		if disabler and noalarm and not disabler._values.enabled and noalarm._values.enabled then
			st.secured, st.mode, st.loud_after_icu = true, "AUTO COMPLETE", true
			say("Heist already loud but the ICU trigger already protected nmh_10 ('disable_achievement_no_alarm' off, 'achievement_noalarm' on) - resuming in AUTO COMPLETE")

			return
		end

		st.failed = "alarm already raised"
		say("NMH_10 FAILED - the heist is already loud - RESTART REQUIRED")
		hint("NMH_10 FAILED - RESTART REQUIRED")

		return
	end

	if st.award and not st.award._values.enabled then
		say("WARNING: the nmh_10 award element is disabled at start (it may be enabled later by the mission, watching it)")
	end

	st.helpers_prev = {}

	for _, h in ipairs(stealth_helpers()) do
		local ok, prev = pcall(h.get)

		st.helpers_prev[h.label] = ok and prev or false
		pcall(h.set, true)
		say("Stealth phase: FunnyMod " .. h.label .. " ON (detection side only, the alarm itself is never touched)")
	end

	say("AUTO STEALTH started")
	say("Alarm : FALSE")
end

-- Runs after SA:automation_on (which turns every FunnyMod system on): loud placements off during
-- the stealth phase. SA:automation_restore puts the player's own setting back at stop.
function NMH10:after_automation(st)
	if drill_place(false) ~= nil then
		st.drill_place_off = true
		say("Stealth phase: FunnyMod auto C4 / drill / saw placement OFF")
	end
end

function NMH10:cleanup(st)
	for _, h in ipairs(stealth_helpers()) do
		if st.helpers_prev and st.helpers_prev[h.label] ~= nil then
			pcall(h.set, st.helpers_prev[h.label])
		end
	end

	st.helpers_prev = nil
end

function NMH10:icu_objective_active()
	for id, data in pairs(managers.objectives and managers.objectives._active_objectives or {}) do
		local text = ((type(data) == "table" and tostring(data.text or "") or "") .. " " .. tostring(id)):lower()

		for _, word in ipairs(self.ICU_WORDS) do
			if text:find(word, 1, true) then
				return true, id
			end
		end
	end

	return false
end

function NMH10:secure(st, why)
	st.secured = true
	st.mode = "AUTO COMPLETE"
	say("ICU trigger detected (" .. why .. ")")
	say("ICU reached")
	say("Alarm before ICU : FALSE")
	say("nmh_10 condition secured : TRUE")
	say("Switching AUTO STEALTH -> AUTO COMPLETE")
	say("Completing remaining objectives...")
	hint("nmh_10 : ICU atteinte sans alarme - AUTO COMPLETE")

	if st.drill_place_off then
		drill_place(true)
		say("FunnyMod auto C4 / drill / saw placement back ON")
	end
end

function NMH10:tick(st, t)
	if st.failed then
		return
	end

	local loud = not whisper()

	if not st.secured then
		if loud then
			st.failed = "alarm triggered before the ICU"
			st.valid = false
			say("NMH_10 FAILED")
			say("Alarm triggered before ICU")
			say("RESTART REQUIRED")
			hint("NMH_10 FAILED - RESTART REQUIRED")
			SA:stop("NMH_10 FAILED - alarm before ICU")

			return
		end

		pcall(SA.destroy_cameras, SA, t)

		local civ_ok, civ_err = pcall(SA.HANDLERS.uno_2.civilians, self, st, t)

		if not civ_ok then
			say("ERROR neutralizing civilians: " .. tostring(civ_err))
		end

		-- Real map logic (logged 2026-10-02): in the ICU, 'activateICUdisguiseArea' arms
		-- 'drew_guns_SecondTimeAlarm' (player state "standard" = guns drawn); it runs logic_toggle_021,
		-- which disables 'disable_achievement_no_alarm': from then on the alarm no longer cancels
		-- 'achievement_noalarm'. Before that, drawing guns / masking up is an alarm.
		local disabler = st.disabler or SA:chain_element_named("disable_achievement_no_alarm")
		local noalarm = st.noalarm or SA:chain_element_named("achievement_noalarm")
		local guns = st.guns_trigger or SA:chain_element_named("drew_guns_SecondTimeAlarm")

		st.disabler, st.noalarm, st.guns_trigger = disabler, noalarm, guns

		if disabler and noalarm and not disabler._values.enabled and noalarm._values.enabled then
			self:secure(st, "mission disabled 'disable_achievement_no_alarm' (guns drawn in the ICU), 'achievement_noalarm' still enabled")
		elseif guns and guns._values.enabled and (st.guns_t == nil or t - st.guns_t > 3) then
			st.guns_t = t

			local state = managers.player:current_state()

			if state ~= "standard" then
				say("ICU trigger armed by the mission ('drew_guns_SecondTimeAlarm' enabled) - drawing guns now (player state " .. tostring(state) .. " -> standard)")
				pcall(managers.player.set_player_state, managers.player, "standard")
			end
		end

		-- "Jouez au docteur" (heist_nmh_6): the ICU area arms the guns trigger when the player walks in.
		local objectives = managers.objectives and managers.objectives._active_objectives or {}

		if objectives.heist_nmh_6 and not (guns and guns._values.enabled) and (st.icu_warp_t == nil or t - st.icu_warp_t > 8) then
			st.icu_warp_t = t

			local moved, why = SA:warp_to_area_leading_to("activateICUdisguiseArea")

			if not moved then
				say("ICU area: " .. tostring(why) .. " - walk into the ICU yourself")
			end
		end

		local icu, objective = self:icu_objective_active()

		if icu and not st.icu_objective_logged then
			st.icu_objective_logged = true
			say("ICU objective active: " .. tostring(objective) .. " (waiting for the mission's ICU trigger)")
		end

		if not st.mask_warned then
			st.mask_warned = true
			say("Stay UNMASKED with weapons away until the ICU: drawing guns before it is an alarm")
			hint("nmh_10 : NE METS PAS TON MASQUE avant l'ICU")
		end

		if t - (st.stealth_log_t or 0) > 10 then
			st.stealth_log_t = t
			say("Current objective : " .. tostring(SA.state.objective))
			say("Alarm : FALSE")
			say("nmh_10 valid : " .. tostring(st.award_enabled ~= false):upper())
		end
	else
		-- The ICU guns trigger (drew_guns_SecondTimeAlarm) is the scripted second alarm: No Mercy goes
		-- loud on purpose. nmh_10 no longer depends on it; the award comes at the escape area.
		if loud and not st.loud_after_icu then
			st.loud_after_icu = true
			say("Alarm after the ICU = No Mercy scripted loud phase (expected). nmh_10 stays VALID - award at the escape (basement or roof), do NOT quit")
			hint("Alarme NORMALE (apres l'ICU) - nmh_10 deja securise : va jusqu'a l'evasion !")
		end

		if loud and t - (st.loud_hint_t or 0) > 20 then
			st.loud_hint_t = t
			hint("nmh_10 OK - termine le casse jusqu'a l'evasion pour l'obtenir")
		end

		pcall(SA.prepare_blood_test, SA, st, t)
		pcall(SA.auto_escape, SA, st, t)

		-- After the ICU: guards handled like uno_2 (FunnyMod kill, real death path).
		pcall(SA.HANDLERS.uno_2.guards, SA.HANDLERS.uno_2, st, t)
	end

	st.valid = not st.failed
end

function NMH10:on_awarded(st)
	st.awarded = true
	say("The game awarded nmh_10")

	if not st.secured then
		self:secure(st, "achievement awarded by the game")
	end
end

function NMH10:status(st)
	return {
		"Mode : " .. tostring(st.mode),
		"Alarm : " .. (st.failed and "FAILED" or (st.loud_after_icu and "OK (alarme du scenario apres l'ICU)" or "OK")),
		"ICU reached : " .. (st.secured and "OUI" or "NON"),
		"Cameras detruites : " .. tostring(st.cameras_destroyed or 0) .. "/" .. tostring(st.cameras_total or 0),
		"Civils neutralises : " .. tostring(st.civ_sig or "-"),
		"Achievement condition : " .. (st.failed and ("FAILED (" .. st.failed .. ")") or "VALID")
	}
end

-- ---------------------------------------------------------------------------------------------
-- Engine
-- ---------------------------------------------------------------------------------------------
local function level_id()
	return managers.job and managers.job:current_level_id() or Global.game_settings and Global.game_settings.level_id
end

-- Handler for the current level, preferring an id of the current Secret selection.
function SA:pick_handler()
	local level = level_id()
	local candidates = {}

	for _, h in pairs(self.HANDLERS) do
		if h.level == level then
			table.insert(candidates, h)
		end
	end

	for _, h in ipairs(candidates) do
		if SecretLogger and SecretLogger.is_in_challenge and SecretLogger:is_in_challenge(h.id) then
			return h, level
		end
	end

	return candidates[1], level
end

function SA:on_marked_event(unit, event)
	local h = self.handler

	if h and h.on_marked_event then
		h:on_marked_event(self.state, unit, event)
	end
end

function SA:blocks_interaction(unit, id)
	local h = self.handler

	if not self.active or not h or not h.blocks_interaction then
		return false
	end

	return h:blocks_interaction(self.state, unit, id)
end

-- Keypad (cas_button_0 .. cas_button_09, cas_button_clear, cas_button_enter) --------------------
-- The code is never guessed: a wrong code can raise the alarm. The module logs how the mission
-- checks the keypad (sequence triggers of every button, depth 2) and every DigitalGui number on
-- the map, then types the code ONLY when exactly one number display near the keypad has as many
-- digits as the keypad needs. Buttons are pressed through FunnyMod RealInteract (real interaction).
SA.KEYPAD_DELAY = 0.5
SA.KEYPAD_NEAR = 2500

local function keypad_buttons()
	local buttons, any = {}, nil

	for _, unit in ipairs(managers.interaction and managers.interaction._interactive_units or {}) do
		local interaction = alive(unit) and unit:interaction()
		local id = interaction and interaction:active() and tostring(interaction.tweak_data)
		local suffix = id and id:match("^cas_button_(.+)$")

		if suffix then
			local key = tonumber(suffix) and tostring(tonumber(suffix)) or suffix

			buttons[key] = unit
			any = unit
		end
	end

	return any and buttons or nil, any
end

local function sequence_trigger_index()
	local index = {}

	for _, el in pairs(SA.all_elements()) do
		local v = el._values

		if type(v) == "table" and type(v.sequence_list) == "table" then
			for _, d in ipairs(v.sequence_list) do
				if d.unit_id then
					index[d.unit_id] = index[d.unit_id] or {}
					table.insert(index[d.unit_id], el)
				end
			end
		end
	end

	return index
end

function SA:keypad_diagnostic(buttons, ref)
	local index = sequence_trigger_index()
	local elements = self.all_elements()

	say("Keypad found: logging how the mission checks the code")

	for key, unit in pairs(buttons) do
		local ud = unit:unit_data()
		local editor_id = ud and ud.unit_id

		for _, el in ipairs(index[editor_id] or {}) do
			local nexts = {}

			for _, p in ipairs(el._values.on_executed or {}) do
				local target = elements[p.id]

				table.insert(nexts, target and self.describe(target) or tostring(p.id))
			end

			say("  button " .. key .. " (unit " .. tostring(editor_id) .. "): " .. self.describe(el) .. " -> " .. table.concat(nexts, " | "))
		end
	end

	local ok, units = pcall(World.find_units_quick, World, "all")
	local found = {}

	for _, unit in ipairs(ok and units or {}) do
		local gui_ok, gui = pcall(function()
			return alive(unit) and unit.digital_gui and unit:digital_gui()
		end)

		gui = gui_ok and gui or nil

		if type(gui) == "table" and gui._number ~= nil then
			local dist = mvector3.distance(unit:position(), ref:position())

			say(string.format("  DigitalGui number=%s type=%s digits=%s visible=%s at %.1f m from the keypad", tostring(gui._number), tostring(gui.TYPE), tostring(gui.NUMBER_DIGITS), tostring(gui._visible), dist / 100))
			table.insert(found, { gui = gui, dist = dist })
		end
	end

	return found
end

local function code_digits(buttons)
	local n = 0

	for key in pairs(buttons) do
		if tonumber(key) then
			n = n + 1
		end
	end

	return n
end

function SA:keypad_find_code(displays)
	local candidates = {}

	for _, d in ipairs(displays) do
		local gui = d.gui

		if gui._visible ~= false and gui.TYPE == "number" and type(gui._number) == "number" and gui._number > 0 and d.dist < self.KEYPAD_NEAR then
			local text = tostring(math.floor(gui._number))
			local digits = tonumber(gui.NUMBER_DIGITS) or #text

			text = string.rep("0", math.max(0, digits - #text)) .. text
			table.insert(candidates, text)
		end
	end

	if #candidates == 1 then
		return candidates[1]
	end

	return nil, #candidates == 0 and "no number display near the keypad" or (#candidates .. " number displays near the keypad")
end

function SA:keypad_tick(t)
	local st = self.state

	if st.keypad_done or (st.keypad_next or 0) > t then
		return
	end

	local buttons, ref = keypad_buttons()

	if not buttons then
		return
	end

	if not st.keypad_logged then
		st.keypad_logged = true
		st.keypad_displays = self:keypad_diagnostic(buttons, ref)

		local code, why = self:keypad_find_code(st.keypad_displays)

		st.keypad_code = code

		if code then
			say("Keypad code found on a number display: " .. code .. " - typing it")
			st.keypad_queue = { "clear" }

			for digit in code:gmatch("%d") do
				table.insert(st.keypad_queue, tostring(tonumber(digit)))
			end

			table.insert(st.keypad_queue, "enter")
		else
			say("Keypad code NOT determined (" .. tostring(why) .. ") - nothing typed. Send the 'button' and 'DigitalGui' lines above")
			hint("SecretAuto : code du coffre non trouve, voir debug.txt")
			st.keypad_done = true

			return
		end

		if code_digits(buttons) < 10 then
			say("Keypad: only " .. code_digits(buttons) .. " digit buttons active")
		end
	end

	local key = table.remove(st.keypad_queue, 1)

	if not key then
		st.keypad_done = true
		say("Keypad: code typed")

		return
	end

	local unit = buttons[key]
	local ri = FunnyMod and FunnyMod.RealInteract

	if not unit or not ri or not ri.trigger then
		say("Keypad: button '" .. key .. "' not available - stopping the keypad entry")
		st.keypad_done = true

		return
	end

	local ok, res, why = pcall(ri.trigger, unit)

	say("Keypad: pressed " .. key .. " -> " .. tostring(ok and res) .. (why and (" (" .. tostring(why) .. ")") or ""))
	st.keypad_next = t + self.KEYPAD_DELAY
end

-- Seek: some mission interactions are only enabled by the mission when the player comes close
-- (Breakin' Feds security boxes: invisible_interaction_open_axis_rvd is inactive until then).
-- While the handler's objective is active, the player is teleported (FunnyMod Teleport.me_to,
-- PlayerManager:warp_to) next to each such unit not visited yet, one at a time; Auto Mission then
-- runs the real interactions.
SA.SEEK_WAIT = 4

local function seek_units(ids)
	local list = {}
	local ok, units = pcall(World.find_units_quick, World, "all")

	for _, unit in ipairs(ok and units or {}) do
		local got, interaction = pcall(function()
			return alive(unit) and unit:interaction()
		end)

		if got and interaction and ids[tostring(interaction.tweak_data)] then
			table.insert(list, { unit = unit, active = interaction:active() })
		end
	end

	return list
end

function SA:seek_tick(t)
	local h, st = self.handler, self.state
	local seek = h and h.SEEK

	if not seek or (st.seek_next or 0) > t then
		return
	end

	st.seek_next = t + 1

	local active_objectives = managers.objectives and managers.objectives._active_objectives or {}

	if not active_objectives[seek.objective] then
		return
	end

	local tp = rawget(_G, "Teleport")
	local player = managers.player:player_unit()

	if not tp or not tp.me_to or not alive(player) then
		if not st.seek_warned then
			st.seek_warned = true
			say("Seek: FunnyMod Teleport not available, walk to the remaining " .. seek.label .. " yourself")
		end

		return
	end

	st.seek_visited = st.seek_visited or {}

	local units = seek_units(seek.ids)
	local pending, target, best = 0, nil, nil

	for _, entry in ipairs(units) do
		if entry.active then
			-- Auto Mission is on it: wait.
			return
		end

		if not st.seek_visited[entry.unit:key()] then
			pending = pending + 1

			local d = mvector3.distance(player:position(), entry.unit:position())

			if not best or d < best then
				target, best = entry.unit, d
			end
		end
	end

	if not target then
		if #units > 0 and not st.seek_reset then
			-- Every one visited once and some still inactive: one more round.
			st.seek_reset = true
			st.seek_visited = {}
			say("Seek: " .. #units .. " " .. seek.label .. " still inactive, visiting them again")
		end

		return
	end

	st.seek_visited[target:key()] = true
	st.seek_next = t + self.SEEK_WAIT
	say(string.format("Seek: teleport to %s (%d left, %.1f m away)", seek.label, pending, best / 100))
	pcall(tp.me_to, target)
end

-- FunnyMod automation switched on while running (previous states restored at stop).
local function fm(name)
	return FunnyMod and FunnyMod[name]
end

SA.AUTOMATION = {
	{ label = "Auto Mission", obj = function() return fm("AutoMission") end, get = "is_enabled", set = "set_enabled" },
	{ label = "Auto drill restart", obj = function() return fm("AutoDrill") end, get = "restart_enabled", set = "set_restart_enabled" },
	{ label = "Auto drill place", obj = function() return fm("AutoDrill") end, get = "place_enabled", set = "set_place_enabled" },
	{ label = "Auto steal", obj = function() return fm("AutoSteal") end, get = "is_enabled", set = "set_enabled" },
	{ label = "Auto toolbag", obj = function() return fm("AutoToolbag") end, get = "is_enabled", set = "set_enabled" },
	{ label = "Instant place", obj = function() return fm("InstantPlace") end, get = "is_enabled", set = "set_enabled" },
	{ label = "Instant interactions", obj = function() return rawget(_G, "InteractionHelpers") end, get = "is_enabled", set = "set_enabled", key = "instant_interactions" },
	{ label = "Ignore requirements", obj = function() return rawget(_G, "InteractionHelpers") end, get = "is_enabled", set = "set_enabled", key = "ignore_requirements" },
	{ label = "Infinite cable ties", obj = function() return rawget(_G, "InteractionHelpers") end, get = "is_enabled", set = "set_enabled", key = "infinite_cable_ties" },
	{ label = "Unbreakable drills", obj = function() return rawget(_G, "InteractionHelpers") end, get = "is_enabled", set = "set_enabled", key = "unbreakable_drills" }
}

local function auto_call(entry, method, ...)
	local obj = entry.obj()

	if not obj or type(obj[method]) ~= "function" then
		return false
	end

	if entry.key then
		return pcall(obj[method], obj, entry.key, ...)
	end

	return pcall(obj[method], obj, ...)
end

-- Search radius of the FunnyMod systems: 0 = whole map while running (restored at stop).
SA.RADIUS_SYSTEMS = { "AutoMission", "AutoDrill", "AutoSteal" }

function SA:radius_unlimited()
	self._radius_prev = {}

	-- FunnyMod's global radius (auto_actions_radius, -1 = per system) overrides every system radius.
	local aa = fm("AutoActions")

	if aa and type(aa.global_radius) == "function" and type(aa.set_global_radius) == "function" then
		local ok, prev = pcall(aa.global_radius)

		if ok then
			self._global_radius_prev = prev
			pcall(aa.set_global_radius, 0)
			say("FunnyMod radius: whole map (global radius was " .. tostring(prev) .. " m)")
		end
	end

	for _, name in ipairs(self.RADIUS_SYSTEMS) do
		local obj = fm(name)

		if obj and type(obj.radius) == "function" and type(obj.set_radius) == "function" then
			local ok, prev = pcall(obj.radius, obj)

			if ok then
				self._radius_prev[name] = prev
				pcall(obj.set_radius, obj, 0)
			end
		end
	end
end

function SA:radius_restore()
	for name, prev in pairs(self._radius_prev or {}) do
		local obj = fm(name)

		if obj then
			pcall(obj.set_radius, obj, prev)
		end
	end

	self._radius_prev = nil

	local aa = fm("AutoActions")

	if aa and self._global_radius_prev ~= nil and type(aa.set_global_radius) == "function" then
		pcall(aa.set_global_radius, self._global_radius_prev)
	end

	self._global_radius_prev = nil
end

-- Spawn elements of units the mission watches for marked / unmarked (Garrett): protected from
-- FunnyMod mass removal / kill, whether SecretAuto runs or not.
function SA:is_protected(unit)
	local ud = alive(unit) and unit:unit_data()
	local spawn = ud and ud.mission_element

	if not spawn or not managers.mission then
		return false
	end

	if self._prot_owner ~= managers.mission then
		self._prot_owner = managers.mission
		self._prot = {}

		for _, el in pairs(self.all_elements()) do
			local v = el._values

			if self.class_of(el) == "ElementEnemyDummyTrigger" and type(v) == "table" and (v.event == "marked" or v.event == "unmarked") then
				for _, id in ipairs(v.elements or {}) do
					self._prot[id] = true
				end
			end
		end
	end

	return self._prot[spawn._id] == true
end

-- Logs once every active interaction FunnyMod Auto Mission does not handle (diagnostic).
function SA:log_unhandled(t)
	if (self._next_unhandled or 0) > t then
		return
	end

	self._next_unhandled = t + 2

	local am = fm("AutoMission")
	local player = managers.player:player_unit()

	if not am or not am.classify or not alive(player) then
		return
	end

	self.state.unhandled = self.state.unhandled or {}

	for _, unit in ipairs(managers.interaction and managers.interaction._interactive_units or {}) do
		local interaction = alive(unit) and unit:interaction()

		if interaction and interaction:active() then
			local id = tostring(interaction.tweak_data)

			if not self.state.unhandled[id] then
				local ok, category, why = pcall(am.classify, unit)

				if ok and not category then
					self.state.unhandled[id] = true
					say(string.format("Interaction not automated: %s (%s) at %.1f m", id, tostring(why), mvector3.distance(player:position(), unit:position()) / 100))
				end
			end
		end
	end
end

function SA:automation_on()
	self:radius_unlimited()
	self._auto_prev = {}

	local on = {}

	for i, entry in ipairs(self.AUTOMATION) do
		local ok, prev = auto_call(entry, entry.get)

		if ok then
			self._auto_prev[i] = prev and true or false
			auto_call(entry, entry.set, true)
			table.insert(on, entry.label)
		end
	end

	say(#on > 0 and ("Automation ON: " .. table.concat(on, ", ")) or "FunnyMod not found: do the objectives yourself")
end

function SA:automation_set(state)
	for i, entry in ipairs(self.AUTOMATION) do
		if self._auto_prev and self._auto_prev[i] ~= nil then
			auto_call(entry, entry.set, state)
		end
	end
end

function SA:automation_restore()
	self:radius_restore()

	for i, entry in ipairs(self.AUTOMATION) do
		if self._auto_prev and self._auto_prev[i] ~= nil then
			auto_call(entry, entry.set, self._auto_prev[i])
		end
	end

	self._auto_prev = nil
end

-- Pause = every FunnyMod automation off (nothing progresses the heist automatically).
function SA:pause(paused)
	local st = self.state

	if st.paused == paused then
		return
	end

	st.paused = paused
	self:automation_set(not paused)
	say(paused and "Automation PAUSED" or "Automation resumed")
end

-- Marks every guard / enemy in a loop (same ContourExt:add as the player's mark), refreshed
-- before its fadeout.
SA.MARK_GUARDS = true
SA.GUARD_INTERVAL = 0.5

function SA:mark_guards(t)
	if not self.MARK_GUARDS or (self._next_guards or 0) > t then
		return
	end

	self._next_guards = t + self.GUARD_INTERVAL
	self._guard_types = self._guard_types or setmetatable({}, { __mode = "k" })

	local ok, list = pcall(managers.enemy.all_enemies, managers.enemy)
	local n = 0

	for _, data in pairs(ok and list or {}) do
		local unit = data.unit

		if alive(unit) and unit:contour() and not (unit:character_damage() and unit:character_damage():dead()) then
			local key = unit:key()

			self._guard_types[key] = self._guard_types[key] or self.contour_type_for(unit)

			if pcall(self.maintain_mark, unit, self._guard_types[key], 2.0) then
				n = n + 1
			end
		end
	end

	if n ~= self._guards_marked then
		self._guards_marked = n
		say("Guards marked (loop): " .. n)
	end
end

-- Every ElementCounter of the award chain (and those its filters / operators target), live.
function SA:update_chain_counters()
	local st = self.state

	if not st.chain_counters then
		st.chain_counters, st.chain_counter_vals = {}, {}

		local elements = self.all_elements()

		for id in pairs(st.chain or {}) do
			local el = elements[id]
			local class = el and self.class_of(el)

			if class == "ElementCounter" then
				st.chain_counters[id] = el
			elseif class == "ElementCounterFilter" or class == "ElementCounterOperator" then
				for _, cid in ipairs(el._values.elements or {}) do
					if elements[cid] then
						st.chain_counters[cid] = elements[cid]
					end
				end
			end
		end
	end

	st.chain_enabled = st.chain_enabled or {}

	local elements = st.chain_elements

	if not elements then
		elements = {}

		local all = self.all_elements()

		for id in pairs(st.chain or {}) do
			elements[id] = all[id]
		end

		st.chain_elements = elements
	end

	for id, el in pairs(elements) do
		local enabled = el._values and el._values.enabled and true or false

		if st.chain_enabled[id] ~= nil and st.chain_enabled[id] ~= enabled then
			say("Chain element #" .. tostring(id) .. " '" .. tostring(el._editor_name) .. "' enabled = " .. tostring(enabled))
		end

		st.chain_enabled[id] = enabled
	end

	for id, counter in pairs(st.chain_counters) do
		local value = counter._values.counter_target

		if value ~= st.chain_counter_vals[id] then
			st.chain_counter_vals[id] = value
			say("Chain counter #" .. tostring(id) .. " '" .. tostring(counter._editor_name) .. "' = " .. tostring(value))
		end
	end
end

function SA:update_award()
	pcall(self.update_chain_counters, self)
	local st = self.state
	local award = st.award

	if not award then
		return
	end

	local enabled = award._values.enabled and true or false

	if enabled ~= st.award_enabled then
		st.award_enabled = enabled
		say(self.handler.id .. " award element enabled = " .. tostring(enabled))

		if not enabled then
			hint("SecretAuto : " .. self.handler.id .. " desactive par la mission !")
		end
	end
end

function SA:update_objectives()
	local ok, active = pcall(function()
		return managers.objectives._active_objectives
	end)

	if not ok or type(active) ~= "table" then
		return
	end

	for id, data in pairs(active) do
		if not self.state.objectives_seen[id] then
			self.state.objectives_seen[id] = true

			local text = type(data) == "table" and tostring(data.text or "") or ""

			self.state.objective = text ~= "" and text or tostring(id)
			say("Objective: " .. tostring(id) .. " - " .. text)

			local low = (tostring(id) .. " " .. text):lower()

			if low:find("safe", 1, true) or low:find("coffre", 1, true) then
				say("Safe objective detected")
			end

			if low:find("escape", 1, true) or low:find("evasion", 1, true) or low:find("évasion", 1, true) or low:find("extract", 1, true) then
				self.state.escape_available = true
				say("Escape available - go to the escape zone to finish the heist")
				hint("SecretAuto : evasion disponible, va a la zone d'evasion")
			end
		end
	end
end

function SA:update(t)
	local state = game_state_machine and game_state_machine:current_state_name()
	local h = self.handler

	if state == "victoryscreen" then
		say("SUCCESS (victory screen)")

		local info = managers.achievment:get_info(h.id)

		say(h.id .. " unlocked = " .. tostring(info and info.awarded == true or (SecretLogger and SecretLogger._session_awarded and SecretLogger._session_awarded[h.id]) == true))

		return self:stop("heist finished")
	elseif state == "gameoverscreen" then
		say("Heist failed (game over)")

		return self:stop("game over")
	end

	if (self._next_tick or 0) > t then
		return
	end

	self._next_tick = t + self.TICK
	self:update_award()
	h:tick(self.state, t)
	pcall(self.mark_guards, self, t)
	pcall(self.log_unhandled, self, t)
	pcall(self.keypad_tick, self, t)
	pcall(self.seek_tick, self, t)
	self:update_objectives()
end

Hooks:Add("GameSetupUpdate", "SecretAuto_GameSetupUpdate", function(t, dt)
	if SA.active then
		-- xpcall / debug.traceback do not exist in PAYDAY 2's Lua: pcall, its message has file:line.
		local ok, err = pcall(SA.update, SA, t)

		if not ok then
			say("ERROR: " .. tostring(err))
			SA:stop("error")
		end
	end
end)

function SA:start()
	if self.active then
		say("Already running")
		hint("SecretAuto : deja en cours")

		return false
	end

	local h, level = self:pick_handler()

	if not h then
		say("No AUTO COMPLETE handler for level '" .. tostring(level) .. "' (available: uno_5 = des, tag_10 = tag, uno_2 = family, nmh_10 = nmh)")
		hint("SecretAuto : aucun achievement automatise sur ce niveau")

		return false
	end

	local difficulty = Global.game_settings and Global.game_settings.difficulty

	if h.difficulties and not h.difficulties[difficulty] then
		say("Difficulty '" .. tostring(difficulty) .. "' too low for " .. h.id)
		hint("SecretAuto : difficulte trop basse pour " .. h.id)

		return false
	end

	local info = managers.achievment and managers.achievment:get_info(h.id)
	local in_secret = SecretLogger and SecretLogger.is_in_challenge and SecretLogger:is_in_challenge(h.id)

	say("Achievement : " .. h.id .. " (in Secret selection: " .. tostring(in_secret) .. ", already unlocked: " .. tostring(info and info.awarded) .. ")")
	say("Heist : " .. h.heist)
	say("Difficulty : " .. tostring(OVERKILL_PLUS[difficulty] or difficulty))

	self.handler = h
	self.state = { objectives_seen = {}, objective = "-", valid = true }
	self._next_tick = 0
	self.active = true

	say("Starting...")

	local award, elements, chain = self:analyze(h.id)

	self.state.award = award
	self.state.chain = chain
	h:start(self.state, elements or self.all_elements())

	if self.state.failed then
		self:stop("cannot start: " .. tostring(self.state.failed))

		return false
	end

	self:automation_on()

	if h.after_automation then
		pcall(h.after_automation, h, self.state)
	end
	say("Completing objectives...")

	hint("SecretAuto : " .. h.id .. " en cours")

	return true
end

function SA:stop(reason)
	if not self.active then
		return
	end

	self.active = false

	self:automation_restore()

	if self.handler and self.handler.cleanup then
		pcall(self.handler.cleanup, self.handler, self.state)
	end
	say("Stopped: " .. tostring(reason))
	hint("SecretAuto : arrete (" .. tostring(reason) .. ")")
end

function SA:status_text()
	local h = self.handler
	local st = self.state or {}
	local lines = {
		"Etat : " .. (self.active and (st.paused and "PAUSE" or "ON") or "OFF"),
		"Achievement : " .. (h and h.id or "-"),
		"Objectif actuel : " .. tostring(st.objective or "-"),
		"Element d'attribution : " .. (st.award and (st.award_enabled == false and "DESACTIVE" or "actif") or "introuvable")
	}

	if h and h.status then
		for _, line in ipairs(h:status(st)) do
			table.insert(lines, line)
		end
	end

	return table.concat(lines, "\n")
end

-- Called by the SecretLogger AchievmentManager:award post hook when the game really awards something.
function SA:on_award(id)
	if self.active and self.handler and id == self.handler.id then
		say("The game awarded " .. id)

		if self.handler.on_awarded then
			self.handler:on_awarded(self.state)
		end
	end
end
