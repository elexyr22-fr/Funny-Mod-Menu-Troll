if not _G.SeamlessInputSwitch then
    dofile(ModPath .. "sis/lua/bootstrap.lua")
end

local SIS = _G.SeamlessInputSwitch
local ControllerManagerClass = CoreControllerManager and CoreControllerManager.ControllerManager

if not ControllerManagerClass or SIS._controller_manager_hooked then
    return
end

SIS._controller_manager_hooked = true

local original_create_controller = ControllerManagerClass.create_controller
local original_get_default_wrapper_type = ControllerManagerClass.get_default_wrapper_type
local original_set_default_wrapper_index = ControllerManagerClass.set_default_wrapper_index
local original_update = ControllerManagerClass.update
local original_paused_update = ControllerManagerClass.paused_update

local function pack(...)
    return { n = select("#", ...), ... }
end

local function resolve_core_module(module_name)
    local manager_module_value = CoreControllerManager and CoreControllerManager[module_name]

    if manager_module_value then
        return manager_module_value
    end

    local global_value = rawget(_G, module_name)

    if global_value then
        return global_value
    end

    if core and core._name_to_module then
        local ok, registered_module = pcall(function()
            return core:_name_to_module(module_name)
        end)

        if ok then
            return registered_module
        end
    end

    return nil
end

local BaseWrapperModule = resolve_core_module("CoreControllerWrapper")
local BaseWrapperClass = BaseWrapperModule and BaseWrapperModule.ControllerWrapper

local function controller_connected(controller)
    if not controller or not controller.connected then
        return false
    end

    local ok, connected = pcall(function()
        return controller:connected()
    end)

    return ok and connected and true or false
end

local function sorted_wrapper_indices(manager)
    local indices = {}

    for wrapper_index, wrapper_class in pairs(manager._wrapper_class_map or {}) do
        local wrapper_type = wrapper_class and wrapper_class.TYPE

        if wrapper_type == "pc" or SIS:is_gamepad_type(wrapper_type) then
            table.insert(indices, wrapper_index)
        end
    end

    table.sort(indices, function(a, b)
        local number_a = tonumber(a)
        local number_b = tonumber(b)

        if number_a and number_b then
            return number_a < number_b
        end

        return tostring(a) < tostring(b)
    end)

    return indices
end

local function collect_sources(manager)
    local pc_data
    local pad_candidates = {}

    for _, wrapper_index in ipairs(sorted_wrapper_indices(manager)) do
        local wrapper_class = manager._wrapper_class_map[wrapper_index]
        local wrapper_type = wrapper_class and wrapper_class.TYPE
        local controller_indices = manager._wrapper_to_controller_list[wrapper_index]
        local controller_index = controller_indices and controller_indices[1]

        if wrapper_type == "pc" then
            pc_data = pc_data or {
                index = wrapper_index,
                type = wrapper_type,
                controller_index = controller_index
            }
        elseif SIS:is_gamepad_type(wrapper_type) and controller_index ~= nil then
            local controller = Input:controller(controller_index)

            table.insert(pad_candidates, {
                index = wrapper_index,
                type = wrapper_type,
                controller_index = controller_index,
                controller = controller,
                connected = controller_connected(controller)
            })
        end
    end

    return pc_data, pad_candidates
end

local function select_pad(manager, requested_index, pad_candidates)
    local requested_type = SIS:wrapper_type_for_index(manager, requested_index)
    local preferred_index

    if manager.get_preferred_default_wrapper_index then
        local ok, value = pcall(function()
            return manager:get_preferred_default_wrapper_index()
        end)

        if ok then
            preferred_index = value
        end
    end

    local preferred_type = SIS:wrapper_type_for_index(manager, preferred_index)

    for _, candidate in ipairs(pad_candidates) do
        if candidate.connected and requested_type ~= "pc" and candidate.type == requested_type then
            return candidate
        end
    end

    for _, candidate in ipairs(pad_candidates) do
        if candidate.connected and SIS.preferred_pad_type and candidate.type == SIS.preferred_pad_type then
            return candidate
        end
    end

    for _, candidate in ipairs(pad_candidates) do
        if candidate.connected and candidate.type == preferred_type then
            return candidate
        end
    end

    for _, candidate in ipairs(pad_candidates) do
        if candidate.connected then
            return candidate
        end
    end

    return pad_candidates[1]
