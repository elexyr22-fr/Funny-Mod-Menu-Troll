-- Loot bag spawner (host only), through the game's own thrown-bag pipeline:
--   PlayerManager:drop_carry (a player throwing a bag) computes camera position / rotation /
--   forward and the carry.throw_distance_multiplier upgrade level, then the host runs
--   PlayerManager:server_drop_carry(...) which spawns the bag, sends sync_carry_data to every
--   peer and pushes it along the throw direction. "throw" mode reuses those exact values.
-- The peer argument is left nil: with a peer, verify_carry checks that this peer was carrying
-- that bag (peer:verify_bag) and would flag the host as a cheater; nil is the branch the game
-- uses for bags created by the server. The thrower is then recorded with set_latest_peer_id.
-- Only bags spawned here are tracked; removal uses set_slot(0) as ElementCarry "remove" does.
local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")

LootSpawner = LootSpawner or {}
local LS = LootSpawner

LS.TYPES = {
	{ id = "money", label_key = "fmmt_loot_money" },
	{ id = "gold", label_key = "fmmt_loot_gold" },
	{ id = "coke", label_key = "fmmt_loot_coke" },
	{ id = "weapon", label_key = "fmmt_loot_weapons" },
	{ id = "diamonds", label_key = "fmmt_loot_jewelry" },
	{ id = "meth", label_key = "fmmt_loot_meth" }
}
LS.spawned = LS.spawned or {}

local function is_authority()
	return NET.is_host()
end

function LS.max_bags()
	local qes = rawget(_G, "QuickEnemySpawner")
	local m = qes and qes.settings and qes.settings.loot_max
	return type(m) == "number" and m > 0 and m or 50
end

function LS.available_types()
	local list = {}
	for _, t in ipairs(LS.TYPES) do
		if tweak_data.carry[t.id] then
			table.insert(list, t)
		end
	end
	return list
end

function LS.count()
	local n = 0
	for key, unit in pairs(LS.spawned) do
		if alive(unit) then
			n = n + 1
		else
			LS.spawned[key] = nil
		end
	end
	return n
end

-- Returns position, rotation, direction, throw upgrade level.
local function spawn_transform(player, where)
	if where == "throw" then
		local camera = player:camera()
		if camera then
			local level = managers.player:upgrade_level("carry", "throw_distance_multiplier", 0)
			return camera:position(), camera:rotation(), camera:forward(), level
		end
	end
	local forward = player:rotation():y()
	return player:position() + forward * 60 + Vector3(0, 0, 40), player:rotation(), Vector3(0, 0, 0), 0
end

-- carry_id "random" picks one of the available types. where: "throw" (default) or "feet".
function LS.spawn(carry_id, where)
	if not is_authority() then
		log("[LootSpawner] Spawn refused: host only")
		return nil
	end
	local player = managers.player and managers.player:player_unit()
	if not alive(player) then
		return nil
	end
	if LS.count() >= LS.max_bags() then
		log("[LootSpawner] Limit reached (" .. LS.max_bags() .. ")")
		if managers.hud and managers.hud.show_hint then
			local L = rawget(_G, "FunnyModMenu") and FunnyModMenu.L
			managers.hud:show_hint({ text = (L and L("fmmt_loot_limit") or "Bag limit reached") .. " (" .. LS.max_bags() .. ")" })
		end
		return nil
	end
	if carry_id == "random" then
		local types = LS.available_types()
		carry_id = #types > 0 and types[math.random(#types)].id or nil
	end
	if not carry_id or not tweak_data.carry[carry_id] then
		log("[LootSpawner] Unknown carry id: " .. tostring(carry_id))
		return nil
	end

	local pos, rot, dir, level = spawn_transform(player, where)
	local ok, unit = pcall(managers.player.server_drop_carry, managers.player, carry_id, 1, false, false, 1, pos, rot, dir, level, nil, nil)
	if not ok then
		log("[LootSpawner] Spawn failed: " .. tostring(unit))
		return nil
	end
	if alive(unit) then
		local peer_id = NET.local_peer_id()
		if peer_id and unit:carry_data() and type(unit:carry_data().set_latest_peer_id) == "function" then
			unit:carry_data():set_latest_peer_id(peer_id)
		end
		LS.spawned[unit:key()] = unit
		log("[LootSpawner] Sac " .. carry_id .. " (" .. LS.count() .. "/" .. LS.max_bags() .. ")")
	end
	return unit
end

function LS.clear()
	if not is_authority() then
		return 0
	end
	local n = 0
	for key, unit in pairs(LS.spawned) do
		if alive(unit) then
			unit:set_slot(0)
			n = n + 1
		end
		LS.spawned[key] = nil
	end
	log("[LootSpawner] Sacs supprimés : " .. n)
	return n
end
