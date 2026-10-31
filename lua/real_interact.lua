-- FunnyMod.RealInteract (V15): runs an interaction that ALREADY exists on a unit with the same
-- calls, in the same order, as the local player pressing / holding the interact key.
-- Nothing is created, faked or deleted: the game's own interaction class does everything.
--
-- V14 bug (log 2026-09-30): the modules did `local RI = FunnyMod.RealInteract or dofile(...)`.
-- SuperBLT's dofile does not return the chunk's values, so RI was nil in auto_drill.lua
-- ("attempt to index upvalue 'RI'" every 0.3 s). V15: this file is loaded by mod.txt (first
-- hooks) and every caller reads FunnyMod.RealInteract at call time (FunnyMod.require_api).
--
-- Vanilla flow verified in the 248.2 source:
--   PlayerStandard:_check_action_interact (playerstandard.lua:2222)
--     -> ObjectInteractionManager:interact (objectinteractionmanager.lua:51)
--        -> int:interact_start(player, data) (interactionext.lua:432): _interact_blocked (+ hint),
--           say_waiting, then if the tweak has a timer: can_interact, _get_timer, sound_start,
--           _at_interact_start (mission callbacks, revive "start_revive_player"...) and
--           returns (false, timer); without timer it returns int:interact(player).
--     -> timer: PlayerStandard:_start_action_interact (2336): HUD bar, unequip animation,
--        send_to_peers_synched("sync_teammate_progress", 1, true, tweak, timer, false),
--        sync_interaction_anim.
--   after the timer: PlayerStandard:_end_action_interact (2383)
--     -> _interupt_action_interact(nil, nil, true) (2361): int:interact_interupt(player, true),
--        sync_teammate_progress(1, false, tweak, 0, true)
--     -> ObjectInteractionManager:end_action_interact (69): int:interact(player).
--   interact() is what syncs (sync_interacted, server_place_mission_door_device,
--   send_to_host("sync_pickup"), revive_player...). Host validation stays the host's.
--
-- RealInteract does exactly those interaction calls on the unit it is given, WITHOUT touching
-- managers.interaction:active_unit() (the player does not need to look at the unit) and without
-- the HUD bar / weapon unequip animation (local cosmetics). The teammate progress RPC is sent
-- like PlayerStandard does. interact_start / interact / can_interact / _interact_blocked are
-- wrapped by interactions.lua with the "Ignore requirements" context, so that option applies here
-- exactly as for a manual interaction, and only when it is ON.
--
-- API:
--   RI.can_interact(unit[, player])   -> true | false, reason
--   RI.start(unit[, player])          -> true, timer | true, nil ("done": no timer, interact ran)
--                                        | false, reason
--   RI.complete(unit[, player])       -> true | false, reason   (after start returned a timer)
--   RI.cancel(unit[, player])         -> interact_interupt(player, false) (vanilla release)
--   RI.trigger(unit[, player])        -> can_interact + start + complete at once: true | false, reason
FunnyMod = FunnyMod or {}
FunnyMod.RealInteract = FunnyMod.RealInteract or {}
local RI = FunnyMod.RealInteract

