--[[
	Auto Secret Piano

	How the game validates the piano step (decompiled lib/units/props/unopianobase.lua
	and lib/units/weapons/raycastweaponbase.lua):

	  * A gunshot ends in InstantBulletBase:on_collision(), which calls
	      body:extension().damage:damage_bullet(attacker, normal, pos, dir, 1)
	      body:extension().damage:damage_damage(attacker, normal, pos, dir, weapon_damage)
	    on the body that was hit (and syncs "sync_body_damage_bullet" to peers).
	  * Each piano key is a body of the piano unit. Its bullet endurance runs a unit
	    sequence that calls UnoPianoBase:note_played(<note>).
	  * UnoPianoBase keeps a sliding window of the last 9 notes and runs the unit
	    sequence "puzzle_done" when string.join(":", notes):key() equals
	    tweak_data.safehouse.uno_notes.

	This mod reads the piano unit's sequence data to map every key body to the note
	it plays, picks the 9 keys from the reference picture, checks the candidate with
	the game's own UnoPianoBase:validate_sequence() (nothing is played otherwise),
	then sends the exact same body damage as a gunshot to each key, one by one.
	No achievement, save or puzzle state is written directly.
]]

AutoSecretPiano = AutoSecretPiano or {}
local ASP = AutoSecretPiano

local function say(msg)
	log("[AutoSecretPiano] " .. tostring(msg))
end

