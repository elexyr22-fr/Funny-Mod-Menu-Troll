-- FunnyMod.AutoActions (V15): ONE engine for every automatic interaction of the local player:
-- Auto Pickup (highlight.lua), Auto Steal (auto_steal.lua), Auto Drill place / restart
-- (auto_drill.lua), Auto Revive (auto_revive.lua). Each module only registers a "system"
-- (what to look for, how to confirm); the engine does the rest the same way for all of them.
--
-- Pipeline for one unit:
--   DETECT    system.detect(ctx): units in range (distance only, no crosshair), with a priority.
--   VALIDATE  system.validate (optional extra rules) + FunnyMod.RealInteract.can_interact.
--   START     RealInteract.start = interact_start (vanilla). Held interaction -> the engine waits
--             its timer, like PlayerStandard (interrupted with the vanilla interact_interupt if the
--             unit / interaction disappears or the player leaves the range).
--   COMPLETE  RealInteract.complete = interact_interupt(complete) + interact (vanilla).
--   CONFIRM   the game's own state: unit removed, interaction deactivated or changed
--             (host answer on a client), or system.confirmed. Modules can confirm at once from a
--             game callback with AutoActions.confirm_unit (Gage pickup callbacks).
--             No confirmation before system.timeout -> FAILED reason=timeout, retry later.
--
-- Tracking: AutoActions._pending[unit_key] = { type, unit, phase, started_at, retries, cooldown,
-- tweak, ... }. A unit that has an entry (any system) is never started again: no double
-- interaction. phase = "started" (waiting for its timer) | "sent" (waiting for confirmation) |
-- "cooldown" (failed / refused, blocked until `cooldown`).
-- Rate: each system runs at most every INTERVAL (~3 Hz) and acts on ONE unit per run. Nothing
-- runs every frame except the tiny started/sent bookkeeping (a handful of entries).
FunnyMod = FunnyMod or {}
FunnyMod.AutoActions = FunnyMod.AutoActions or {}
local AA = FunnyMod.AutoActions
AutoActions = AA

AA.INTERVAL = 1 / 3
AA.BOOKKEEPING_INTERVAL = 0.05
AA.COOLDOWN = 3
AA.MAX_RETRIES = 3
AA.LONG_COOLDOWN = 20
AA.TIMEOUT_HOST = 2
AA.TIMEOUT_CLIENT = 5
-- A started held interaction is cancelled when the player goes further than radius * this.
AA.RANGE_SLACK = 1.5
-- Global radius choices (settings "auto_actions_radius"): -1 = each system keeps its own radius,
-- 0 = MAX (no limit), otherwise meters.
AA.GLOBAL_RADII = { -1, 2, 5, 10, 20, 0 }
AA.systems = AA.systems or {}
AA.order = AA.order or {}
AA._pending = AA._pending or {}
AA._next_t = AA._next_t or {}

local function RI()
	return FunnyMod.RealInteract or FunnyMod.require_api and FunnyMod.require_api("RealInteract", "real_interact.lua")
end

local function NET()
	return FunnyMod.Network
end

local function setting(key, default)
	local q = rawget(_G, "QuickEnemySpawner")
	local value = q and q.settings and q.settings[key]
	if value == nil then
		return default
	end
	return value
end
AA.setting = setting

function AA.set_setting(key, value)
	local q = rawget(_G, "QuickEnemySpawner")
	if q and type(q.set_setting) == "function" then
		q.set_setting(key, value)
	end
end

function AA.debug()
	return setting("debug_auto_actions", false) == true
end

function AA.global_radius()
	return tonumber(setting("auto_actions_radius", -1)) or -1
end

function AA.set_global_radius(meters)
	AA.set_setting("auto_actions_radius", meters)
end

local function is_client()
	local net = NET()
	return net and net.is_client() or false
end

function AA.unit_label(unit)
	if not alive(unit) then
		return "<gone>"
	end
	local tweak = RI() and RI().tweak_id(unit)
	return tostring(tweak or unit:name()) .. "#" .. tostring(unit:key()):gsub("^userdata: ", "")
end

local function dlog(msg)
	if AA.debug() then
		log("[AutoActions] " .. msg)
	end
end
AA.dlog = dlog