-- Player states that can interact (lib/units/beings/player/states/*): downed, cuffed, tased,
-- driving, zipline... are refused. civilian / mask_off / clean are left to the interaction's own
-- _is_in_required_state check (can_interact_in_civilian).
RI.ALLOWED_STATES = {
	standard = true,
	carry = true,
	mask_off = true,
	clean = true,
	civilian = true
}

function RI.local_player()
	local player = managers.player and managers.player:player_unit()
	return alive(player) and player or nil
end

-- true | false, reason
function RI.player_ready(player)
	if not alive(player) then
		return false, "no player"
	end
	local movement = player:movement()
	if not movement or type(movement.current_state_name) ~= "function" then
		return false, "no movement"
	end
	local state_name = movement:current_state_name()
	if not RI.ALLOWED_STATES[state_name] then
		return false, "player state " .. tostring(state_name)
	end
	-- The player is holding an interaction / deploying: never interfere with it.
	local state = type(movement.current_state) == "function" and movement:current_state()
	if state and (state._interact_expire_t or state._use_item_expire_t) then
		return false, "player busy"
	end
	local damage = player:character_damage()
	if damage and type(damage.dead) == "function" and damage:dead() then
		return false, "player dead"
	end
	return true
end

-- The position the game itself targets (BaseInteractionExt:interact_position = interaction
-- object, else unit position).
function RI.position(unit)
	local interaction = unit:interaction()
	if interaction and type(interaction.interact_position) == "function" then
		local ok, pos = pcall(interaction.interact_position, interaction)
		if ok and pos then
			return pos
		end
	end
	return unit:position()
end

-- Instance of the global class `class_name` (or of a subclass). class() in
-- core/lib/utils/coreclass.lua: instance metatable = class table, class_table.super = parent.
function RI.is_a(object, class_name)
	local class = rawget(_G, class_name)
	if type(object) ~= "table" or type(class) ~= "table" then
		return false
	end
	local mt = getmetatable(object)
	local guard = 0
	while type(mt) == "table" and guard < 32 do
		if mt == class then
			return true
		end
		mt = rawget(mt, "super")
		guard = guard + 1
	end
	return false
end

function RI.tweak_id(unit)
	local interaction = alive(unit) and unit:interaction()
	return interaction and type(interaction.tweak_data) == "string" and interaction.tweak_data or nil
end

local function player_or_local(player)
	return player or RI.local_player()
end

-- V18: WHY can_select refused (BaseInteractionExt:can_select checks, 248.2): required player
-- state (_is_in_required_state: unmasked / civilian / clean refused unless the tweak has
-- can_interact_in_civilian), required deployable, required skill. The 30/09 client log only had
-- "can_select=false" for every Gage package / shaped charge: this tells a casing-mode refusal
-- (player not masked, nothing is sent to the host) from a real requirement.
-- RI._last_code: "state" | "deployable" | "upgrade" | "other".
function RI.can_select_reason(interaction, player)
	local movement = alive(player) and player:movement()
	local state = movement and type(movement.current_state_name) == "function" and movement:current_state_name() or "?"
	local function check(name, ...)
		local f = interaction[name]
		if type(f) ~= "function" then
			return true
		end
		local ok, result = pcall(f, interaction, ...)
		return not ok or result and true or false
	end
	if not check("_is_in_required_state", state) then
		RI._last_code = "state"
		return "can_select=false (player state " .. tostring(state) .. ": put the mask on)"
	end
	if not check("_has_required_deployable") then
		RI._last_code = "deployable"
		local td = interaction._tweak_data
		return "can_select=false (required deployable " .. tostring(type(td) == "table" and td.required_deployable or "?") .. ")"
	end
	if not check("_has_required_upgrade", state) then
		RI._last_code = "upgrade"
		return "can_select=false (required skill)"
	end
	RI._last_code = "other"
	return "can_select=false (state " .. tostring(state) .. ")"
end

-- Same checks as a manual interaction, no hint shown: true | false, reason [, code].
function RI.can_interact(unit, player)
	player = player_or_local(player)
	if not player then
		return false, "no player"
	end
	if not alive(unit) then
		return false, "unit gone"
	end
	local interaction = unit:interaction()
	if not interaction then
		return false, "no interaction"
	end
	if type(interaction.active) ~= "function" or not interaction:active() then
		return false, "inactive"
	end
	if type(interaction.disabled) == "function" and interaction:disabled() then
		return false, "disabled"
	end
	if type(interaction.can_select) == "function" and not interaction:can_select(player) then
		local reason = RI.can_select_reason(interaction, player)
		return false, reason, RI._last_code
	end
	if type(interaction._interact_blocked) == "function" and interaction:_interact_blocked(player) then
		return false, "blocked"
	end
	if type(interaction.can_interact) == "function" and not interaction:can_interact(player) then
		return false, "can_interact=false"
	end
	return true
end
-- V14 name.
RI.available = RI.can_interact

local function send_progress(started, tweak, timer, complete)
	local session = managers.network and managers.network:session()
	if session and type(session.send_to_peers_synched) == "function" then
		-- Same RPC and arguments as PlayerStandard:_start_action_interact / _interupt_action_interact.
		pcall(session.send_to_peers_synched, session, "sync_teammate_progress", 1, started, tweak or "", timer or 0, complete and true or false)
	end
end

-- interact_start. true, timer (held interaction started) | true, nil (instant interaction, interact
-- already ran inside interact_start) | false, reason.
function RI.start(unit, player)
	player = player_or_local(player)
	if not player or not alive(unit) or not unit:interaction() then
		return false, "no unit / player"
	end
	local interaction = unit:interaction()
	local tweak = interaction.tweak_data
	local interacted, timer = interaction:interact_start(player, nil)
	if timer then
		send_progress(true, tweak, timer, false)
		return true, timer
	end
	-- ObjectInteractionManager:interact counts nil as "interacted" (many interact() return nothing):
	-- only an explicit false is a refusal. The real result is checked by the confirmation phase.
	if interacted == false then
		return false, "interact_start refused"
	end
	return true, nil
end

-- Completion of a held interaction (PlayerStandard:_end_action_interact).
function RI.complete(unit, player)
	player = player_or_local(player)
	if not player then
		return false, "no player"
	end
	if not alive(unit) or not unit:interaction() then
		return false, "unit gone before completion"
	end
	local interaction = unit:interaction()
	local tweak = interaction.tweak_data
	interaction:interact_interupt(player, true)
	send_progress(false, tweak, 0, true)
	if not alive(unit) or not unit:interaction() then
		return false, "unit gone after interupt"
	end
	unit:interaction():interact(player)
	return true
end

-- Vanilla release of a held interaction (PlayerStandard:_interupt_action_interact, complete nil).
function RI.cancel(unit, player)
	player = player_or_local(player)
	if not player or not alive(unit) or not unit:interaction() then
		return
	end
	local interaction = unit:interaction()
	pcall(interaction.interact_interupt, interaction, player, false)
	send_progress(false, interaction.tweak_data, 0, false)
end

-- Everything at once (no wait for the timer). true | false, reason.
function RI.trigger(unit, player)
	player = player_or_local(player)
	local ok, why = RI.can_interact(unit, player)
	if not ok then
		return false, why
	end
	local started, timer_or_why = RI.start(unit, player)
	if not started then
		return false, timer_or_why
	end
	if timer_or_why then
		return RI.complete(unit, player)
	end
	return true
end

-- Loads a FunnyMod API that another file owns if it is not loaded yet, and returns it.
-- dofile's return value is never used (SuperBLT's dofile does not forward it).
function FunnyMod.require_api(name, file)
	if FunnyMod[name] == nil and file then
		local base = ModPath or (FunnyModMenu and FunnyModMenu.path) or ""
		pcall(dofile, base .. "lua/" .. file)
	end
	return FunnyMod[name]
end
