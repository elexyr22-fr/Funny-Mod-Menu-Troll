local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")
NeverDetectedV212 = NeverDetectedV212 or {}
if NeverDetectedV212.enabled == nil then
    NeverDetectedV212.enabled = true
end

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

local function active()
    if not NeverDetectedV212.enabled or NeverDetectedV212.cameras_blind == false then
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

local function clear_camera(self)
    if self._detected_attention_objects and next(self._detected_attention_objects) then
        if self._destroy_all_detected_attention_object_data then
            self:_destroy_all_detected_attention_object_data()
        else
            self._detected_attention_objects = {}
        end
    end

    self._suspicion = nil
    self._suspicion_lvl_sync = nil

    if self._set_suspicion_sound then
        self:_set_suspicion_sound(0)
    end

    if self._stop_all_sounds then
        self:_stop_all_sounds()
    end
end

-- The camera normally acquires attention objects before suspicion starts.
-- Blocking acquisition makes it genuinely blind rather than only blocking alarm consequences.
if SecurityCamera and SecurityCamera._upd_acquire_new_attention_objects
    and not NeverDetectedV212._cam_acquire_hooked then

    NeverDetectedV212._cam_acquire_hooked = true
    NeverDetectedV212.original_cam_acquire = SecurityCamera._upd_acquire_new_attention_objects

    SecurityCamera._upd_acquire_new_attention_objects = function(self, t, ...)
        if active() then
            clear_camera(self)
            return
        end

        return NeverDetectedV212.original_cam_acquire(self, t, ...)
    end
end

-- Safety net: if something was already acquired by a mission/script, do not process detection.
if SecurityCamera and SecurityCamera._upd_detect_attention_objects
    and not NeverDetectedV212._cam_detect_hooked then

    NeverDetectedV212._cam_detect_hooked = true
    NeverDetectedV212.original_cam_detect = SecurityCamera._upd_detect_attention_objects

    SecurityCamera._upd_detect_attention_objects = function(self, t, ...)
        if active() then
            clear_camera(self)
            return
        end

        return NeverDetectedV212.original_cam_detect(self, t, ...)
    end
end

-- Extra safety: no suspicion progression.
if SecurityCamera and SecurityCamera._upd_suspicion
    and not NeverDetectedV212._cam_susp_hooked then

    NeverDetectedV212._cam_susp_hooked = true
    NeverDetectedV212.original_cam_suspicion = SecurityCamera._upd_suspicion

    SecurityCamera._upd_suspicion = function(self, t, ...)
        if active() then
            clear_camera(self)
            return
        end

        return NeverDetectedV212.original_cam_suspicion(self, t, ...)
    end
end

-- Keep the alarm/police-call safeguards too.
if SecurityCamera and SecurityCamera._sound_the_alarm
    and not NeverDetectedV212._cam_alarm_hooked then

    NeverDetectedV212._cam_alarm_hooked = true
    NeverDetectedV212.original_cam_alarm = SecurityCamera._sound_the_alarm

    SecurityCamera._sound_the_alarm = function(self, detected_unit, ...)
        if active() then
            clear_camera(self)
            return
        end

        return NeverDetectedV212.original_cam_alarm(self, detected_unit, ...)
    end
end

if SecurityCamera and SecurityCamera.clbk_call_the_police
    and not NeverDetectedV212._cam_call_hooked then

    NeverDetectedV212._cam_call_hooked = true
    NeverDetectedV212.original_cam_call = SecurityCamera.clbk_call_the_police

    SecurityCamera.clbk_call_the_police = function(self, ...)
        if active() then
            self._call_police_clbk_id = nil
            return
        end

        return NeverDetectedV212.original_cam_call(self, ...)
    end
end
