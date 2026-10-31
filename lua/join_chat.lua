-- FunnyMod.JoinChat (V17): sends "Funny Game lol" ONCE per online session, in the real game chat.
--
-- Verified in the 248.2 source:
--   ChatManager:send_message(channel_id, sender, message) (chatmanager.lua:36): with a network
--   session it calls session:send_to_peers_ip_verified("send_chat_message", channel_id, message)
--   and shows it locally with receive_message_by_peer (our name, our peer color). Every other
--   player, vanilla or modded, gets it through ConnectionNetworkHandler:send_chat_message
--   (connectionnetworkhandler.lua:637) -> receive_message_by_peer: the normal chat, lobby and game.
--   ChatManager.GAME (= 1) is the lobby / in-game chat channel.
--   Client: ClientNetworkSession:on_join_request_reply sets the host peer ip_verified once the
--   join is accepted (clientnetworksession.lua:228/235). Host: a joining peer becomes synched
--   (NetworkPeer:synched) when its join sync is complete (BaseNetworkSession:on_peer_sync_complete).
--
-- Once per session, not once per map: the flag lives in Global (kept across the level loads of a
-- multi-day job, where the mod scripts are reloaded but the network session goes on) and is reset
-- only when no session exists any more (main menu, session destroyed / left): a new lobby sends
-- again. Solo / offline (Global.game_settings.single_player, or no session): nothing is sent.
-- Host: sent when the first remote player has finished joining (first moment someone can read it).
-- Client: sent once the host accepted the join. Option: settings.join_chat_message (default ON).
FunnyMod = FunnyMod or {}
FunnyMod.JoinChat = FunnyMod.JoinChat or {}
local JC = FunnyMod.JoinChat

JC.MESSAGE = "Funny Game lol"
JC.CHECK_INTERVAL = 0.5
-- Seconds between "session ready" and the message, so the other side's chat GUI is up.
JC.SEND_DELAY = 2

local function NET()
	return FunnyMod.Network
end

local function state()
	Global.fmmt_join_chat = Global.fmmt_join_chat or { sent = false }
	return Global.fmmt_join_chat
end

function JC.enabled()
	local qes = rawget(_G, "QuickEnemySpawner")
	if qes and type(qes.get_setting) == "function" and qes.settings then
		return qes.get_setting("join_chat_message") ~= false
	end
	return true
end

function JC.reset(reason)
	local s = state()
	if s.sent or s.key then
		log("[FunnyMod][JoinChat] reset (" .. tostring(reason) .. ")")
	end
	s.sent, s.key = false, nil
	JC._ready_t = nil
end

local function peer_call(peer, name)
	local f = peer and peer[name]
	if type(f) ~= "function" then
		return nil
	end
	local ok, v = pcall(f, peer)
	return ok and v or nil
end

-- Session identity: the host's account for a client, "host" when we host. Changing host without
-- passing through "no session" is still a new lobby.
local function session_key(session)
	if NET().is_client() then
		local host = type(session.server_peer) == "function" and session:server_peer()
		return "client:" .. tostring(peer_call(host, "user_id"))
	end
	return "host"
end

local function session_ready(session)
	if type(session.local_peer) ~= "function" or not session:local_peer() then
		return false
	end
	if NET().is_client() then
		local host = type(session.server_peer) == "function" and session:server_peer()
		return peer_call(host, "ip_verified") and true or false
	end
	if not NET().is_host() or type(session.peers) ~= "function" then
		return false
	end
	for _, peer in pairs(session:peers()) do
		if peer_call(peer, "ip_verified") and peer_call(peer, "synched") then
			return true
		end
	end
	return false
end

local function send()
	local chat = managers.chat
	if not chat or type(chat.send_message) ~= "function" then
		return false, "no ChatManager"
	end
	local channel = ChatManager and ChatManager.GAME or 1
	local account = managers.network and managers.network.account
	local name = account and type(account.username) == "function" and account:username() or "Offline"
	return pcall(chat.send_message, chat, channel, tostring(name), JC.MESSAGE)
end

function JC.update(t)
	if JC._next_t and t < JC._next_t then
		return
	end
	JC._next_t = t + JC.CHECK_INTERVAL
	local net = NET()
	if not net then
		return
	end
	local session = net.session()
	if not session or net.is_singleplayer() then
		JC.reset(not session and "no session" or "solo")
		return
	end
	local s = state()
	local key = session_key(session)
	if s.key and s.key ~= key then
		JC.reset("new session")
	end
	s.key = key
	if s.sent then
		return
	end
	if not session_ready(session) then
		JC._ready_t = nil
		return
	end
	-- t = the running setup's clock (MenuUpdate / GameSetupUpdate); JC is rebuilt at each level
	-- load, so the delay never mixes two clocks.
	JC._ready_t = JC._ready_t or t
	if t - JC._ready_t < JC.SEND_DELAY then
		return
	end
	-- The flag is set even when the option is OFF: turning it ON later in the same session never
	-- sends a late message.
	s.sent = true
	if not JC.enabled() then
		log("[FunnyMod][JoinChat] option OFF: nothing sent (" .. net.mode() .. ")")
		return
	end
	local ok, err = send()
	log("[FunnyMod][JoinChat] " .. (ok and "sent" or ("send failed: " .. tostring(err))) .. " (" .. net.mode() .. ")")
end

if not JC._hooked and Hooks then
	JC._hooked = true
	local function tick(t)
		local ok, err = pcall(JC.update, t or 0)
		if not ok and not JC._error_logged then
			JC._error_logged = true
			log("[FunnyMod][JoinChat] error: " .. tostring(err))
		end
	end
	Hooks:Add("MenuUpdate", "FMMT_JoinChat_Menu", function(t, dt)
		tick(t)
	end)
	Hooks:Add("GameSetupUpdate", "FMMT_JoinChat_Game", function(t, dt)
		tick(t)
	end)
end

return JC
