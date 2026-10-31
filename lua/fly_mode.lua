-- Fly Mode / No Clip for the LOCAL player only (PlayerStandard is the local player's state class;
-- PlayerCarry, PlayerMaskOff, PlayerClean and PlayerCivilian share its _update_movement).
-- Nothing global: no time scale, no world collision change, no other unit touched.
--
-- Built on the game's own movement mechanics (playerstandard.lua, 248.2):
--   Fly        mover kept, gravity 0 (what _activate_mover does on a ladder), velocity cleared,
--              position driven with movement():set_position like _update_movement does, so the
--              mover still collides with walls.
--   No Clip    the mover is removed with unit:kill_mover(), exactly what _start_action_zipline
--              does, and the position is set directly (zipline movement). No collision for the
--              local player only.
--   Both       free 3D flight through everything.
-- Controls: WASD (move axis) / Space (jump) up / Ctrl (duck) down / Shift (run) faster. In Fly the
-- direction follows the camera pitch. No Clip alone walks on the camera's flat plane and follows
-- the floor below (ground ray, same slot mask as PlayerStandard).
-- While active: jump, duck, landing/fall damage (_update_foley) are skipped, as on a zipline.
-- The position is sent with the native _update_network_position, so other players see it.
-- Off: mover reactivated (_activate_mover), gravity restored, and if the player is in the air or
-- was in No Clip the player is warped to the nearest navmesh point (nav tracker field_position).
-- Reset to OFF at every level unload / mission end (reset() called by core.lua). Never saved.

FlyMode = FlyMode or {}
local FM = FlyMode

FM.FLY_SPEED = 800
FM.FAST_MUL = 3
FM.NOCLIP_STEP_UP = 60
FM.NOCLIP_FLOOR_SEARCH = 600
FM.NOCLIP_FALL_SPEED = 1500
FM.ALLOWED_STATES = { standard = true, carry = true, mask_off = true, clean = true, civilian = true }
FM.fly = FM.fly or false
FM.noclip = FM.noclip or false

local function hint(key, state)
	if managers.hud and managers.hud.show_hint then
		local fmm = rawget(_G, "FunnyModMenu")
		local text = fmm and (fmm.L(key) .. " : " .. fmm.L(state and "fmmt_on" or "fmmt_off")) or (key .. " : " .. (state and "ON" or "OFF"))
		managers.hud:show_hint({ text = text })
	end
end

function FM:is_fly()
	return FM.fly and true or false
end

function FM:is_noclip()
	return FM.noclip and true or false
end

function FM:set_fly(state)
	FM.fly = state and true or false
	log("[ModMenu] Fly Mode -> " .. (FM.fly and "ON" or "OFF"))
	hint("fmmt_fly", FM.fly)
end

function FM:set_noclip(state)
	FM.noclip = state and true or false
	log("[ModMenu] No Clip -> " .. (FM.noclip and "ON" or "OFF"))
	hint("fmmt_noclip", FM.noclip)
end

function FM:is_both()
	return FM.fly and FM.noclip
end

function FM:set_both(state)
	FM.fly = state and true or false
	FM.noclip = state and true or false
	log("[ModMenu] Fly + No Clip -> " .. (state and "ON" or "OFF"))
	hint("fmmt_fly_noclip", state)
end

-- Level unload / mission end / restart / lobby. The restore itself happens on the next update of
-- the player state, or is not needed at all when the player unit is destroyed with the level.
function FM.reset()
	FM.fly = false
	FM.noclip = false
	FM._applied = nil
end

local function active_for(state)
	if not (FM.fly or FM.noclip) then
		return false
	end
	local ext = state._ext_movement
	local name = ext and type(ext.current_state_name) == "function" and ext:current_state_name()
	if not FM.ALLOWED_STATES[name] then
		return false
	end
	local sd = state._state_data
	if sd and (sd.on_zipline or sd.on_ladder) then
		return false
	end
	return true
end
FM.active_for = active_for

local function input_bool(state, name)
	local c = state._controller
	if not c or type(c.get_input_bool) ~= "function" then
		return false
	end
	local ok, v = pcall(c.get_input_bool, c, name)
	return ok and v and true or false
end

local function mover_for(state)
	local sd = state._state_data
	return sd and sd.ducking and PlayerStandard.MOVER_DUCK or PlayerStandard.MOVER_STAND
end

local function set_still(mover, gravity_z)
	mover:set_gravity(Vector3(0, 0, gravity_z))
	mover:set_velocity(Vector3(0, 0, 0))
end

local function floor_z(state, pos)
	local from = pos + math.UP * FM.NOCLIP_STEP_UP
	local to = pos - math.UP * FM.NOCLIP_FLOOR_SEARCH
	local ray = World:raycast("ray", from, to, "slot_mask", state._slotmask_gnd_ray, "ray_type", "body mover")
	return ray and ray.position and ray.position.z or nil
