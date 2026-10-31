if _G.SeamlessInputSwitch then
    return
end

local SIS = {
    VERSION = "1.1.1",
    ARCHITECTURE = "single-vc-merged-input-pc-ui",
    UI_TYPE = "pc",
    DYNAMIC_UI = false,
    MOD_PATH = ModPath .. "sis/",
    SAVE_FILE = SavePath .. "seamless_input_switch.json",
    PAD_TYPES = {
        xbox360 = true,
        xb1 = true,
        ps3 = true,
        ps4 = true,
        steam = true,
        steampad = true,
        gyropad = true
    },
    CUSTOM_BIND_PAD_TYPES = {
        xbox360 = true,
        xb1 = true
    },
    PROMPT_STYLE_CHOICES = {
        "pc",
        "xbox",
        "playstation"
    },
    GAMEPAD_BINDING_CHOICES = {
        "a",
        "b",
        "x",
        "y",
        "left_shoulder",
        "right_shoulder",
        "left_trigger",
        "right_trigger",
        "left_thumb",
        "right_thumb",
        "d_up",
        "d_down",
        "d_left",
        "d_right"
    },
    GAMEPAD_BINDINGS = {
        { connection = "primary_attack", setting = "bind_primary_attack", default = "right_trigger" },
        { connection = "secondary_attack", setting = "bind_secondary_attack", default = "left_trigger" },
        { connection = "interact", setting = "bind_interact", default = "right_shoulder" },
        { connection = "use_item", setting = "bind_use_item", default = "left_shoulder" },
        { connection = "reload", setting = "bind_reload", default = "x" },
        { connection = "jump", setting = "bind_jump", default = "a" },
        { connection = "duck", setting = "bind_duck", default = "b" },
        { connection = "switch_weapon", setting = "bind_switch_weapon", default = "y" },
        { connection = "run", setting = "bind_run", default = "left_thumb" },
        { connection = "melee", setting = "bind_melee", default = "right_thumb" },
        { connection = "throw_grenade", setting = "bind_throw_grenade", default = "d_left" },
        { connection = "weapon_gadget", setting = "bind_weapon_gadget", default = "d_down" },
        { connection = "weapon_firemode", setting = "bind_weapon_firemode", default = "d_right" }
    },
    DEFAULTS = {
        mode = "auto",
        prompt_style = "pc",
        force_aim_assist = true,
        aim_assist_sticky_enabled = true,
        aim_assist_snap_enabled = true,
        aim_assist_sticky_strength = 1.00,
        aim_assist_snap_strength = 1.00,
        custom_gamepad_bindings = false,
        bind_primary_attack = "right_trigger",
        bind_secondary_attack = "left_trigger",
        bind_interact = "right_shoulder",
        bind_use_item = "left_shoulder",
        bind_reload = "x",
        bind_jump = "a",
        bind_duck = "b",
        bind_switch_weapon = "y",
        bind_run = "left_thumb",
        bind_melee = "right_thumb",
        bind_throw_grenade = "d_left",
        bind_weapon_gadget = "d_down",
        bind_weapon_firemode = "d_right",
        menu_mouse = true,
        controller_vibration = true,
        axis_threshold = 0.18,
        axis_change_threshold = 0.10,
        gamepad_look_sensitivity = 2.00,
        gamepad_ads_sensitivity = 1.00,
        gamepad_look_deadzone = 0.05,
        gamepad_look_outer_deadzone = 0.00,
        gamepad_look_response_curve = 1.00,
        gamepad_move_deadzone = 0.10,
        gamepad_move_outer_deadzone = 0.00,
        gamepad_move_response_curve = 1.00,
        gamepad_invert_y = false,
        verbose_logging = false
    },
    settings = {},
    active_type = nil,
    active_family = nil,
    preferred_pad_type = nil,
    hybrid_available = false,
    wrappers = setmetatable({}, { __mode = "k" }),
    raw_axis_state = setmetatable({}, { __mode = "k" }),
    raw_button_state = setmetatable({}, { __mode = "k" }),
    raw_axis_catalog = setmetatable({}, { __mode = "k" }),
    raw_button_catalog = setmetatable({}, { __mode = "k" }),
    _pointer_syncing = false,
    _aim_assist_scope = false,
    _gamepad_semantics_scope = false
}

