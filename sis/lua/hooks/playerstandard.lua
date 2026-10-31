if not _G.SeamlessInputSwitch then
    dofile(ModPath .. "sis/lua/bootstrap.lua")
end

local SIS = _G.SeamlessInputSwitch

if SIS._player_standard_hooked then
    return
end

SIS._player_standard_hooked = true

local function add_vanilla_gamepad_helpers(player, unit)
    local base = unit and unit.base and unit:base()
    local controller = base and base.controller and base:controller()

    if not controller or not controller._sis_hybrid then
        return
    end

    player._input = player._input or {}

    local has_bipod_helper = false
    local has_second_deployable_helper = false

    for _, helper in ipairs(player._input) do
        has_bipod_helper = has_bipod_helper or helper._deploy_bipod_t ~= nil
        has_second_deployable_helper = has_second_deployable_helper or helper._secondary_deployable_t ~= nil
    end

    local insert_index = 1

    if not has_bipod_helper and BipodDeployControllerInput and BipodDeployControllerInput.new then
        table.insert(player._input, insert_index, BipodDeployControllerInput:new())
        insert_index = insert_index + 1
    end

    local has_second_deployable = managers and managers.player and managers.player.has_category_upgrade and managers.player:has_category_upgrade("player", "second_deployable")

    if has_second_deployable and not has_second_deployable_helper and SecondDeployableControllerInput and SecondDeployableControllerInput.new then
        table.insert(player._input, insert_index, SecondDeployableControllerInput:new())
    end

    if not SIS._vanilla_gameplay_helpers_announced then
        SIS._vanilla_gameplay_helpers_announced = true
        SIS:log("Vanilla gamepad gameplay helpers active: interact/shout, bipod and secondary deployable.", true)
    end
end

if PlayerStandard and PlayerStandard.init then
    local original_init = PlayerStandard.init

    function PlayerStandard:init(unit, ...)
        original_init(self, unit, ...)
        add_vanilla_gamepad_helpers(self, unit)
    end
end

if PlayerStandard and PlayerStandard._check_action_interact then
    local original_check_action_interact = PlayerStandard._check_action_interact

    function PlayerStandard:_check_action_interact(...)
        local wrapper = self._controller

        if SIS.active_family == "gamepad" and wrapper and wrapper._sis_hybrid then
       
            return SIS:call_with_gamepad_semantics(original_check_action_interact, self, wrapper, ...)
        end

        return original_check_action_interact(self, ...)
    end
end

if PlayerStandard and PlayerStandard._start_action_steelsight then
    local original_start_action_steelsight = PlayerStandard._start_action_steelsight

    function PlayerStandard:_start_action_steelsight(...)
        local result = original_start_action_steelsight(self, ...)

      
        if SIS.settings.force_aim_assist and SIS.settings.aim_assist_snap_enabled and self._state_data and self._state_data.in_steelsight and self._equipped_unit and self._camera_unit then
            local ok, error_message = pcall(function()
                local closest_ray = self._equipped_unit:base():check_autoaim(self:get_fire_weapon_position(), self:get_fire_weapon_direction(), nil, true)

                self._camera_unit:base():clbk_aim_assist(closest_ray)
            end)

            if not ok and not SIS._ads_aim_assist_error_announced then
                SIS._ads_aim_assist_error_announced = true
                SIS:log("ADS aim assist could not be applied: " .. tostring(error_message))
            end
        end

        return result
    end
end

if BipodDeployControllerInput and BipodDeployControllerInput.update then
    local original_bipod_update = BipodDeployControllerInput.update

    function BipodDeployControllerInput:update(...)
        if SIS.active_family == "pc" then
            self._deploy_bipod_t = 0
            self._deploy_bipod_waiting = true

            return
        end

        return original_bipod_update(self, ...)
    end
end

if SecondDeployableControllerInput and SecondDeployableControllerInput.update then
    local original_second_deployable_update = SecondDeployableControllerInput.update

    function SecondDeployableControllerInput:update(...)
        if SIS.active_family == "pc" then
            self._secondary_deployable_t = 0
            self._secondary_deployable_waiting = true

            return
        end

        return original_second_deployable_update(self, ...)
    end
end

SIS:log("Player input and ADS aim-assist hook installed.", true)
