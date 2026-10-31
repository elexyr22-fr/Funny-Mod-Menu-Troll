-- FunnyMod.Vanish (V15): the AI half of Vanish (the visual half, V16, is lua/player_invisibility.lua).
-- The AI ignores the LOCAL player only. Not God Mode (damage is unchanged:
-- stray bullets, explosions, fire still hurt), not Never Detected (the other players / bots are
-- still detected and attacked normally, alarms and cameras on them still work). HOST ONLY.
-- Verified in the 248.2 source:
--
--   Every AI observer (cops: CopLogicBase._upd_attention_obj_detection coplogicbase.lua:421,
--   CopLogicIdle, team AI, sentries sentrygunbrain.lua:135, cameras securitycamera.lua:230) gets
--   its targets from GroupAIStateBase:get_AI_attention_objects_by_filter (groupaistatebase.lua:4579)
--   and keeps one only if attention_info.handler:get_attention(...) returns settings
--   (AIAttentionObject:get_attention, lib/units/props/aiattentionobject.lua:185). The filter lists
--   are rebuilt per unit by GroupAIStateBase:on_AI_attention_changed (:4551), which also calls
--   get_attention. The local player's handler is PlayerMovement:attention_handler()
--   (CharacterAttentionObject = class(AIAttentionObject), get_attention not overridden).
--
--   Vanish ON : AIAttentionObject:get_attention returns nil for the local player's handler only,
--               then handler:_call_listeners() (aiattentionobject.lua:248) =
--               groupai on_AI_attention_changed (the player leaves every filter list) + the
--               "detect_<enemy>" listeners of every enemy that had detected the player ->
--               CopLogicBase.on_detected_attention_obj_modified (coplogicbase.lua): get_attention
--               is nil -> _destroy_detected_attention_object_data (suspicion / notice reset),
--               _set_attention_obj(nil) when the player was the focus, firing stopped.
--               = detection reset, no focus, the other targets are untouched.
--   Vanish OFF: the wrapper returns the vanilla settings again, _call_listeners() once more puts
--               the player back in the lists, the enemies detect them the normal way.
--
-- Network: detection / targeting run on the server (clients only have Husk units). A client
-- cannot remove their own attention from the host's AI, and a local-only fake is refused: HOST
-- ONLY (capability "vanish" = host). Solo counts as host.
FunnyMod = FunnyMod or {}
Vanish = Vanish or {}
FunnyMod.Vanish = Vanish
local VN = Vanish

VN.CHECK_INTERVAL = 0.5

local function setting(key, default)
	local q = rawget(_G, "QuickEnemySpawner")
	local value = q and q.settings and q.settings[key]
	if value == nil then
		return default
	end
	return value
end

local function is_host()
	local n = FunnyMod.Network
	return n and n.is_host() or false
end

function VN:is_enabled()
	return setting("vanish", false) == true
end

function VN:is_active()
	return VN._handler ~= nil
end

function VN:set_enabled(state)
	local q = rawget(_G, "QuickEnemySpawner")
	if q and type(q.set_setting) == "function" then
		q.set_setting("vanish", state and true or false)
	end
	log("[Vanish] -> " .. (state and "ON" or "OFF") .. (is_host() and "" or " (HOST ONLY: no effect as client)"))
	VN.apply()
end

local function local_handler()
	local player = managers.player and managers.player:player_unit()
	if not alive(player) then
		return nil
	end
	local movement = player:movement()
	return movement and type(movement.attention_handler) == "function" and movement:attention_handler() or nil, player
end

-- Enemies that currently have the player in their detected attention objects (log only).
local function count_detecting(player)
	local n = 0
	local key = player:key()
	local enemies = managers.enemy and type(managers.enemy.all_enemies) == "function" and managers.enemy:all_enemies()
	for _, data in pairs(enemies or {}) do
		local brain = alive(data.unit) and data.unit:brain()
		local ld = brain and brain._logic_data
		if ld and ld.detected_attention_objects and ld.detected_attention_objects[key] then
			n = n + 1
		end
	end
	return n
end

local function notify(handler)
	if handler and type(handler._call_listeners) == "function" then
		local ok, err = pcall(handler._call_listeners, handler)
		if not ok then
			log("[Vanish] listener refresh failed: " .. tostring(err))
		end
	end
end

-- Brings the real state in line with the option (called on toggle and every CHECK_INTERVAL: a new
-- player unit after custody gets a new handler).
function VN.apply()
	local want = VN:is_enabled() and is_host()
	local handler, player = local_handler()
	if want and handler then
		if VN._handler ~= handler then
			local old = VN._handler
			local before = player and count_detecting(player) or 0
			VN._handler = handler
			if old then
				notify(old)
			end
			notify(handler)
			local after = player and count_detecting(player) or 0
			log(string.format("[Vanish] ON (HOST): local player removed from AI attention, detection reset on %d enemies (%d still tracking)", before, after))
		end
	elseif VN._handler then
		local old = VN._handler
		VN._handler = nil
		notify(old)
		log("[Vanish] OFF: normal AI attention restored" .. (want and "" or (is_host() and "" or " (not host)")))
	end
end

if RequiredScript == "lib/units/props/aiattentionobject" and AIAttentionObject and not VN._attention_hooked then
	VN._attention_hooked = true
	local original_get_attention = AIAttentionObject.get_attention
	function AIAttentionObject:get_attention(...)
		if VN._handler ~= nil and self == VN._handler then
			return nil
		end
		return original_get_attention(self, ...)
	end
end

if not VN._update_hooked and Hooks then
	VN._update_hooked = true
	Hooks:Add("GameSetupUpdate", "FMMT_VanishUpdate", function(t, dt)
		if not VN._handler and not VN:is_enabled() then
			return
		end
		if VN._next_t and t < VN._next_t then
			return
		end
		VN._next_t = t + VN.CHECK_INTERVAL
		local ok, err = pcall(VN.apply)
		if not ok and not VN._error_logged then
			VN._error_logged = true
			log("[Vanish] error: " .. tostring(err))
		end
	end)
end

-- V16: Vanish never survives the level (unload, lobby, mission end): AI option reset OFF too.
function VN.reset()
	VN._handler = nil
	VN._next_t = nil
	local q = rawget(_G, "QuickEnemySpawner")
	if q and q.settings and q.settings.vanish then
		q.settings.vanish = false
		if type(q.save_settings) == "function" then
			pcall(q.save_settings)
		end
		log("[Vanish] AI vanish reset OFF (level change)")
	end
end

return VN