SIS.GAMEPAD_BINDING_CHOICE_SET = {}
SIS.GAMEPAD_BINDING_BY_CONNECTION = {}
SIS.PROMPT_STYLE_CHOICE_SET = {}

for _, input_name in ipairs(SIS.GAMEPAD_BINDING_CHOICES) do
    SIS.GAMEPAD_BINDING_CHOICE_SET[input_name] = true
end

for _, binding in ipairs(SIS.GAMEPAD_BINDINGS) do
    SIS.GAMEPAD_BINDING_BY_CONNECTION[binding.connection] = binding
end

for _, prompt_style in ipairs(SIS.PROMPT_STYLE_CHOICES) do
    SIS.PROMPT_STYLE_CHOICE_SET[prompt_style] = true
end

_G.SeamlessInputSwitch = SIS

local function shallow_copy(source)
    local result = {}

    for key, value in pairs(source or {}) do
        result[key] = value
    end

    return result
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function pack(...)
    return { n = select("#", ...), ... }
end

function SIS:log(message, verbose_only)
    if verbose_only and not self.settings.verbose_logging then
        return
    end

    local line = "[Seamless Input Switch] " .. tostring(message)

    if not verbose_only then
        self._logged_messages = self._logged_messages or {}

        if self._logged_messages[line] then
            return
        end

        self._logged_messages[line] = true
    end

    if _G.log then
        _G.log(line)
    elseif Application and Application.debug then
        Application:debug(line)
    end
end

local function read_settings_file(path)
    local opened, file, open_error, open_code = pcall(io.open, path, "rb")

    if not opened or not file then
        return nil, opened and open_error or file, opened and open_code or nil
    end

    local read_ok, contents = pcall(file.read, file, "*all")
    local close_ok, closed = pcall(file.close, file)

    if not read_ok or type(contents) ~= "string" or not close_ok or not closed then
        return nil, "File read or close failed."
    end

    return contents
end

local function decode_settings(contents)
    if type(contents) ~= "string" or not json or not json.decode then
        return nil
    end

    local ok, decoded = pcall(json.decode, contents)

    return ok and type(decoded) == "table" and decoded or nil
end

function SIS:load_settings()
    self.settings = shallow_copy(self.DEFAULTS)

    local contents, read_error, read_code = read_settings_file(self.SAVE_FILE)
    local decoded = decode_settings(contents)

    if not decoded then
        local backup = read_settings_file(self.SAVE_FILE .. ".bak")

        decoded = decode_settings(backup)

        if decoded then
            self._settings_from_backup = true
            self:log("Settings recovered from the backup file.")
        elseif contents or read_code ~= 2 then
            self:log("Settings could not be read; defaults are in memory. Existing files were left unchanged: " .. tostring(read_error or "Invalid JSON."))
        end
    end

    if decoded then
        for key, default_value in pairs(self.DEFAULTS) do
            if type(decoded[key]) == type(default_value) then
                self.settings[key] = decoded[key]
            end
        end
    end

    if self.settings.mode ~= "auto" and self.settings.mode ~= "pc" and self.settings.mode ~= "gamepad" then
        self.settings.mode = "auto"
    end

    if not self.PROMPT_STYLE_CHOICE_SET[self.settings.prompt_style] then
        self.settings.prompt_style = "pc"
    end

    self.settings.axis_threshold = clamp(self.settings.axis_threshold, 0.05, 0.50)
    self.settings.axis_change_threshold = clamp(self.settings.axis_change_threshold, 0.02, 0.50)
    self.settings.gamepad_look_sensitivity = clamp(self.settings.gamepad_look_sensitivity, 0.50, 4.00)
    self.settings.gamepad_ads_sensitivity = clamp(self.settings.gamepad_ads_sensitivity, 0.50, 2.00)
    self.settings.gamepad_look_deadzone = clamp(self.settings.gamepad_look_deadzone, 0.00, 0.30)
    self.settings.gamepad_look_outer_deadzone = clamp(self.settings.gamepad_look_outer_deadzone, 0.00, 0.30)
    self.settings.gamepad_look_response_curve = clamp(self.settings.gamepad_look_response_curve, 0.50, 2.00)
    self.settings.gamepad_move_deadzone = clamp(self.settings.gamepad_move_deadzone, 0.10, 0.30)
    self.settings.gamepad_move_outer_deadzone = clamp(self.settings.gamepad_move_outer_deadzone, 0.00, 0.30)
    self.settings.gamepad_move_response_curve = clamp(self.settings.gamepad_move_response_curve, 0.50, 2.00)
    self.settings.aim_assist_sticky_strength = clamp(self.settings.aim_assist_sticky_strength, 0.25, 2.00)
    self.settings.aim_assist_snap_strength = clamp(self.settings.aim_assist_snap_strength, 0.25, 2.00)

    for _, binding in ipairs(self.GAMEPAD_BINDINGS) do
        if not self.GAMEPAD_BINDING_CHOICE_SET[self.settings[binding.setting]] then
            self.settings[binding.setting] = binding.default
        end
    end
