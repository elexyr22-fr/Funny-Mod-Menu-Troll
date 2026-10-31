if not _G.SeamlessInputSwitch then
    dofile(ModPath .. "sis/lua/bootstrap.lua")
end

local SIS = _G.SeamlessInputSwitch

if not AssetsItem or not AssetsItem.update or SIS._mission_briefing_hooked then
    return
end

SIS._mission_briefing_hooked = true

local original_update = AssetsItem.update
local resolved_buy_all_button = setmetatable({}, { __mode = "k" })
local BUY_ALL_BUTTON_ALIASES = {
    "x",
    "square",
    "face_left"
}

local function pack(...)
    return { n = select("#", ...), ... }
end

local function controller_has_button(controller, input_name)
    if not controller or not controller.has_button or input_name == nil then
        return false
    end

    local input_id = type(input_name) == "string" and Idstring(input_name) or input_name
    local ok, available = pcall(controller.has_button, controller, input_id)

    return ok and available and true or false
end

local function buy_all_button_candidates(wrapper)
    local candidates = {}
    local seen = {}

    local function add(input_name)
        if input_name == nil then
            return
        end

        local key = type(input_name) .. ":" .. tostring(input_name)

        if not seen[key] then
            seen[key] = true
            table.insert(candidates, input_name)
        end
    end

    local connection = SIS:get_pad_connection_settings(wrapper, "buy_all_assets")
    local input_names = connection and connection.get_input_name_list and connection:get_input_name_list()

    for _, input_name in ipairs(input_names or {}) do
        add(input_name)
    end

    for _, input_name in ipairs(BUY_ALL_BUTTON_ALIASES) do
        add(input_name)
    end

    return candidates
end

local function resolve_buy_all_button(wrapper, controller)
    local cached = resolved_buy_all_button[controller]

    if cached ~= nil then
        return cached
    end

    for _, input_name in ipairs(buy_all_button_candidates(wrapper)) do
        if controller_has_button(controller, input_name) then
            resolved_buy_all_button[controller] = input_name

            return input_name
        end
    end

    return nil
end

local function raw_button_pressed(controller, input_name)
    if not controller or not controller.pressed or input_name == nil then
        return false
    end

    local input_id = type(input_name) == "string" and Idstring(input_name) or input_name
    local ok, pressed = pcall(controller.pressed, controller, input_id)

    if not ok and type(input_name) ~= "number" then
        ok, pressed = pcall(controller.pressed, controller, input_name)
    end

    return ok and pressed and true or false
end

function AssetsItem:update(t, dt)
    local result = pack(original_update(self, t, dt))

    if not managers or not managers.menu or not managers.preplanning then
        return unpack(result, 1, result.n)
    end


    if not managers.menu:is_pc_controller() or managers.preplanning:has_current_level_preplanning() then
        return unpack(result, 1, result.n)
    end

    local wrapper = managers.menu:get_controller()
    local pad_type = wrapper and wrapper._sis_pad_type

    if not wrapper or not wrapper._sis_hybrid or not pad_type or not SIS:is_type_allowed(pad_type) then
        return unpack(result, 1, result.n)
    end

    local pad_controller = SIS:get_pad_controller(wrapper, true)
    local input_name = pad_controller and resolve_buy_all_button(wrapper, pad_controller)

    if raw_button_pressed(pad_controller, input_name) then
        SIS:set_active_type(pad_type, "briefing-buy-all-assets")
        self:open_assets_buy_all()
    end

    return unpack(result, 1, result.n)
end

SIS:log("Mission-briefing gamepad shortcut hook installed.", true)
