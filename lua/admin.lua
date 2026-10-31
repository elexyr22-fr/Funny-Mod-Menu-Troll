-- Host administration built only on PAYDAY 2's own session tools:
--   kick     = VoteManager:message_host_kick  -> send_to_peers("kick_peer", id, 0) + on_peer_kicked
--   ban      = MenuCallbackHandler:_kick_ban_player_confirm -> managers.ban_list:ban + kick_peer id 6
--   join ban = HostStateBase:_is_banned, already checked by the game on every join request
-- The ban identifier is the one the game itself uses: peer:account_id() on PC.
local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")

ModMenuAdmin = ModMenuAdmin or {}
local Admin = ModMenuAdmin

local KICK_MESSAGE_ID = 0
local BAN_MESSAGE_ID = 6

function Admin.log(msg)
	local qes = rawget(_G, "QuickEnemySpawner")
	if not (qes and qes.settings and qes.settings.show_admin_logs == false) then
		log("[ModMenu] " .. tostring(msg))
	end
end

function Admin.is_host()
	return NET.can_affect_remote_players()
end

local function session()
	return NET.session()
end

local function identifier_of(peer)
	return IS_PC and peer:account_id() or peer:name()
end

function Admin.get_players()
	local list = {}
	local s = session()
	if not s then
		return list
	end
	local local_peer = s:local_peer()
	for id, peer in pairs(s:all_peers()) do
		table.insert(list, {
			id = id,
			name = peer:name(),
			account_id = peer:account_id(),
			identifier = identifier_of(peer),
			is_host = peer:is_host(),
			is_local = peer == local_peer
		})
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return list
end

local function kickable_peer(peer_id)
	if not Admin.is_host() then
		Admin.log("Kick/Ban refused: not host")
		return nil
	end
	local s = session()
	local peer = s and s:peer(peer_id)
	if not peer then
		Admin.log("Kick/Ban refused: peer " .. tostring(peer_id) .. " not found")
		return nil
	end
	if peer == s:local_peer() then
		Admin.log("Kick/Ban refused: cannot target yourself")
		return nil
	end
	return peer, s
end

function Admin.kick_peer(peer_id)
	local peer, s = kickable_peer(peer_id)
	if not peer then
		return false
	end
	local name = peer:name()
	Admin.log("Kick requested: " .. name)
	s:send_to_peers("kick_peer", peer_id, KICK_MESSAGE_ID)
	s:on_peer_kicked(peer, peer_id, KICK_MESSAGE_ID)
	Admin.log("Kicked: " .. name)
	return true
end

local function persist_ban_list()
	if managers.savefile and type(managers.savefile.save_progress) == "function" then
		pcall(managers.savefile.save_progress, managers.savefile)
	end
end

function Admin.ban_peer(peer_id)
	local peer, s = kickable_peer(peer_id)
	if not peer then
		return false
	end
	if not managers.ban_list then
		Admin.log("Ban refused: managers.ban_list unavailable")
		return false
	end
	local name = peer:name()
	local identifier = identifier_of(peer)
	if not managers.ban_list:banned(identifier) then
		managers.ban_list:ban(identifier, name)
	end
	persist_ban_list()
	Admin.log("Banned: " .. name .. " id=" .. tostring(identifier))
	s:send_to_peers("kick_peer", peer_id, BAN_MESSAGE_ID)
	s:on_peer_kicked(peer, peer_id, BAN_MESSAGE_ID)
	Admin.log("Kicked: " .. name)
	return true
end

function Admin.get_bans()
	local list = {}
	if managers.ban_list then
		for _, entry in ipairs(managers.ban_list:ban_list()) do
			table.insert(list, { name = entry.name, identifier = entry.identifier })
		end
	end
	return list
end

function Admin.unban(identifier)
	if not Admin.is_host() then
		Admin.log("Unban refused: not host")
		return false
	end
	if not managers.ban_list then
		return false
	end
	managers.ban_list:unban(identifier)
	persist_ban_list()
	Admin.log("Unbanned: id=" .. tostring(identifier))
	return true
end

function Admin.unban_all()
	if not Admin.is_host() then
		Admin.log("Unban refused: not host")
		return false
	end
	local count = 0
	for _, entry in ipairs(Admin.get_bans()) do
		managers.ban_list:unban(entry.identifier)
		count = count + 1
	end
	persist_ban_list()
	Admin.log("Unbanned all (" .. count .. ")")
	return true
end

-- Logging only: the game already refuses banned accounts in HostStateBase:_is_banned.
if RequiredScript == "lib/network/base/session_states/hoststatebase" and HostStateBase and not Admin._join_hooked then
	Admin._join_hooked = true
	local original_is_banned = HostStateBase._is_banned
	function HostStateBase:_is_banned(peer_name, account_id, ...)
		local banned = original_is_banned(self, peer_name, account_id, ...)
		if banned then
			Admin.log("Banned player attempted to join: " .. tostring(peer_name))
			Admin.log("Join refused for banned account: " .. tostring(account_id))
		end
		return banned
	end
end
