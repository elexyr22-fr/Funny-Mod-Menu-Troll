local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")
NeverDetectedV212 = NeverDetectedV212 or {}
if NeverDetectedV212.enabled == nil then
    NeverDetectedV212.enabled = true
end

-- AI runs only on the host (clients receive synced results), so gating on solo-or-server
-- makes the effect global for every player in the session, host and clients alike.

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

if NeverDetectedV212.cameras_blind == nil then
    NeverDetectedV212.cameras_blind = true
end
if NeverDetectedV212.auto_disable_in_loud == nil then
    NeverDetectedV212.auto_disable_in_loud = true
end

-- Public API used by the Quick Enemy Spawner mod menu. The keybind (toggle.lua) and the menu
-- both change NeverDetectedV212.enabled, so there is a single state.
function NeverDetectedV212:set_enabled(state)
    self.enabled = state and true or false
end

function NeverDetectedV212:is_enabled()
    return self.enabled and true or false
end

function NeverDetectedV212:set_cameras_blind(state)
    self.cameras_blind = state and true or false
end

function NeverDetectedV212:is_cameras_blind()
    return self.cameras_blind ~= false
end

function NeverDetectedV212:set_auto_disable_in_loud(state)
    self.auto_disable_in_loud = state and true or false
end

function NeverDetectedV212:is_auto_disable_in_loud()
    return self.auto_disable_in_loud ~= false
end

function NeverDetectedV212:is_loud()
    return is_loud()
end

function NeverDetectedV212:has_authority()
    return NET.is_host()
end

function NeverDetectedV212:status()
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
    if not NeverDetectedV212.enabled then
        return false
    end
    if NeverDetectedV212.auto_disable_in_loud ~= false and is_loud() then
        if not NeverDetectedV212._loud_logged then
            NeverDetectedV212._loud_logged = true
            log("[NeverDetected] Loud detected - bypassed, normal AI")
        end
        return false
    end
    if not Global or not Global.game_settings then
        return false
    end
    local is_host = NET.is_host()
    if is_host and not NeverDetectedV212._mp_logged then
        NeverDetectedV212._mp_logged = true
        log("[NeverDetected] Multiplayer host - global stealth sandbox enabled")
    end
    return is_host
end

if CopLogicBase and CopLogicBase._upd_attention_obj_detection and not NeverDetectedV212._ai_hooked then
    NeverDetectedV212._ai_hooked = true
    NeverDetectedV212.original_detection = CopLogicBase._upd_attention_obj_detection

    CopLogicBase._upd_attention_obj_detection = function(data, min_reaction, max_reaction)
        if active() then
            if data and data.detected_attention_objects then
                for _, info in pairs(data.detected_attention_objects) do
                    if info then
                        info.notice_progress = nil
                        info.uncover_progress = nil
                        info.last_suspicion_t = nil
                    end
                end
            end
            return 1
        end

        return NeverDetectedV212.original_detection(data, min_reaction, max_reaction)
    end
end
