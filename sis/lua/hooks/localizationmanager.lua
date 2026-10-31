if not _G.SeamlessInputSwitch then
    dofile(ModPath .. "sis/lua/bootstrap.lua")
end

local SIS = _G.SeamlessInputSwitch

if not LocalizationManager or SIS._localization_manager_hooked then
    return
end

SIS._localization_manager_hooked = true

local original_setup_macros = LocalizationManager._setup_macros
local original_btn_macro = LocalizationManager.btn_macro

local INPUT_ALIASES = {
    confirm = "a",
    cancel = "b",
    cross = "a",
    circle = "b",
    square = "x",
    triangle = "y",
    face_down = "a",
    face_right = "b",
    face_left = "x",
    face_up = "y",
    plus = "start",
    minus = "back",
    select = "back",
    view = "back",
    share = "back",
    create = "back",
    options = "start",
    touchpad = "back",
    touchpad_click = "back",
    touchpad_press = "back",
    touchpad_left = "back",
    l = "left_shoulder",
    r = "right_shoulder",
    zl = "left_trigger",
    zr = "right_trigger",
    left_stick_btn = "left_thumb",
    right_stick_btn = "right_thumb",
    dpad_up = "d_up",
    dpad_down = "d_down",
    dpad_left = "d_left",
    dpad_right = "d_right",

 
    l1_trigger = "left_trigger",
    r1_trigger = "right_trigger",
    l2_trigger = "left_shoulder",
    r2_trigger = "right_shoulder"
}

local PLAYSTATION_TEXT = {
    a = "[X]",
    b = "[O]",
    x = "[SQ]",
    y = "[TRI]",
    back = "[BACK]",
    start = "[OPTIONS]",
    options = "[OPTIONS]",
    share = "[SHARE]",
    create = "[CREATE]",
    touchpad = "[TOUCHPAD]",
    touchpad_click = "[TOUCHPAD]",
    touchpad_press = "[TOUCHPAD]",
    touchpad_left = "[TOUCHPAD]",
    left = "[LS]",
    right = "[RS]",
    left_shoulder = "[L1]",
    right_shoulder = "[R1]",
    left_trigger = "[L2]",
    right_trigger = "[R2]",
    left_thumb = "[L3]",
    right_thumb = "[R3]",
    d_up = "[D-UP]",
    d_down = "[D-DOWN]",
    d_left = "[D-LEFT]",
    d_right = "[D-RIGHT]"
}

local PHYSICAL_MACROS = {
    BTN_BACK = "back",
    BTN_START = "start",
    BTN_A = "a",
    BTN_B = "b",
    BTN_X = "x",
    BTN_Y = "y",
    BTN_TOP_L = "left_trigger",
    BTN_TOP_R = "right_trigger",
    BTN_BOTTOM_L = "left_shoulder",
    BTN_BOTTOM_R = "right_shoulder",
    BTN_STICK_L = "left",
    BTN_STICK_R = "right",
    STICK_L = "left",
    STICK_R = "right",
    BTN_ATTACK = "a",
    BTN_BLOCK = "b"
}

local ACTION_MACROS = {
    BTN_ACCEPT = "confirm",
    BTN_CANCEL = "cancel",
    CONTINUE = "continue",
    BTN_INTERACT = "interact",
    BTN_USE_ITEM = "use_item",
    BTN_PRIMARY = "primary_attack",
    BTN_SECONDARY = "secondary_attack",
    BTN_RELOAD = "reload",
    BTN_JUMP = "jump",
    BTN_SKILLSET = "menu_switch_skillset",
    BTN_GADGET = "weapon_gadget",
    BTN_BIPOD = "deploy_bipod",
    BTN_SWITCH_WEAPON = "switch_weapon",
    BTN_STATS_VIEW = "stats_screen",
    BTN_RESET_SKILLS = "menu_respec_tree",
    BTN_RESET_ALL_SKILLS = "menu_respec_tree_all",
    BTN_CHANGE_EQ = "change_equipment",
    BTN_CHANGE_PROFILE_RIGHT = "menu_change_profile_right",
    BTN_CHANGE_PROFILE_LEFT = "menu_change_profile_left"
}

