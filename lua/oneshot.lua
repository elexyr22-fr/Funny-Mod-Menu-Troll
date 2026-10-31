-- One Shot total: any DIRECT damage dealt by the LOCAL player that really reaches a target kills
-- it through the target's own native damage function (animation, ragdoll, callbacks, network sync,
-- kill statistics). Nothing is killed around the player: only the unit whose damage_* callback
-- the game itself called with attack_data.attacker_unit == local player (or a projectile/grenade
-- whose thrower_unit is the local player).
--
-- Targets and native paths (PAYDAY 2 248.2 source):
--   Enemies, QES units, civilians     CopDamage:damage_bullet / damage_melee / damage_explosion /
--   (CopDamage and every subclass)    damage_fire / damage_dot / damage_simple / damage_tase.
--                                     The damage is raised above the unit's health and, for the
--                                     duration of that single vanilla call only:
--                                       DAMAGE_CLAMP_BULLET / _EXPLOSION / _SHOCK lifted (bosses),
--                                       medic heal-instead-of-death skipped (check_medic_heal),
--                                       invulnerable_to_slotmask immunity skipped,
--                                       Bulldozer plate treated as armor piercing.
--                                     Mission invulnerability (_invulnerable) and scripted
--                                     immortality (_immortal) are respected: they are mission logic.
--                                     Host only: if the vanilla call still left the unit alive, the
--                                     game's own damage_mission finishes it (synced death).
--   Jokers / allied NPCs (HOST)       same CopDamage path, the friendly fire check
--                                     (CopDamage:is_friendly_fire, PlayerDamage.is_friendly_fire)
--                                     is lifted for that call only.
--   Bots / TeamAI (HOST)              TeamAIDamage:force_custody(), the call the mission element
--                                     ElementTeamAICommands uses (bleedout + death, synced).
--   Human players                     HuskPlayerDamage only sends damage when the vanilla Friendly
--                                     Fire mutator is active (it is also what lets bullets hit
--                                     players). Then the hit is raised to a lethal value and sent
--                                     through the native "sync_friendly_fire_damage" message. The
--                                     victim's own game applies it. Without that mutator the
--                                     victim's game refuses friendly damage: nothing is forced.
--                                     "God Mode tous les joueurs" (host) keeps humans invincible.
-- On a client, allied NPCs and bots are simulated by the host: only enemies are affected there.
local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")

OneShot = OneShot or {}
local OS = OneShot

OS.COP_METHODS = { "damage_bullet", "damage_melee", "damage_explosion", "damage_fire", "damage_dot", "damage_simple", "damage_tase" }
OS.CLAMPS = {
	damage_bullet = "DAMAGE_CLAMP_BULLET",
	damage_explosion = "DAMAGE_CLAMP_EXPLOSION",
	damage_simple = "DAMAGE_CLAMP_SHOCK"
}
OS.TEAM_AI_METHODS = { "damage_bullet", "damage_melee", "damage_explosion", "damage_fire" }
OS.HUSK_PLAYER_METHODS = { "damage_bullet", "damage_melee", "damage_fire" }
OS.LETHAL_MUL = 1000

local function setting(key, default)
	local qes = rawget(_G, "QuickEnemySpawner")
	if qes and qes.settings and qes.settings[key] ~= nil then
		return qes.settings[key]
	end
	return default
end

function OS:is_enabled()
	return setting("one_shot_total", true) and true or false
end

function OS:set_enabled(state)
	local qes = rawget(_G, "QuickEnemySpawner")
	if qes and type(qes.set_setting) == "function" then
		qes.set_setting("one_shot_total", state and true or false)
	end
	log("[ModMenu] One Shot total -> " .. (state and "ON" or "OFF"))
end

local function is_authority()
	return NET.is_host()
end

local function local_player()
	local player = managers.player and managers.player:player_unit()
	return alive(player) and player or nil
end

-- True when the hit comes from the local player, directly or through a projectile he threw.
function OS.is_local_attack(attack_data)
	local player = local_player()
	if not player or type(attack_data) ~= "table" then
		return false
	end
	local attacker = attack_data.attacker_unit
	if attacker == player then
		return true
	end
	if alive(attacker) then
		local base = attacker:base()
		if base and type(base.thrower_unit) == "function" then
			local ok, thrower = pcall(base.thrower_unit, base)
			return ok and thrower == player or false
		end
	end
	return false
end

local function hostile_to_players(unit)
	local movement = unit:movement()
	local team = movement and type(movement.team) == "function" and movement:team()
	return team and team.foes and team.foes.criminal1 and true or false
end

local function pack(...)
	return { n = select("#", ...), ... }
end

local function no()
	return false
end

local function none()
	return nil
end

