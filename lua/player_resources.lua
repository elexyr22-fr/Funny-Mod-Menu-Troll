-- Infinite Player Resources: throwables, deployables and body bags for the LOCAL player only.
-- Each effect hooks the single place where the game consumes the resource and lets the normal
-- action run (animation, projectile, deploy, network sync); only the counter stays unchanged:
--   throwables  PlayerManager:on_throw_grenade (refunded right after through the native regain path)
--   deployables PlayerManager:use_selected_equipment -> remove_equipment
--   body bags   PlayerManager:on_used_body_bag
-- Weapon reserve ammo lives in infiniteammo.lua, No Reload in noreload.lua.
local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")

InfinitePlayerResources = InfinitePlayerResources or {}
local IPR = InfinitePlayerResources

IPR.SETTINGS_FILE = SavePath .. "fmmt_player_resources.json"
IPR.KEYS = { "ammo", "no_reload", "throwables", "deployables", "body_bags" }
IPR.DEFAULTS = {
	ammo = true,
	no_reload = true,
	throwables = true,
	deployables = true,
	body_bags = true
}
IPR.FRENCH = {
	ammo = "Munitions infinies",
	no_reload = "No Reload",
	throwables = "Grenades infinies",
	deployables = "Équipements infinis",
	body_bags = "Sacs mortuaires infinis"
}
IPR.LABELS = {
	ammo = "InfiniteAmmo",
	no_reload = "NoReload",
	throwables = "InfiniteThrowables",
	deployables = "InfiniteDeployables",
	body_bags = "InfiniteBodyBags"
}
-- The host verifies every client's deployables against the vanilla maximum
-- (NetworkPeer:verify_deployable). Beyond it the host refuses to spawn the item and marks the
-- client as a cheater, and the game has no refund path for deployables, so infinite
-- deployables only run in solo or as the host.
IPR.AUTHORITY_ONLY = {
	deployables = true
}

local function load_flags()
	IPR.flags = {}
	for _, key in ipairs(IPR.KEYS) do
		IPR.flags[key] = IPR.DEFAULTS[key]
	end
	local file = io.open(IPR.SETTINGS_FILE, "r")
	if file then
		local ok, data = pcall(json.decode, file:read("*all"))
		file:close()
		if ok and type(data) == "table" then
			for _, key in ipairs(IPR.KEYS) do
				if type(data[key]) == "boolean" then
					IPR.flags[key] = data[key]
				end
			end
		end
	end
end

local function save_flags()
	local file = io.open(IPR.SETTINGS_FILE, "w")
	if file then
		file:write(json.encode(IPR.flags))
		file:close()
	end
end

if not IPR.flags then
	load_flags()
end

function IPR:has_authority()
	return NET.is_host()
end

function IPR:is_enabled(key)
	return self.flags[key] ~= false
end

function IPR:is_effective(key)
	if not self:is_enabled(key) then
		return false
	end
	if self.AUTHORITY_ONLY[key] and not self:has_authority() then
		return false
	end
	return true
end

function IPR:set_enabled(key, state)
	if self.flags[key] == nil then
		return
	end
	self.flags[key] = state and true or false
	save_flags()
	log("[ModMenu] " .. (self.FRENCH[key] or self.LABELS[key]) .. " -> " .. (self.flags[key] and "ON" or "OFF"))
end

function IPR:set_all(state)
	for _, key in ipairs(self.KEYS) do
		self.flags[key] = state and true or false
	end
	save_flags()
	log("[InfinitePlayerResources] All -> " .. (state and "ON" or "OFF"))
end

function IPR:status(key)
	if not self:is_enabled(key) then
		return "OFF"
	end
	if self.AUTHORITY_ONLY[key] and not self:has_authority() then
		return "ON (INACTIVE - HOST/SOLO ONLY)"
	end
	return "ON"
end

function IPR:set_ammo_enabled(state) self:set_enabled("ammo", state) end
function IPR:set_throwables_enabled(state) self:set_enabled("throwables", state) end
function IPR:set_deployables_enabled(state) self:set_enabled("deployables", state) end
function IPR:set_body_bags_enabled(state) self:set_enabled("body_bags", state) end
function IPR:set_no_reload_enabled(state) self:set_enabled("no_reload", state) end

if RequiredScript == "lib/managers/playermanager" and PlayerManager and not IPR._hooked then
	IPR._hooked = true

	local original_on_throw_grenade = PlayerManager.on_throw_grenade
	local original_remove_equipment = PlayerManager.remove_equipment
	local original_on_used_body_bag = PlayerManager.on_used_body_bag

	-- The throw runs untouched (it decrements). The grenade is then given back through the
	-- game's own regain path, add_grenade_amount(1, true): with sync=true it sends sync_grenades
	-- with this peer as register id, and register_grenade() lowers the same verify_grenade counter
	-- that the throw raised, so the host does not flag itself for exceeding the maximum.
	function PlayerManager:on_throw_grenade(...)
		local result = original_on_throw_grenade(self, ...)
		if IPR:is_effective("throwables") then
			self:add_grenade_amount(1, true)
		end
		return result
	end

	function PlayerManager:remove_equipment(equipment_id, slot, ...)
		if IPR:is_effective("deployables") then
			return
		end
		return original_remove_equipment(self, equipment_id, slot, ...)
	end

	function PlayerManager:on_used_body_bag(...)
		if IPR:is_effective("body_bags") then
			return
		end
		return original_on_used_body_bag(self, ...)
	end
end
