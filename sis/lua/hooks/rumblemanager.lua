if not _G.SeamlessInputSwitch then
    dofile(ModPath .. "sis/lua/bootstrap.lua")
end

local SIS = _G.SeamlessInputSwitch
local RumbleManagerClass

if type(RumbleManager) == "table" then
    RumbleManagerClass = RumbleManager.RumbleManager

    if not RumbleManagerClass and RumbleManager.register_controller then
        RumbleManagerClass = RumbleManager
    end
end

if not RumbleManagerClass and CoreRumbleManager then
    RumbleManagerClass = CoreRumbleManager.RumbleManager
end

if not RumbleManagerClass or not RumbleManagerClass.register_controller or not RumbleManagerClass.unregister_controller or not RumbleManagerClass.play or SIS._rumble_manager_hooked then
    return
end

SIS._rumble_manager_hooked = true

local original_register_controller = RumbleManagerClass.register_controller
local original_unregister_controller = RumbleManagerClass.unregister_controller
local original_play = RumbleManagerClass.play

local function rumble_wrapper(controller_wrapper)
    if not controller_wrapper or not controller_wrapper._sis_hybrid then
        return controller_wrapper
    end

    if controller_wrapper._sis_rumble_proxy then
        return controller_wrapper._sis_rumble_proxy
    end

    local pad_controller = SIS:get_pad_controller(controller_wrapper, false)
    local pad_type = controller_wrapper._sis_pad_type

    if not pad_controller or not SIS:is_gamepad_type(pad_type) then
        return controller_wrapper
    end

    local proxy = {
        TYPE = pad_type,
        _sis_raw_controller = pad_controller
    }

    function proxy:get_controller()
        return self._sis_raw_controller
    end

    controller_wrapper._sis_rumble_proxy = proxy

    return proxy
end

function RumbleManagerClass:register_controller(controller_wrapper, pos_callback, ...)
    return original_register_controller(self, rumble_wrapper(controller_wrapper), pos_callback, ...)
end

function RumbleManagerClass:unregister_controller(controller_wrapper, pos_callback, ...)
    return original_unregister_controller(self, rumble_wrapper(controller_wrapper), pos_callback, ...)
end

function RumbleManagerClass:play(...)
    if SIS.settings.controller_vibration == false then
        return false
    end

    return original_play(self, ...)
end