end

local function map_special_input(pad_type, input_name)
    if input_name == "confirm" then
        return "a"
    elseif input_name == "cancel" then
        return "b"
    end

    return input_name
end

local function controller_has_input(controller, input_name)
    if not controller or not input_name then
        return false
    end

    local id = type(input_name) == "number" and input_name or Idstring(input_name)
    local ok, available = pcall(function()
        return controller.has_button and controller:has_button(id) or controller.has_axis and controller:has_axis(id)
    end)

    return ok and available and true or false
end

local PAD_INPUT_ALIAS_GROUPS = {
    { "a", "cross", "face_down" },
    { "b", "circle", "face_right" },
    { "x", "square", "face_left" },
    { "y", "triangle", "face_up" },
    { "start", "options" }
}


local FIXED_STATS_SCREEN_INPUTS = {
    "back",
    "select",
    "view",
    "share",
    "touchpad",
    "touchpad_click",
    "touchpad_press",
    "touchpad_left"
}


local function should_suppress_hybrid_pad_connection(wrapper, connection_name)
    if connection_name ~= "toggle_chat" then
        return false
    end

    local wrapper_name = wrapper.get_name and wrapper:get_name() or wrapper._name

    return wrapper_name == "MenuManager"
end

local PAD_INPUT_ALIASES = {}

for _, alias_group in ipairs(PAD_INPUT_ALIAS_GROUPS) do
    for _, input_name in ipairs(alias_group) do
        PAD_INPUT_ALIASES[input_name] = alias_group
    end
end

local function resolve_physical_input(pad_type, input_name, controller)
    local mapped_input = map_special_input(pad_type, input_name)

    if controller_has_input(controller, mapped_input) then
        return mapped_input
    end

    for _, alias in ipairs(PAD_INPUT_ALIASES[mapped_input] or PAD_INPUT_ALIASES[input_name] or {}) do
        if alias ~= mapped_input and controller_has_input(controller, alias) then
            return alias
        end
    end

    return mapped_input
end

local function fixed_stats_screen_inputs(input_names, controller)
    local result = {}
    local seen = {}

    local function add_if_available(input_name)
        local input_key = type(input_name) .. ":" .. tostring(input_name)

        if not seen[input_key] and controller_has_input(controller, input_name) then
            seen[input_key] = true
            table.insert(result, input_name)
        end
    end

    for _, input_name in ipairs(input_names or {}) do
        add_if_available(input_name)
    end

    if #result == 0 then
        for _, input_name in ipairs(FIXED_STATS_SCREEN_INPUTS) do
            add_if_available(input_name)

            if #result > 0 then
                break
            end
        end
    end


    return #result > 0 and result or input_names
end

