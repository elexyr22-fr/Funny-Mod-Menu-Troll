-- FunnyMod.AutoSteal (V15): system "steal" of the common engine FunnyMod.AutoActions. Takes the
-- pickable objects close to the local player through their REAL interaction
-- (FunnyMod.RealInteract), host AND client: as client only the vanilla request goes to the host,
-- and if the host refuses nothing changes locally. Nothing is deleted, spawned or added to the
-- inventory by the mod. Verified classes / methods (248.2, lib/units/interactions/interactionext.lua):
--
--   priority 1  collectibles: Gage packages (GageAssignmentInteractionExt:interact ->
--               GageAssignmentBase:_pickup -> sync_pickup / send_to_host("sync_pickup")),
--               turtle / horseshoe ids (UseInteractionExt, sync_interacted).
--   priority 2  mission items: SpecialEquipmentInteractionExt (:2686, keycards, crowbar, ... the
--               item comes from apply_item_pickup on the host / sync_interacted), and mission
--               pickups by tweak id prefix (pickup_, gen_pku_, press_pick_up, hold_pku_, pku_,
--               take_, hold_take_).
--   priority 3  valuables: SmallLootInteractionExt (:1675, base:take), MoneyWrapInteractionExt
--               (:1687), DiamondInteractionExt (:1694) (base:take_money).
--   priority 4  other allowed pickups: pick_up_item.
--   NEVER: anything that gives a loot BAG (CarryInteractionExt, unit:carry_data(), tweak
--   blocked_hint "carry_block": it would put a bag on the player's back), SpecialEquipmentGiveAndTake
--   (consumes an item), deployables (ammo / doctor / grenade / body bags, sentries, ECM, trip
--   mines), revive / hostages, drills, doors, cameras, vehicles, zip lines, turrets, safehouse.
--
-- V18 client audit (30/09 log, 6 client sessions): not one Auto Steal / Auto Pickup request was
-- ever SENT as client. Every attempt stopped locally in RealInteract.can_interact with
-- "can_select=false" (Gage packages AND shaped charges, seconds after the level started): a local
-- BaseInteractionExt:can_select refusal, before interact() and before any RPC. The host / RPC
-- path was never reached, so nothing in that log shows it broken. V18: the refusal reason is
-- detailed (player state / deployable / skill), a casing-state refusal waits instead of burning
-- retries, and every type keeps its own HOST / CLIENT result (AS.stats, AS.TYPES).
--
-- Vanilla client path per type (what interact() does on a client, 248.2 interactionext.lua):
--   collectible  GageAssignmentInteractionExt -> GageAssignmentBase:pickup -> send_to_host
--                "sync_pickup"; the host validates, the pickup callback confirms.
--   keycard      SpecialEquipmentInteractionExt:interact -> client: send_to_host
--   crowbar      "sync_interacted"; host: apply_item_pickup (checks the peer can carry it) ->
--   mission      special_eq_response to that peer -> only THEN the client gets the item.
--                Mission pickups by id prefix (UseInteractionExt): "interact" sequence +
--                sync_interacted.
--   valuable     SmallLoot / MoneyWrap / Diamond: base:take -> sent to the host, which secures it.
--   other        pick_up_item (generic, UseInteractionExt, sync_interacted).
-- The mod never adds an item, never set_slot(0) / deletes a unit: only interact() runs, exactly
-- the manual path. A type that fails AS.CLIENT_FAIL_LIMIT times as client with no confirmation in
-- the session is marked unsupported on client and no longer tried (log + menu matrix).
--
-- Auto Pickup (highlight.lua) = collectibles only. Auto Steal = everything above. Both share
-- RealInteract and the engine: a unit taken by one is never started again by the other.
FunnyMod = FunnyMod or {}
AutoSteal = AutoSteal or {}
FunnyMod.AutoSteal = AutoSteal
local AS = AutoSteal

AS.RADII = { 2, 5, 10, 20, 0 }
AS.PRIORITY = { collectible = 1, keycard = 2, crowbar = 2, mission = 2, jewelry = 3, cash_bundle = 3, atm_cash = 3, valuable = 3, other = 4 }
-- Display order of the per-type matrix ("other" = generic pickup).
AS.TYPES = { "collectible", "keycard", "crowbar", "mission", "jewelry", "cash_bundle", "atm_cash", "valuable", "other" }
AS.CLIENT_FAIL_LIMIT = 3
-- stats[type][mode] = { sent, confirmed, refused }; mode "HOST" (solo / host) or "CLIENT".
AS.stats = AS.stats or {}
AS._client_unsupported = AS._client_unsupported or {}

local COLLECTIBLE_IDS = {
	gage_assignment = true,
	hold_pick_up_turtle = true,
	ranc_press_pickup_horseshoe = true
}
local MISSION_PREFIXES = { "pickup_", "gen_pku_", "press_pick_up", "hold_pku_", "pku_", "take_", "hold_take_" }
local OTHER_IDS = { pick_up_item = true }
-- V18.x, ids checked in 248.2 lib/tweak_data/interactiontweakdata.lua. Jewelry: icon
-- "interaction_diamond", no carry_block (small loot secured by the host, no bag). Cash bundles:
-- icon "interaction_money_wrap" WITHOUT blocked_hint "carry_block" (money_wrap / money_wrap_axis /
-- money_wrap_active / money_small are BAG piles and stay excluded by gives_bag).
local JEWELRY_IDS = {
	diamond_pickup = true,
	diamond_pickup_axis = true,
	diamond_pickup_3sec = true,
	diamond_pickup_pal = true,
	diamonds_pickup = true,
	diamonds_pickup_full = true,
	diamond_single_pickup = true,
	diamond_single_pickup_axis = true,
	safe_loot_pickup = true,
	suburbia_necklace_pickup = true
}
local CASH_IDS = {
	money_wrap_single_bundle = true,
	suburbia_money_wrap = true
}
-- ATM (248.2): the ATM unit uses "atm_interaction" (open after the drill) / "requires_ecm_jammer_atm".
-- V18.2: ATM units are only used by [ATMDEBUG] (never opened / drilled here). The cash inside is
-- classed by its own tweak / class; "atm_cash" stays in the matrix until a real id is identified.
local ATM_IDS = { atm_interaction = true, requires_ecm_jammer_atm = true }
local VALUABLE_CLASSES = { "SmallLootInteractionExt", "MoneyWrapInteractionExt", "DiamondInteractionExt" }
local NEVER_CLASSES = {
	"CarryInteractionExt",
	"SpecialEquipmentGiveAndTakeInteractionExt",
	"ReviveInteractionExt",
	"IntimitateInteractionExt",
	"MissionDoorDeviceInteractionExt",
	"AmmoBagInteractionExt",
	"DoctorBagBaseInteractionExt",
	"GrenadeCrateInteractionExt",
	"BodyBagsBagInteractionExt",
	"C4BagInteractionExt",
	"MultipleEquipmentBagInteractionExt",
	"SentryGunInteractionExt",
	"SentryGunFireModeInteractionExt",
	"TripMineInteractionExt",
	"ECMJammerInteractionExt",
	"SecurityCameraInteractionExt",
	"AccessCameraInteractionExt",
	"ZipLineInteractionExt",
	"DrivingInteractionExt",
	"PlayerTurretInteractionExt",
	"LootBankInteractionExt",
	"CivilianHeisterInteractionExt",
	"SafehouseNPCInteractionExt",
	"MultipleChoiceInteractionExt"
}

local function RI()
	return FunnyMod.RealInteract or FunnyMod.require_api and FunnyMod.require_api("RealInteract", "real_interact.lua")
end

local function setting(key, default)
	local q = rawget(_G, "QuickEnemySpawner")
	local value = q and q.settings and q.settings[key]
	if value == nil then
		return default
	end
	return value
end

local function set_setting(key, value)
	local q = rawget(_G, "QuickEnemySpawner")
	if q and type(q.set_setting) == "function" then
		q.set_setting(key, value)
	end
end

function AS:is_enabled()
	return setting("auto_steal", false) == true
end

function AS:set_enabled(state)
	set_setting("auto_steal", state and true or false)
	log("[AutoSteal] -> " .. (state and "ON" or "OFF"))
	if not state and FunnyMod.AutoActions then
		FunnyMod.AutoActions.reset("steal")
	end
end

function AS:radius()
	return tonumber(setting("auto_steal_radius", 5)) or 5
end

function AS:set_radius(meters)
	set_setting("auto_steal_radius", meters)
end

local function starts_with_any(id, prefixes)
	for _, prefix in ipairs(prefixes) do
		if id:sub(1, #prefix) == prefix then
			return true
		end
	end
	return false
end

local function is_any(ri, interaction, classes)
	for _, name in ipairs(classes) do
		if ri.is_a(interaction, name) then
			return true, name
		end
	end
	return false
end

local function gives_bag(unit, interaction)
	if type(unit.carry_data) == "function" and unit:carry_data() then
		return true
	end
	local td = interaction._tweak_data
	return type(td) == "table" and td.blocked_hint == "carry_block"
end

-- "collectible" | "mission" | "valuable" | "other" | nil, reason
function AS.classify(unit)
	local ri = RI()
	local interaction = alive(unit) and unit:interaction()
	if not interaction then
		return nil, "no interaction"
	end
	local id = type(interaction.tweak_data) == "string" and interaction.tweak_data or ""
	local oh = FunnyMod.Highlight
	local gage_class = rawget(_G, "GageAssignmentInteractionExt")
	if COLLECTIBLE_IDS[id] or (gage_class and ri.is_a(interaction, "GageAssignmentInteractionExt")) then
		return "collectible"
	end
	if (JEWELRY_IDS[id] or CASH_IDS[id]) and not gives_bag(unit, interaction) then
		if JEWELRY_IDS[id] then
			return "jewelry"
		end
		-- V18.2: the ATM proximity guess is gone (never seen confirmed in game): ATM cash is classed by
		-- its real tweak / class like any cash; [CashDebug] / [ATMDEBUG] identify it at runtime.
		return "cash_bundle"
	end
	local never, class_name = is_any(ri, interaction, NEVER_CLASSES)
	if never then
		return nil, "excluded class " .. tostring(class_name)
	end
	if gives_bag(unit, interaction) then
		return nil, "gives a loot bag"
	end
	if ri.is_a(interaction, "SpecialEquipmentInteractionExt") then
		local eq = tostring(interaction._special_equipment or "")
		if eq == "bank_manager_key" or id:find("keycard", 1, true) or eq:find("keycard", 1, true) then
			return "keycard"
		elseif eq == "crowbar" or id:find("crowbar", 1, true) then
			return "crowbar"
		end
		return "mission"
	end
	if starts_with_any(id, MISSION_PREFIXES) then
		return "mission"
	end
	-- V18.2: by the real extension class (248.2 interactionext.lua:1675-1699), whatever the tweak id:
	-- MoneyWrapInteractionExt / DiamondInteractionExt -> base:take_money, SmallLootInteractionExt ->
	-- base:take. Bag piles were already refused above (gives_bag: carry_data / carry_block).
	if ri.is_a(interaction, "MoneyWrapInteractionExt") then
		return "cash_bundle"
	elseif ri.is_a(interaction, "DiamondInteractionExt") then
		return "jewelry"
	elseif ri.is_a(interaction, "SmallLootInteractionExt") then
		return "valuable"
	end
	if OTHER_IDS[id] then
		return "other"
	end
	return nil, "not a pickup (" .. id .. ")"
end

local function mode()
	local n = FunnyMod.Network
	return n and n.is_client() and "CLIENT" or "HOST"
end

local function stat(kind, m)
	kind = kind or "other"
	AS.stats[kind] = AS.stats[kind] or {}
	local st = AS.stats[kind][m]
	if not st then
		st = { sent = 0, confirmed = 0, refused = 0 }
		AS.stats[kind][m] = st
	end
	return st
end

local function dlog(msg)
	local aa = FunnyMod.AutoActions
	if aa and aa.debug() then
		log("[AutoSteal] " .. msg)
	end
end

-- "ok" | "fail" | "unsupported" | "untested" for one type in one mode (this session).
function AS.status(kind, m)
	m = m or mode()
	if m == "CLIENT" and AS._client_unsupported[kind] then
		return "unsupported"
	end
	local st = AS.stats[kind] and AS.stats[kind][m]
	if not st or st.sent == 0 then
		return "untested"
	end
	if st.confirmed > 0 then
		return "ok"
	end
	return st.refused > 0 and "fail" or "untested"
end

function AS.client_allowed(kind)
	return mode() ~= "CLIENT" or not AS._client_unsupported[kind]
end

-- V18.1 DIAGNOSTIC (Debug Auto Actions ON, every AS.DIAG_INTERVAL s, never per frame).
-- [AutoSteal] reject: why a relevant pickup (collectible / jewelry / cash / valuable...) is not
-- taken, logged ONCE per unit and reason. PLAYER_STATE = vanilla BaseInteractionExt:can_select ->
-- _is_in_required_state refused (casing / mask_off: only tweaks with can_interact_in_civilian, or
-- requires_mask_off_upgrade + the mask_off_pickup skill, pass). Nothing is bypassed.
-- [AutoSteal][ATMDEBUG]: every interactable within ATM_DEBUG_RANGE of an ATM unit, logged once per
-- unit / tweak / active change, to identify the real cash unit of an opened ATM.
AS.DIAG_INTERVAL = 2
AS._rejects = AS._rejects or {}
AS._atm_seen = AS._atm_seen or {}
local ATM_DEBUG_RANGE_SQ = 250 * 250
local CASH_DEBUG_RANGE_SQ = 800 * 800
AS._cash_seen = AS._cash_seen or {}
local EXT_CLASSES = {
	"GageAssignmentInteractionExt", "SmallLootInteractionExt", "MoneyWrapInteractionExt",
	"DiamondInteractionExt", "SpecialEquipmentInteractionExt", "CarryInteractionExt",
	"MissionDoorDeviceInteractionExt", "UseInteractionExt", "BaseInteractionExt"
}

local function ext_class(ri, interaction)
	for _, name in ipairs(EXT_CLASSES) do
		if ri.is_a(interaction, name) then
			return name
		end
	end
	return "?"
end

local function player_state(player)
	local m = alive(player) and player:movement()
	return m and type(m.current_state_name) == "function" and m:current_state_name() or "?"
end

local function reject(unit, id, reason, extra)
	local key = unit:key()
	if AS._rejects[key] == reason then
		return
	end
	AS._rejects[key] = reason
	log(string.format("[AutoSteal] reject tweak=%s unit=%s reason=%s%s (%s)", tostring(id), tostring(FunnyMod.AutoActions.unit_label(unit)), reason, extra and (" " .. extra) or "", mode()))
end

function AS.diagnose(ctx)
	local aa = FunnyMod.AutoActions
	if not aa or not aa.debug() then
		return
	end
	if AS._diag_t and ctx.t < AS._diag_t then
		return
	end
	AS._diag_t = ctx.t + AS.DIAG_INTERVAL
	local units = managers.interaction and managers.interaction._interactive_units
	if type(units) ~= "table" then
		return
	end
	local ri = RI()
	local state = player_state(ctx.player)
	local atms = {}
	for _, unit in ipairs(units) do
		local ix = alive(unit) and unit:interaction()
		if ix and ATM_IDS[ix.tweak_data] then
			table.insert(atms, unit:position())
		end
	end
	for _, unit in ipairs(units) do
		local ix = alive(unit) and unit:interaction()
		if not ix then
			-- NO_INTERACTION: nothing to log for a unit without an interaction extension.
		else
			local id = type(ix.tweak_data) == "string" and ix.tweak_data or "?"
			local pos = ri.position(unit)
			local active = type(ix.active) == "function" and ix:active() or false
			-- ATM debug.
			if not ATM_IDS[id] then
				for _, apos in ipairs(atms) do
					local d = mvector3.distance_sq(pos, apos)
					if d <= ATM_DEBUG_RANGE_SQ then
						local sig = id .. tostring(active)
						if AS._atm_seen[unit:key()] ~= sig then
							AS._atm_seen[unit:key()] = sig
							local ok_ci, why = ri.can_interact(unit, ctx.player)
							log(string.format("[AutoSteal][ATMDEBUG] unit=%s interaction_tweak=%s ext=%s active=%s can_interact=%s%s distance_to_atm=%.2fm player_dist=%.1fm player_state=%s mask=%s %s",
								tostring(aa.unit_label(unit)), id, ext_class(ri, ix), tostring(active), tostring(ok_ci and true or false), ok_ci and "" or (" (" .. tostring(why) .. ")"),
								math.sqrt(d) / 100, mvector3.distance(ctx.pos, pos) / 100, state, tostring(state ~= "mask_off" and state ~= "civilian" and state ~= "clean"), mode()))
						end
						break
					end
				end
			end
			local kind = AS.classify(unit)
			-- V18.2 [CashDebug]: every interaction within CASH_DEBUG_RANGE of the player that is
			-- unknown to Auto Steal or classed as cash / jewelry / small loot, once per unit + tweak +
			-- active state. Gives the REAL unit / class / tweak of the money seen in game.
			if (kind == nil or kind == "cash_bundle" or kind == "jewelry" or kind == "valuable")
				and mvector3.distance_sq(ctx.pos, pos) <= CASH_DEBUG_RANGE_SQ then
				local sig = id .. tostring(active)
				if AS._cash_seen[unit:key()] ~= sig then
					AS._cash_seen[unit:key()] = sig
					local td = ix._tweak_data
					local ok_ci, why = ri.can_interact(unit, ctx.player)
					log(string.format("[CashDebug] unit_key=%s unit_name=%s interaction_class=%s tweak=%s kind=%s active=%s distance=%.1fm can_interact=%s%s carry_block=%s special_equipment=%s mode=%s player_state=%s",
						tostring(unit:key()), tostring(aa.unit_label(unit)), ext_class(ri, ix), id, tostring(kind or "UNKNOWN_TYPE"), tostring(active),
						mvector3.distance(ctx.pos, pos) / 100, tostring(ok_ci and true or false), ok_ci and "" or (" (" .. tostring(why) .. ")"),
						tostring(gives_bag(unit, ix)), tostring(type(td) == "table" and td.special_equipment or ix._special_equipment or "-"), mode(), state))
				end
			end
			-- Reject reasons for relevant pickups only.
			if kind then
				local key = unit:key()
				local pending = aa._pending[key]
				if not active then
					reject(unit, id, "INACTIVE")
				elseif ctx.max_sq and mvector3.distance_sq(ctx.pos, pos) > ctx.max_sq then
					reject(unit, id, "OUT_OF_RANGE")
				elseif not AS.client_allowed(kind) then
					reject(unit, id, "CLIENT_UNSUPPORTED")
				elseif pending and pending.phase == "cooldown" and ctx.t < (pending.cooldown or 0) then
					reject(unit, id, "COOLDOWN", tostring(pending.reason or ""))
				elseif pending and pending.phase ~= "cooldown" then
					reject(unit, id, "PENDING", tostring(pending.phase))
				else
					local ok_ci, why, code = ri.can_interact(unit, ctx.player)
					if not ok_ci then
						reject(unit, id, code == "state" and "PLAYER_STATE" or "CAN_INTERACT_FALSE", "(" .. tostring(why) .. ")")
					else
						AS._rejects[key] = nil
					end
				end
			end
		end
	end
end

-- V18.3: money kinds also taken when only Auto Pickup (auto_pickup_collectibles) is ON.
local MONEY_KINDS = { jewelry = true, cash_bundle = true, atm_cash = true, valuable = true }

function AS.pickup_money()
	local oh = FunnyMod.Highlight
	return oh and type(oh.auto_pickup_enabled) == "function" and oh:auto_pickup_enabled() and true or false
end

-- Auto Steal ON: every kind. Auto Pickup only: money kinds (Gage stays with the pickup system).
function AS.kind_wanted(kind)
	return AS:is_enabled() or MONEY_KINDS[kind] == true
end

AS.system = {
	id = "steal",
	mission_action = false,
	-- V18.3: Auto Pickup ON also takes money / jewelry / small loot (not only Gage packages).
	enabled = function()
		return AS:is_enabled() or AS.pickup_money()
	end,
	radius = function()
		return AS:radius()
	end,
	detect = function(ctx)
		local list, seen = {}, {}
		-- Collectibles first, from the Gage lists too (a package is not always in the interaction list).
		local oh = FunnyMod.Highlight
		if oh and type(oh.find_collectibles) == "function" then
			for key, unit in pairs(oh.find_collectibles()) do
				seen[key] = true
				if AS:is_enabled() and AS.client_allowed("collectible") then
					table.insert(list, { unit = unit, priority = AS.PRIORITY.collectible, info = "collectible" })
				end
			end
		end
		pcall(AS.diagnose, ctx)
		local units = managers.interaction and managers.interaction._interactive_units
		if type(units) == "table" then
			local ri = RI()
			for _, unit in ipairs(units) do
				if alive(unit) and not seen[unit:key()] then
					local interaction = unit:interaction()
					if interaction and interaction:active() then
						-- Cheap distance filter before the classification.
						if not ctx.max_sq or mvector3.distance_sq(ctx.pos, ri.position(unit)) <= ctx.max_sq then
							local kind = AS.classify(unit)
							if kind and AS.client_allowed(kind) and AS.kind_wanted(kind) then
								table.insert(list, { unit = unit, priority = AS.PRIORITY[kind], info = kind })
							end
						end
					end
				end
			end
		end
		return list
	end,
	validate = function(unit, ctx, candidate)
		if candidate and candidate.info == "collectible" then
			local oh = FunnyMod.Highlight
			if oh and type(oh.auto_pickup_allowed_unit) == "function" then
				return oh.auto_pickup_allowed_unit(unit)
			end
			return true
		end
		local kind, why = AS.classify(unit)
		return kind ~= nil, why
	end,
	on_phase = function(phase, entry, data)
		local kind = entry.info or "other"
		local m = entry.mode or mode()
		if phase == "detect" then
			entry.unit_key = alive(entry.unit) and entry.unit:key() or nil
			entry.mode = mode()
			local sig = tostring(entry.unit_key) .. kind
			if AS._last_candidate ~= sig then
				AS._last_candidate = sig
				dlog(string.format("candidate=%s tweak=%s unit=%s at %.1f m (%s)", kind:upper(), tostring(entry.tweak), tostring(entry.label), entry.distance or -1, entry.mode))
			end
		elseif phase == "complete" then
			entry.sent = true
			local st = stat(kind, m)
			st.sent = st.sent + 1
			if m == "CLIENT" then
				log(string.format("[AutoSteal] client request sent type=%s unit=%s at %.1f m", kind, tostring(entry.label), entry.distance or -1))
			else
				log(string.format("[AutoSteal] Request sent type=%s unit=%s at %.1f m (%s)", kind, tostring(entry.label), entry.distance or -1, m))
			end
		elseif phase == "confirmed" then
			local st = stat(kind, m)
			if not entry.sent then
				st.sent = st.sent + 1
			end
			entry.sent = nil
			st.confirmed = st.confirmed + 1
			log(string.format("[AutoSteal] %s type=%s unit=%s (%s)", m == "CLIENT" and "host confirmed" or "Confirmed", kind, tostring(entry.label), tostring(data)))
			local oh = FunnyMod.Highlight
			if oh and type(oh.marker_confirmed) == "function" and entry.unit_key then
				oh.marker_confirmed(entry.unit, entry.unit_key)
			end
		elseif phase == "failed" and entry.sent then
			-- Only a request that really left counts as a refusal (a local validate refusal is not).
			entry.sent = nil
			local st = stat(kind, m)
			st.refused = st.refused + 1
			log(string.format("[AutoSteal] %s type=%s unit=%s reason=%s", m == "CLIENT" and "host refused" or "Refused", kind, tostring(entry.label), tostring(data)))
			if m == "CLIENT" and st.confirmed == 0 and st.refused >= AS.CLIENT_FAIL_LIMIT and not AS._client_unsupported[kind] then
				AS._client_unsupported[kind] = true
				log("[AutoSteal] unsupported on client type=" .. kind .. " (" .. st.refused .. " requests, no host confirmation): no longer tried this session")
			end
		end
	end
}

do
	local aa = FunnyMod.AutoActions
	if not aa then
		local base = ModPath or (FunnyModMenu and FunnyModMenu.path) or ""
		if not FunnyMod.RealInteract then
			pcall(dofile, base .. "lua/real_interact.lua")
		end
		pcall(dofile, base .. "lua/auto_actions.lua")
		aa = FunnyMod.AutoActions
	end
	if aa then
		aa.register(AS.system)
	end
end

function AS.reset()
	AS._client_unsupported = {}
	AS._rejects = {}
	AS._atm_seen = {}
	AS._cash_seen = {}
	AS._diag_t = nil
	local e = FunnyMod.AutoActions
	if e then
		e.reset("steal")
	end
end

return AS