local function normalize_input_name(input_name, style)
    local key = tostring(input_name or "")

    if style == "playstation" and PLAYSTATION_TEXT[key] then
        return key
    end

    return INPUT_ALIASES[key] or key
end

local function get_pad_settings()
    local controller_manager = managers and managers.controller

    if not controller_manager or not controller_manager.get_settings then
        return nil, nil
    end

    local candidates = {}

    if SIS.preferred_pad_type then
        table.insert(candidates, SIS.preferred_pad_type)
    end

    table.insert(candidates, "xb1")
    table.insert(candidates, "xbox360")
    table.insert(candidates, "ps4")
    table.insert(candidates, "ps3")
    local seen = {}

    for _, pad_type in ipairs(candidates) do
        if pad_type and not seen[pad_type] then
            seen[pad_type] = true

            local ok, settings = pcall(controller_manager.get_settings, controller_manager, pad_type)

            if ok and settings then
                return settings, pad_type
            end
        end
    end

    return nil, nil
end

local function input_for_connection(connection_name)
    local settings, pad_type = get_pad_settings()

    if not settings or not settings.get_connection then
        return nil, pad_type
    end

    local custom_input = SIS:get_custom_gamepad_binding(connection_name, pad_type)

    if custom_input then
        return custom_input, pad_type
    end

    local ok, connection = pcall(settings.get_connection, settings, connection_name)

    if not ok or not connection or not connection.get_input_name_list then
        return nil, pad_type
    end

    local input_ok, input_names = pcall(connection.get_input_name_list, connection)
    local input_name = input_ok and input_names and input_names[1]

    return input_name, pad_type
end

local function text_for_input(localization_manager, input_name, to_upper)
    if not input_name then
        return nil
    end

    local style = SIS.settings.prompt_style
    local normalized_input = normalize_input_name(input_name, style)
    local result

    if style == "playstation" then
        result = PLAYSTATION_TEXT[normalized_input]
    elseif style == "xbox" and localization_manager.key_to_btn_text then
        result = localization_manager:key_to_btn_text(normalized_input, to_upper, "xb1")
    end

    if result and to_upper and utf8 and utf8.to_upper then
        return utf8.to_upper(result)
    end

    return result
end

local function text_for_connection(localization_manager, connection_name, to_upper)
    local input_name = input_for_connection(connection_name)

    return text_for_input(localization_manager, input_name, to_upper)
end

local function apply_prompt_macros(localization_manager)
    local style = SIS.settings.prompt_style

    if style == "pc" or not localization_manager or not localization_manager.set_default_macro then
        return
    end

    for macro_name, input_name in pairs(PHYSICAL_MACROS) do
        local value = text_for_input(localization_manager, input_name, false)

        if value then
            localization_manager:set_default_macro(macro_name, value)
        end
    end

    for macro_name, connection_name in pairs(ACTION_MACROS) do
        local value = text_for_connection(localization_manager, connection_name, false)

        if value then
            localization_manager:set_default_macro(macro_name, value)
        end
    end
end

if original_setup_macros then
    function LocalizationManager:_setup_macros(...)
        original_setup_macros(self, ...)
        apply_prompt_macros(self)
    end
end

if original_btn_macro then
    function LocalizationManager:btn_macro(button, to_upper, nil_if_empty)
        if SIS.settings.prompt_style ~= "pc" then
            local result = text_for_connection(self, button, to_upper)

            if result then
                return result
            elseif nil_if_empty then
                return nil
            end
        end

        return original_btn_macro(self, button, to_upper, nil_if_empty)
    end
end

function SIS:refresh_prompt_display(localization_manager)
    localization_manager = localization_manager or managers and managers.localization

    if not localization_manager or not localization_manager._setup_macros then
        return false
    end

    local ok, error_message = pcall(localization_manager._setup_macros, localization_manager)

    if not ok then
        self:log("Prompt labels could not be refreshed: " .. tostring(error_message))

        return false
    end

    self:refresh_interaction_text()

    return true
end

SIS:refresh_prompt_display()
SIS:log("Safe prompt-style hook installed (PC / Xbox / PlayStation text).", true)
