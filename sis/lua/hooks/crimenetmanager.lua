if not _G.SeamlessInputSwitch then
    dofile(ModPath .. "sis/lua/bootstrap.lua")
end

local SIS = _G.SeamlessInputSwitch

if not CrimeNetGui or not CrimeNetGui.update or not CrimeNetGui.close or SIS._crimenet_manager_hooked then
    return
end

SIS._crimenet_manager_hooked = true

local original_update = CrimeNetGui.update
local original_close = CrimeNetGui.close
local original_disable_crimenet = CrimeNetGui.disable_crimenet

local function pack(...)
    return { n = select("#", ...), ... }
end

local function pad_controller()
    local input = SIS:get_menu_input()
    local wrapper = input and input._controller

    return wrapper and SIS:get_pad_controller(wrapper, true) or nil
end

local function pointer_call(pointer, method_name, ...)
    local method = pointer[method_name]

    if not method then
        return true
    end

    local ok, result = pcall(method, pointer, ...)

    if not ok then
        SIS:log("Crime.net pointer " .. method_name .. " failed: " .. tostring(result))
    end

    return ok, result
end

local function restore_mouse_pointer(gui)
    local state = gui._sis_crimenet_pointer

    if not state then
        return true
    end

    local pointer = state.pointer

    if pointer._controller_updater and pointer._controller_updater ~= state.updater then
        gui._sis_crimenet_pointer = nil

        return true
    end

    if pointer._controller_updater then
        local ok = pointer_call(pointer, "change_controller_to_mouse")

        if not ok or pointer._controller_updater then
            return false
        end
    end

    state.updater = nil

    if pointer._confine_panel == gui._panel then
        local ok

        if state.previous_confine then
            ok = pointer_call(pointer, "confine_mouse_pointer", state.previous_confine)
        else
            ok = pointer_call(pointer, "release_mouse_pointer")
        end

        if not ok then
            return false
        end
    end

    if pointer._mouse_callbacks and #pointer._mouse_callbacks > 0 and pointer._activate then
        if not pointer_call(pointer, "_activate") then
            return false
        end
    end

    gui._sis_crimenet_pointer = nil

    return true
end

local function activate_crimenet_pointer(gui)
    if not SIS.settings.menu_mouse or not gui._crimenet_enabled or not managers or not managers.mouse_pointer then
        restore_mouse_pointer(gui)

        return
    end

    local controller = pad_controller()
    local pointer = managers.mouse_pointer
    local state = gui._sis_crimenet_pointer

    if state and state.updater and state.pointer == pointer and state.updater == pointer._controller_updater and state.controller == controller then
        return
    end

    if not restore_mouse_pointer(gui) then
        return
    end

    if not controller or pointer._controller_updater or not pointer.change_mouse_to_controller then
        return
    end

    local previous_confine = pointer._confine_panel
    state = {
        pointer = pointer,
        controller = controller,
        previous_confine = previous_confine
    }
    gui._sis_crimenet_pointer = state

    if gui._panel and pointer.confine_mouse_pointer then
        if not pointer_call(pointer, "confine_mouse_pointer", gui._panel) then
            restore_mouse_pointer(gui)

            return
        end
    end

    local ok, changed = pointer_call(pointer, "change_mouse_to_controller", controller)
    state.updater = pointer._controller_updater

    if not ok or not changed then
        restore_mouse_pointer(gui)

        return
    end

    if pointer._mouse_callbacks and #pointer._mouse_callbacks > 0 and pointer._activate then
        if not pointer_call(pointer, "_activate") then
            restore_mouse_pointer(gui)

            return
        end
    end

    if not gui._sis_crimenet_pointer_centered and gui._panel and pointer.set_mouse_world_position and managers.gui_data and managers.gui_data.safe_to_full then
        local position_ok, x, y = pcall(function()
            return managers.gui_data:safe_to_full(gui._panel:world_center())
        end)

        if position_ok then
            gui._sis_crimenet_pointer_centered = true
            pointer_call(pointer, "set_mouse_world_position", x, y)
        end
    end
end

function CrimeNetGui:update(...)
    if SIS.active_family == "gamepad" then
        activate_crimenet_pointer(self)
    else
        restore_mouse_pointer(self)
    end

    return original_update(self, ...)
end

function CrimeNetGui:close(...)
    restore_mouse_pointer(self)

    local result = pack(pcall(original_close, self, ...))

    restore_mouse_pointer(self)

    if not result[1] then
        error(result[2])
    end

    return unpack(result, 2, result.n)
end

if original_disable_crimenet then
    function CrimeNetGui:disable_crimenet(...)
        restore_mouse_pointer(self)

        return original_disable_crimenet(self, ...)
    end
end

SIS:log("Crime.net isolated gamepad cursor hook installed.", true)
