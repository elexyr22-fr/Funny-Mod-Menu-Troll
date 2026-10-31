if not _G.SeamlessInputSwitch then
    dofile(ModPath .. "sis/lua/bootstrap.lua")
end

local SIS = _G.SeamlessInputSwitch

if not IngameAccessCamera or not IngameAccessCamera._setup_controller or SIS._access_camera_hooked then
    return
end

SIS._access_camera_hooked = true

local original_setup_controller = IngameAccessCamera._setup_controller

local function pack(...)
    return { n = select("#", ...), ... }
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

local function gamepad_vertical_correction(controller)
    local pc_setup = controller and controller.get_setup and controller:get_setup()
    local pc_look = pc_setup and pc_setup.get_connection and pc_setup:get_connection("look")
    local pad_look = SIS:get_pad_connection_settings(controller, "look")
    local pc_y_sign = connection_y_sign(pc_look)
    local pad_y_sign = connection_y_sign(pad_look, true)
    local correction = pc_y_sign and pad_y_sign and pc_y_sign * pad_y_sign or 1

    if SIS.settings.gamepad_invert_y then
        correction = -correction
    end

    return correction
end

local function corrected_gamepad_look_axis(controller, axis)
    if not axis or not Vector3 then
        return axis
    end

    local correction = gamepad_vertical_correction(controller)

    if correction == 1 then
        return axis
    end

    local x, y, z = SIS:axis_components(axis)

    return Vector3(x, y * correction, z)
end

local function install_access_camera_axis_bridge(controller)
    if not controller or controller._sis_access_camera_axis_bridge or not controller.get_input_axis then
        return
    end

    controller._sis_access_camera_axis_bridge = true

    local original_get_input_axis = controller.get_input_axis

    controller.get_input_axis = function(wrapper, connection_name, ...)
        local axis = original_get_input_axis(wrapper, connection_name, ...)

        if connection_name == "look" and SIS.active_family == "gamepad" then
            return corrected_gamepad_look_axis(wrapper, axis)
        end

        return axis
    end
end

function IngameAccessCamera:_setup_controller(...)
    local result = pack(pcall(original_setup_controller, self, ...))

    if not result[1] then
        error(result[2])
    end

    install_access_camera_axis_bridge(self._controller)

    return unpack(result, 2, result.n)
end

SIS:log("Security-camera gamepad look correction hook installed.", true)
