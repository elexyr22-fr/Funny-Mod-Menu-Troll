if not _G.SeamlessInputSwitch then
    dofile(ModPath .. "sis/lua/bootstrap.lua")
end

local SIS = _G.SeamlessInputSwitch
local mod_path = SIS.MOD_PATH or ModPath

if SIS._menu_manager_hooked then
    return
end

SIS._menu_manager_hooked = true

Hooks:Add("LocalizationManagerPostInit", "SIS_LocalizationManagerPostInit", function(localization_manager)
    localization_manager:load_localization_file(mod_path .. "loc/en.json")

    if SystemInfo:language():key() == Idstring("polish"):key() then
        localization_manager:load_localization_file(mod_path .. "loc/pl.json")
    end

    if SIS.refresh_prompt_display then
        SIS:refresh_prompt_display(localization_manager)
    end
end)

Hooks:Add("MenuManagerInitialize", "SIS_MenuManagerInitialize", function()
    local settings_dirty = false
    local bindings_dirty = false
    local mode_options = { "auto", "pc", "gamepad" }
    local prompt_style_options = SIS.PROMPT_STYLE_CHOICES or { "pc", "xbox", "playstation" }

    MenuCallbackHandler.sis_mode = function(self, item)
        local selected_index = tonumber(item:value()) or 1
        local selected_mode = mode_options[selected_index] or "auto"

        if SIS.settings.mode ~= selected_mode then
            SIS.settings.mode = selected_mode
            settings_dirty = true
            SIS:apply_mode()
        end
    end

    MenuCallbackHandler.sis_prompt_style = function(self, item)
        local selected_index = tonumber(item:value()) or 1
        local selected_style = prompt_style_options[selected_index] or "pc"

        if SIS.settings.prompt_style ~= selected_style then
            SIS.settings.prompt_style = selected_style
            settings_dirty = true

            if SIS.refresh_prompt_display then
                SIS:refresh_prompt_display()
            end
        end
    end

    local function toggle_callback(setting_name)
        return function(self, item)
            local value = item:value() == "on"

            if SIS.settings[setting_name] ~= value then
                SIS.settings[setting_name] = value
                settings_dirty = true
            end
        end
    end

    MenuCallbackHandler.sis_menu_mouse = toggle_callback("menu_mouse")
    MenuCallbackHandler.sis_force_aim_assist = toggle_callback("force_aim_assist")
    MenuCallbackHandler.sis_aim_assist_sticky_enabled = toggle_callback("aim_assist_sticky_enabled")
    MenuCallbackHandler.sis_aim_assist_snap_enabled = toggle_callback("aim_assist_snap_enabled")
    MenuCallbackHandler.sis_gamepad_invert_y = toggle_callback("gamepad_invert_y")

    MenuCallbackHandler.sis_controller_vibration = function(self, item)
        local value = item:value() == "on"

        if SIS.settings.controller_vibration ~= value then
            SIS.settings.controller_vibration = value
            settings_dirty = true

            if not value and managers and managers.rumble and managers.rumble.stop then
                managers.rumble:stop("all")
            end
        end
    end

    MenuCallbackHandler.sis_custom_gamepad_bindings = function(self, item)
        local value = item:value() == "on"

        if SIS.settings.custom_gamepad_bindings ~= value then
            SIS.settings.custom_gamepad_bindings = value
            settings_dirty = true
            bindings_dirty = true
        end
    end

    for _, binding in ipairs(SIS.GAMEPAD_BINDINGS) do
        local setting_name = binding.setting

        MenuCallbackHandler["sis_" .. setting_name] = function(self, item)
            local selected_index = tonumber(item:value()) or 1
            local input_name = SIS.GAMEPAD_BINDING_CHOICES[selected_index] or SIS.DEFAULTS[setting_name]

            if SIS.settings[setting_name] ~= input_name then
                SIS.settings[setting_name] = input_name
                settings_dirty = true
                bindings_dirty = true
            end
        end
    end

    local function slider_callback(setting_name)
        return function(self, item)
            local value = tonumber(item:value()) or SIS.DEFAULTS[setting_name]

            if SIS.settings[setting_name] ~= value then
                SIS.settings[setting_name] = value
                settings_dirty = true
            end
        end
    end

    MenuCallbackHandler.sis_axis_threshold = slider_callback("axis_threshold")
    MenuCallbackHandler.sis_axis_change_threshold = slider_callback("axis_change_threshold")
    MenuCallbackHandler.sis_gamepad_look_sensitivity = slider_callback("gamepad_look_sensitivity")
    MenuCallbackHandler.sis_gamepad_ads_sensitivity = slider_callback("gamepad_ads_sensitivity")
    MenuCallbackHandler.sis_gamepad_look_deadzone = slider_callback("gamepad_look_deadzone")
    MenuCallbackHandler.sis_gamepad_look_outer_deadzone = slider_callback("gamepad_look_outer_deadzone")
    MenuCallbackHandler.sis_gamepad_look_response_curve = slider_callback("gamepad_look_response_curve")
    MenuCallbackHandler.sis_gamepad_move_deadzone = slider_callback("gamepad_move_deadzone")
    MenuCallbackHandler.sis_gamepad_move_outer_deadzone = slider_callback("gamepad_move_outer_deadzone")
    MenuCallbackHandler.sis_gamepad_move_response_curve = slider_callback("gamepad_move_response_curve")
    MenuCallbackHandler.sis_aim_assist_sticky_strength = slider_callback("aim_assist_sticky_strength")
    MenuCallbackHandler.sis_aim_assist_snap_strength = slider_callback("aim_assist_snap_strength")

    local function update_binding_menu_values()
        local active_menu = managers and managers.menu and managers.menu.active_menu and managers.menu:active_menu()
        local logic = active_menu and active_menu.logic
        local node = logic and logic.selected_node and logic:selected_node()

        if not node or not node.item then
            return
        end

        local enabled_item = node:item("sis_custom_gamepad_bindings")

        if enabled_item and enabled_item.set_value then
            enabled_item:set_value("off")
        end

        for _, binding in ipairs(SIS.GAMEPAD_BINDINGS) do
            local item = node:item("sis_" .. binding.setting)
            local default_index = table.index_of(SIS.GAMEPAD_BINDING_CHOICES, binding.default) or 1

            if item and item.set_value then
                item:set_value(default_index)
            end
        end
    end

    MenuCallbackHandler.sis_restore_vanilla_bindings = function()
        SIS:restore_vanilla_gamepad_bindings()
        update_binding_menu_values()
        settings_dirty = true
        bindings_dirty = true
    end

    MenuCallbackHandler.sis_flush_settings = function()
        if settings_dirty then
            settings_dirty = not SIS:save_settings()
        end

        if bindings_dirty then
            bindings_dirty = not SIS:request_controller_rebind()

            if SIS.refresh_prompt_display then
                SIS:refresh_prompt_display()
            end

        end
    end

    local data = {
        mode = table.index_of(mode_options, SIS.settings.mode) or 1,
        prompt_style = table.index_of(prompt_style_options, SIS.settings.prompt_style) or 1,
        force_aim_assist = SIS.settings.force_aim_assist,
        menu_mouse = SIS.settings.menu_mouse,
        controller_vibration = SIS.settings.controller_vibration,
        axis_threshold = SIS.settings.axis_threshold,
        axis_change_threshold = SIS.settings.axis_change_threshold,
        gamepad_look_sensitivity = SIS.settings.gamepad_look_sensitivity,
        gamepad_ads_sensitivity = SIS.settings.gamepad_ads_sensitivity,
        gamepad_look_deadzone = SIS.settings.gamepad_look_deadzone,
        gamepad_invert_y = SIS.settings.gamepad_invert_y
    }

    local aim_assist_data = {
        aim_assist_sticky_enabled = SIS.settings.aim_assist_sticky_enabled,
        aim_assist_snap_enabled = SIS.settings.aim_assist_snap_enabled,
        aim_assist_sticky_strength = SIS.settings.aim_assist_sticky_strength,
        aim_assist_snap_strength = SIS.settings.aim_assist_snap_strength
    }

    local controller_tuning_data = {
        gamepad_move_deadzone = SIS.settings.gamepad_move_deadzone,
        gamepad_move_outer_deadzone = SIS.settings.gamepad_move_outer_deadzone,
        gamepad_move_response_curve = SIS.settings.gamepad_move_response_curve,
        gamepad_look_outer_deadzone = SIS.settings.gamepad_look_outer_deadzone,
        gamepad_look_response_curve = SIS.settings.gamepad_look_response_curve
    }

    local binding_data = {
        custom_gamepad_bindings = SIS.settings.custom_gamepad_bindings
    }

    for _, binding in ipairs(SIS.GAMEPAD_BINDINGS) do
        binding_data[binding.setting] = table.index_of(SIS.GAMEPAD_BINDING_CHOICES, SIS.settings[binding.setting]) or table.index_of(SIS.GAMEPAD_BINDING_CHOICES, binding.default) or 1
    end

    MenuHelper:LoadFromJsonFile(mod_path .. "menus/options.json", nil, data)
    MenuHelper:LoadFromJsonFile(mod_path .. "menus/aim_assist.json", nil, aim_assist_data)
    MenuHelper:LoadFromJsonFile(mod_path .. "menus/controller_tuning.json", nil, controller_tuning_data)
    MenuHelper:LoadFromJsonFile(mod_path .. "menus/bindings.json", nil, binding_data)
end)

SIS:log("Options menu hook installed.", true)
