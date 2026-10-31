-- Custody helpers (host only), built on TradeManager, the game's trade/respawn system.
-- Verified in 248.2 (lib/managers/trademanager.lua, groupaistatebesiege.lua):
--   * A dead criminal gets a respawn_penalty (on_player_criminal_death / on_AI_criminal_death)
--     counted down once per second in TradeManager:update.
--   * The vanilla trade only starts when is_trade_allowed() (host, not whisper mode, hostage_count
--     > 0 OR a converted enemy exists) AND _trade_countdown is true. GroupAIStateBesiege sets
--     set_trade_countdown(false) at the start of EVERY assault (groupaistatebesiege.lua:503) and
--     back to true only when the regroup ends (:762): no trade during an assault. That is why a
--     hostage / converted enemy did not give an immediate trade in V11.
--   * After that, vanilla still waits math.random(2, 5) s, plays the megaphone line, waits
--     TRADE_DELAY (5 s) and makes the hostage walk (clbk_begin_hostage_trade_dialog / _trade).
--   * Converted enemies DO count for a trade in vanilla: is_trade_allowed accepts
--     all_converted_enemies(), and get_best_hostage falls back to a converted enemy when no real
--     hostage exists. So a converted enemy is a valid trade target natively; nothing is faked.
--
-- Instant trade (ON): penalty forced to 0 at death (sent to clients through set_trade_death),
-- and while someone is in custody and an exchangeable hostage exists, the host runs the Stockholm
-- Syndrome instant trade path at once (PlayerManager:clbk_super_syndrome_respawn uses the same
-- calls): get_best_hostage + criminal_respawn + begin_hostage_trade(instant). criminal_respawn
-- syncs "set_trade_spawn" and spawns the member through spawn_member_by_id / spawn_one_teamAI.
-- Whisper mode (stealth) is respected for the AUTOMATIC trade, like vanilla; the manual
-- "trade now" button works in any phase.
--
-- Force respawn: TradeManager:criminal_respawn alone, the call the game makes at the end of every
-- trade (native, synced). No teleport is simulated.
local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")

FunnyMod = FunnyMod or {}
CustodyTrade = CustodyTrade or {}
FunnyMod.Trade = CustodyTrade
local CT = CustodyTrade

CT.AUTO_CHECK_INTERVAL = 0.5

local function is_authority()
	return NET.is_host()
end

local function setting(key, default)
	local qes = rawget(_G, "QuickEnemySpawner")
	local value = qes and qes.settings and qes.settings[key]
	if value == nil then
		return default
	end
	return value and true or false
end

local function set_setting(key, state)
	local qes = rawget(_G, "QuickEnemySpawner")
	if qes and type(qes.set_setting) == "function" then
		qes.set_setting(key, state and true or false)
	end
end

function CT:instant_enabled()
	return setting("instant_trades", true)
end

function CT:converted_tradeable()
	return setting("converted_tradeable", true)
end

function CT:set_converted_tradeable(state)
	set_setting("converted_tradeable", state)
	log("[Trade] Converted = tradeable hostage -> " .. (state and "ON" or "OFF"))
end

function CT:set_instant_enabled(state)
	set_setting("instant_trades", state)
	if state and is_authority() and managers.trade and type(managers.trade._criminals_to_respawn) == "table" then
		for _, crim in ipairs(managers.trade._criminals_to_respawn) do
			crim.respawn_penalty = 0
		end
	end
	log("[ModMenu] Instant trades -> " .. (state and "ON" or "OFF"))
end

-- { { id = character name, ai = bool, peer_id, crim = trade entry } }
function CT.in_custody()
	local list = {}
	local trade = managers.trade
	if trade and type(trade._criminals_to_respawn) == "table" then
		for _, crim in ipairs(trade._criminals_to_respawn) do
			table.insert(list, { id = crim.id, ai = crim.ai and true or false, peer_id = crim.peer_id, crim = crim })
		end
	end
	return list
end

function CT.custody_entry_for_peer(peer_id)
	for _, entry in ipairs(CT.in_custody()) do
		if entry.peer_id == peer_id and not entry.ai then
			return entry
		end
	end
	return nil
end

local function group_state()
	return managers.groupai and managers.groupai:state()
end

