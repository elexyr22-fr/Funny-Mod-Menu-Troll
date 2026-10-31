-- Reserve ammo for the LOCAL player's equipped weapon. Ammo is never networked to other peers,
-- so this works the same for the host and for a client that has the mod installed.
-- Kept as a per-frame check (validated in game); it only writes when the reserve dropped.

local infinite_ammo_logged = false

local function ammo_enabled()
    local ipr = rawget(_G, "InfinitePlayerResources")
    if ipr and type(ipr.is_enabled) == "function" then
        return ipr:is_enabled("ammo")
    end
    return true
end

Hooks:Add("GameSetupUpdate", "InfiniteAmmo_Update", function(t, dt)
    if not managers.player then return end
    local player = managers.player:player_unit()
    if not alive(player) then return end

    if not infinite_ammo_logged then
        infinite_ammo_logged = true
        local NET = FunnyMod and FunnyMod.Network
        log("[InfiniteReserveAmmo] Enabled for local player (" .. (NET and NET.mode() or "?") .. ")")
    end

    if not ammo_enabled() then return end

    local inventory = player:inventory()
    if not inventory then return end

    local weapon = inventory:equipped_unit()
    if not alive(weapon) then return end

    local base = weapon:base()
    if not base then return end

    if base.set_ammo_total and base.get_ammo_max then
        local max = base:get_ammo_max()
        local before = base.get_ammo_total and base:get_ammo_total() or nil
        if not before or before ~= max then
            base:set_ammo_total(max)
        end
    end
end)