end

function SIS:save_settings()
    local function failed(reason)
        self:log("Settings were not saved: " .. tostring(reason))

        return false
    end

    if not json or not json.encode or not json.decode then
        return failed("JSON support is unavailable.")
    end

    local encoded_ok, encoded = pcall(json.encode, self.settings)

    if not encoded_ok or not decode_settings(encoded) then
        return failed("Settings could not be encoded.")
    end

    local temp_path = self.SAVE_FILE .. ".tmp"
    local backup_path = self.SAVE_FILE .. ".bak"
    local opened, file = pcall(io.open, temp_path, "wb")

    if not opened or not file then
        return failed("Could not open the temporary file.")
    end

    local wrote_ok, wrote = pcall(file.write, file, encoded)
    local flushed_ok, flushed = pcall(file.flush, file)
    local closed_ok, closed = pcall(file.close, file)

    if not wrote_ok or not wrote or not flushed_ok or not flushed or not closed_ok or not closed then
        return failed("Temporary file write, flush or close failed.")
    end

    if read_settings_file(temp_path) ~= encoded then
        return failed("Temporary file verification failed.")
    end

    local previous, previous_error, previous_code = read_settings_file(self.SAVE_FILE)

    if not previous and previous_code ~= 2 then
        return failed(previous_error or "Could not inspect the existing file.")
    end

    local moved_previous = false

    if previous then
        if not decode_settings(previous) then
            return failed("The existing file contains invalid JSON. Keep it for recovery before saving again.")
        end

        local backup, backup_error, backup_code = read_settings_file(backup_path)

        if not backup and backup_code ~= 2 then
            return failed(backup_error or "Could not inspect the backup file.")
        end

        if backup then
            local removed_ok, removed = pcall(os.remove, backup_path)

            if not removed_ok or not removed then
                return failed("Could not rotate the backup file.")
            end
        end

        local moved_ok, moved = pcall(os.rename, self.SAVE_FILE, backup_path)

        if not moved_ok or not moved then
            return failed("Could not preserve the previous settings file.")
        end

        moved_previous = true
    end

    local renamed_ok, renamed = pcall(os.rename, temp_path, self.SAVE_FILE)

    if not renamed_ok or not renamed then
        if moved_previous then
            local restored_ok, restored = pcall(os.rename, backup_path, self.SAVE_FILE)

            if not restored_ok or not restored then
                return failed("Could not restore the primary file. Previous settings remain in " .. backup_path)
            end
        end

        return failed("Could not replace the settings file.")
    end

    self._settings_from_backup = nil

    return true
end

