if not _G.SeamlessInputSwitch then
    dofile(ModPath .. "sis/lua/bootstrap.lua")
end

local SIS = _G.SeamlessInputSwitch

if not MenuInput or SIS._menu_input_hooked then
    return
end

SIS._menu_input_hooked = true

local original_activate_mouse = MenuInput.activate_mouse
local original_open = MenuInput.open
local original_mouse_moved = MenuInput.mouse_moved
local original_mouse_pressed = MenuInput.mouse_pressed
local original_give_special_buttons = MenuInput._give_special_buttons

local FALLBACK_SPECIAL_BUTTONS = {
    "menu_remove_skill",
    "menu_toggle_voice_message",
    "menu_respec_tree",
    "menu_respec_tree_all",
    "menu_switch_skillset",
    "menu_modify_item",
    "menu_preview_item",
    "menu_remove_item",
    "menu_preview_item_alt",
    "menu_toggle_legends",
    "menu_toggle_filters",
    "menu_toggle_ready",
    "toggle_chat",
    "menu_toggle_pp_drawboard",
    "menu_toggle_pp_breakdown",
    "trigger_left",
    "trigger_right",
    "menu_challenge_claim",
    "menu_edit_skin",
    "menu_change_profile_right",
    "menu_change_profile_left",
    "drop_in_accept",
    "drop_in_return",
    "drop_in_kick",
    "menu_toggle_show_tracked",
    "menu_toggle_tracked",
    "menu_preview_achievement",
    "menu_favorite_achievement",
    "menu_unlocked_achievement",
    "menu_clear",
    "cancel",
    "next_page",
    "previous_page",
    "menu_update",
    "continue",
    "menu_go_infamous"
}

local RAW_INPUT_ALIASES = {
    confirm = { "confirm", "a", "cross", "face_down" },
    cancel = { "cancel", "b", "circle", "face_right" },
    a = { "a", "cross", "face_down" },
    b = { "b", "circle", "face_right" },
    x = { "x", "square", "face_left" },
    y = { "y", "triangle", "face_up" },
    start = { "start", "options" }
}

local function raw_button_event(controller, method_name, input_name)
    local method = controller and controller[method_name]

    if not method or input_name == nil then
        return false
    end

    for _, candidate in ipairs(RAW_INPUT_ALIASES[input_name] or { input_name }) do
        local input_id = type(candidate) == "string" and Idstring(candidate) or candidate
        local ok, active = pcall(method, controller, input_id)

        if not ok and type(candidate) ~= "number" then
            ok, active = pcall(method, controller, candidate)
        end

        if ok and active then
            return true
        end
    end

    return false
end

local function raw_connection_event(wrapper, controller, connection_name, method_name)
    local connection = SIS:get_pad_connection_settings(wrapper, connection_name)

    if not connection or not connection.get_input_name_list then
        return false
    end

    if connection.get_connect_dest_type then
        local ok, destination_type = pcall(connection.get_connect_dest_type, connection)

        if ok and destination_type ~= "button" then
            return false
        end
    end

    for _, input_name in ipairs(connection:get_input_name_list() or {}) do
        if raw_button_event(controller, method_name, input_name) then
            return true
        end
    end

    return false
end

local function should_fallback_connection(wrapper, connection_name)
    local merged_connections = wrapper and wrapper._sis_pad_merged_connections

    if merged_connections and merged_connections[connection_name] then
        return false
    end

    if connection_name == "toggle_chat" then
        local wrapper_name = wrapper and (wrapper.get_name and wrapper:get_name() or wrapper._name)

        if wrapper_name == "MenuManager" then
            return false
        end
    end

    return true
end

function MenuInput:activate_mouse(position, controller_activated)
    if not SIS.settings.menu_mouse then
        return original_activate_mouse(self, position, controller_activated)
    end

    if self._mouse_active then
        SIS:sync_pointer()

        return
    end

    self._mouse_active = true

    managers.mouse_pointer:use_mouse({
        mouse_move = callback(self, self, "mouse_moved"),
        mouse_press = callback(self, self, "mouse_pressed"),
        mouse_release = callback(self, self, "mouse_released"),
        mouse_click = callback(self, self, "mouse_clicked"),
        mouse_double_click = callback(self, self, "mouse_double_click"),
        id = self._menu_name
    }, position)

    SIS:sync_pointer()
end

function MenuInput:open(...)
    local result = original_open(self, ...)

    SIS:sync_pointer()

    return result
end

function MenuInput:mouse_moved(o, x, y, mouse_ws, ...)

    if mouse_ws and not managers.mouse_pointer._controller_updater then
        SIS:set_active_type("pc", "menu-mouse")
    elseif not mouse_ws and SIS.active_family == "gamepad" then
    
        return
    end

    return original_mouse_moved(self, o, x, y, mouse_ws, ...)
end

function MenuInput:mouse_pressed(...)
    if not managers.mouse_pointer._controller_updater then
        SIS:set_active_type("pc", "menu-mouse-button")
    end

    return original_mouse_pressed(self, ...)
end

function MenuInput:_give_special_buttons(...)
    local result = original_give_special_buttons(self, ...)
    local wrapper = self._controller
    local pad_type = wrapper and wrapper._sis_pad_type

    if not self._accept_input or not wrapper or not wrapper._sis_hybrid or not pad_type or not SIS:is_type_allowed(pad_type) then
        return result
    end

    local controller = SIS:get_pad_controller(wrapper, true)
    local active_menu = managers and managers.menu and managers.menu:active_menu()
    local renderer = active_menu and active_menu.renderer

    if not controller or not renderer or not renderer.special_btn_pressed then
        return result
    end

    for _, connection_name in ipairs(FALLBACK_SPECIAL_BUTTONS) do
        if should_fallback_connection(wrapper, connection_name) then
            local button = Idstring(connection_name)

            if raw_connection_event(wrapper, controller, connection_name, "pressed") then
                SIS:set_active_type(pad_type, "menu-shortcut:" .. connection_name)

                if renderer:special_btn_pressed(button) then
                    if active_menu and active_menu.renderer then
                        active_menu.renderer:disable_input(0.2)
                    end

                    break
                end
            elseif renderer.special_btn_released and raw_connection_event(wrapper, controller, connection_name, "released") and renderer:special_btn_released(button) then
                renderer:disable_input(0.2)

                break
            end
        end
    end

    return result
end

SIS:log("Menu mouse hook installed.", true)
