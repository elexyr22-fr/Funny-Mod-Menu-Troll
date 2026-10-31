-- F9 keybind: opens / closes the Funny Mod Menu Troll menu (lua/menu.lua).
-- V16.1: the menu is a BeardLib MenuUI. Without BeardLib loaded, menu.lua used to crash the game
-- (FATAL "attempt to index global 'MenuUI'"); now the key only logs why nothing opens.

local sis = false
if BLT and BLT.Mods and type(BLT.Mods.GetModByName) == "function" then
	local ok, mod = pcall(BLT.Mods.GetModByName, BLT.Mods, "Seamless Input Switch")
	sis = ok and mod ~= nil and (type(mod.IsEnabled) ~= "function" or mod:IsEnabled()) or false
end

local path = ModPath or (FunnyModMenu and FunnyModMenu.path)
local menu = rawget(_G, "SpawnerMenu")
if not path then
	log("[FunnyModMenuTroll] Menu not opened: mod path unknown")
elseif rawget(_G, "MenuUI") == nil then
	log("[FunnyMod][F9] Menu not opened: BeardLib (MenuUI) is not loaded. Install / enable BeardLib in mods/.")
else
	dofile(path .. "lua/menu.lua")
end