-- Runs original(self, attack_data, ...) with the per-call overrides, always restoring them.
local function lethal_cop_call(self, method, original, attack_data, friendly, ...)
	local health = self._HEALTH_INIT or self._health or 1000
	attack_data.damage = math.max(tonumber(attack_data.damage) or 0, health * OS.LETHAL_MUL)
	attack_data.armor_piercing = true

	local base = self._unit:base()
	local char_tweak = base and type(base.char_tweak) == "function" and base:char_tweak()
	local clamp_key = OS.CLAMPS[method]
	local clamp = char_tweak and clamp_key and char_tweak[clamp_key]
	if clamp then
		char_tweak[clamp_key] = nil
	end
	local saved_medic, saved_immune, saved_ff = rawget(self, "check_medic_heal"), rawget(self, "chk_immune_to_attacker"), rawget(self, "is_friendly_fire")
	self.check_medic_heal = no
	self.chk_immune_to_attacker = none
	local saved_static_ff = PlayerDamage and PlayerDamage.is_friendly_fire
	if friendly then
		self.is_friendly_fire = no
		if PlayerDamage then
			PlayerDamage.is_friendly_fire = no
		end
	end

	local result = pack(pcall(original, self, attack_data, ...))

	if clamp then
		char_tweak[clamp_key] = clamp
	end
	self.check_medic_heal = saved_medic
	self.chk_immune_to_attacker = saved_immune
	if friendly then
		self.is_friendly_fire = saved_ff
		if PlayerDamage then
			PlayerDamage.is_friendly_fire = saved_static_ff
		end
	end
	if not result[1] then
		error(result[2], 0)
	end
	return unpack(result, 2, result.n)
end

local function finish_if_alive(self, attack_data)
	if self._dead or self._invulnerable or self._immortal or not is_authority() then
		return
	end
	if type(self.damage_mission) ~= "function" then
		return
	end
	local ok, err = pcall(self.damage_mission, self, {
		damage = (self._HEALTH_INIT or 1000) * OS.LETHAL_MUL,
		attacker_unit = attack_data.attacker_unit,
		variant = attack_data.variant or "bullet",
		col_ray = attack_data.col_ray
	})
	if not ok then
		log("[OneShot] damage_mission fallback failed: " .. tostring(err))
	end
end

if RequiredScript == "lib/units/enemies/cop/copdamage" and CopDamage and not OS._cop_hooked then
	OS._cop_hooked = true
	for _, method in ipairs(OS.COP_METHODS) do
		local original = CopDamage[method]
		if type(original) == "function" then
			CopDamage[method] = function(self, attack_data, ...)
				if self._dead or self._invulnerable or self._immortal or not OS:is_enabled() or not OS.is_local_attack(attack_data) then
					return original(self, attack_data, ...)
				end
				local friendly = not hostile_to_players(self._unit)
				if friendly and not is_authority() then
					return original(self, attack_data, ...)
				end
				local result = lethal_cop_call(self, method, original, attack_data, friendly, ...)
				if not self._dead then
					finish_if_alive(self, attack_data)
				end
				return result
			end
		end
	end
end

if RequiredScript == "lib/units/player_team/teamaidamage" and TeamAIDamage and not OS._team_ai_hooked then
	OS._team_ai_hooked = true
	for _, method in ipairs(OS.TEAM_AI_METHODS) do
		local original = TeamAIDamage[method]
		if type(original) == "function" then
			TeamAIDamage[method] = function(self, attack_data, ...)
				if not self._dead and OS:is_enabled() and is_authority() and OS.is_local_attack(attack_data)
					and type(self.force_custody) == "function" then
					self:force_custody()
					log("[OneShot] Bot " .. tostring(self._unit and self._unit:key()) .. " killed (" .. method .. ")")
					return { type = "death", variant = attack_data.variant or "bullet" }
				end
				return original(self, attack_data, ...)
			end
		end
	end
end

if RequiredScript == "lib/units/beings/player/huskplayerdamage" and HuskPlayerDamage and not OS._husk_player_hooked then
	OS._husk_player_hooked = true
	for _, method in ipairs(OS.HUSK_PLAYER_METHODS) do
		local original = HuskPlayerDamage[method]
		if type(original) == "function" then
			HuskPlayerDamage[method] = function(self, attack_data, ...)
				local gm = rawget(_G, "GodMode")
				local protected = gm and type(gm.all_players_effective) == "function" and gm:all_players_effective()
				if not protected and OS:is_enabled() and OS.is_local_attack(attack_data) then
					-- modify_value("HuskPlayerDamage:FriendlyFireDamage") scales by the mutator multiplier * 0.25.
					attack_data.damage = math.max(tonumber(attack_data.damage) or 0, 100000)
				end
				return original(self, attack_data, ...)
			end
		end
	end
end

function OS.friendly_fire_mutator_active()
	local mutators = managers.mutators
	local ff = rawget(_G, "MutatorFriendlyFire")
	if mutators and ff and type(mutators.is_mutator_active) == "function" then
		local ok, active = pcall(mutators.is_mutator_active, mutators, ff)
		return ok and active and true or false
	end
	return false
end