function SIS:family_for_type(wrapper_type)
    if wrapper_type == "pc" then
        return "pc"
    elseif self.PAD_TYPES[wrapper_type] then
        return "gamepad"
    end

    return nil
end

function SIS:is_gamepad_type(wrapper_type)
    return self:family_for_type(wrapper_type) == "gamepad"
end

function SIS:get_custom_gamepad_binding(connection_name, pad_type)
    if not self.settings.custom_gamepad_bindings or not self.CUSTOM_BIND_PAD_TYPES[pad_type] then
        return nil
    end

    local binding = self.GAMEPAD_BINDING_BY_CONNECTION[connection_name]
    local input_name = binding and self.settings[binding.setting]

    if input_name and self.GAMEPAD_BINDING_CHOICE_SET[input_name] then
        return input_name
    end

    return nil
end

function SIS:restore_vanilla_gamepad_bindings()
    self.settings.custom_gamepad_bindings = false

    for _, binding in ipairs(self.GAMEPAD_BINDINGS) do
        self.settings[binding.setting] = binding.default
    end
end

function SIS:request_controller_rebind()
    if not managers or not managers.controller or not managers.controller.request_rebind_connections then
        return false
    end

    local ok, error_message = pcall(function()
        managers.controller:request_rebind_connections()
    end)

    if not ok then
         self:log("Controller bindings could not be refreshed: " .. tostring(error_message))
    end

    return ok
end

function SIS:wrapper_type_for_index(manager, index)
    local wrapper_class = manager and manager._wrapper_class_map and index and manager._wrapper_class_map[index]

    return wrapper_class and wrapper_class.TYPE
end

function SIS:has_hybrid_sources(manager)
    if not IS_PC or _G.IS_VR or not manager or not manager._wrapper_class_map then
        return false
    end

    local has_pc = false
    local has_pad = false

    for _, wrapper_class in pairs(manager._wrapper_class_map) do
        local wrapper_type = wrapper_class and wrapper_class.TYPE

        has_pc = has_pc or wrapper_type == "pc"
        has_pad = has_pad or self:is_gamepad_type(wrapper_type)
    end

    return has_pc and has_pad
end

function SIS:should_make_hybrid(manager, name, debug)
    if not self:has_hybrid_sources(manager) then
        return false
    end

    if type(name) == "string" and (string.sub(name, 1, 5) == "boot_" or string.sub(name, 1, 6) == "title_") then
        return false
    end

    return not debug
end

local function raw_controller_connected(controller)
    if not controller or not controller.connected then
        return false
    end

    local ok, connected = pcall(function()
        return controller:connected()
    end)

    return ok and connected and true or false
end

function SIS:get_pad_controller(wrapper, require_connected)
    local controller = wrapper and wrapper._sis_pad_controller

    if controller and (not require_connected or raw_controller_connected(controller)) then
        return controller
    end

    return nil
end

function SIS:any_connected_pad()
    for wrapper in pairs(self.wrappers) do
        if self:get_pad_controller(wrapper, true) then
            return true
        end
    end

    return false
end

function SIS:effective_mode()
    if self.settings.mode == "gamepad" and not self:any_connected_pad() then
        return "pc"
    end

    return self.settings.mode
end

function SIS:is_type_allowed(wrapper_type)
    local family = self:family_for_type(wrapper_type)
    local mode = self:effective_mode()

    if mode == "pc" then
        return family == "pc"
    elseif mode == "gamepad" then
        return family == "gamepad"
    end

    return family ~= nil
end

