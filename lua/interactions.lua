-- Interaction helpers for the LOCAL player (drill jam / drill timers: host only, the host runs them).
-- Network verdict (248.2): the interaction timer runs on the interacting peer; the host only gets
-- a HUD message (sync_teammate_progress) and the completion (sync_interacted / unit_tied /
-- server_place_mission_door_device), none of which re-check duration or inventory. So instant
-- interactions, requirement bypass, C4 helper and cable ties work as a client; TimerGui (drill,
-- saw, hack countdown and jams) is decided by the host only.
--   Instant interactions : every interaction with a timer > 0 gets INSTANT_TIMER instead of 0.
--                          A timer of exactly 0 makes interact_start skip _at_interact_start,
--                          which carries mission callbacks (MissionElementInteractionExt ->
--                          mission_element:on_interact_start), revive start RPCs, pager answer
--                          start and bag expiry pause. A tiny timer keeps the whole vanilla flow
--                          (start + completion) and completes in a couple of frames.
--                          BaseInteractionExt:_get_timer is the only definition in the game;
--                          subclasses only override _get_modified_timer, called inside it.
--                          Drill / saw / hack countdowns (TimerGui:start) run with a 1 s timer that
--                          the host also sends to the clients (start_timer_gui).
--   Ignore requirements  : only on interactions that ALREADY exist and declare an inventory
--                          requirement in their tweak data (special_equipment such as keycards,
--                          crowbar, C4, possible_special_equipment, required_deployable). While the
--                          game itself checks or runs THAT interaction (can_select, selected,
--                          update_show_interact, can_interact, _interact_blocked, interact_start,
--                          interact of every *InteractionExt class that defines them), the
--                          required item counts as owned and is not consumed if the player does
--                          not really have it. Everything else is vanilla: callbacks, mission
--                          scripts, sequences, network (the host does not re-check the item in
--                          sync_interacted / server_place_mission_door_device). special_equipment_block
--                          is never faked. No interaction is ever created.
--   C4 helper            : the same mechanism restricted to interactions that really accept C4
--                          (special_equipment "c4", shaped charges). The C4 / trip mine is never consumed.
--   Cable ties           : PlayerManager:remove_special("cable_tie") is skipped.
--   Unbreakable drills   : host only (TimerGui:_set_jamming_values returns at once on clients: the
--                          host decides every jam and syncs it). No jam is ever scheduled
--                          (_set_jamming_values leaves no interval) and TimerGui:set_jammed(true) -
--                          the single entry point used by the jam timer, cop sabotage
--                          (Drill:on_sabotage_SO_started) and MissionDoor:set_jammed - is ignored.
--                          The timer keeps running. Nothing is repaired afterwards: a device that is
--                          already jammed stays as it is.
local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")

InteractionHelpers = InteractionHelpers or {}
local IX = InteractionHelpers

IX.DEFAULTS = {
	instant_interactions = true,
	ignore_requirements = true,
	unbreakable_drills = true,
	c4_helper = true,
	infinite_cable_ties = true
}
IX.LABELS = {
	instant_interactions = "Interactions instantanées",
	ignore_requirements = "Ignorer prérequis interactions",
	unbreakable_drills = "Perceuses incassables",
	c4_helper = "C4 illimité",
	infinite_cable_ties = "Liens civils infinis"
}
IX.HOST_ONLY = { unbreakable_drills = true }
IX.INSTANT_TIMER = 0.05
-- Interaction tweak ids left untouched. None is known to break with a short timer; the table
-- exists so one can be excluded without touching the hook.
IX.BLACKLIST = {}
-- result_place_mission_door_device: on a client the C4 / drill / shaped charge consumption arrives
-- later, from the host's answer (RPC result_place_mission_door_device), outside interact(); without
-- the context the vanilla remove_equipment would index a missing deployable (playermanager.lua).
IX.CONTEXT_METHODS = { "can_select", "selected", "update_show_interact", "can_interact", "_interact_blocked", "interact_start", "interact", "result_place_mission_door_device" }
IX._ctx_stack = IX._ctx_stack or {}

