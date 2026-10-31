if not SecretLogger or not SecretLogger.export then
	log("[SecretLogger] main.lua not loaded, cannot export")
	return
end

local ok, data = SecretLogger:export("touche Export", true)
local text

if ok and type(data) == "table" then
	text = string.format("Secret exporte : %d/%d debloques, %d restants", data.completed, data.count, data.remaining)
else
	text = "Secret Logger : liste non disponible (voir logs/debug.txt)"
end

if managers.hud then
	pcall(managers.hud.show_hint, managers.hud, { text = text, time = 3 })
elseif managers.menu then
	pcall(function()
		QuickMenu:new("Secret Logger", text, { { text = "OK", is_cancel_button = true } }, true)
	end)
end
