-- Top-right popup shown when a level starts: how to open the menu (key read from the keybind).
FunnyMod = FunnyMod or {}
FunnyMod.Welcome = FunnyMod.Welcome or {}
local W = FunnyMod.Welcome

W.DURATION = 9
W.FADE = 0.6

local function key_name()
	local name = "F9"
	pcall(function()
		local kb = BLT.Keybinds:get_keybind("fmmt_menu")
		local k = kb and kb:Key()
		if type(k) == "string" and k ~= "" then
			name = k:upper()
		end
	end)
	return name
end

local function message()
	local fmm = rawget(_G, "FunnyModMenu")
	local text = fmm and type(fmm.L) == "function" and fmm.L("fmmt_welcome", { KEY = key_name() })
	if type(text) ~= "string" or text == "fmmt_welcome" then
		text = "Funny Mod Menu Troll - press " .. key_name() .. " to open the menu"
	end
	return text
end

function W.show()
	W.hide()
	local ok, err = pcall(function()
		local hud = managers.hud and managers.hud:script(PlayerBase.PLAYER_INFO_HUD_PD2)
		local panel = hud and hud.panel
		if not panel then
			return
		end
		local box = panel:panel({ name = "fmmt_welcome", layer = 900, w = 360, h = 56 })
		box:rect({ color = Color.black:with_alpha(0.65), layer = 0 })
		box:rect({ color = Color(0.043, 0.808, 0.6), w = 4, layer = 1 })
		local title = box:text({
			text = "Funny Mod Menu Troll", font = tweak_data.menu.pd2_medium_font, font_size = 18,
			color = Color(0.043, 0.808, 0.6), x = 14, y = 6, layer = 2
		})
		local body = box:text({
			text = message(), font = tweak_data.menu.pd2_small_font, font_size = 15,
			color = Color.white, x = 14, y = 29, w = box:w() - 20, layer = 2
		})
		box:set_right(panel:w() - 10)
		box:set_top(10)
		W.panel, W.parent, W.t = box, panel, 0
	end)
	if not ok then
		log("[FunnyModMenuTroll] welcome popup failed: " .. tostring(err))
	end
end

function W.hide()
	if W.panel and alive(W.panel) and W.parent and alive(W.parent) then
		pcall(W.parent.remove, W.parent, W.panel)
	end
	W.panel, W.parent = nil, nil
end

Hooks:Add("GameSetupUpdate", "FMMT_WelcomeUpdate", function(t, dt)
	if not (W.panel and alive(W.panel)) then
		return
	end
	W.t = W.t + dt
	local a = 1
	if W.t < W.FADE then
		a = W.t / W.FADE
	elseif W.t > W.DURATION - W.FADE then
		a = math.max(0, (W.DURATION - W.t) / W.FADE)
	end
	W.panel:set_alpha(a)
	if W.t >= W.DURATION then
		W.hide()
	end
end)

if GameSetup and not W._hooked then
	W._hooked = true
	Hooks:PostHook(GameSetup, "init_finalize", "FMMT_WelcomeShow", function()
		W.show()
	end)
end
