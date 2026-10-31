if not _G.SeamlessInputSwitch then
    dofile(ModPath .. "sis/lua/bootstrap.lua")
end

local SIS = _G.SeamlessInputSwitch

if not MenuSceneManager or SIS._menu_scene_manager_hooked then
    return
end

SIS._menu_scene_manager_hooked = true

local original_mouse_moved = MenuSceneManager.mouse_moved
local original_mouse_pressed = MenuSceneManager.mouse_pressed

function MenuSceneManager:_sis_release_preview_grabs()
    self._character_grabbed = false
    self._item_grabbed = false
    self._item_move_grabbed = false
    self._character_grabbed_current_x = nil
    self._character_grabbed_current_y = nil
    self._item_grabbed_current_x = nil
    self._item_grabbed_current_y = nil
    self._item_move_grabbed_current_x = nil
    self._item_move_grabbed_current_y = nil
end

if original_mouse_pressed then
    function MenuSceneManager:mouse_pressed(...)
        if self._sis_controller_preview then
            self:_sis_release_preview_grabs()
            self._sis_controller_preview = nil
        end

        return original_mouse_pressed(self, ...)
    end
end

function MenuSceneManager:mouse_moved(o, x, y, ...)
    if self._sis_controller_preview then
        self:_sis_release_preview_grabs()
        self._sis_controller_preview = nil
    end

    if self._character_grabbed and
        (self._character_grabbed_current_x == nil or self._character_grabbed_current_y == nil) then
        self._character_grabbed = false
    end

    if self._item_grabbed and
        (self._item_grabbed_current_x == nil or self._item_grabbed_current_y == nil) then
        self._item_grabbed = false
    end

    if self._item_move_grabbed and
        (self._item_move_grabbed_current_x == nil or self._item_move_grabbed_current_y == nil) then
        self._item_move_grabbed = false
    end

    return original_mouse_moved(self, o, x, y, ...)
end

SIS:log("Menu scene mixed-input crash guard installed.", true)
