--[[
	Auto Secret Door

	The Secret puzzle door is UnoPuzzleDoorBase (lib/units/props/unopuzzledoorbase.lua):
	  * 3 rings (outer / middle / inner) of 26 stops each, turned with
	    turn_outer_cw / _ccw, turn_middle_cw / _ccw, turn_inner_cw / _ccw;
	  * init_puzzle() (run by the mission) picks 4 of the 13 riddles of
	    tweak_data.safehouse.uno_door_riddles at random (self._riddle_ids);
	  * submit_answer() hashes "outer:middle:inner" and compares it with the riddle's key;
	    a wrong answer sends the door back to riddle 1, the 4th right answer runs
	    "all_riddles_solved".
	The 13 answers below were found offline from those keys with the game's own hash, and every
	answer is checked again in game (string.join(":", stops):key() == door._solution) before
	submit_answer() is called: a wrong answer is never sent.
]]

AutoSecretDoor = AutoSecretDoor or {}
local ASD = AutoSecretDoor

if ASD._loaded then
	return
end

ASD._loaded = true

-- riddle id (index in tweak_data.safehouse.uno_door_riddles) -> { outer, middle, inner } stops
ASD.ANSWERS = {
	[1] = { 10, 4, 22 },
	[2] = { 24, 7, 20 },
	[3] = { 2, 11, 8 },
	[4] = { 12, 25, 18 },
	[5] = { 8, 16, 4 },
	[6] = { 20, 2, 12 },
	[7] = { 14, 10, 0 },
	[8] = { 4, 9, 16 },
	[9] = { 16, 9, 6 },
	[10] = { 6, 20, 14 },
	[11] = { 22, 7, 2 },
	[12] = { 18, 25, 10 },
	[13] = { 0, 3, 24 }
}
ASD.STOPS = 26
ASD.TURN_DELAY = 0.15
ASD.SUBMIT_DELAY = 2
ASD.NEXT_DELAY = 3

local function say(msg)
	log("[AutoSecretDoor] " .. tostring(msg))
end

local function hint(msg)
	if managers.hud then
		pcall(managers.hud.show_hint, managers.hud, { text = msg, time = 4 })
	end
end

local function find_door()
	local ok, units = pcall(World.find_units_quick, World, "all")

	for _, unit in ipairs(ok and units or {}) do
		local got, base = pcall(function()
			return alive(unit) and unit:base()
		end)

		if got and type(base) == "table" and base.submit_answer and base.turn_outer_cw and base._outer then
			return unit, base
		end
	end
end

local RINGS = { "outer", "middle", "inner" }

-- Queue of ring turns (shortest way) from the current stops to the answer.
local function plan_turns(base, answer)
	local queue = {}

	for i, ring in ipairs(RINGS) do
		local current = base["_" .. ring]:current_stop()
		local diff = (answer[i] - current) % ASD.STOPS

		if diff <= ASD.STOPS / 2 then
			for _ = 1, diff do
				table.insert(queue, "turn_" .. ring .. "_cw")
			end
		else
			for _ = 1, ASD.STOPS - diff do
				table.insert(queue, "turn_" .. ring .. "_ccw")
			end
		end
	end

	return queue
end

local function current_key(base)
	return string.join(":", { base._outer:current_stop(), base._middle:current_stop(), base._inner:current_stop() }):key()
end

function ASD:start()
	if self.active then
		return
	end

	local unit, base = find_door()

	if not unit then
		say("Secret puzzle door not found on this level")
		hint("Porte du Secret introuvable sur ce niveau")

		return
	end

	self.active, self.unit, self.base = true, unit, base

	-- Ending trace (mission_end_log.lua): logs the ending elements the mission runs from now on.
	if AutoSecretDoorInstallTrace then
		pcall(AutoSecretDoorInstallTrace)
		AutoSecretDoorTraceOn = true
	end
	self.phase, self.next_t, self.queue = "wait", 0, nil
	say("Secret puzzle door found - solving (riddles of this run: " .. table.concat(base._riddle_ids or {}, ", ") .. ")")
	hint("Porte du Secret : resolution automatique")
end

function ASD:stop(reason)
	if not self.active then
		return
	end

	self.active = false
	say("Stopped: " .. tostring(reason))
	hint("Porte du Secret : " .. tostring(reason))
end

function ASD:toggle()
	if self.active then
		self:stop("arret manuel")
	else
		self:start()
	end
end

function ASD:update(t)
	if not self.active or t < (self.next_t or 0) then
		return
	end

	local base = self.base

	if not alive(self.unit) then
		return self:stop("door unit gone")
	end

	local riddle = base._current_riddle

	if not riddle then
		-- init_puzzle() not run yet by the mission.
		if not self.wait_logged then
			self.wait_logged = true
			say("Waiting for the mission to activate the door (init_puzzle)...")
			hint("Porte du Secret : en attente de l'activation de la porte")
		end

		self.next_t = t + 1

		return
	end

	local riddle_id = base._riddle_ids and base._riddle_ids[riddle]
	local answer = riddle_id and self.ANSWERS[riddle_id]

	if not answer then
		return self:stop("unknown riddle id " .. tostring(riddle_id))
	end

	if self.phase == "wait" or self.riddle ~= riddle then
		self.riddle, self.phase = riddle, "turn"
		self.queue = plan_turns(base, answer)
		say(string.format("Riddle %d/%d (id %d): answer %d:%d:%d, %d ring turns", riddle, base.RIDDLE_COUNT or 4, riddle_id, answer[1], answer[2], answer[3], #self.queue))
	end

	if self.phase == "turn" then
		local step = table.remove(self.queue, 1)

		if step then
			base[step](base)
			self.next_t = t + self.TURN_DELAY

			return
		end

		self.phase, self.next_t = "submit", t + self.SUBMIT_DELAY

		return
	end

	if self.phase == "submit" then
		if current_key(base) ~= base._solution then
			-- Never send a wrong answer (it would reset the door to riddle 1).
			say("Answer check failed for riddle id " .. riddle_id .. " - nothing submitted")

			return self:stop("reponse non verifiee, rien envoye")
		end

		local last = riddle == (base.RIDDLE_COUNT or 4)

		say("Riddle " .. riddle .. " answer verified with the game's key - submitting")
		base:submit_answer()

		if last then
			say("All riddles solved (all_riddles_solved)")
			hint("Porte du Secret ouverte !")

			return self:stop("toutes les enigmes resolues")
		end

		self.phase, self.next_t = "wait", t + self.NEXT_DELAY
	end
end

Hooks:Add("GameSetupUpdate", "AutoSecretDoor_GameSetupUpdate", function(t, dt)
	if ASD.active then
		local ok, err = pcall(ASD.update, ASD, t)

		if not ok then
			say("ERROR: " .. tostring(err))
			ASD:stop("erreur, voir le log")
		end
	end
end)

say("Loaded")
