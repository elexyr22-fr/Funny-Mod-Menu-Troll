if not _G.SeamlessInputSwitch then
    dofile(ModPath .. "sis/lua/bootstrap.lua")
end

local SIS = _G.SeamlessInputSwitch

if not PlayerInventoryGui or not PlayerInventoryGui.special_btn_pressed or SIS._player_inventory_gui_hooked then
    return
end

SIS._player_inventory_gui_hooked = true

local original_special_btn_pressed = PlayerInventoryGui.special_btn_pressed
local profile_switch_button = Idstring("menu_preview_item")

local function pack(...)
    return { n = select("#", ...), ... }
end

function PlayerInventoryGui:special_btn_pressed(button, ...)
    local result = pack(original_special_btn_pressed(self, button, ...))


    if SIS.active_family == "gamepad" and self._enabled and button == profile_switch_button and managers and managers.menu and managers.menu:is_pc_controller() then
        managers.menu:open_node("profile_switch", {})
    end

    return unpack(result, 1, result.n)
end

SIS:log("Player inventory gamepad shortcut hook installed.", true)
