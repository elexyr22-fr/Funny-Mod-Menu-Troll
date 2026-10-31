local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")
-- Infinite sentry ammo for sentries owned by the LOCAL player.
-- SentryGunWeapon:fire spends ammo with change_ammo(-1) (sentrygunweapon.lua); only that
-- decrement is skipped, so firing, rate, damage, targeting and the ammo sync stay vanilla.
-- Player sentries carry an owner id (SentryGunBase:get_owner_id); enemy / mission turrets have
-- none and are never affected. HOST ONLY (verified, sentrygunbrain.lua: expend_ammo =
-- Network:is_server()): sentries only spend ammo on the host, a client's sentry is fired by the
-- host and its ammo reaches the owner through sync_ammo. So this works for the host's own sentries.

SentryAmmo = SentryAmmo or {}
local SA = SentryAmmo

function SA:is_enabled()
	local qes = rawget(_G, "QuickEnemySpawner")
	local value = qes and qes.settings and qes.settings.sentry_infinite_ammo
	if value == nil then
		return true
	end
	return value and true or false
end

function SA:set_enabled(state)
	local qes = rawget(_G, "QuickEnemySpawner")
	if qes and type(qes.set_setting) == "function" then
		qes.set_setting("sentry_infinite_ammo", state and true or false)
	end
	log("[ModMenu] Sentry infinite ammo -> " .. (state and "ON" or "OFF"))
end

local function owned_by_local_player(unit)
	local base = alive(unit) and unit:base()
	if not base then
		return false
	end
	local player = managers.player and managers.player:player_unit()
	if type(base.get_owner) == "function" and player and base:get_owner() == player then
		return true
	end
	local peer_id = NET.local_peer_id()
	if type(base.get_owner_id) == "function" and peer_id then
		local owner_id = base:get_owner_id()
		return owner_id ~= nil and owner_id == peer_id
	end
	return false
end

if RequiredScript == "lib/units/weapons/sentrygunweapon" and SentryGunWeapon and not SA._hooked then
	SA._hooked = true
	local original_change_ammo = SentryGunWeapon.change_ammo

	function SentryGunWeapon:change_ammo(amount, ...)
		if type(amount) == "number" and amount < 0 and SA:is_enabled() and NET.is_host() and owned_by_local_player(self._unit) then
			return
		end
		return original_change_ammo(self, amount, ...)
	end
end
