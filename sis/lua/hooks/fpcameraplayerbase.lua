if not _G.SeamlessInputSwitch then
    dofile(ModPath .. "sis/lua/bootstrap.lua")
end

local SIS = _G.SeamlessInputSwitch

if not FPCameraPlayerBase or SIS._camera_hooked then
    return
end

SIS._camera_hooked = true

local original_set_parent_unit = FPCameraPlayerBase.set_parent_unit
local original_update_rot = FPCameraPlayerBase._update_rot
local original_gamepad_look_function_ctl = FPCameraPlayerBase._gamepad_look_function_ctl
local original_get_aim_assist = FPCameraPlayerBase._get_aim_assist
local original_update_aim_assist_sticky = FPCameraPlayerBase._update_aim_assist_sticky

local function pack(...)
    return { n = select("#", ...), ... }
end

local function apply_look_mode(camera, wrapper_type)
    local family = SIS:family_for_type(wrapper_type)

    if family == "pc" then
        camera._look_function = callback(camera, camera, "_pc_look_function")
        camera._tweak_data.uses_keyboard = true
    elseif wrapper_type == "steam" or wrapper_type == "steampad" then
        camera._look_function = callback(camera, camera, "_steampad_look_function")
        camera._tweak_data.uses_keyboard = true
    elseif family == "gamepad" then
        camera._look_function = callback(camera, camera, "_gamepad_look_function_ctl")
        camera._tweak_data.uses_keyboard = false
    end
end

local function current_controller(camera)
    local parent = camera._parent_unit
    local base = parent and parent.base and parent:base()

    return base and base.controller and base:controller() or nil
end

local function current_player_state(camera)
    local parent = camera._parent_unit
    local movement = parent and parent.movement and parent:movement()

    return movement and movement.current_state and movement:current_state() or nil
end

local function camera_is_aiming(camera)
    local state = current_player_state(camera)

    if not state or not state.in_steelsight then
        return false
    end

    local ok, aiming = pcall(state.in_steelsight, state)

    return ok and aiming and true or false
end

local function connection_y_sign(connection, normalize_user_inversion)
    if not connection or not connection.get_inversion then
        return nil
    end

    local ok, inversion = pcall(connection.get_inversion, connection)

    if not ok or not inversion then
        return nil
    end

    local _, y = SIS:axis_components(inversion)

    if math.abs(y) < 0.001 then
        return nil
    end

    local sign = y < 0 and -1 or 1

    if normalize_user_inversion and connection.get_inversion_unmodified then
        local user_ok, user_inversion = pcall(connection.get_inversion_unmodified, connection)

        if user_ok and user_inversion then
            local _, user_y = SIS:axis_components(user_inversion)

            if math.abs(user_y) >= 0.001 then
                sign = sign * (user_y < 0 and -1 or 1)
            end
        end
    end

    return sign
end

local function gamepad_vertical_correction(camera)
    local wrapper = current_controller(camera)
    local pc_setup = wrapper and wrapper.get_setup and wrapper:get_setup()
    local pc_look = pc_setup and pc_setup.get_connection and pc_setup:get_connection("look")
    local pad_look = SIS:get_pad_connection_settings(wrapper, "look")
    local pc_y_sign = connection_y_sign(pc_look)
    local pad_y_sign = connection_y_sign(pad_look, true)
    local correction = pc_y_sign and pad_y_sign and pc_y_sign * pad_y_sign or 1

    if SIS.settings.gamepad_invert_y then
        correction = -correction
    end

    return correction
end

local function corrected_gamepad_axis(camera, axis)
    if not axis then
        return nil, 1
    end

    local correction = gamepad_vertical_correction(camera)

    if correction == 1 then
        return axis, correction
    end

    local x, y, z = SIS:axis_components(axis)

    return Vector3(x, y * correction, z), correction
end

local CAMERA_SPEED_FIELDS = {
    "look_speed_standard",
    "look_speed_fast",
    "look_speed_steel_sight"
}