-- Loaded with lib/units/props/unopianobase: remember the piano unit and log played notes.
if type(RequiredScript) == "string" and RequiredScript:lower() == "lib/units/props/unopianobase" then
	if UnoPianoBase and not ASP._piano_hooked then
		ASP._piano_hooked = true

		Hooks:PostHook(UnoPianoBase, "init", "AutoSecretPiano_UnoPianoBase_init", function(self, unit)
			ASP._piano = unit
		end)

		Hooks:PostHook(UnoPianoBase, "note_played", "AutoSecretPiano_UnoPianoBase_note_played", function(self, note)
			local window = {}

			for i, n in ipairs(self._notes_played or {}) do
				window[i] = tostring(n)
			end

			say(string.format("Game registered note '%s' (window %d/%d: %s)", tostring(note), #window, self.SEQUENCE_LENGTH or 9, table.concat(window, ":")))
		end)
	end

	return
end

if ASP._loaded then
	return
end

ASP._loaded = true

ASP.NOTE_DELAY = 0.4
ASP.SEARCH_BUDGET = 2000
ASP.MAX_RADIUS = 6
ASP.FULL_SEARCH_MAX_KEYS = 18
ASP.SAFEHOUSE_LEVELS = { chill = true, chill_combat = true }

-- Reference picture: keys 1..9 = A B C D E E D C B (6-9 reuse the keys of 5-2).
ASP.PATTERN = { 1, 2, 3, 4, 5, 5, 4, 3, 2 }
-- Keys 1..5 on the picture of an 88-key piano, 1-based from the lowest key (A0):
-- C5, A#4, G#4, G4, F4. Only used as the starting point of the search.
ASP.GUESS_88 = { 52, 50, 48, 47, 45 }
ASP.GUESS_MIDI = { 72, 70, 68, 67, 65 }
-- Notes 1..5 as named by the piano sequences (white_1 = A0, black_1 = A#0).
-- Checked offline against tweak_data.safehouse.uno_notes; still re-checked in game
-- with UnoPianoBase:validate_sequence() before anything is played.
ASP.KNOWN_SOLUTION = { "white_31", "black_21", "black_20", "white_28", "white_27" }

local ENDURANCE_TYPES = { "bullet", "damage" }
local RUN_SEQUENCE_BASE_ATTRS = {
	name = true,
	start_time = true,
	start_time_element_id = true,
	start_time_id_var = true,
	repeat_nr = true,
	filter = true,
	delayed_filter = true
}

local function hud(msg)
	say("HUD: " .. msg)

	local ok = managers.hud and pcall(managers.hud.show_hint, managers.hud, { text = msg, time = 3 })

	if not ok and managers.chat then
		pcall(managers.chat._receive_message, managers.chat, 1, "Secret Piano", msg, Color.yellow)
	end
end

-- Sequence attributes are stored as raw Lua expressions (the game loadstring()s them).
local eval_env_mt = { __index = _G }

local function eval_raw(raw, params)
	if type(raw) ~= "string" then
		return raw
	end

	local func = loadstring("return " .. raw)

	if not func then
		return nil
	end

	setfenv(func, setmetatable({ params = params or {} }, eval_env_mt))

	local ok, value = pcall(func)

	return ok and value or nil
end

local function body_center(body)
	local ok, pos = pcall(function()
		return body:oobb():center()
	end)

	if ok and pos then
		return pos
	end

	ok, pos = pcall(function()
		return body:center_of_mass()
	end)

	if ok and pos then
		return pos
	end

	ok, pos = pcall(function()
		return body:position()
	end)

	return ok and pos or nil
end

function ASP:in_safehouse()
	local level = managers.job and managers.job:current_level_id() or Global.game_settings and Global.game_settings.level_id

	return self.SAFEHOUSE_LEVELS[level] == true, level
end

local function is_piano(unit)
	local ok, base = pcall(function()
		return unit:base()
	end)

	return ok and type(base) == "table" and base.note_played ~= nil and base.validate_sequence ~= nil
end

function ASP:find_piano()
	if alive(self._piano) and is_piano(self._piano) then
		return self._piano
	end

	self._piano = nil

	local ok, units = pcall(World.find_units_quick, World, "all")

	if not ok or type(units) ~= "table" then
		return nil
	end

	for _, unit in ipairs(units) do
		if alive(unit) and is_piano(unit) then
			self._piano = unit

			return unit
		end
	end

	return nil
end

-- Walks a sequence element tree and collects the notes passed to note_played.
function ASP:_collect(element, unit_element, params, depth, out, stack)
	if type(element) ~= "table" or depth > 16 then
		return
	end

	local p = element._parameters

	if type(p) == "table" then
		if p["function"] ~= nil then
			if eval_raw(p["function"], params) == "note_played" then
				table.insert(out, eval_raw(p.param1, params))
			end

			return
		end

		-- run_sequence element: has _params and no child list
		if p.name ~= nil and element._params ~= nil and element._elements == nil then
			local seq_name = eval_raw(p.name, params)
			local seq

			if type(seq_name) == "string" then
				local ok, s = pcall(unit_element.get_sequence_element, unit_element, seq_name)
				seq = ok and s or unit_element._sequence_elements and unit_element._sequence_elements[seq_name]
			end

			if seq and not stack[seq] then
				local new_params = {}

				for k, v in pairs(params or {}) do
					new_params[k] = v
				end

				for k, raw in pairs(p) do
					if not RUN_SEQUENCE_BASE_ATTRS[k] then
						new_params[k] = eval_raw(raw, params)
					end
				end

				stack[seq] = true
				self:_collect(seq, unit_element, new_params, depth + 1, out, stack)
				stack[seq] = nil
			end

			return
		end
	end

	if type(element._elements) == "table" then
		for _, child in ipairs(element._elements) do
			self:_collect(child, unit_element, params, depth + 1, out, stack)
		end
	end
end

-- Returns { unit, body, body_name, note, endurance } for every body that plays exactly one note.
function ASP:_scan_unit(unit, keys)
	local dmg = unit:damage()
	local unit_element = dmg and dmg._unit_element

	if not unit_element or type(unit_element._bodies) ~= "table" then
		return
	end

	for body_name, body_element in pairs(unit_element._bodies) do
		local unique, seen, etype_used = {}, {}, nil

		for _, etype in ipairs(ENDURANCE_TYPES) do
			local endurance = body_element._first_endurance and body_element._first_endurance[etype]
			local visited = {}

			while type(endurance) == "table" and not visited[endurance] do
				visited[endurance] = true

				local found = {}

				self:_collect(endurance, unit_element, {}, 0, found, {})

				for _, note in ipairs(found) do
					if note ~= nil and not seen[note] then
						seen[note] = true
						table.insert(unique, note)
						etype_used = etype_used or etype
					end
				end

				endurance = endurance._next and endurance._next[etype]
			end
		end

		if #unique == 1 then
			local body = unit:body(body_name)

			if alive(body) then
				table.insert(keys, {
					unit = unit,
					body = body,
					body_name = tostring(body_name),
					note = unique[1],
					endurance = etype_used,
					pos = body_center(body)
				})
			end
		elseif #unique > 1 then
			say("Body '" .. tostring(body_name) .. "' plays several notes, ignored")
		end
	end
end

function ASP:find_keys(piano)
	local keys = {}

	self:_scan_unit(piano, keys)

	if #keys == 0 then
		-- Fallback: keys could be separate units placed around the piano.
		local ok, units = pcall(World.find_units_quick, World, "all")
		local center = piano:position()

		if ok and type(units) == "table" then
			for _, unit in ipairs(units) do
				if alive(unit) and unit ~= piano and unit:damage() and mvector3.distance(unit:position(), center) < 800 then
					self:_scan_unit(unit, keys)
				end
			end
		end
	end

	-- Two bodies playing the same note make the mapping ambiguous: keep the first.
	local by_note, result = {}, {}

	for _, key in ipairs(keys) do
		if not by_note[key.note] then
			by_note[key.note] = key
			table.insert(result, key)
		end
	end

	return result
end

local PITCH_CLASS = { c = 0, d = 2, e = 4, f = 5, g = 7, a = 9, b = 11 }

-- white_N / black_N (piano unit naming) -> MIDI pitch, white_1 = A0 = 21.
local KEY_NAME_PITCH = {}

do
	local white, black = 0, 0
	local is_black = { [1] = true, [3] = true, [6] = true, [8] = true, [10] = true }

	for midi = 21, 108 do
		if is_black[midi % 12] then
			black = black + 1
			KEY_NAME_PITCH["black_" .. black] = midi
		else
			white = white + 1
			KEY_NAME_PITCH["white_" .. white] = midi
		end
	end
end

local function parse_pitch(note)
	if type(note) ~= "string" then
		return nil
	end

	if KEY_NAME_PITCH[note] then
		return KEY_NAME_PITCH[note]
	end

	local letter, acc, oct = note:lower():match("([a-g])([#sb]?)_?(%-?%d+)$")

	if not letter then
		return nil
	end

	local pitch = (tonumber(oct) + 1) * 12 + PITCH_CLASS[letter]

	if acc == "#" or acc == "s" then
		pitch = pitch + 1
	elseif acc == "b" then
		pitch = pitch - 1
	end

	return pitch
end

local function all_unique(keys, field)
	local seen = {}

	for _, key in ipairs(keys) do
		if key[field] == nil or seen[key[field]] then
			return false
		end

		seen[key[field]] = true
	end

	return true
end

-- Sorts keys from low to high and returns the list of index guesses to try first.
function ASP:order_keys(piano, keys)
	local n = #keys

	for _, key in ipairs(keys) do
		key.pitch = parse_pitch(key.note)
		key.number = tonumber(key.note)
	end

	if all_unique(keys, "pitch") then
		table.sort(keys, function(a, b)
			return a.pitch < b.pitch
		end)

		local guess = {}

		for i, midi in ipairs(self.GUESS_MIDI) do
			local best, best_d = 1, math.huge

			for k, key in ipairs(keys) do
				local d = math.abs(key.pitch - midi)

				if d < best_d then
					best, best_d = k, d
				end
			end

			guess[i] = best
		end

		return "note names", { guess }
	end

	local scaled = {}

	for i, idx in ipairs(self.GUESS_88) do
		scaled[i] = n == 88 and idx or math.max(1, math.min(n, math.floor((idx - 1) / 87 * (n - 1) + 1.5)))
	end

	if all_unique(keys, "number") then
		table.sort(keys, function(a, b)
			return a.number < b.number
		end)

		return "note numbers", { scaled }
	end

	-- Geometry: project key centers on the piano's x axis, try both directions.
	local axis = piano:rotation():x()
	local distinct = {}

	for _, key in ipairs(keys) do
		key.proj = key.pos and mvector3.dot(key.pos, axis) or 0
		distinct[math.floor(key.proj * 10)] = true
	end

	if table.size(distinct) >= n * 0.8 then
		table.sort(keys, function(a, b)
			return a.proj < b.proj
		end)

		local mirrored = {}

		for i, idx in ipairs(scaled) do
			mirrored[i] = n + 1 - idx
		end

		return "key positions", { scaled, mirrored }
	end

	return "unordered", { scaled }
end

function ASP:_make_sequence(keys, idx)
	local seq = {}

	for i, p in ipairs(self.PATTERN) do
		seq[i] = keys[idx[p]].note
	end

	return seq
end

-- Coroutine: finds 5 key indices whose pattern is accepted by UnoPianoBase:validate_sequence.
function ASP:_search(base, keys, guesses)
	local n = #keys
	local tried = 0

	local function test(idx)
		for i = 1, 5 do
			if idx[i] < 1 or idx[i] > n then
				return false
			end

			for j = 1, i - 1 do
				if idx[i] == idx[j] then
					return false
				end
			end
		end

		tried = tried + 1

		if tried % self.SEARCH_BUDGET == 0 then
			coroutine.yield()
		end

		return base:validate_sequence(self:_make_sequence(keys, idx))
	end

	for _, g in ipairs(guesses) do
		if test(g) then
			return g, tried
		end
	end

	for r = 1, self.MAX_RADIUS do
		for _, g in ipairs(guesses) do
			local d = { -r, -r, -r, -r, -r }

			while true do
				local m = 0

				for i = 1, 5 do
					m = math.max(m, math.abs(d[i]))
				end

				if m == r then
					local idx = { g[1] + d[1], g[2] + d[2], g[3] + d[3], g[4] + d[4], g[5] + d[5] }

					if test(idx) then
						return idx, tried
					end
				end

				local i = 1

				while i <= 5 do
					d[i] = d[i] + 1

					if d[i] > r then
						d[i] = -r
						i = i + 1
					else
						break
					end
				end

				if i > 5 then
					break
				end
			end
		end
	end

	if n <= self.FULL_SEARCH_MAX_KEYS then
		say("Neighbourhood search failed, trying every combination of " .. n .. " keys")

		for a = 1, n do
			for b = 1, n do
				for c = 1, n do
					for d = 1, n do
						for e = 1, n do
							local idx = { a, b, c, d, e }

							if test(idx) then
								return idx, tried
							end
						end
					end
				end
			end
		end
	end

	return nil, tried
end

Hooks:Add("GameSetupUpdate", "AutoSecretPiano_GameSetupUpdate", function(t, dt)
	local co = ASP._search_co

	if not co then
		return
	end

	local ok, err = coroutine.resume(co)

	if not ok then
		ASP._search_co = nil
		ASP._busy = false
		say("Search error: " .. tostring(err))
		hud("Secret Piano: error, see SuperBLT log")
	elseif coroutine.status(co) == "dead" then
		ASP._search_co = nil
	end
end)

local function weapon_damage()
	local ok, dmg = pcall(function()
		return managers.player:equipped_weapon_unit():base():_get_current_damage(1)
	end)

	if ok and type(dmg) == "number" and dmg > 0 then
		return dmg
	end

	return 5
end

-- Same calls as InstantBulletBase:on_collision for a body with a damage extension.
function ASP:_hit_key(key)
	local unit, body = key.unit, key.body

	if not alive(unit) or not alive(body) then
		return false, "key unit/body no longer exists"
	end

	local body_dmg_ext = body:extension() and body:extension().damage

	if not body_dmg_ext then
		return false, "key body has no damage extension"
	end

	local player = managers.player:player_unit()
	local user_unit = alive(player) and player or nil
	local pos = key.pos or body_center(body) or unit:position()
	local from = user_unit and user_unit:movement():m_head_pos() or pos + Vector3(0, 0, 100)
	local dir = pos - from

	mvector3.normalize(dir)

	local normal = -dir
	local network_damage = math.ceil(weapon_damage() * 163.84)
	local body_damage = network_damage / 163.84

	if unit:id() ~= -1 and managers.network:session() then
		pcall(function()
			local normal_yaw, normal_pitch = InstantBulletBase._get_vector_sync_yaw_pitch(normal, 128, 64)
			local dir_yaw, dir_pitch = InstantBulletBase._get_vector_sync_yaw_pitch(dir, 128, 64)

			managers.network:session():send_to_peers_synched("sync_body_damage_bullet", body, user_unit and user_unit:id() ~= -1 and user_unit or nil, normal_yaw, normal_pitch, pos, dir_yaw, dir_pitch, math.min(16384, network_damage))
		end)
	end

	body_dmg_ext:damage_bullet(user_unit, normal, pos, dir, 1)

	if unit:alive() then
		body_dmg_ext:damage_damage(user_unit, normal, pos, dir, body_damage)
	end

	return true
end

function ASP:_finish(piano, aborted)
	self._busy = false

	if aborted then
		say("Sequence aborted: " .. tostring(aborted))
		hud("Secret Piano: sequence aborted")

		return
	end

	local base = alive(piano) and piano:base()

	if base and base.validate_sequence and base:validate_sequence(base._notes_played or {}) then
		say("Game note window matches the solution, puzzle_done was triggered")
	else
		say("Warning: the game's note window does not match the solution (see 'Game registered note' lines)")
	end

	say("Sequence completed")
	hud("Secret Piano: sequence completed")
end

function ASP:_play(piano, sequence_keys)
	hud("Secret Piano: sequence started")

	local i = 0

	local function step()
		i = i + 1

		if not alive(piano) then
			return self:_finish(piano, "piano unit is gone")
		end

		local key = sequence_keys[i]

		say(string.format("Playing note %d/9 (note '%s', body '%s')", i, tostring(key.note), key.body_name))

		local ok, res, err = pcall(self._hit_key, self, key)

		if not ok or not res then
			return self:_finish(piano, not ok and res or err)
		end

		if i >= #sequence_keys then
			DelayedCalls:Add("AutoSecretPiano_step", 0.5, function()
				self:_finish(piano)
			end)
		else
			DelayedCalls:Add("AutoSecretPiano_step", self.NOTE_DELAY, step)
		end
	end

	step()
end

function ASP:_start(piano, keys, idx)
	local sequence_keys, names = {}, {}

	for i, p in ipairs(self.PATTERN) do
		sequence_keys[i] = keys[idx[p]]
		names[i] = tostring(keys[idx[p]].note)
	end

	-- The puzzle is only playable if every key still has a live endurance for the gunshot.
	for _, key in ipairs(sequence_keys) do
		local ext = alive(key.body) and key.body:extension() and key.body:extension().damage
		local enabled_ok, enabled = pcall(function()
			return key.body:enabled()
		end)

		if not enabled_ok then
			enabled = nil
		end

		if not ext or not ext._endurance or not ext._endurance[key.endurance or "bullet"] or enabled == false then
			say("Key '" .. tostring(key.note) .. "' (body '" .. key.body_name .. "') cannot be shot right now")
			say("Piano not found / puzzle unavailable")
			hud("Secret Piano: puzzle unavailable")
			self._busy = false

			return
		end
	end

	self._solution = names
	say("Solution verified against tweak_data.safehouse.uno_notes: " .. table.concat(names, ":"))
	self:_play(piano, sequence_keys)
end

function ASP:trigger()
	if self._busy then
		say("Sequence already running, key press ignored")
		hud("Secret Piano: already running")

		return
	end

	local in_safehouse, level = self:in_safehouse()

	if not in_safehouse then
		say("Not in the Safe House (level '" .. tostring(level) .. "'), nothing done")
		hud("Secret Piano: only works in the Safe House")

		return
	end

	say("Safe House detected (level '" .. tostring(level) .. "')")

	-- Note: solving the piano makes the game draw a new 20-achievement Secret selection (reroll).

	if not alive(managers.player:player_unit()) then
		say("No player unit, nothing done")

		return
	end

	local piano = self:find_piano()

	if not piano then
		say("Piano not found / puzzle unavailable")
		hud("Secret Piano: piano not found")

		return
	end

	say("Piano found at " .. tostring(piano:position()))

	local keys = self:find_keys(piano)

	if #keys < 5 then
		say("Only " .. #keys .. " playable key bodies found")
		say("Piano not found / puzzle unavailable")
		hud("Secret Piano: puzzle unavailable")

		return
	end

	local method, guesses = self:order_keys(piano, keys)
	local note_list = {}

	for i, key in ipairs(keys) do
		note_list[i] = tostring(key.note)
	end

	say(string.format("%d key bodies found, ordered by %s: %s", #keys, method, table.concat(note_list, " ")))

	local base = piano:base()

	-- Known solution / solution found earlier in this session, checked by the game first.
	local solutions = { self.KNOWN_SOLUTION }

	if self._solution then
		table.insert(solutions, 1, self._solution)
	end

	for _, solution in ipairs(solutions) do
		local idx_by_note, idx, complete = {}, {}, true

		for i, key in ipairs(keys) do
			idx_by_note[tostring(key.note)] = i
		end

		for i = 1, 5 do
			idx[i] = idx_by_note[solution[i]]
			complete = complete and idx[i] ~= nil
		end

		if complete then
			if base:validate_sequence(self:_make_sequence(keys, idx)) then
				self._busy = true

				return self:_start(piano, keys, idx)
			end

			say("Stored solution rejected by the game, searching instead")
		end
	end

	self._busy = true
	say("Searching the 9-note sequence accepted by the game...")

	self._search_co = coroutine.create(function()
		local idx, tried = self:_search(base, keys, guesses)

		if not idx then
			say("No key combination matches tweak_data.safehouse.uno_notes (" .. tried .. " tried)")
			say("Piano not found / puzzle unavailable")
			hud("Secret Piano: solution not found, see log")
			self._busy = false

			return
		end

		say("Sequence found after " .. tried .. " checks")

		if not alive(piano) then
			self._busy = false

			return
		end

		self:_start(piano, keys, idx)
	end)
end

say("Loaded")