-- Registers (or replaces) a system. def fields:
--   id, tag                 "pickup", "[AutoPickup]"
--   enabled()               bool
--   radius()                meters, 0 = MAX
--   detect(ctx)             { { unit = u, priority = n (lower first), info = any }, ... }
--   validate(unit, ctx, c)  optional: true | false, reason (before RealInteract.can_interact)
--   act(unit, ctx, c)       optional: replaces START/COMPLETE: true [, "sent"] | false, reason
--   confirmed(entry)        optional: true, reason when done (checked before the generic rules)
--   generic_confirm         false to disable the generic rules (unit / interaction gone)
--   timeout                 optional seconds
--   on_phase(phase, entry, data)  optional module log / side effects
function AA.register(def)
	if type(def) ~= "table" or type(def.id) ~= "string" then
		return
	end
	if not AA.systems[def.id] then
		table.insert(AA.order, def.id)
	end
	AA.systems[def.id] = def
end

function AA.is_pending(key)
	local e = key and AA._pending[key]
	return e ~= nil and e.phase ~= "cooldown"
end

function AA.is_busy(key, t)
	local e = AA._pending[key]
	if not e then
		return false
	end
	if e.phase == "cooldown" then
		return t < (e.cooldown or 0)
	end
	return true
end

local function phase_hook(def, phase, entry, data)
	if def and type(def.on_phase) == "function" then
		pcall(def.on_phase, phase, entry, data)
	end
end

-- Last GameSetupUpdate time (same clock as started_at).
local function now()
	return AA._t or 0
end

local function fail(def, entry, t, reason)
	local retries = (entry.retries or 0) + 1
	entry.retries = retries
	entry.phase = "cooldown"
	entry.reason = reason
	if retries >= AA.MAX_RETRIES then
		entry.cooldown = t + AA.LONG_COOLDOWN
		entry.retries = 0
	else
		entry.cooldown = t + AA.COOLDOWN
	end
	-- Always logged when debug is on; otherwise once per unit and reason.
	if AA.debug() or entry.logged_reason ~= reason then
		entry.logged_reason = reason
		log(string.format("[AutoActions] FAILED type=%s unit=%s reason=%s retry=%d cooldown=%.0fs", def.id, entry.label or "?", tostring(reason), retries, entry.cooldown - t))
	end
	phase_hook(def, "failed", entry, reason)
end

local function confirm(def, entry, key, reason, t)
	AA._pending[key] = nil
	dlog(string.format("type=%s unit=%s phase=confirmed (%s) after %.2f s", def.id, entry.label or "?", tostring(reason), (t or now()) - (entry.started_at or 0)))
	phase_hook(def, "confirmed", entry, reason)
end

-- Immediate confirmation from a game callback (e.g. GageAssignmentManager:on_unit_interact).
function AA.confirm_unit(unit, reason)
	if not unit then
		return false
	end
	local ok, key = pcall(unit.key, unit)
	local entry = ok and AA._pending[key]
	if not entry or entry.phase == "cooldown" then
		return false
	end
	-- Called from inside our own interact_start / interact (synchronous game callback): keep the
	-- log order detect -> start -> complete -> confirmed, the caller confirms right after.
	if entry.in_call then
		entry.early = entry.early or reason or "game callback"
		return true
	end
	local def = AA.systems[entry.type]
	confirm(def, entry, key, reason or "game callback")
	return true
end

local function finish_call(def, entry, key, t)
	entry.in_call = nil
	if entry.early then
		confirm(def, entry, key, entry.early, t)
		return true
	end
	return false
end

-- Generic confirmation: the unit or its interaction is gone / changed.
local function generic_confirmed(entry)
	local unit = entry.unit
	if not alive(unit) then
		return true, "unit removed"
	end
	local interaction = unit:interaction()
	if not interaction then
		return true, "interaction removed"
	end
	if type(interaction.active) == "function" and not interaction:active() then
		return true, "interaction inactive"
	end
	if entry.tweak and interaction.tweak_data ~= entry.tweak then
		return true, "interaction changed to " .. tostring(interaction.tweak_data)
	end
	return false
end

function AA.radius_for(def)
	local global = AA.global_radius()
	if global >= 0 then
		return global
	end
	local r = type(def.radius) == "function" and tonumber(def.radius()) or 5
	return r or 5
end

local function timeout_for(def)
	if def.timeout then
		return def.timeout
	end
	return is_client() and AA.TIMEOUT_CLIENT or AA.TIMEOUT_HOST
end