function SIS:register_wrapper(wrapper, manager, pad_data, requested_index)
    if not wrapper or not pad_data or not pad_data.controller or not self:is_gamepad_type(pad_data.type) then
        return false
    end

    if wrapper._sis_hybrid then
        return true
    end

    wrapper._sis_hybrid = true
    wrapper._sis_manager = manager
    wrapper._sis_pad_controller = pad_data.controller
    wrapper._sis_pad_controller_index = pad_data.controller_index
    wrapper._sis_pad_wrapper_index = pad_data.index
    wrapper._sis_pad_type = pad_data.type

    self.wrappers[wrapper] = true
    self.hybrid_available = true
    self.preferred_pad_type = pad_data.type

    if not self.active_type then
        if self.settings.mode == "gamepad" and raw_controller_connected(pad_data.controller) then
            self.active_type = pad_data.type
        else
        
            self.active_type = "pc"
        end

        self.active_family = self:family_for_type(self.active_type)
    end


    if not self._hybrid_ready_announced then
        self._hybrid_ready_announced = true
        local native_id = wrapper.get_id and wrapper:get_id() or "unknown"

       self:log("Hybrid input ready: pc + " .. tostring(pad_data.type) .. " (" .. self.ARCHITECTURE .. "; native vc=ctrl_" .. tostring(native_id) .. ").", true)
    end

    return true
end

function SIS:get_pad_connection_settings(wrapper, connection_name)
    if not wrapper or not wrapper._sis_hybrid then
        return nil
    end

    local manager = wrapper._sis_manager or wrapper.__manager
    local setup = manager and manager._controller_setup and manager._controller_setup[wrapper._sis_pad_type]

    return setup and setup.get_connection and setup:get_connection(connection_name) or nil
end

function SIS:refresh_interaction_text()
    if not managers or not managers.interaction or not managers.interaction.active_unit then
        return
    end

    local unit = managers.interaction:active_unit()

    if alive(unit) and unit:interaction() and unit:interaction().set_text_dirty then
        unit:interaction():set_text_dirty(true)
    end
end

function SIS:set_active_type(wrapper_type, reason, bypass_mode)
    local family = self:family_for_type(wrapper_type)

    if not family then
        return false
    end

    if not bypass_mode and not self:is_type_allowed(wrapper_type) then
        return false
    end

    if family == "gamepad" then
        self.preferred_pad_type = wrapper_type
    end

    local changed = self.active_type ~= wrapper_type

    self.active_type = wrapper_type
    self.active_family = family

    if changed then

        if self.DYNAMIC_UI then
            self:refresh_interaction_text()
            self:sync_pointer()
        end
    end

    return changed
end

function SIS:axis_components(axis)
    if not axis then
        return 0, 0, 0, 0
    end

    local function component(name)
        if mvector3 and mvector3[name] then
            return mvector3[name](axis)
        end

        local value = axis[name]

        if type(value) == "function" then
            return value(axis)
        elseif type(value) == "number" then
            return value
        end

        return 0
    end

    local x = component("x")
    local y = component("y")
    local z = component("z")

    return x, y, z, math.sqrt(x * x + y * y + z * z)
end


function SIS:apply_stick_response(axis, inner_deadzone, outer_deadzone, response_curve, output_deadzone)
    if not axis or not Vector3 then
        return axis
    end

    local x, y, z, magnitude = self:axis_components(axis)
    local inner = clamp(tonumber(inner_deadzone) or 0, 0, 0.95)
    local outer = clamp(tonumber(outer_deadzone) or 0, 0, 0.95)
    local curve = clamp(tonumber(response_curve) or 1, 0.10, 4.00)
    local output_floor = clamp(tonumber(output_deadzone) or inner, 0, 0.95)
    local saturation = math.max(inner + 0.001, 1 - outer)

    if magnitude <= 0 or magnitude < inner then
        return Vector3()
    end

    if math.abs(inner - output_floor) < 0.000001 and outer < 0.000001 and math.abs(curve - 1) < 0.000001 then
        return Vector3(x, y, z)
    end

    local normalized = clamp((math.min(magnitude, saturation) - inner) / (saturation - inner), 0, 1)
    local shaped = normalized ^ curve
    local output_magnitude = output_floor + (1 - output_floor) * shaped
    local scale = output_magnitude / magnitude

    return Vector3(x * scale, y * scale, z * scale)
end