function IX:is_enabled(key)
	local qes = rawget(_G, "QuickEnemySpawner")
	if qes and qes.settings and qes.settings[key] ~= nil then
		return qes.settings[key] and true or false
	end
	return self.DEFAULTS[key] and true or false
end

function IX:set_enabled(key, state)
	local qes = rawget(_G, "QuickEnemySpawner")
	if qes and type(qes.set_setting) == "function" then
		qes.set_setting(key, state and true or false)
	end
	log("[ModMenu] " .. (self.LABELS[key] or key) .. " -> " .. (state and "ON" or "OFF"))
end

local function is_authority()
	return NET.is_host()
end
IX.is_authority = is_authority

local function pack(...)
	return { n = select("#", ...), ... }
end

local function needs_c4(td)
	if td.special_equipment == "c4" then
		return true
	end
	if type(td.possible_special_equipment) == "table" and table.contains(td.possible_special_equipment, "c4") then
		return true
	end
	return false
end

local function is_shaped_charge(td)
	return td.required_deployable == "trip_mine" and td.icon == "equipment_c4"
end

-- Requirement context of an existing interaction, or nil.
--   names       special equipment that counts as owned
--   deployable  required deployable that counts as owned
--   keep_all    never consume (C4 helper), otherwise consume only what the player really has
function IX.context_for(interaction)
	local td = type(interaction) == "table" and interaction._tweak_data
	if type(td) ~= "table" then
		return nil
	end
	if IX:is_enabled("ignore_requirements") and (td.special_equipment or td.possible_special_equipment or td.required_deployable) then
		local names, any = {}, false
		-- special_equipment "nothing" is not an item: the game uses it to lock decoys (wrong
		-- computers, e.g. big_computer_not_hackable). Never bypass it.
		if type(td.special_equipment) == "string" and td.special_equipment ~= "nothing" then
			names[td.special_equipment] = true
			any = true
		end
		if type(td.possible_special_equipment) == "table" then
			for _, name in ipairs(td.possible_special_equipment) do
				if name ~= "nothing" then
					names[name] = true
					any = true
				end
			end
		end
		if any or td.required_deployable then
			local keep_all = IX:is_enabled("c4_helper") and (needs_c4(td) or is_shaped_charge(td))
			return { names = names, deployable = td.required_deployable, keep_all = keep_all }
		end
	end
	if IX:is_enabled("c4_helper") then
		if needs_c4(td) then
			return { names = { c4 = true }, keep_all = true }
		end
		if is_shaped_charge(td) then
			return { names = {}, deployable = td.required_deployable, keep_all = true }
		end
	end
	return nil
end

