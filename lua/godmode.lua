-- God Mode, through PAYDAY 2's own switches only.
--
-- Personal (local player, saved, default ON):
--   PlayerDamage:set_god_mode(state) sets Global.god_mode and the player's _god_mode. The game
--   honours it in damage_bullet / damage_melee / damage_explosion / damage_fire / damage_simple /
--   damage_killzone / damage_fall / damage_tase, PlayerMovement:on_SPOOCed (cloaker) and on_cuffed.
--   New player units read Global.god_mode on init, so it survives respawns and level loads.
--
-- All players (HOST ONLY, saved, default OFF):
--   host      same native switch as personal (effective = personal OR all players).
--   bots      TeamAIDamage (host-simulated): damage_bullet / melee / explosion / fire / tase / dot
--             and the client-originated sync_damage_bullet / explosion / fire / melee are dropped,
--             TeamAIMovement:on_SPOOCed returns nil (what PlayerMovement:on_SPOOCed does in god
--             mode: the cloaker kick has no effect). Mission kills (damage_mission) stay scripted.
--   clients   NOT protectable from the host: every client computes the damage it receives on its
--             own machine (CopActionShoot targets attention.unit:base().is_local_player on each
--             peer, the taser and cloaker actions run on the victim's PlayerMovement). The only
--             host-authoritative player damage is friendly fire sent by the host
--             (HuskPlayerDamage -> "sync_friendly_fire_damage"): that one is blocked.
--   One Shot total from the local player still kills bots (oneshot.lua wraps after this file).
local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")

GodMode = GodMode or {}
GodMode.SETTINGS_FILE = SavePath .. "fmmt_god_mode.json"
GodMode.TEAM_AI_METHODS = {
	"damage_bullet", "damage_melee", "damage_explosion", "damage_fire", "damage_tase", "damage_dot",
	"sync_damage_bullet", "sync_damage_explosion", "sync_damage_fire", "sync_damage_melee"
}
GodMode.HUSK_PLAYER_METHODS = { "damage_bullet", "damage_melee", "damage_fire" }

local function save(state)
	local file = io.open(GodMode.SETTINGS_FILE, "w")
	if file then
		file:write(json.encode({ enabled = state and true or false }))
		file:close()
	end
end

if GodMode.saved_enabled == nil then
	GodMode.saved_enabled = true
	local file = io.open(GodMode.SETTINGS_FILE, "r")
	if file then
		local ok, data = pcall(json.decode, file:read("*all"))
		file:close()
		if ok and type(data) == "table" and type(data.enabled) == "boolean" then
			GodMode.saved_enabled = data.enabled
		end
	else
		save(true)
	end
	-- Read by PlayerDamage:init for every player unit spawned afterwards.
	Global.god_mode = GodMode.saved_enabled
end

local function is_authority()
	return NET.is_host()
end

local function player_damage()
	local player = managers.player and managers.player:player_unit()
	if not alive(player) then
		return nil
	end
	local dmg = player:character_damage()
	if dmg and type(dmg.set_god_mode) == "function" then
		return dmg
	end
	return nil
end

local function hint(key, state)
	if managers.hud and managers.hud.show_hint then
		local fmm = rawget(_G, "FunnyModMenu")
		local text = fmm and (fmm.L(key) .. " : " .. fmm.L(state and "fmmt_on" or "fmmt_off")) or ("GOD MODE : " .. (state and "ON" or "OFF"))
		managers.hud:show_hint({ text = text })
	end
end

-- Personal setting (what the menu shows), independent of "all players".
function GodMode:is_enabled()
	return GodMode.saved_enabled and true or false
end

function GodMode:all_players_enabled()
	local qes = rawget(_G, "QuickEnemySpawner")
	return qes and qes.settings and qes.settings.god_mode_all and true or false
end

function GodMode:all_players_effective()
	return self:all_players_enabled() and is_authority()
end

function GodMode:effective_local()
	return self:is_enabled() or self:all_players_effective()
end

-- Pushes the effective state into the local player through the native switch.
function GodMode:apply()
	local state = self:effective_local() and true or false
	local dmg = player_damage()
	if dmg then
		dmg:set_god_mode(state)
	else
		Global.god_mode = state
	end
end

function GodMode:set_enabled(state)
	state = state and true or false
	GodMode.saved_enabled = state
	save(state)
	self:apply()
	log("[ModMenu] Mode Dieu personnel -> " .. (state and "ON" or "OFF"))
	hint("fmmt_godmode", state)
end

function GodMode:set_all_players_enabled(state)
	state = state and true or false
	local qes = rawget(_G, "QuickEnemySpawner")
	if qes and type(qes.set_setting) == "function" then
		qes.set_setting("god_mode_all", state)
	end
	self:apply()
	log("[ModMenu] Mode Dieu tous les joueurs -> " .. (state and "ON" or "OFF") .. (is_authority() and "" or " (inactive: host only)"))
	hint("fmmt_godmode_all", state)
end

function GodMode:toggle()
	self:set_enabled(not self:is_enabled())
end

function GodMode:status()
	return self:is_enabled() and "ON" or "OFF"
end

local function wrap_blocking(class, methods, tag)
	for _, method in ipairs(methods) do
		local original = class[method]
		if type(original) == "function" then
			class[method] = function(self, ...)
				if GodMode:all_players_effective() then
					return nil
				end
				return original(self, ...)
			end
		end
	end
	log("[GodMode] " .. tag .. " protection hooks installed")
end

if RequiredScript == "lib/units/player_team/teamaidamage" and TeamAIDamage and not GodMode._team_ai_hooked then
	GodMode._team_ai_hooked = true
	wrap_blocking(TeamAIDamage, GodMode.TEAM_AI_METHODS, "TeamAI damage")
end

if RequiredScript == "lib/units/player_team/teamaimovement" and TeamAIMovement and not GodMode._team_ai_movement_hooked then
	GodMode._team_ai_movement_hooked = true
	wrap_blocking(TeamAIMovement, { "on_SPOOCed" }, "TeamAI cloaker")
end

if RequiredScript == "lib/units/beings/player/huskplayerdamage" and HuskPlayerDamage and not GodMode._husk_player_hooked then
	GodMode._husk_player_hooked = true
	wrap_blocking(HuskPlayerDamage, GodMode.HUSK_PLAYER_METHODS, "Host friendly fire")
end