local function attach_pad_bindings(wrapper)
    if not BaseWrapperClass or not BaseWrapperClass.virtual_connect2 or not wrapper or not wrapper._sis_hybrid then
        return false, 0, 0
    end

    if wrapper._sis_pad_bindings_attached then
        return true, wrapper._sis_pad_binding_count or 0, wrapper._sis_pad_binding_skipped or 0
    end

    local manager = wrapper._sis_manager or wrapper.__manager
    local pad_type = wrapper._sis_pad_type
    local pad_controller = wrapper._sis_pad_controller
    local pad_setup = manager and manager._controller_setup and manager._controller_setup[pad_type]
    local pc_setup = wrapper.get_setup and wrapper:get_setup()

    if not pad_controller or not pad_setup or not pc_setup or not pad_setup.get_connection_list or not pad_setup.get_connection_map then
        return false, 0, 0
    end

    local pad_connection_map = pad_setup:get_connection_map()
    local pc_connection_map = pc_setup.get_connection_map and pc_setup:get_connection_map() or {}
    local connected_count = 0
    local skipped_count = 0
    local failed_count = 0
    local custom_count = 0
    local suppressed_count = 0
    local seen_connections = {}

    wrapper._sis_pad_merged_connections = wrapper._sis_pad_merged_connections or {}

    for _, connection_name in ipairs(pad_setup:get_connection_list()) do
        if not seen_connections[connection_name] then
            seen_connections[connection_name] = true

            local pad_connection = pad_connection_map[connection_name]
            local pc_connection = pc_connection_map[connection_name]
            local debug_only = pad_connection and pad_connection.get_debug and pad_connection:get_debug()
            local suppress_pad_source = should_suppress_hybrid_pad_connection(wrapper, connection_name)

            if suppress_pad_source then
                suppressed_count = suppressed_count + 1
            end

            if pad_connection and pc_connection and not debug_only and not suppress_pad_source and wrapper.connection_exist and wrapper:connection_exist(connection_name) then
                local seen_inputs = {}
                local input_names = pad_connection:get_input_name_list()
                local custom_input = SIS:get_custom_gamepad_binding(connection_name, pad_type)

                if connection_name == "stats_screen" then
                    input_names = fixed_stats_screen_inputs(input_names, pad_controller)
                end

                if custom_input then
                    local resolved_custom_input = resolve_physical_input(pad_type, custom_input, pad_controller)

                    if controller_has_input(pad_controller, resolved_custom_input) then
                        input_names = { resolved_custom_input }
                        custom_count = custom_count + 1
                    else
                        local warning_key = tostring(pad_type) .. ":" .. tostring(custom_input)

                        SIS._invalid_custom_binding_warnings = SIS._invalid_custom_binding_warnings or {}

                        if not SIS._invalid_custom_binding_warnings[warning_key] then
                            SIS._invalid_custom_binding_warnings[warning_key] = true
                            SIS:log("Custom input '" .. tostring(custom_input) .. "' is unavailable on " .. tostring(pad_type) .. "; the vanilla route will be used.")
                        end
                    end
                end

                for _, input_name in ipairs(input_names) do
                    local mapped_input = resolve_physical_input(pad_type, input_name, pad_controller)
                    local input_key = type(mapped_input) .. ":" .. tostring(mapped_input)

                    if not seen_inputs[input_key] then
                        seen_inputs[input_key] = true

                        local ok, error_message = pcall(
                            BaseWrapperClass.virtual_connect2,
                            wrapper,
                            "sis_" .. tostring(pad_type),
                            pad_controller,
                            mapped_input,
                            connection_name,
                            pad_connection
                        )

                        if ok then
                            connected_count = connected_count + 1
                            wrapper._sis_pad_merged_connections[connection_name] = true
                        else
                            failed_count = failed_count + 1
                            SIS:log("Could not merge " .. tostring(pad_type) .. " input '" .. tostring(mapped_input) .. "' into '" .. tostring(connection_name) .. "': " .. tostring(error_message))
                        end
                    end
                end
            else
                skipped_count = skipped_count + 1
            end
        end
    end

    wrapper._sis_pad_bindings_attached = connected_count > 0
    wrapper._sis_pad_binding_count = connected_count
    wrapper._sis_pad_binding_skipped = skipped_count
    wrapper._sis_pad_binding_failed = failed_count
    wrapper._sis_custom_binding_count = custom_count
    wrapper._sis_pad_binding_suppressed = suppressed_count

    return connected_count > 0, connected_count, skipped_count
end

local function install_rebind_bridge(wrapper)
    if wrapper._sis_rebind_bridge or not wrapper.rebind_connections then
        return
    end

    wrapper._sis_rebind_bridge = true

    local original_rebind_connections = wrapper.rebind_connections

    wrapper.rebind_connections = function(self, ...)
        self._sis_pad_bindings_attached = false
        self._sis_pad_merged_connections = {}

        local result = pack(pcall(original_rebind_connections, self, ...))

        if not result[1] then
            error(result[2])
        end

        local attached, connection_count = attach_pad_bindings(self)

        if attached then
            SIS:log("Reattached " .. tostring(connection_count) .. " gamepad input routes after controller rebind.", true)
        else
            SIS:log("Gamepad input routes could not be restored after controller rebind.")
        end

        return unpack(result, 2, result.n)
    end
end

local function install_axis_bridge(wrapper)
    if wrapper._sis_axis_bridge or not wrapper.get_input_axis then
        return
    end

    wrapper._sis_axis_bridge = true

    local original_get_input_axis = wrapper.get_input_axis

    wrapper.get_input_axis = function(self, connection_name, ...)
        local axis = original_get_input_axis(self, connection_name, ...)

        if connection_name == "move" and SIS.active_family == "gamepad" then
            return SIS:apply_gamepad_move_response(axis)
        end

        return axis
    end