local function complete(def, entry, key, player, t)
	local ri = RI()
	entry.in_call = true
	local ok, done, why = pcall(ri.complete, entry.unit, player)
	if (not ok or not done) and not entry.early then
		entry.in_call = nil
		AA._pending[key] = entry
		fail(def, entry, t, ok and why or tostring(done))
		return
	end
	entry.phase = "sent"
	entry.sent_at = t
	dlog(string.format("type=%s unit=%s phase=complete", def.id, entry.label))
	phase_hook(def, "complete", entry)
	finish_call(def, entry, key, t)
end

-- Started (timer running) and sent (waiting for the game) entries.
function AA.update_pending(t)
	local ri = RI()
	local player = ri and ri.local_player()
	for key, entry in pairs(AA._pending) do
		local def = AA.systems[entry.type]
		if not def then
			AA._pending[key] = nil
		elseif entry.phase == "cooldown" then
			-- Forget old cooldowns of units that no longer exist.
			if t >= (entry.cooldown or 0) + 60 or not alive(entry.unit) then
				AA._pending[key] = nil
			end
		elseif entry.phase == "started" then
			local unit = entry.unit
			local interaction = alive(unit) and unit:interaction()
			if not interaction or not interaction:active() or interaction.tweak_data ~= entry.tweak then
				fail(def, entry, t, "interaction gone during the timer")
			elseif not player or not ri.player_ready(player) then
				if player then
					ri.cancel(unit, player)
				end
				fail(def, entry, t, "player not ready during the timer (interrupted)")
			elseif entry.max_sq and mvector3.distance_sq(player:position(), ri.position(unit)) > entry.max_sq * AA.RANGE_SLACK * AA.RANGE_SLACK then
				ri.cancel(unit, player)
				fail(def, entry, t, "left the radius during the timer (interrupted)")
			elseif t >= entry.complete_at then
				complete(def, entry, key, player, t)
			end
		elseif entry.phase == "sent" then
			local done, reason
			if type(def.confirmed) == "function" then
				local ok, r1, r2 = pcall(def.confirmed, entry)
				done, reason = ok and r1, r2
			end
			if not done and def.generic_confirm ~= false then
				done, reason = generic_confirmed(entry)
			end
			if done then
				confirm(def, entry, key, reason, t)
			elseif t - (entry.sent_at or entry.started_at) > timeout_for(def) then
				fail(def, entry, t, "timeout (no confirmation from the game" .. (is_client() and " / host" or "") .. ")")
			end
		end
	end
end