end

function FM.update(state, t, dt)
	local unit = state._unit
	local fly, noclip = FM.fly, FM.noclip
	FM._applied = { unit_key = unit:key(), noclip = noclip }

	if noclip then
		if unit:mover() then
			unit:kill_mover()
		end
	else
		if not unit:mover() then
			state:_activate_mover(mover_for(state))
		end
		set_still(unit:mover(), 0)
	end

	local dir = Vector3(0, 0, 0)
	local stick = state._stick_move
	if stick and mvector3.length(stick) >= PlayerStandard.MOVEMENT_DEADZONE then
		local right = state._ext_camera:rotation():x()
		local fwd = fly and state._cam_fwd or state._cam_fwd_flat
		if not fly then
			right = Vector3(right.x, right.y, 0)
		end
		dir = fwd * stick.y + right * stick.x
	end
	if fly then
		if input_bool(state, "jump") then
			dir = dir + math.UP
		end
		if input_bool(state, "duck") then
			dir = dir - math.UP
		end
	end

	local speed
	if fly then
		speed = FM.FLY_SPEED * (input_bool(state, "run") and FM.FAST_MUL or 1)
		local ps = rawget(_G, "PlayerSpeed")
		if ps and type(ps.is_enabled) == "function" and ps:is_enabled() then
			speed = speed * ps:multiplier()
		end
	else
		speed = state:_get_max_walk_speed(t)
	end

	local len = mvector3.length(dir)
	local pos_new = mvector3.copy(state._pos)
	if len > 0.01 then
		pos_new = pos_new + dir * (speed * dt / math.max(len, 1))
	end
	if noclip and not fly then
		local z = floor_z(state, pos_new)
		if z then
			if z < pos_new.z then
				mvector3.set_z(pos_new, math.max(z, pos_new.z - FM.NOCLIP_FALL_SPEED * dt))
			else
				mvector3.set_z(pos_new, z)
			end
		end
	end

	unit:movement():set_position(pos_new)
	mvector3.set_static(state._last_velocity_xy, 0, 0, 0)
	if state._state_data then
		state._state_data.in_air = false
		state._state_data.enter_air_pos_z = pos_new.z
	end
	state:_update_network_position(t, dt, pos_new, pos_new)
end

function FM.restore(state)
	local applied = FM._applied
	FM._applied = nil
	local unit = state._unit
	if not alive(unit) or not applied or applied.unit_key ~= unit:key() then
		return
	end
	if not unit:mover() then
		state:_activate_mover(mover_for(state))
	end
	if unit:mover() then
		set_still(unit:mover(), -982)
	end

	local pos = unit:position()
	state:_update_ground_ray()
	if applied.noclip or not state._gnd_ray then
		local target = pos
		local tracker = state._ext_movement and state._ext_movement:nav_tracker()
		if tracker then
			local ok = pcall(tracker.move, tracker, pos)
			local okf, field = pcall(tracker.field_position, tracker)
			if ok and okf and field then
				target = field
			end
		end
		if mvector3.distance(target, pos) > 30 then
			unit:warp_to(unit:rotation(), target)
			local network = state._ext_network
			if network and type(network.send) == "function" then
				pcall(network.send, network, "action_teleport", target)
			end
			pos = target
			log("[ModMenu] Fly/NoClip off -> replaced on navmesh")
		end
	end
	if state._state_data then
		state._state_data.in_air = false
		state._state_data.enter_air_pos_z = pos.z
	end
	unit:set_driving("script")
end

if RequiredScript == "lib/units/beings/player/states/playerstandard" and PlayerStandard and not FM._hooked then
	FM._hooked = true

	local original_update_movement = PlayerStandard._update_movement
	function PlayerStandard:_update_movement(t, dt)
		if active_for(self) then
			local ok, err = pcall(FM.update, self, t, dt)
			if ok then
				return
			end
			log("[FlyMode] update failed, back to normal movement: " .. tostring(err))
			FM.fly, FM.noclip = false, false
		end
		if FM._applied then
			local ok, err = pcall(FM.restore, self)
			if not ok then
				log("[FlyMode] restore failed: " .. tostring(err))
			end
		end
		return original_update_movement(self, t, dt)
	end

	local function skip_while_active(method)
		local original = PlayerStandard[method]
		PlayerStandard[method] = function(self, ...)
			if active_for(self) then
				return
			end
			return original(self, ...)
		end
	end
	skip_while_active("_update_foley")
	skip_while_active("_check_action_jump")
	skip_while_active("_check_action_duck")
	skip_while_active("_start_action_ducking")
	skip_while_active("_end_action_ducking")
end
