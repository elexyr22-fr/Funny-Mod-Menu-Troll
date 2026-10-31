local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")
NoStealthNoiseAlerts = NoStealthNoiseAlerts or {}

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

if NoStealthNoiseAlerts.enabled == nil then
    NoStealthNoiseAlerts.enabled = true
end
if NoStealthNoiseAlerts.auto_disable_in_loud == nil then
    NoStealthNoiseAlerts.auto_disable_in_loud = true
end

-- Public API used by the Quick Enemy Spawner mod menu.
function NoStealthNoiseAlerts:set_enabled(state)
    self.enabled = state and true or false
end

function NoStealthNoiseAlerts:is_enabled()
    return self.enabled and true or false
end

function NoStealthNoiseAlerts:set_auto_disable_in_loud(state)
    self.auto_disable_in_loud = state and true or false
end

function NoStealthNoiseAlerts:is_auto_disable_in_loud()
    return self.auto_disable_in_loud ~= false
end

function NoStealthNoiseAlerts:has_authority()
    return NET.is_host()
end

function NoStealthNoiseAlerts:status()
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
    if not NoStealthNoiseAlerts.enabled then
        return false
    end
    if not Global or not Global.game_settings then
        return false
    end
    if NoStealthNoiseAlerts.auto_disable_in_loud ~= false and is_loud() then
        if not NoStealthNoiseAlerts._loud_logged then
            NoStealthNoiseAlerts._loud_logged = true
            log("[NoStealthNoiseAlerts] Loud detected - bypassed, normal AI")
        end
        return false
    end
    local is_host = NET.is_host()
    if is_host and not NoStealthNoiseAlerts._mp_logged then
        NoStealthNoiseAlerts._mp_logged = true
        log("[NoStealthNoiseAlerts] Multiplayer host - global alerts disabled")
    end
    return is_host
end

NoStealthNoiseAlerts._seen_types = NoStealthNoiseAlerts._seen_types or {}

-- PAYDAY 2 AI does not learn about loud events directly from
-- on_police_called(). It first distributes alert events to cops/civilians
-- through GroupAIStateBase:propagate_alert().
--
-- CopBrain listeners include aggressive alert types such as:
-- bullet, explosion, fire and aggression.
--
-- Drop those events before any AI listener receives them.
local blocked_types = {
    bullet = true,
    explosion = true,
    fire = true,
    aggression = true
}

if GroupAIStateBase
    and GroupAIStateBase.propagate_alert
    and not NoStealthNoiseAlerts._propagate_hooked then

    NoStealthNoiseAlerts._propagate_hooked = true
    NoStealthNoiseAlerts.original_propagate_alert =
        GroupAIStateBase.propagate_alert

    GroupAIStateBase.propagate_alert = function(self, alert_data, ...)
        local is_active = active()
        local alert_type = type(alert_data) == "table" and alert_data[1] or nil

        -- One line per distinct alert type for the whole session, to identify which type
        -- glass breaking uses in this game version (not verifiable without the game source).
        if is_active and alert_type ~= nil and not NoStealthNoiseAlerts._seen_types[alert_type] then
            NoStealthNoiseAlerts._seen_types[alert_type] = true
            log("[NoStealthNoiseAlerts] alert type seen: " .. tostring(alert_type) .. " blocked=" .. tostring(blocked_types[alert_type] == true))
        end

        if is_active and alert_type ~= nil and blocked_types[alert_type] then
            return
        end

        return NoStealthNoiseAlerts.original_propagate_alert(
            self, alert_data, ...
        )
    end
end