function SIS:apply_gamepad_move_response(axis)
    return self:apply_stick_response(
        axis,
        self.settings.gamepad_move_deadzone,
        self.settings.gamepad_move_outer_deadzone,
        self.settings.gamepad_move_response_curve,
        0.10
    )
end

local function raw_controller_count(controller, method_name)
    if not controller or not controller[method_name] then
        return nil
    end

    local ok, count = pcall(function()
        return controller[method_name](controller)
    end)

    if ok and type(count) == "number" then
        return math.max(0, math.floor(count))
    end

    return nil
end

local function raw_button_name(controller, index)
    if not controller or not controller.button_name then
        return nil
    end

    local ok, name = pcall(function()
        return controller:button_name(index)
    end)

    return ok and name or nil
end

local function raw_button_value(controller, method_name, index, name)
    if not controller or not controller[method_name] then
        return false, nil
    end

    local ok, value = pcall(function()
        return controller[method_name](controller, index)
    end)

    if not ok and name then
        ok, value = pcall(function()
            return controller[method_name](controller, name)
        end)
    end

    return ok, ok and not not value or nil
end

function SIS:get_raw_button_catalog(controller)
    local catalog = self.raw_button_catalog[controller]

    if catalog then
        return catalog
    end

    local button_count = raw_controller_count(controller, "num_buttons")

    if button_count == nil then
        return nil
    end

    catalog = {}

    for index = 0, button_count - 1 do
        table.insert(catalog, {
            index = index,
            name = raw_button_name(controller, index)
        })
    end

    self.raw_button_catalog[controller] = catalog

    return catalog
end

function SIS:raw_button_activity(source_type, controller, track_only)
    if not raw_controller_connected(controller) then
        if controller then
            self.raw_button_state[controller] = nil
            self.raw_button_catalog[controller] = nil
        end

        return false, false, nil
    end

    local readable = false

    if controller.pressed_list then
        local ok, pressed_count = pcall(function()
            local pressed = controller:pressed_list()

            return pressed and #pressed or 0
        end)

        if ok then
            readable = true

            if pressed_count > 0 and not track_only then
                return self:set_active_type(source_type, "raw-button-list"), true, nil
            end

            return false, true, nil
        end
    end

    local button_catalog = self:get_raw_button_catalog(controller)

    if not button_catalog then
        return false, readable, nil
    end

    local button_state = self.raw_button_state[controller]

    if not button_state then
        button_state = {}
        self.raw_button_state[controller] = button_state
    end

    local activity_key

    for _, button in ipairs(button_catalog) do
        local index = button.index
        local name = button.name
        local state_key = tostring(name or index)
        local down_ok, down = raw_button_value(controller, "down", index, name)
        local previous = button_state[state_key]
        local pressed_ok, pressed = false, nil

        if not down_ok then
            pressed_ok, pressed = raw_button_value(controller, "pressed", index, name)
        end

        readable = readable or pressed_ok or down_ok

        if down_ok then
            button_state[state_key] = down
        elseif pressed_ok then
            button_state[state_key] = pressed
        end

        if pressed or down and previous ~= true then
            activity_key = activity_key or state_key
        end
    end

    if activity_key and not track_only then
        return self:set_active_type(source_type, "raw-button:" .. activity_key), readable, #button_catalog
    end

    return false, readable, #button_catalog
end

function SIS:get_raw_axis_catalog(controller)
    local catalog = self.raw_axis_catalog[controller]

    if catalog then
        return catalog
    end

    local axis_count = raw_controller_count(controller, "num_axes")

    if axis_count == nil then
        return nil
    end

    catalog = {}

    for index = 0, axis_count - 1 do
        local name_ok, axis_name = false, nil

        if controller.axis_name then
            name_ok, axis_name = pcall(function()
                return controller:axis_name(index)
            end)
        end

        table.insert(catalog, {
            index = index,
            name = name_ok and axis_name or nil
        })
    end

    self.raw_axis_catalog[controller] = catalog

    return catalog
end

