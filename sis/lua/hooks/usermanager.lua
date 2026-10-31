if not _G.SeamlessInputSwitch then
    dofile(ModPath .. "sis/lua/bootstrap.lua")
end

local SIS = _G.SeamlessInputSwitch

if not GenericUserManager or not GenericUserManager.get_setting or SIS._user_manager_hooked then
    return
end

SIS._user_manager_hooked = true

local original_get_setting = GenericUserManager.get_setting

function GenericUserManager:get_setting(name, ...)
 
    if name == "sticky_aim" and SIS._aim_assist_scope and SIS.settings.force_aim_assist then
        return true
    end

    return original_get_setting(self, name, ...)
end

SIS:log("Scoped aim-assist settings hook installed.", true)
