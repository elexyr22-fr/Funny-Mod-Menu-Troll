local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")
NoPlayerGunAlerts = NoPlayerGunAlerts or {}

-- Once the heist goes loud (whisper mode off), step aside so the AI behaves normally.
local function is_loud()
    local gs = managers and managers.groupai and managers.groupai:state()
    if not gs then
        return false
    end
    if type(gs.whisper_mode) == "function" then
        return not gs:whisper_mode()
    end
    if type(gs.enemy_weapons_hot) == "function" then
        return gs:enemy_weapons_hot() and true or false
    end
    return false
end

if NoPlayerGunAlerts.enabled == nil then
    NoPlayerGunAlerts.enabled = true
end
if NoPlayerGunAlerts.auto_disable_in_loud == nil then
    NoPlayerGunAlerts.auto_disable_in_loud = true
end

-- Public API used by the Quick Enemy Spawner mod menu.
function NoPlayerGunAlerts:set_enabled(state)
    self.enabled = state and true or false
end

function NoPlayerGunAlerts:is_enabled()
    return self.enabled and true or false
end

function NoPlayerGunAlerts:set_auto_disable_in_loud(state)
    self.auto_disable_in_loud = state and true or false
end

function NoPlayerGunAlerts:is_auto_disable_in_loud()
    return self.auto_disable_in_loud ~= false
end

function NoPlayerGunAlerts:has_authority()
    return NET.is_host()
end

function NoPlayerGunAlerts:status()
    if not self.enabled then
        return "OFF"
    end
    if not self:has_authority() then
        return "ON (NO EFFECT - CLIENT)"
    end
    if self:is_auto_disable_in_loud() and is_loud() then
        return "BYPASSED (LOUD)"
    end
    return "ON"
end

local function active()
    if not NoPlayerGunAlerts.enabled then
        return false
    end
    if not Global or not Global.game_settings then
        return false
    end
    if NoPlayerGunAlerts.auto_disable_in_loud ~= false and is_loud() then
        if not NoPlayerGunAlerts._loud_logged then
            NoPlayerGunAlerts._loud_logged = true
            log("[NoPlayerGunAlerts] Loud detected - bypassed, normal AI")
        end
        return false
    end
    return NET.is_host()
end

-- Any human player: the local one, or a client's husk on the host.
local function is_human_player(unit)
    if not alive(unit) then
        return false
    end
    local player = managers.player and managers.player:player_unit()
    if unit == player then
        return true
    end
    if type(unit.base) ~= "function" then
        return false
    end
    local base = unit:base()
    return base and (base.is_local_player or base.is_husk_player) and true or false
end

if RaycastWeaponBase and RaycastWeaponBase._check_alert and not NoPlayerGunAlerts.hooked then
    NoPlayerGunAlerts.hooked = true
    NoPlayerGunAlerts.original_check_alert = RaycastWeaponBase._check_alert

    RaycastWeaponBase._check_alert = function(self, rays, fire_pos, direction, user_unit, ...)
        if active() and is_human_player(user_unit) then
            return
        end

        return NoPlayerGunAlerts.original_check_alert(
            self, rays, fire_pos, direction, user_unit, ...
        )
    end
end