function SIS:raw_axis_activity(source_type, controller, track_only)
    if not raw_controller_connected(controller) then
        if controller then
            self.raw_axis_state[controller] = nil
            self.raw_axis_catalog[controller] = nil
        end

        return false, false, nil
    end

    if not controller.num_axes or not controller.axis then
        return false, false, nil
    end

    local axis_catalog = self:get_raw_axis_catalog(controller)

    if not axis_catalog then
        return false, false, nil
    end

    local controller_state = self.raw_axis_state[controller]

    if not controller_state then
        controller_state = {}
        self.raw_axis_state[controller] = controller_state
    end

    local family = self:family_for_type(source_type)
    local threshold = family == "pc" and 0.001 or self.settings.axis_threshold
    local change_threshold = family == "pc" and 0.001 or self.settings.axis_change_threshold
    local readable = false
    local activity_key

    for _, axis_data in ipairs(axis_catalog) do
        local index = axis_data.index
        local axis_name = axis_data.name

        local axis_ok, axis = false, nil

        if axis_name then
            axis_ok, axis = pcall(function()
                return controller:axis(axis_name)
            end)
        end

        if not axis_ok or not axis then
            axis_ok, axis = pcall(function()
                return controller:axis(index)
            end)
        end

        if axis_ok and axis then
            readable = true
            local x, y, z, magnitude = self:axis_components(axis)
            local state_key = tostring(axis_name or index)
            local previous = controller_state[state_key]
            local active = magnitude > threshold
            local became_active = previous and active and not previous.active
            local changed_enough = false

            if previous and active then
                local dx = x - previous.x
                local dy = y - previous.y
                local dz = z - previous.z

                changed_enough = math.sqrt(dx * dx + dy * dy + dz * dz) >= change_threshold
            end

            controller_state[state_key] = {
                x = x,
                y = y,
                z = z,
                active = active
            }

            if active and (became_active or changed_enough) then
                activity_key = activity_key or state_key
            end
        end
    end

    if activity_key and not track_only then
        return self:set_active_type(source_type, "raw-axis:" .. activity_key), readable, #axis_catalog
    end

    return false, readable, #axis_catalog
end

function SIS:poll_raw_controller(source_type, controller, track_only)
    local button_switched, buttons_readable, button_count = self:raw_button_activity(source_type, controller, track_only)
    local axis_switched, axes_readable, axis_count = self:raw_axis_activity(source_type, controller, track_only)

    if self:is_gamepad_type(source_type) and not self._raw_watcher_announced and raw_controller_connected(controller) then
        self._raw_watcher_announced = true

        if buttons_readable or axes_readable then
            self:log("Inactive gamepad watcher ready: " .. tostring(source_type) .. " (buttons=" .. tostring(button_count or "list") .. ", axes=" .. tostring(axis_count or "unavailable") .. ").", true)
        else
            self:log("Inactive gamepad watcher could not read physical " .. tostring(source_type) .. " input.")
        end
    end

    return button_switched or axis_switched
end

function SIS:poll_wrapper(wrapper)
    if not wrapper or not wrapper._sis_hybrid or not wrapper.enabled or not wrapper:enabled() then
        return
    end

    local raw_pad = self:get_pad_controller(wrapper)
    local pad = self:get_pad_controller(wrapper, true)

    if self.active_family == "gamepad" and not pad then
        self:set_active_type("pc", "gamepad-disconnected", true)
    end

    local was_gamepad = self.active_family == "gamepad"

    if Input and Input.keyboard then
        self:poll_raw_controller("pc", Input:keyboard(), not was_gamepad)
    end

    if Input and Input.mouse then
        self:poll_raw_controller("pc", Input:mouse(), not was_gamepad)
    end

    if raw_pad then
        self:poll_raw_controller(wrapper._sis_pad_type, raw_pad, was_gamepad or not pad)
    end
end

