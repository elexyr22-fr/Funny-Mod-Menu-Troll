if not _G.SeamlessInputSwitch then
    dofile(ModPath .. "sis/lua/bootstrap.lua")
end

local SIS = _G.SeamlessInputSwitch

if not MenuSceneGui or SIS._menu_scene_gui_hooked then
    return
end

SIS._menu_scene_gui_hooked = true

local original_update = MenuSceneGui.update

local function raw_axis(controller, axis_name)
    if not controller or not controller.axis then
        return nil
    end

    local axis_id = Idstring(axis_name)

    if controller.has_axis then
        local ok, available = pcall(controller.has_axis, controller, axis_id)

        if ok and not available then
            return nil
        end
    end

    local ok, axis = pcall(controller.axis, controller, axis_id)

    return ok and axis or nil
end

local function active_axis(axis)
    local x, y = SIS:axis_components(axis)
    local deadzone = math.max(0.12, tonumber(SIS.settings.axis_threshold) or 0.18)

    if math.abs(x) < deadzone then
        x = 0
    end

    if math.abs(y) < deadzone then
        y = 0
    end

    return x, y, x ~= 0 or y ~= 0
end

function MenuSceneGui:update(t, dt, ...)
    local result = original_update(self, t, dt, ...)
    local scene = managers and managers.menu_scene

    if not scene or not scene._sis_release_preview_grabs then
        return result
    end

    if SIS.active_family ~= "gamepad" then
        if scene._sis_controller_preview then
            scene:_sis_release_preview_grabs()
            scene._sis_controller_preview = nil
        end

        return result
    end

    local input = SIS:get_menu_input()
    local wrapper = input and input._controller
    local controller = wrapper and SIS:get_pad_controller(wrapper, true)

    if not controller then
        if scene._sis_controller_preview then
            scene:_sis_release_preview_grabs()
            scene._sis_controller_preview = nil
        end

        return result
    end

    local left_x, left_y, left_active = active_axis(raw_axis(controller, "left"))
    local right_x, right_y, right_active = active_axis(raw_axis(controller, "right"))

    if left_active or right_active then
        scene:_sis_release_preview_grabs()
        scene._sis_controller_preview = true
    elseif scene._sis_controller_preview then
        scene:_sis_release_preview_grabs()
        scene._sis_controller_preview = nil
    end

    local ok, error_message = pcall(function()
        if left_active and scene.controller_move then
            scene:controller_move(left_x * dt, left_y * dt)
        end

        if right_active and scene.controller_zoom then
            scene:controller_zoom(right_x * dt, right_y * dt)
        end
    end)

    if scene._sis_controller_preview then
        scene:_sis_release_preview_grabs()
    end

    if not ok then
        error(error_message)
    end

    return result
end

SIS:log("MenuSceneGui raw gamepad preview controls installed.", true)
