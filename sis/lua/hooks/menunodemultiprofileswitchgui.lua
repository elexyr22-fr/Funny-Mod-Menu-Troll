if not _G.SeamlessInputSwitch then
    dofile(ModPath .. "sis/lua/bootstrap.lua")
end

local SIS = _G.SeamlessInputSwitch

if not MenuNodeMultiProfileSwitchGui or not MenuNodeMultiProfileSwitchGui.special_btn_pressed or SIS._multi_profile_switch_gui_hooked then
    return
end

SIS._multi_profile_switch_gui_hooked = true

local original_special_btn_pressed = MenuNodeMultiProfileSwitchGui.special_btn_pressed
local move_profile_button = Idstring("menu_preview_item_alt")

function MenuNodeMultiProfileSwitchGui:special_btn_pressed(button, ...)
    if SIS.active_family == "gamepad" and button == move_profile_button and self._selected_item and self._selected_item.name and not self._selected_item.item:parameters().previous_node then
        if self._moving_profile then
            self:_finish_profile_move()
        else
            self:_start_profile_move()
        end

        return
    end

    return original_special_btn_pressed(self, button, ...)
end

SIS:log("Multi-profile gamepad shortcut hook installed.", true)