function SIS:poll_manager(manager)
    local function eligible(wrapper)
        if not wrapper or not self.wrappers[wrapper] or not wrapper._sis_hybrid or not wrapper.enabled then
            return false
        end

        if manager and wrapper._sis_manager and wrapper._sis_manager ~= manager then
            return false
        end

        local ok, enabled = pcall(wrapper.enabled, wrapper)

        return ok and enabled and true or false
    end

    local input = self:get_menu_input()
    local menu_wrapper = input and input._controller

    if eligible(menu_wrapper) and self:get_pad_controller(menu_wrapper, true) then
        self:poll_wrapper(menu_wrapper)

        return
    end

    local selected
    local selected_key
    local selected_connected = false

    for wrapper in pairs(self.wrappers) do
        if eligible(wrapper) then
            local connected = self:get_pad_controller(wrapper, true) ~= nil
            local key = tostring(wrapper._id or wrapper._name or wrapper)

            if not selected or connected and not selected_connected or connected == selected_connected and key < selected_key then
                selected = wrapper
                selected_key = key
                selected_connected = connected
            end
        end
    end

    if selected then
        self:poll_wrapper(selected)
    end
end

function SIS:get_menu_input()
    if not managers or not managers.menu or not managers.menu.active_menu then
        return nil
    end

    local active_menu = managers.menu:active_menu()

    return active_menu and active_menu.input
end

function SIS:sync_pointer()
    if not self.DYNAMIC_UI or self._pointer_syncing or not self.settings.menu_mouse or not managers or not managers.mouse_pointer then
        return
    end

    local input = self:get_menu_input()

    if not input or not input._mouse_active then
        return
    end

    local pointer = managers.mouse_pointer

    self._pointer_syncing = true

    local ok, error_message = pcall(function()
        if self.active_family == "pc" then
            if pointer._controller_updater and pointer:change_controller_to_mouse() and pointer._mouse_callbacks and #pointer._mouse_callbacks > 0 then
                pointer:_activate()
            end
        elseif self.active_family == "gamepad" and (input._controller_mouse_active_counter or 0) > 0 and not pointer._controller_updater then
            local controller = input._controller and input._controller:get_controller()

            if controller and pointer:change_mouse_to_controller(controller) and pointer._mouse_callbacks and #pointer._mouse_callbacks > 0 then
                pointer:_activate()
            end
        end
    end)

    self._pointer_syncing = false

    if not ok then
        self:log("Menu pointer sync failed: " .. tostring(error_message))
    end
end

function SIS:apply_mode()
    local mode = self:effective_mode()

    if mode == "pc" then
        self:set_active_type("pc", "settings", true)
    elseif mode == "gamepad" then
        local pad_type = self.preferred_pad_type

        if pad_type then
            self:set_active_type(pad_type, "settings", true)
        end
    end

    if self.DYNAMIC_UI then
        self:sync_pointer()
    end
end

function SIS:call_with_aim_assist_semantics(func, target, ...)
    local previous_scope = self._aim_assist_scope

    self._aim_assist_scope = true

    local result = pack(pcall(func, target, ...))

    self._aim_assist_scope = previous_scope

    if not result[1] then
        error(result[2])
    end

    return unpack(result, 2, result.n)
end

function SIS:call_with_gamepad_semantics(func, target, wrapper, ...)
    if type(wrapper) ~= "table" then
        return func(target, ...)
    end

    local previous_scope = self._gamepad_semantics_scope
    local previous_type = rawget(wrapper, "TYPE")
    local pad_type = wrapper._sis_pad_type or self.preferred_pad_type or "xb1"

    self._gamepad_semantics_scope = true
    rawset(wrapper, "TYPE", pad_type)

    local result = pack(pcall(func, target, ...))

    rawset(wrapper, "TYPE", previous_type)
    self._gamepad_semantics_scope = previous_scope

    if not result[1] then
        error(result[2])
    end

    return unpack(result, 2, result.n)
end

SIS:load_settings()
SIS:log("Loaded v" .. SIS.VERSION .. " (mode=" .. tostring(SIS.settings.mode) .. ", architecture=" .. SIS.ARCHITECTURE .. ").", true)