local function call_with_gamepad_camera_qol(camera, stick_input, stick_input_multiplier, dt, unscaled_stick_input)
    local sensitivity = tonumber(SIS.settings.gamepad_look_sensitivity) or 1

    if camera_is_aiming(camera) then
        sensitivity = sensitivity * (tonumber(SIS.settings.gamepad_ads_sensitivity) or 1)
    end

    local corrected_axis, vertical_correction = corrected_gamepad_axis(camera, unscaled_stick_input)
    local look_deadzone = tonumber(SIS.settings.gamepad_look_deadzone) or 0.05

    corrected_axis = SIS:apply_stick_response(
        corrected_axis,
        look_deadzone,
        SIS.settings.gamepad_look_outer_deadzone,
        SIS.settings.gamepad_look_response_curve,
        look_deadzone
    )

    local tweak = camera._tweak_data
    local original_values = {}

    if tweak then
        for _, field_name in ipairs(CAMERA_SPEED_FIELDS) do
            local value = tweak[field_name]

            if type(value) == "number" then
                original_values[field_name] = value
                tweak[field_name] = value * sensitivity
            end
        end

        if type(tweak.look_speed_dead_zone) == "number" then
            original_values.look_speed_dead_zone = tweak.look_speed_dead_zone
            tweak.look_speed_dead_zone = look_deadzone
        end
    end

    local result = pack(pcall(function()
        if SIS.settings.force_aim_assist and SIS.settings.aim_assist_sticky_enabled then
            return SIS:call_with_aim_assist_semantics(
                original_gamepad_look_function_ctl,
                camera,
                stick_input,
                stick_input_multiplier,
                dt,
                corrected_axis
            )
        end

        return original_gamepad_look_function_ctl(camera, stick_input, stick_input_multiplier, dt, corrected_axis)
    end))

    if tweak then
        for field_name, value in pairs(original_values) do
            tweak[field_name] = value
        end
    end

    if not result[1] then
        error(result[2])
    end

    if not camera._sis_camera_qol_logged then
        camera._sis_camera_qol_logged = true
        SIS:log(
            string.format(
                "Gamepad camera QoL active: sensitivity=%.2f, ADS=%.2f, deadzone=%.2f, outer=%.2f, curve=%.2f, vertical=%s (route correction=%d).",
                tonumber(SIS.settings.gamepad_look_sensitivity) or 1,
                tonumber(SIS.settings.gamepad_ads_sensitivity) or 1,
                tonumber(SIS.settings.gamepad_look_deadzone) or 0.02,
                tonumber(SIS.settings.gamepad_look_outer_deadzone) or 0,
                tonumber(SIS.settings.gamepad_look_response_curve) or 1,
                SIS.settings.gamepad_invert_y and "inverted" or "normal",
                vertical_correction
            ),
            true
        )
    end

    return unpack(result, 2, result.n)
end

local function call_with_pad_look_multiplier(camera, func, ...)
    local wrapper = current_controller(camera)
    local pc_setup = wrapper and wrapper.get_setup and wrapper:get_setup()
    local pc_look = pc_setup and pc_setup.get_connection and pc_setup:get_connection("look")
    local pad_look = SIS:get_pad_connection_settings(wrapper, "look")

    if not pc_look or not pad_look or not pc_look.get_multiplier or not pc_look.set_multiplier or not pad_look.get_multiplier then
        return func(camera, ...)
    end

    local original_multiplier = pc_look:get_multiplier()
    local pad_multiplier = pad_look:get_multiplier()

    pc_look:set_multiplier(pad_multiplier)

    local result = pack(pcall(func, camera, ...))

    pc_look:set_multiplier(original_multiplier)

    if not result[1] then
        error(result[2])
    end

    return unpack(result, 2, result.n)
end

function FPCameraPlayerBase:set_parent_unit(...)
    local result = original_set_parent_unit(self, ...)

    apply_look_mode(self, SIS.active_type)

    return result
end


if original_gamepad_look_function_ctl then
    function FPCameraPlayerBase:_gamepad_look_function_ctl(stick_input, stick_input_multiplier, dt, unscaled_stick_input)
        return call_with_gamepad_camera_qol(self, stick_input, stick_input_multiplier, dt, unscaled_stick_input)
    end
end


if original_get_aim_assist then
    function FPCameraPlayerBase:_get_aim_assist(t, dt, speed, aim_data)
        if SIS.settings.force_aim_assist then
            if aim_data == self._aim_assist_sticky then
                if not SIS.settings.aim_assist_sticky_enabled then
                    self:_stop_aim_assist(aim_data)

                    return 0, 0
                end

                speed = speed * (tonumber(SIS.settings.aim_assist_sticky_strength) or 1)
            elseif aim_data == self._aim_assist then
                if not SIS.settings.aim_assist_snap_enabled then
                    self:_stop_aim_assist(aim_data)

                    return 0, 0
                end

                speed = speed * (tonumber(SIS.settings.aim_assist_snap_strength) or 1)
            end
        end

        return original_get_aim_assist(self, t, dt, speed, aim_data)
    end
end


if original_update_aim_assist_sticky then
    function FPCameraPlayerBase:_update_aim_assist_sticky(t, dt)
        if not SIS.settings.force_aim_assist then
            return original_update_aim_assist_sticky(self, t, dt)
        end

        if not SIS.settings.aim_assist_sticky_enabled then
            self:_stop_aim_assist(self._aim_assist_sticky)

            return
        end



        
        local weapon = self._parent_unit:inventory():equipped_unit()
        local player_state = self._parent_unit:movement():current_state()

        if weapon then
            local closest_ray = weapon:base():get_aim_assist(player_state:get_fire_weapon_position(), player_state:get_fire_weapon_direction(), nil, true)

            self:_start_aim_assist(closest_ray, self._aim_assist_sticky)
        else
            self:_stop_aim_assist(self._aim_assist_sticky)
        end
    end
end


function FPCameraPlayerBase:_update_rot(...)
    local source_type = SIS.active_type or "pc"

    apply_look_mode(self, source_type)

    if SIS:family_for_type(source_type) == "gamepad" then
        return call_with_pad_look_multiplier(self, original_update_rot, ...)
    end

    return original_update_rot(self, ...)
end

SIS:log("First-person camera, stick response and configurable aim-assist hook installed.", true)