function IX.current_context()
	return IX._ctx_stack[#IX._ctx_stack]
end

-- Runs fn with ctx pushed, and always pops it again, even if fn errors (nesting safe).
local function with_context(ctx, fn, ...)
	if not ctx then
		return fn(...)
	end
	table.insert(IX._ctx_stack, ctx)
	local depth = #IX._ctx_stack
	local result = pack(pcall(fn, ...))
	for i = #IX._ctx_stack, depth, -1 do
		IX._ctx_stack[i] = nil
	end
	if not result[1] then
		error(result[2], 0)
	end
	return unpack(result, 2, result.n)
end

local function wrap_context(class, method)
	local original = rawget(class, method)
	if type(original) ~= "function" then
		return false
	end
	class[method] = function(self, ...)
		return with_context(IX.context_for(self), original, self, ...)
	end
	return true
end

if RequiredScript == "lib/units/interactions/interactionext" and BaseInteractionExt and not IX._interaction_hooked then
	IX._interaction_hooked = true

	local original_get_timer = BaseInteractionExt._get_timer
	function BaseInteractionExt:_get_timer(...)
		local timer = original_get_timer(self, ...)
		if type(timer) == "number" and timer > IX.INSTANT_TIMER and IX:is_enabled("instant_interactions")
			and not IX.BLACKLIST[self.tweak_data] then
			return IX.INSTANT_TIMER
		end
		return timer
	end

	local original_has_deployable = BaseInteractionExt._has_required_deployable
	function BaseInteractionExt:_has_required_deployable(...)
		local ctx = IX.context_for(self)
		if ctx and ctx.deployable then
			return true
		end
		return original_has_deployable(self, ...)
	end

	-- Every interaction class of the game file that defines one of the checked methods itself.
	local wrapped = 0
	for name, class in pairs(_G) do
		if type(name) == "string" and name:sub(-14) == "InteractionExt" and type(class) == "table" then
			for _, method in ipairs(IX.CONTEXT_METHODS) do
				if wrap_context(class, method) then
					wrapped = wrapped + 1
				end
			end
		end
	end
	log("[InteractionHelpers] requirement context on " .. wrapped .. " interaction methods")
end

if RequiredScript == "lib/managers/playermanager" and PlayerManager and not IX._player_hooked then
	IX._player_hooked = true

	local original_has_special = PlayerManager.has_special_equipment
	function PlayerManager:has_special_equipment(name, ...)
		local data = original_has_special(self, name, ...)
		if not data then
			local ctx = IX.current_context()
			if ctx and ctx.names[name] then
				return { amount = Application:digest_value(1, true) }
			end
		end
		return data
	end

	local original_remove_special = PlayerManager.remove_special
	function PlayerManager:remove_special(name, ...)
		if name == "cable_tie" and IX:is_enabled("infinite_cable_ties") then
			return
		end
		local ctx = IX.current_context()
		if ctx and ctx.names[name] and (ctx.keep_all or not original_has_special(self, name)) then
			return
		end
		return original_remove_special(self, name, ...)
	end

	-- Required deployable consumption: skipped with the C4 helper, or when the player has none
	-- left (the vanilla code would index a missing equipment as nil).
	local original_remove_equipment = PlayerManager.remove_equipment
	function PlayerManager:remove_equipment(equipment_id, slot, ...)
		local ctx = IX.current_context()
		if ctx and ctx.deployable and equipment_id == ctx.deployable then
			if ctx.keep_all then
				return
			end
			local ok, left = pcall(self.has_deployable_left, self, equipment_id, slot or 1)
			if not (ok and left) then
				return
			end
		end
		return original_remove_equipment(self, equipment_id, slot, ...)
	end
end

if RequiredScript == "lib/units/props/timergui" and TimerGui and not IX._timer_hooked then
	IX._timer_hooked = true

	local original_start = TimerGui.start
	function TimerGui:start(timer, ...)
		if not self._started and IX:is_enabled("instant_interactions") and is_authority() then
			local previous_override = self._override_timer
			self._override_timer = 1
			local result = pack(pcall(original_start, self, timer, ...))
			self._override_timer = previous_override
			if not result[1] then
				error(result[2], 0)
			end
			return unpack(result, 2, result.n)
		end
		return original_start(self, timer, ...)
	end

	local function unbreakable()
		return IX:is_enabled("unbreakable_drills") and is_authority()
	end

	local original_set_jamming_values = TimerGui._set_jamming_values
	function TimerGui:_set_jamming_values(...)
		local result = pack(original_set_jamming_values(self, ...))
		if unbreakable() then
			self._jamming_intervals = {}
			self._current_jam_timer = nil
		end
		return unpack(result, 1, result.n)
	end

	local original_set_jammed = TimerGui.set_jammed
	function TimerGui:set_jammed(jammed, ...)
		if jammed and unbreakable() then
			self._jamming_intervals = {}
			self._current_jam_timer = nil
			log("[ModMenu] Drill jam blocked (" .. tostring(self._unit and alive(self._unit) and self._unit:key()) .. ")")
			return
		end
		return original_set_jammed(self, jammed, ...)
	end
end