end

local function create_merged_controller(manager, name, requested_index, prio)
    local pc_data, pad_candidates = collect_sources(manager)
    local pad_data = select_pad(manager, requested_index, pad_candidates)

    if not BaseWrapperClass or not pc_data or not pad_data then
        SIS:log("Single-VC hybrid unavailable (base=" .. (BaseWrapperClass and "yes" or "no") .. ", pc=" .. (pc_data and "yes" or "no") .. ", pad=" .. (pad_data and "yes" or "no") .. "); using the stock single-device controller.")

        return original_create_controller(manager, name, requested_index, false, prio)
    end

    
    local wrapper = original_create_controller(manager, name, pc_data.index, false, prio)

    if not wrapper or wrapper.get_type and wrapper:get_type() ~= "pc" then
        SIS:log("The stock controller returned for '" .. tostring(name) .. "' was not a PC wrapper; hybrid merge was skipped.")

        return wrapper
    end

    if wrapper._sis_hybrid then
        return wrapper
    end

    if not SIS:register_wrapper(wrapper, manager, pad_data, requested_index) then
        SIS:log("Could not register the merged controller for '" .. tostring(name) .. "'.")

        return wrapper
    end

    local attached, connection_count, skipped_count = attach_pad_bindings(wrapper)

    if attached then
        install_rebind_bridge(wrapper)
        install_axis_bridge(wrapper)

        if not SIS._merged_bindings_announced then
            SIS._merged_bindings_announced = true
            SIS:log("Single native controller active: merged " .. tostring(connection_count) .. " " .. tostring(pad_data.type) .. " input routes (skipped=" .. tostring(skipped_count) .. ").", true)
        end
    else
        SIS:log("No gamepad routes were merged into '" .. tostring(name) .. "'; this controller remains keyboard/mouse only.")
    end

    return wrapper
end

function ControllerManagerClass:create_controller(name, index, debug, prio)
    self:update_controller_wrapper_mappings()

    local requested_index = index or Global.controller_manager.default_wrapper_index or self:get_preferred_default_wrapper_index()
    local make_hybrid = SIS:should_make_hybrid(self, name, debug)
    local wrapper

    if make_hybrid then
        wrapper = create_merged_controller(self, name, requested_index, prio)
    else
        wrapper = original_create_controller(self, name, index, debug, prio)
    end

    if make_hybrid and (not wrapper or not wrapper._sis_hybrid) then
        SIS:log("Controller '" .. tostring(name) .. "' is using the stock single-device fallback.", true)
    elseif not debug and not SIS:has_hybrid_sources(self) and not SIS._no_pad_wrapper_announced then
        SIS._no_pad_wrapper_announced = true
        SIS:log("No simultaneous PC/gamepad source detected. Check Steam Input and reconnect the pad before launch.")
    end

    return wrapper
end

function ControllerManagerClass:get_default_wrapper_type()
    if SIS._gamepad_semantics_scope or SIS._aim_assist_scope and SIS.settings.force_aim_assist then
        return SIS.preferred_pad_type or "xb1"
    end

    if SIS.hybrid_available and SIS.UI_TYPE then
        return SIS.UI_TYPE
    end

    return original_get_default_wrapper_type(self)
end

function ControllerManagerClass:set_default_wrapper_index(default_wrapper_index)
    original_set_default_wrapper_index(self, default_wrapper_index)

    local wrapper_type = SIS:wrapper_type_for_index(self, default_wrapper_index)

    if wrapper_type == "pc" or SIS:is_gamepad_type(wrapper_type) then
        if SIS.settings.mode == "auto" then
            SIS:set_active_type(wrapper_type, "title-screen-selection")
        else
            SIS:apply_mode()
        end
    end
end

if original_update then
    function ControllerManagerClass:update(t, dt)
        original_update(self, t, dt)
        SIS:poll_manager(self)
    end
end

if original_paused_update then
    function ControllerManagerClass:paused_update(t, dt)
        original_paused_update(self, t, dt)
        SIS:poll_manager(self)
    end
end

SIS:log("Controller manager single-VC hook installed.", true)