-- Real hostages (civilians / tied cops, GroupAIStateBase:hostage_count) + converted enemies
-- when the option is on. On a client the headcount is the synced one (display only).
function CT.tradeable_count()
	local state = group_state()
	if not state then
		return 0, 0, 0
	end
	local hostages = type(state.hostage_count) == "function" and state:hostage_count() or 0
	local converted = 0
	if CT:converted_tradeable() and type(state.all_converted_enemies) == "function" then
		for _, unit in pairs(state:all_converted_enemies() or {}) do
			if alive(unit) then
				converted = converted + 1
			end
		end
	end
	return hostages + converted, hostages, converted
end

local function is_converted(unit)
	local state = group_state()
	local all = state and type(state.all_converted_enemies) == "function" and state:all_converted_enemies()
	return all and alive(unit) and all[unit:key()] ~= nil or false
end

-- Returns true, or false + reason ("host_only", "no_player", "no_hostage", "trading").
function CT.free_with_hostage(crim)
	if not is_authority() then
		return false, "host_only"
	end
	local player = managers.player and managers.player:player_unit()
	if not alive(player) then
		return false, "no_player"
	end
	local trade = managers.trade
	if not trade or not crim then
		return false, "no_player"
	end
	if trade._trading_hostage then
		return false, "trading"
	end
	local hostage = trade:get_best_hostage(player:position(), true)
	if not hostage or not alive(hostage.unit) then
		return false, "no_hostage"
	end
	if not CT:converted_tradeable() and is_converted(hostage.unit) then
		return false, "no_hostage"
	end
	local pos, rot = hostage.unit:position(), hostage.unit:rotation()
	trade:criminal_respawn(pos, rot, crim)
	trade:begin_hostage_trade(pos, rot, hostage, true, true, true)
	log("[Trade] " .. tostring(crim.id) .. " traded with a hostage" .. (is_converted(hostage.unit) and " (converted enemy)" or ""))
	return true
end

CT.trade_now = CT.free_with_hostage

function CT.force_respawn(crim)
	if not is_authority() then
		return false, "host_only"
	end
	local player = managers.player and managers.player:player_unit()
	if not alive(player) or not crim then
		return false, "no_player"
	end
	managers.trade:criminal_respawn(player:position(), player:rotation(), crim)
	log("[Trade] " .. tostring(crim.id) .. " force respawned")
	return true
end

-- Automatic instant trade, run BEFORE TradeManager:update so the vanilla dialog / delayed
-- callback is never scheduled while the instant path is possible.
function CT.auto_update(trade, t)
	if not is_authority() or not CT:instant_enabled() then
		return
	end
	if CT._next_check_t and t < CT._next_check_t then
		return
	end
	CT._next_check_t = t + CT.AUTO_CHECK_INTERVAL
	if #(trade._criminals_to_respawn or {}) == 0 or trade._trading_hostage or trade._hostage_trade_clbk or trade._speaker_snd_event then
		return
	end
	local state = group_state()
	if not state or (type(state.whisper_mode) == "function" and state:whisper_mode()) then
		return
	end
	if CT.tradeable_count() <= 0 then
		return
	end
	local player = managers.player and managers.player:player_unit()
	if not alive(player) then
		return
	end
	local crim = trade:get_criminal_to_trade(false)
	if crim then
		CT.free_with_hostage(crim)
	end
end

if RequiredScript == "lib/managers/trademanager" and TradeManager and not CT._hooked then
	CT._hooked = true
	local original_player_death = TradeManager.on_player_criminal_death
	local original_ai_death = TradeManager.on_AI_criminal_death

	function TradeManager:on_player_criminal_death(criminal_name, respawn_penalty, ...)
		if is_authority() and CT:instant_enabled() then
			respawn_penalty = 0
		end
		return original_player_death(self, criminal_name, respawn_penalty, ...)
	end

	function TradeManager:on_AI_criminal_death(criminal_name, respawn_penalty, ...)
		if is_authority() and CT:instant_enabled() then
			respawn_penalty = 0
		end
		return original_ai_death(self, criminal_name, respawn_penalty, ...)
	end

	Hooks:PreHook(TradeManager, "update", "FMMT_InstantTradeUpdate", function(self, t, dt)
		local ok, err = pcall(CT.auto_update, self, t)
		if not ok and not CT._error_logged then
			CT._error_logged = true
			log("[Trade] auto trade error: " .. tostring(err))
		end
	end)
end

return CT