-- One run of one system: at most one unit.
function AA.run_system(def, t)
	local ri = RI()
	if not ri then
		return
	end
	local player = ri.local_player()
	if not player then
		return
	end
	if not ri.player_ready(player) then
		return
	end
	local radius_m = AA.radius_for(def)
	local ctx = {
		player = player,
		pos = player:position(),
		radius = radius_m,
		max_sq = radius_m > 0 and (radius_m * 100) ^ 2 or nil,
		t = t
	}
	local ok, list = pcall(def.detect, ctx)
	if not ok then
		if not def._detect_error then
			def._detect_error = true
			log("[AutoActions] FAILED type=" .. def.id .. " reason=detect error: " .. tostring(list))
		end
		return
	end
	if type(list) ~= "table" or #list == 0 then
		return
	end
	-- Closest of the best priority, among units that are not busy.
	local best, best_d, best_p
	for _, c in ipairs(list) do
		local unit = c.unit
		if alive(unit) and not AA.is_busy(unit:key(), t) then
			local d = mvector3.distance_sq(ctx.pos, ri.position(unit))
			if not ctx.max_sq or d <= ctx.max_sq then
				local p = c.priority or 1
				if not best or p < best_p or (p == best_p and d < best_d) then
					best, best_d, best_p = c, d, p
				end
			end
		end
	end
	if not best then
		return
	end
	local unit = best.unit
	local key = unit:key()
	local old = AA._pending[key]
	local entry = {
		type = def.id,
		unit = unit,
		label = AA.unit_label(unit),
		tweak = ri.tweak_id(unit),
		started_at = t,
		retries = old and old.retries or 0,
		logged_reason = old and old.logged_reason,
		cooldown = 0,
		priority = best.priority,
		info = best.info,
		distance = math.sqrt(best_d) / 100,
		max_sq = ctx.max_sq
	}
	dlog(string.format("type=%s unit=%s phase=detect distance=%.1fm priority=%s", def.id, entry.label, entry.distance, tostring(best.priority or 1)))
	phase_hook(def, "detect", entry)

	-- VALIDATE
	local valid, reason = true, nil
	if type(def.validate) == "function" then
		local okv, r1, r2 = pcall(def.validate, unit, ctx, best)
		valid, reason = okv and r1, okv and r2 or tostring(r1)
	end
	local code
	if valid and not def.act then
		valid, reason, code = ri.can_interact(unit, player)
	end
	dlog(string.format("type=%s unit=%s phase=validate result=%s%s", def.id, entry.label, tostring(valid and true or false), valid and "" or (" reason=" .. tostring(reason))))
	phase_hook(def, "validate", entry, { result = valid and true or false, reason = reason })
	if not valid then
		AA._pending[key] = entry
		-- V18: an unmasked / casing player cannot interact at all (vanilla): not a failure of the
		-- unit, no retry escalation, one log line per system until the state changes.
		if code == "state" then
			entry.phase = "cooldown"
			entry.cooldown = t + AA.COOLDOWN
			entry.reason = reason
			if def._state_logged ~= reason then
				def._state_logged = reason
				log(string.format("[AutoActions] WAITING type=%s reason=%s (nothing sent)", def.id, tostring(reason)))
			end
			return
		end
		def._state_logged = nil
		fail(def, entry, t, "validate: " .. tostring(reason))
		return
	end
	def._state_logged = nil

	-- Custom action (native drill repair...): START + COMPLETE in one call.
	if type(def.act) == "function" then
		AA._pending[key] = entry
		entry.in_call = true
		local oka, done, why = pcall(def.act, unit, ctx, best, entry)
		if (not oka or not done) and not entry.early then
			entry.in_call = nil
			fail(def, entry, t, oka and why or tostring(done))
			return
		end
		entry.phase = "sent"
		entry.sent_at = t
		dlog(string.format("type=%s unit=%s phase=start (%s)", def.id, entry.label, tostring(why or "custom")))
		dlog(string.format("type=%s unit=%s phase=complete", def.id, entry.label))
		phase_hook(def, "start", entry, why)
		phase_hook(def, "complete", entry)
		finish_call(def, entry, key, t)
		return
	end

	-- START
	AA._pending[key] = entry
	entry.in_call = true
	local oks, started, timer_or_why = pcall(ri.start, unit, player)
	if (not oks or not started) and not entry.early then
		entry.in_call = nil
		fail(def, entry, t, oks and timer_or_why or tostring(started))
		return
	end
	if not oks or not started then
		timer_or_why = nil
	end
	if timer_or_why and not entry.early then
		entry.in_call = nil
		entry.phase = "started"
		entry.timer = timer_or_why
		entry.complete_at = t + timer_or_why
		dlog(string.format("type=%s unit=%s phase=start timer=%.2fs", def.id, entry.label, timer_or_why))
		phase_hook(def, "start", entry, timer_or_why)
		-- A zero-length wait completes in the same tick.
		if timer_or_why <= 0 then
			complete(def, entry, key, player, t)
		end
	else
		-- No timer: interact() already ran inside interact_start.
		entry.phase = "sent"
		entry.sent_at = t
		dlog(string.format("type=%s unit=%s phase=start (no timer, interact ran)", def.id, entry.label))
		dlog(string.format("type=%s unit=%s phase=complete", def.id, entry.label))
		phase_hook(def, "start", entry)
		phase_hook(def, "complete", entry)
		finish_call(def, entry, key, t)
	end
end

function AA.update(t)
	AA._t = t
	if not AA._next_book or t >= AA._next_book then
		AA._next_book = t + AA.BOOKKEEPING_INTERVAL
		if next(AA._pending) ~= nil then
			local ok, err = pcall(AA.update_pending, t)
			if not ok and not AA._pending_error then
				AA._pending_error = true
				log("[AutoActions] FAILED bookkeeping error: " .. tostring(err))
			end
		end
	end
	if not AA._level_t0 then
		AA._level_t0 = t
		-- V18.2: which systems are ON for this level (a feature OFF in the save is visible at once).
		local parts = {}
		for _, id in ipairs(AA.order) do
			local def = AA.systems[id]
			local ok, on = pcall(def.enabled)
			table.insert(parts, id .. "=" .. ((ok and on) and "ON" or "OFF"))
		end
		log("[AutoActions] systems: " .. table.concat(parts, " "))
	end
	local mission_allowed
	for _, id in ipairs(AA.order) do
		local def = AA.systems[id]
		if def and (not AA._next_t[id] or t >= AA._next_t[id]) then
			AA._next_t[id] = t + (def.interval or AA.INTERVAL)
			local enabled = type(def.enabled) == "function" and def.enabled()
			-- V18.1: only mission_action systems are gated (loud / police called), nothing else.
			if enabled and def.mission_action == true then
				if mission_allowed == nil then
					mission_allowed = AA.update_mission_gate()
				end
				enabled = mission_allowed
			end
			if enabled then
				local ok, err = pcall(AA.run_system, def, t)
				if not ok and not def._run_error then
					def._run_error = true
					log("[AutoActions] FAILED type=" .. id .. " reason=error: " .. tostring(err))
				end
			end
		end
	end
