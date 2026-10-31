-- Observer only (nothing is changed or blocked):
--   * when the mission ends (ElementMissionEnd), logs which element ended it, its state, the
--     instigator and the chain of elements that executed it (5 levels up, with their classes);
--   * on the Secret ending level ("vit") after the door, logs every executed mission element whose
--     name looks related to the ending (dentist, boss, timer, fail, gold, ...), so the steps the
--     mission expects become visible.
if AutoSecretDoorEndLog then
	return
end

AutoSecretDoorEndLog = true

local function say(msg)
	log("[AutoSecretDoor] " .. tostring(msg))
end

local CLASS_OF = setmetatable({}, { __mode = "k" })

local function all_elements()
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

local function describe(el)
	local v = el._values or {}
	local extra = {}

	for _, k in ipairs({ "state", "timer", "time", "counter_target", "toggle", "event", "chance", "sequence", "enabled" }) do
		if v[k] ~= nil then
			table.insert(extra, k .. "=" .. tostring(v[k]))
		end
	end

	return string.format("#%s %s '%s' %s", tostring(el._id), tostring(CLASS_OF[el] or "?"), tostring(el._editor_name), table.concat(extra, " "))
end

local function callers_of(elements, id)
	local list = {}

	for _, el in pairs(elements) do
		local v = el._values

		for _, p in ipairs(type(v) == "table" and type(v.on_executed) == "table" and v.on_executed or {}) do
			if p.id == id then
				table.insert(list, el)
			end
		end

		for _, eid in ipairs(type(v) == "table" and type(v.elements) == "table" and v.elements or {}) do
			if eid == id then
				table.insert(list, el)
			end
		end
	end

	return list
end

local function on_mission_end(self, instigator)
	if not self._values or not self._values.enabled then
		return
	end

	-- Recorded first, so the game over line is right even if the rest fails.
	AutoSecretDoorLastEnd = { id = self._id, name = self._editor_name, state = self._values.state }

	local who = "-"

	if type(instigator) == "userdata" and alive(instigator) then
		who = managers.player:player_unit() == instigator and "local player" or tostring(instigator)
	end

	local elements = all_elements()

	say("MISSION END: " .. describe(self) .. " instigator=" .. who)

	local seen = {}

	local function walk(id, depth)
		if depth > 5 then
			return
		end

		for _, el in ipairs(callers_of(elements, id)) do
			if not seen[el._id] then
				seen[el._id] = true
				say(string.rep("  ", depth) .. "<- " .. describe(el))
				walk(el._id, depth + 1)
			end
		end
	end

	walk(self._id, 1)
end

if type(RequiredScript) == "string" and RequiredScript:lower() == "lib/managers/mission/elementmissionend" and ElementMissionEnd then
	Hooks:PreHook(ElementMissionEnd, "on_executed", "AutoSecretDoor_MissionEnd_log", function(self, instigator)
		local ok, err = pcall(on_mission_end, self, instigator)

		if not ok then
			say("mission end log error: " .. tostring(err))
		end
	end)
end

-- Executed-element trace on the Secret ending level.
local TRACE_WORDS = { "dentist", "boss", "uno", "final", "fail", "lose", "win", "end", "kill", "dead", "death", "timer", "gold", "invul", "damage", "health", "shoot", "phase" }

local function trace_wanted(el)
	local name = tostring(el._editor_name):lower()

	for _, w in ipairs(TRACE_WORDS) do
		if name:find(w, 1, true) then
			return true
		end
	end

	return false
end

function AutoSecretDoorInstallTrace()
	if AutoSecretDoorTraceHooked then
		return
	end

	local core = rawget(_G, "CoreMissionScriptElement")
	local base = core and core.MissionScriptElement

	if type(base) ~= "table" or type(base.on_executed) ~= "function" then
		say("trace: MissionScriptElement class not reachable, trace off")

		return
	end

	AutoSecretDoorTraceHooked = true
	all_elements()

	Hooks:PreHook(base, "on_executed", "AutoSecretDoor_trace_on_executed", function(self)
		if not AutoSecretDoorTraceOn or not self._values or not self._values.enabled then
			return
		end

		local ok, wanted = pcall(trace_wanted, self)

		if ok and wanted then
			say("trace executed: " .. describe(self))
		end
	end)

	say("trace: logging executed ending elements (dentist / boss / timer / fail / gold ...)")
end

-- Game over WITHOUT a mission end element = every player down / in custody (not a mission fail).
Hooks:Add("GameSetupUpdate", "AutoSecretDoor_GameOverWatch", function()
	local state = game_state_machine and game_state_machine:current_state_name()

	if state ~= AutoSecretDoorLastState then
		AutoSecretDoorLastState = state

		if state == "gameoverscreen" then
			if AutoSecretDoorLastEnd then
				say("GAME OVER caused by mission end element #" .. tostring(AutoSecretDoorLastEnd.id) .. " '" .. tostring(AutoSecretDoorLastEnd.name) .. "' (state " .. tostring(AutoSecretDoorLastEnd.state) .. ")")
			else
				say("GAME OVER without any mission end element: the players were downed / in custody")
			end
		end

		if state ~= "gameoverscreen" and state ~= "victoryscreen" then
			AutoSecretDoorLastEnd = nil
		end
	end
end)
