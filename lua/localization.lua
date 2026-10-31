-- Identity, localization, credits and legacy-mod warning for Funny Mod Menu Troll.
-- Language: the game's own language check (SystemInfo:language(), as the game's GUI code does)
-- selects French for a French game and English for every other language, unless the player
-- picked one in the settings. Strings live in localization/en.txt and localization/fr.txt
-- (SuperBLT JSON format); English is the fallback for any missing key.

FunnyModMenu = FunnyModMenu or {}
local FMM = FunnyModMenu

FMM.NAME = "Funny Mod Menu Troll"
FMM.VERSION = "1.6"
FMM.AUTHOR = "Elexyr22"
FMM.WEBSITE = "https://elexyr22.fr/"
FMM.LEGACY_MODS = {
	"Quick Enemy Spawner", "God Mode", "Infinite Player Resources", "Infinite Reserve Ammo",
	"Never Detected V2.1.2 (Offline)", "No Stealth Noise Alerts (Offline)", "No Player Gun Alerts (Offline)"
}

if not FMM.path and ModPath then
	FMM.path = ModPath
end

local function read_json(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local ok, data = pcall(json.decode, file:read("*all"))
	file:close()
	return ok and type(data) == "table" and data or nil
end

function FMM.load_strings()
	FMM.strings = {}
	for _, code in ipairs({ "en", "fr" }) do
		FMM.strings[code] = FMM.path and read_json(FMM.path .. "localization/" .. code .. ".txt") or {}
	end
end

if not FMM.strings then
	FMM.load_strings()
end

function FMM.game_is_french()
	if SystemInfo and type(SystemInfo.language) == "function" then
		local ok, lang = pcall(SystemInfo.language, SystemInfo)
		return ok and lang and lang:key() == Idstring("french"):key() or false
	end
	return false
end

-- "fr" or "en", from the saved setting ("auto", "fr", "en").
function FMM.language()
	local qes = rawget(_G, "QuickEnemySpawner")
	local choice = qes and qes.settings and qes.settings.language or "auto"
	if choice == "fr" or choice == "en" then
		return choice
	end
	return FMM.game_is_french() and "fr" or "en"
end

-- L("key", { NAME = "x" }) -> localized text with $NAME replaced.
function FMM.L(key, macros)
	local lang = FMM.language()
	local text = FMM.strings[lang] and FMM.strings[lang][key] or FMM.strings.en and FMM.strings.en[key] or key
	if macros then
		for name, value in pairs(macros) do
			text = text:gsub("%$" .. name, (tostring(value):gsub("%%", "%%%%")))
		end
	end
	return text
end

-- Opens a URL with managers.network.account:overlay_activate("url", url): the call SuperBLT
-- (base/req/BLTUpdate.lua) and BeardLib (Modules/Utils/ModAssetsModule.lua) use to open links,
-- and the game's own MenuNodeUpdatesGui:open_url. No shell / cmd.
function FMM.open_url(url)
	local account = managers.network and managers.network.account
	if account and type(account.overlay_activate) == "function" then
		local ok, err = pcall(account.overlay_activate, account, "url", url)
		if not ok then
			log("[FunnyModMenuTroll] overlay_activate failed: " .. tostring(err))
		end
		return ok
	end
	return false
end

function FMM.open_website()
	local ok = FMM.open_url(FMM.WEBSITE)
	log("[FunnyModMenuTroll] Open " .. FMM.WEBSITE .. " -> " .. (ok and "overlay requested" or "overlay unavailable"))
	if not ok and managers.hud and managers.hud.show_hint then
		managers.hud:show_hint({ text = FMM.WEBSITE })
	end
	return ok
end

-- Warns (never errors) when an old standalone version is enabled next to this mod.
function FMM.check_legacy_mods()
	if FMM._legacy_checked then
		return
	end
	FMM._legacy_checked = true
	local blt = rawget(_G, "BLT")
	local mods = blt and blt.Mods and type(blt.Mods.Mods) == "function" and blt.Mods:Mods()
	if type(mods) ~= "table" then
		return
	end
	for _, mod in ipairs(mods) do
		local ok_name, name = pcall(mod.GetName, mod)
		local ok_enabled, enabled = pcall(mod.IsEnabled, mod)
		if ok_name and ok_enabled and enabled and table.contains(FMM.LEGACY_MODS, name) then
			log("[FunnyModMenuTroll] WARNING: duplicate legacy mod detected: " .. tostring(name))
		end
	end
end

if not FMM._loaded_logged then
	FMM._loaded_logged = true
	log("[FunnyModMenuTroll] " .. FMM.NAME .. " " .. FMM.VERSION .. " by " .. FMM.AUTHOR .. " - " .. FMM.WEBSITE)
	FMM.check_legacy_mods()
end
