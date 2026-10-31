-- No Reload for the LOCAL player's weapons.
-- RaycastWeaponBase:fire (also reached through NewRaycastWeaponBase, AkimboWeaponBase and
-- RevolvingShotgunBase via super.fire) consumes ammo with
--   base:set_ammo_remaining_in_clip(ammo_in_clip - ammo_usage) and use_ammo -> set_ammo_total.
-- SawWeaponBase:fire has its own copy of that consumption.
-- fire() runs completely untouched (rate, recoil, damage, raycast, network); afterwards only
-- the clip and total that this shot removed are put back, so the magazine never empties.

local function no_reload_enabled()
	local ipr = rawget(_G, "InfinitePlayerResources")
	if ipr and type(ipr.is_enabled) == "function" then
		return ipr:is_enabled("no_reload")
	end
	return false
end

local function wrap_fire(class, marker)
	if not class or not class.fire or class[marker] then
		return
	end
	class[marker] = true
	local original_fire = class.fire

	class.fire = function(self, ...)
		if not no_reload_enabled() or not self._setup or self._setup.user_unit ~= managers.player:player_unit() then
			return original_fire(self, ...)
		end

		local base = type(self.ammo_base) == "function" and self:ammo_base() or self
		local clip = base:get_ammo_remaining_in_clip()
		local total = base:get_ammo_total()

		local result = original_fire(self, ...)

		if base:get_ammo_remaining_in_clip() < clip then
			base:set_ammo_remaining_in_clip(clip)
		end
		if base:get_ammo_total() < total then
			base:set_ammo_total(total)
		end

		return result
	end
end

if RequiredScript == "lib/units/weapons/raycastweaponbase" then
	wrap_fire(RaycastWeaponBase, "_ipr_no_reload_wrapped")
elseif RequiredScript == "lib/units/weapons/sawweaponbase" then
	wrap_fire(SawWeaponBase, "_ipr_no_reload_wrapped_saw")
end