end

-- V18.1: ONE mission gate, the same for HOST and CLIENT, independent of Auto Steal / mask / player
-- state. Only systems registered with mission_action = true (Auto Mission: C4 / drill / saw / hack
-- / terminal / insert / door, Auto Drill place / restart) are gated. steal, pickup and revive
-- NEVER call it.
-- Vanilla state (248.2 lib/managers/group_ai_states/groupaistatebase.lua, all saved / synced to
-- clients: save/load + sync_event):
--   is_police_called()   _police_called, set by on_police_called / on_enemy_weapons_hot / sync_event
--   enemy_weapons_hot()  _enemy_weapons_hot, the alarm went off (loud)
--   whisper_mode()       _whisper_mode, true while the heist is in stealth (set_whisper_mode);
--                        false on loud-only heists. It starts false in init and the mission turns
--                        it on shortly after spawn: a false value is only trusted after
--                        AA.WHISPER_GRACE seconds of level time, so no C4 goes off at spawn.
-- The presence of a cop on the map is never used (some heists have guards before the alarm).
AA.WHISPER_GRACE = 5

function AA.is_loud()
	local gm = managers.groupai
	local state = gm and gm:state()
	if not state then
		return false
	end
	if type(state.is_police_called) == "function" and state:is_police_called() then
		return true
	end
	if type(state.enemy_weapons_hot) == "function" and state:enemy_weapons_hot() then
		return true
	end
	if type(state.whisper_mode) == "function" and not state:whisper_mode() then
		return AA._level_t0 ~= nil and (AA._t or 0) - AA._level_t0 >= AA.WHISPER_GRACE
	end
	return false
end

-- true = mission actions may run (loud / police called). Depends on nothing else.
-- V18.3: HOST / solo = always allowed (user request); CLIENT = only once loud / police called.
function AA.allow_mission_actions()
	return not is_client() or AA.is_loud()
end

-- Menu / V18.x name: true while mission actions are paused.
function AA.mission_paused()
	return not AA.allow_mission_actions()
end

-- One log line per change of state.
function AA.update_mission_gate()
	local allow = AA.allow_mission_actions()
	if allow ~= AA._mission_allowed_logged then
		AA._mission_allowed_logged = allow
		log("[AutoActions] state=" .. (AA.is_loud() and "LOUD" or "STEALTH") .. " mode=" .. (is_client() and "CLIENT" or "HOST") .. " mission_actions=" .. (allow and "ACTIVE" or "PAUSED"))
	end
	return allow
end

-- Pending entries of one system (or all) are dropped: level change, option turned off.
function AA.reset(type_id)
	for key, entry in pairs(AA._pending) do
		if not type_id or entry.type == type_id then
			AA._pending[key] = nil
		end
	end
	if not type_id then
		AA._next_t = {}
		AA._next_book = nil
		AA._level_t0 = nil
		AA._mission_allowed_logged = nil
	end
end

-- V18.5: only while really playing. Victory / game over / disconnect screens: nothing is started
-- (a level that is ending must not receive interaction RPCs).
function AA.in_active_game()
	local gsm = rawget(_G, "game_state_machine")
	local name = gsm and type(gsm.current_state_name) == "function" and gsm:current_state_name() or ""
	return name:find("^ingame") ~= nil and not name:find("waiting") and not name:find("lobby")
end

if not AA._update_hooked and Hooks then
	AA._update_hooked = true
	Hooks:Add("GameSetupUpdate", "FMMT_AutoActionsUpdate", function(t, dt)
		if not managers.player or not managers.player:player_unit() or not AA.in_active_game() then
			return
		end
		AA.update(t)
	end)
end
