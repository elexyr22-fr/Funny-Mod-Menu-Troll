-- Funny Mod Menu Troll core (QES = spawned enemies): tracking, verified batched cleanup (cop + every attached weapon unit),
-- spawn limit / queue rate, deferred mission end and restart, persistent menu settings.
-- Loaded through mod.txt hooks so it exists before the F9 menu script (mod.lua) is ever run.
local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")

QuickEnemySpawner = QuickEnemySpawner or {}
local QES = QuickEnemySpawner

SpawnerMenu = SpawnerMenu or {}
SpawnerMenu.spawned = SpawnerMenu.spawned or {}
QES.tracked = SpawnerMenu.spawned
QES.pending_cleanup = QES.pending_cleanup or {}
QES._resume_allowed = QES._resume_allowed or {}
QES._spawn_queue = QES._spawn_queue or {}

QES.BATCH_SIZE = 8
QES.PROGRESS_LOG_EVERY = 8
QES.DIAG_UNITS_PER_JOB = 3
-- A cop put in slot 0 is destroyed later by the engine. Still alive after this many frames:
-- World:delete_unit, the call the game itself uses at mission end.
QES.COP_FALLBACK_AFTER_FRAMES = 2
-- Frames given to the engine after the cop is gone to run the weapons' own pre_destroy
-- (NewRaycastWeaponBase:pre_destroy -> weapon_factory:disassemble) before leftovers are deleted.
QES.ATTACHED_GRACE_FRAMES = 2
QES.FORCE_AFTER_SECONDS = 5
QES.SPAWN_RATES = {
	SAFE = { every = 3, per = 1 },
	FAST = { every = 1, per = 1 },
	EXTREME = { every = 1, per = 5 }
}
QES.MAX_ALIVE_CHOICES = { 50, 75, 100, 0 }
QES.SETTINGS_FILE = SavePath .. "funny_mod_menu_troll.json"
-- First launch: everything ON. Afterwards the saved file wins.
QES.DEFAULT_SETTINGS = {
	auto_clear_restart = true,
	auto_clear_mission_end = true,
	auto_disable_stealth_in_loud = true,
	nd_enabled = true,
	nd_cameras_blind = true,
	noise_alerts_enabled = true,
	gun_alerts_enabled = true,
	one_shot_total = true,
	god_mode_all = false,
	hide_host_only = false,
	ignore_requirements = true,
	unbreakable_drills = true,
	sentry_infinite_ammo = true,
	highlight_collectibles = true,
	highlight_objectives = true,
	instant_trades = true,
	language = "auto",
	loot_throw = true,
	instant_interactions = true,
	no_pagers = true,
	spawner_favorites = { "ene_spook_1", "ene_tazer_1", "ene_bulldozer_minigun", "ene_bulldozer_medic", "ene_sniper_1" },
	c4_helper = true,
	infinite_cable_ties = true,
	speed_enabled = true,
	speed_multiplier = 1.5,
	ignore_bag_weight = true,
	loot_max = 50,
	show_qes_logs = true,
	show_admin_logs = true,
	confirm_kick = true,
	confirm_ban = true,
	max_alive = 75,
	spawn_rate = "SAFE",
	-- V12
	highlight_loot = false,
	aimbot_enabled = false,
	auto_kill = false,
	aimbot_targets = "enemies",
	aimbot_fov = 60,
	aimbot_distance = 50,
	auto_kill_delay = 0.5,
	converted_tradeable = true,
	auto_revive = true,
	auto_revive_radius = 5,
	follow_delay = 3,
	-- V13
	auto_drill = true,
	auto_drill_radius = 5,
	-- V14
	auto_drill_place = true,
	auto_pickup_collectibles = true,
	auto_pickup_radius = 5,
	spawn_debounce_ms = 125,
	debug_perf = false,
	-- V15
	auto_steal = false,
	auto_steal_radius = 5,
	instant_place = true,
	vanish = false,
	-- V16
	vanish_players = false,
	auto_actions_radius = -1,
	debug_auto_actions = false,
	-- V18
	auto_mission = true,
	auto_mission_radius = 5,
	-- V17
	show_descriptions = true,
	show_net_tags = true,
	join_chat_message = true,
	settings_rev = 0
}
-- Settings revision: one-time migrations of saved values (load_settings).
QES.SETTINGS_REV = 15
-- While the F9 menu is open the queue never goes faster than 1 spawn every 3 frames.
QES.MENU_OPEN_RATE = { every = 3, per = 1 }
QES.SLOW_MS = 50

FunnyMod = FunnyMod or {}
FunnyMod.QES = QES

function QES.log(msg)
	if not QES.settings or QES.settings.show_qes_logs ~= false then
		log("[QES] " .. tostring(msg))
	end
end

-- Perf profiling (settings.debug_perf only). os.clock is used by the game itself
-- (lib/managers/machinegunbeltmanager.lua); it measures time spent inside one call.
function QES.perf_enabled()
	return QES.settings and QES.settings.debug_perf == true or false
end

function QES.clock_ms()
	return os.clock() * 1000
end

-- Settings ------------------------------------------------------------------------------------

function QES.load_settings()
	QES.settings = {}
	for k, v in pairs(QES.DEFAULT_SETTINGS) do
		QES.settings[k] = v
	end

	local file = io.open(QES.SETTINGS_FILE, "r")
	if file then
		local ok, data = pcall(json.decode, file:read("*all"))
		file:close()
		if ok and type(data) == "table" then
			for k, v in pairs(data) do
				if QES.DEFAULT_SETTINGS[k] ~= nil and type(v) == type(QES.DEFAULT_SETTINGS[k]) then
					QES.settings[k] = v
				end
			end
		end
		log("[ModMenu] Configuration chargée")
	else
		QES.save_settings()
		log("[ModMenu] Configuration par défaut créée (tout activé)")
	end
	if not QES.SPAWN_RATES[QES.settings.spawn_rate] then
		QES.settings.spawn_rate = QES.DEFAULT_SETTINGS.spawn_rate
	end
	-- V15: the collectible markers were found OFF in the saved file after V14 (no contour, no
	-- waypoint, and V14's auto pickup depended on them): turned back ON once.
	if (tonumber(QES.settings.settings_rev) or 0) < QES.SETTINGS_REV then
		if QES.settings.highlight_collectibles == false then
			QES.settings.highlight_collectibles = true
			log("[ModMenu] V15 migration: collectible highlight turned back ON")
		end
		QES.settings.settings_rev = QES.SETTINGS_REV
		QES.save_settings()
	end
end

function QES.save_settings()
	local file = io.open(QES.SETTINGS_FILE, "w")
	if not file then
		log("[QES] Could not write settings file")
		return false
	end
	file:write(json.encode(QES.settings))
	file:close()
	QES.log("Settings saved")
	return true
end

function QES.get_setting(key)
	return QES.settings and QES.settings[key]
end

function QES.set_setting(key, value)
	if QES.DEFAULT_SETTINGS[key] == nil or type(value) ~= type(QES.DEFAULT_SETTINGS[key]) then
		return
	end
	QES.settings[key] = value
	QES.save_settings()
	QES.apply_module_settings()
end

local function module_api(name)
	local t = rawget(_G, name)
	return type(t) == "table" and t or nil
end

-- Pushes the saved preferences into the other mods through their own API (only those that are
-- installed and loaded). Called once per level and after each change made from the menu.
function QES.apply_module_settings()
	local s = QES.settings
	local gm = module_api("GodMode")
	if gm and type(gm.apply) == "function" then
		pcall(gm.apply, gm)
	end
	local loud = s.auto_disable_stealth_in_loud and true or false
	local nd = module_api("NeverDetectedV212")
	if nd and type(nd.set_enabled) == "function" then
		nd:set_enabled(s.nd_enabled)
		nd:set_cameras_blind(s.nd_cameras_blind)
		nd:set_auto_disable_in_loud(loud)
	end
	local noise = module_api("NoStealthNoiseAlerts")
	if noise and type(noise.set_enabled) == "function" then
		noise:set_enabled(s.noise_alerts_enabled)
		noise:set_auto_disable_in_loud(loud)
	end
	local gun = module_api("NoPlayerGunAlerts")
	if gun and type(gun.set_enabled) == "function" then
		gun:set_enabled(s.gun_alerts_enabled)
		gun:set_auto_disable_in_loud(loud)
	end
end

if not QES.settings then
	log("[ModMenu] Chargé")
	QES.load_settings()
end

-- Authority -----------------------------------------------------------------------------------

function QES.is_host()
	return NET.is_host()
end

-- Tracking ------------------------------------------------------------------------------------

local function is_dead(unit)
	local dmg = unit:character_damage()
	return dmg and type(dmg.dead) == "function" and dmg:dead() and true or false
end

local function is_registered_enemy(key)
	local all = managers.enemy and managers.enemy:all_enemies()
	return all and all[key] ~= nil or false
end

function QES.track(unit)
	if alive(unit) then
		QES.tracked[unit:key()] = unit
	end
end

function QES.is_tracked(unit)
	return alive(unit) and QES.tracked[unit:key()] ~= nil or false
end

function QES.prune_dead_references()
	local removed = 0
	for key, unit in pairs(QES.tracked) do
		if not alive(unit) or is_dead(unit) then
			QES.tracked[key] = nil
			removed = removed + 1
		end
	end
	for key, entry in pairs(QES.pending_cleanup) do
		if not alive(entry.unit) then
			QES.pending_cleanup[key] = nil
		end
	end
	return removed
end

function QES.get_spawned_count()
	QES.prune_dead_references()
	return table.size(QES.tracked)
end

function QES.get_pending_cleanup_count()
	return table.size(QES.pending_cleanup)
end

function QES.get_queue_count()
	return #QES._spawn_queue
end

-- Spawn limit, queue rate, manual spawn flag --------------------------------------------------

function QES.max_alive()
	local m = QES.settings.max_alive
	return type(m) == "number" and m > 0 and m or nil
end

function QES.limit_reached(extra)
	local m = QES.max_alive()
	return m ~= nil and QES.get_spawned_count() + (extra or 0) >= m
end

function QES.notify_limit()
	local now = Application:time()
	if QES._limit_notified_t and now - QES._limit_notified_t < 2 then
		return
	end
	QES._limit_notified_t = now
	local text = "QES spawn limit reached (" .. tostring(QES.max_alive()) .. ")"
	log("[QuickEnemySpawner] " .. text)
	if managers.hud and managers.hud.show_hint then
		managers.hud:show_hint({ text = text })
	end
end

-- Every QES spawn goes through here. The flag lets EnemyControl's hard mode tell QES spawns
-- apart; the pcall guarantees it is cleared even when the spawn errors (xpcall does not exist
-- in PAYDAY 2's Lua environment).
function QES.spawn_now(params)
	if not QES.is_host() then
		log("[QuickEnemySpawner] Client attempted spawn - blocked")
		return nil
	end
	if QES._shutting_down or not SpawnerMenu.spawn then
		return nil
	end
	if QES.limit_reached() then
		QES._spawn_queue = {}
		QES.notify_limit()
		return nil
	end

	local perf = QES.perf_enabled()
	local t0 = perf and QES.clock_ms()
	if perf then
		log("[QES][perf] spawn start")
	end

	QES._manual_spawn_in_progress = true
	local ok, result = pcall(SpawnerMenu.spawn, params.unit_ids, params.hp_mult, params.team, params.objective)
	QES._manual_spawn_in_progress = false

	if perf then
		local ms = QES.clock_ms() - t0
		log(string.format("[QES][perf] spawn end ms=%.1f", ms))
		if ms > QES.SLOW_MS then
			log(string.format("[QES][perf] SLOW SPAWN %.1f ms", ms))
		end
	end

	if not ok then
		QES.log("spawn failed: " .. tostring(result))
		return nil
	end
	return result
end

-- The ONLY entry point of the menu's SPAWN buttons: it never spawns, it only adds one spawn to
-- the queue that GameSetupUpdate processes (step_spawn_queue). A second click inside
-- spawn_debounce_ms is ignored (double click protection, the button stays usable).
function QES.enqueue_spawn(params)
	if not QES.is_host() then
		log("[QuickEnemySpawner] Client attempted spawn - blocked")
		return false
	end
	local now = Application:time() * 1000
	local debounce = tonumber(QES.settings.spawn_debounce_ms) or 125
	if QES._last_enqueue_ms and now - QES._last_enqueue_ms < debounce then
		if QES.perf_enabled() then
			log("[QES][perf] click ignored (debounce " .. debounce .. " ms)")
		end
		return false
	end
	QES._last_enqueue_ms = now
	return QES.queue_spawn(1, params)
end

function QES.queue_spawn(count, params)
	if not QES.is_host() then
		log("[QuickEnemySpawner] Client attempted spawn - blocked")
		return
	end
	if QES._shutting_down then
		return
	end
	local m = QES.max_alive()
	if m then
		local room = m - QES.get_spawned_count() - #QES._spawn_queue
		if room <= 0 then
			QES.notify_limit()
			return
		end
		if count > room then
			QES.log("Spawn request reduced from " .. count .. " to " .. room .. " (limit " .. m .. ")")
			count = room
		end
	end
	for _ = 1, count do
		table.insert(QES._spawn_queue, params)
	end
	-- One line per menu click would be spam: only multi-spawn requests are logged.
	if count > 1 or QES.perf_enabled() then
		QES.log("Queued " .. count .. " spawns (rate " .. tostring(QES.settings.spawn_rate) .. ", in queue " .. #QES._spawn_queue .. ")")
	end
	return true
end

local function menu_open()
	local menu = SpawnerMenu and SpawnerMenu.menu
	if not menu or type(menu.Enabled) ~= "function" then
		return false
	end
	local ok, enabled = pcall(menu.Enabled, menu)
	return ok and enabled and true or false
end

-- Light UI update after a spawn: only the "QES actifs" label text (menu.lua), never a rebuild.
local function notify_menu_count()
	local fn = SpawnerMenu and SpawnerMenu.update_count
	if type(fn) == "function" then
		-- Throttled in menu.lua; the last spawn of a burst always forces the final value.
		pcall(fn, #QES._spawn_queue == 0)
	end
end

local function step_spawn_queue()
	local rate = QES.SPAWN_RATES[QES.settings.spawn_rate] or QES.SPAWN_RATES.SAFE
	if menu_open() then
		rate = {
			every = math.max(rate.every, QES.MENU_OPEN_RATE.every),
			per = math.min(rate.per, QES.MENU_OPEN_RATE.per)
		}
	end
	QES._queue_frame = (QES._queue_frame or 0) + 1
	if QES._queue_frame % rate.every ~= 0 then
		return
	end
	for _ = 1, rate.per do
		local params = table.remove(QES._spawn_queue, 1)
		if not params then
			break
		end
		QES.spawn_now(params)
		if #QES._spawn_queue == 0 then
			break
		end
	end
	notify_menu_count()
end

-- Unit teardown -------------------------------------------------------------------------------

local function noop()
end

-- QES objectives (defend/sniper/follow) re-issue themselves from their failed/complete
-- callbacks, and CopLogicBase.on_objective_unit_destroyed fires those callbacks when a followed
-- unit is destroyed. Neutralise them before any unit is removed.
local function neutralize_objective_callbacks(unit)
	local brain = unit:brain()
	if brain and brain._logic_data then
		brain._logic_data.objective_complete_clbk = noop
		brain._logic_data.objective_failed_clbk = noop
	end
end

local function add_unit(list, seen, u)
	if alive(u) and not seen[u:key()] then
		seen[u:key()] = true
		table.insert(list, u)
		return true
	end
	return false
end

-- Units attached to a cop, as created by the game (all normally removed by the extensions'
-- pre_destroy when the cop is destroyed):
--   CopInventory      weapon units (_available_selections), shield (_shield_unit)
--   weapon base       factory parts (_parts[*].unit), laser (_laser_unit), akimbo _second_gun
--   CopMovement       reload magazine in hand (_magazine_data.unit), gadgets (_equipped_gadgets),
--                     melee item (_melee_item_unit), rope (_rope)
--   CopBase           headwear (_headwear_unit)
-- On top of those fields, every unit near the cop whose parent() chain leads to the cop or to one
-- of the units above is collected too, so nothing linked is missed whatever field holds it.
local WEAPON_CLASSES = {
	"NPCAkimboWeaponBase", "EnemyAkimboWeaponBase", "NewNPCFlamethrowerBase", "NPCSawWeaponBase",
	"NPCSniperRifleBase", "NPCGrenadeLauncherBase", "NPCBowWeaponBase", "NewNPCRaycastWeaponBase",
	"NPCRaycastWeaponBase", "NewRaycastWeaponBase", "RaycastWeaponBase"
}
QES.LINK_SCAN_RADIUS = 400

local function class_name(obj)
	local mt = obj and getmetatable(obj)
	for _, name in ipairs(WEAPON_CLASSES) do
		local cls = rawget(_G, name)
		if cls and mt == cls then
			return name
		end
	end
	return "unknown"
end

local function collect_weapon_units(weapon, list, seen, stats)
	if not add_unit(list, seen, weapon) then
		return
	end
	local base = weapon:base()
	if not base then
		return
	end
	stats.weapons = stats.weapons + 1
	stats.classes[#stats.classes + 1] = class_name(base)
	if type(base._parts) == "table" then
		for _, part in pairs(base._parts) do
			if type(part) == "table" and add_unit(list, seen, part.unit) then
				stats.parts = stats.parts + 1
			end
		end
	end
	add_unit(list, seen, base._laser_unit)
	if alive(base._second_gun) then
		collect_weapon_units(base._second_gun, list, seen, stats)
	end
end

local scan_mask
local function link_scan_mask()
	if scan_mask == nil then
		local slots = {}
		for i = 1, 39 do
			slots[#slots + 1] = i
		end
		local ok, mask = pcall(World.make_slot_mask, World, unpack(slots))
		scan_mask = ok and mask or false
		if not ok then
			QES.log("[weapon-cleanup] slot mask unavailable: " .. tostring(mask))
		end
	end
	return scan_mask or nil
end

-- Units found around the cop whose parent chain reaches one of the roots.
local function collect_linked_units(unit, list, seen, stats)
	local mask = link_scan_mask()
	if not mask then
		return
	end
	local ok, found = pcall(World.find_units_quick, World, "sphere", unit:position(), QES.LINK_SCAN_RADIUS, mask)
	if not ok or type(found) ~= "table" then
		return
	end
	local roots = { [unit:key()] = true }
	for _, u in ipairs(list) do
		roots[u:key()] = true
	end
	for _, candidate in ipairs(found) do
		if alive(candidate) and not seen[candidate:key()] and candidate ~= unit then
			local p, depth = candidate, 0
			while depth < 6 do
				local okp, parent = pcall(p.parent, p)
				if not okp or not alive(parent) then
					break
				end
				if roots[parent:key()] then
					add_unit(list, seen, candidate)
					stats.linked = stats.linked + 1
					stats.linked_names[#stats.linked_names + 1] = tostring(candidate:name())
					break
				end
				p, depth = parent, depth + 1
			end
		end
	end
end

function QES.collect_attached_units(unit)
	local list, seen = {}, {}
	local stats = { weapons = 0, parts = 0, linked = 0, classes = {}, linked_names = {} }
	seen[unit:key()] = true

	local inv = unit:inventory()
	if inv then
		if type(inv._available_selections) == "table" then
			for _, selection in pairs(inv._available_selections) do
				if type(selection) == "table" and alive(selection.unit) then
					collect_weapon_units(selection.unit, list, seen, stats)
				end
			end
		end
		if type(inv.equipped_unit) == "function" then
			local equipped = inv:equipped_unit()
			if alive(equipped) then
				collect_weapon_units(equipped, list, seen, stats)
			end
		end
		add_unit(list, seen, inv._shield_unit)
	end

	local mov = unit:movement()
	if mov then
		if type(mov._magazine_data) == "table" then
			add_unit(list, seen, mov._magazine_data.unit)
		end
		if type(mov._equipped_gadgets) == "table" then
			for _, items in pairs(mov._equipped_gadgets) do
				for _, item in ipairs(items) do
					add_unit(list, seen, item)
				end
			end
		end
		add_unit(list, seen, mov._melee_item_unit)
		add_unit(list, seen, mov._rope)
	end

	local base = unit:base()
	if base then
		add_unit(list, seen, base._headwear_unit)
	end

	collect_linked_units(unit, list, seen, stats)
	return list, stats
end

local function count_alive(list)
	local n = 0
	for _, u in ipairs(list) do
		if alive(u) then
			n = n + 1
		end
	end
	return n
end

local function unit_label(u)
	local base = alive(u) and u:base()
	return tostring(base and base._name_id or (alive(u) and u:name()) or "?")
end

-- Body removal is unchanged from the version the logs validated: callbacks neutralised,
-- brain inactive, CopInventory:destroy_all_items(), base:set_slot(unit, 0).
local function begin_remove(job, unit)
	local key = unit:key()
	local attached, stats = QES.collect_attached_units(unit)
	local entry = {
		unit = unit,
		key = key,
		frames = 0,
		gone_frames = 0,
		stage = "cop",
		attached = attached
	}

	if job.diag_left > 0 then
		job.diag_left = job.diag_left - 1
		entry.diag = true
		QES.log("[weapon-cleanup] unit key=" .. tostring(key) .. " base_class=" .. table.concat(stats.classes, ","))
		QES.log("[weapon-cleanup] weapons=" .. stats.weapons .. " parts=" .. stats.parts .. " linked=" .. stats.linked .. " total_attached=" .. #attached)
		for i, name in ipairs(stats.linked_names) do
			QES.log("[weapon-cleanup] linked[" .. i .. "] " .. name)
		end
	end

	neutralize_objective_callbacks(unit)

	local brain = unit:brain()
	if brain then
		brain:set_active(false)
	end

	local inv = unit:inventory()
	if inv and type(inv.destroy_all_items) == "function" then
		inv:destroy_all_items()
	end

	unit:base():set_slot(unit, 0)

	job.pending[key] = entry
end

-- Kill = ElementSpawnEnemyDummy:kill_all_units (synced death through the damage extension).
local function kill_unit(unit)
	neutralize_objective_callbacks(unit)
	unit:character_damage():damage_mission({
		damage = 1000,
		forced = true
	})
end

local function force_delete_entry(job, entry)
	if alive(entry.unit) then
		pcall(World.delete_unit, World, entry.unit)
		job.cop_fallback = job.cop_fallback + 1
	end
	for _, u in ipairs(entry.attached) do
		if alive(u) then
			pcall(World.delete_unit, World, u)
			job.orphans_deleted = job.orphans_deleted + 1
		end
	end
end

local function resolve(job, entry)
	job.pending[entry.key] = nil
	job.resolved = job.resolved + 1

	local cop_alive = alive(entry.unit)
	local weapons_alive = count_alive(entry.attached)

	if not cop_alive and weapons_alive == 0 then
		job.removed = job.removed + 1
	else
		job.failed = job.failed + 1
		job.weapons_left = job.weapons_left + weapons_alive
		QES.pending_cleanup[entry.key] = entry
	end

	if entry.diag then
		QES.log("[weapon-cleanup] unit alive after=" .. tostring(cop_alive) .. " frames=" .. entry.frames .. " registered_enemy=" .. tostring(is_registered_enemy(entry.key)))
		QES.log("[weapon-cleanup] remaining_visual_units=" .. weapons_alive .. " orphans_deleted=" .. tostring(entry.orphans or 0))
	end
end

-- Per-frame state machine of one unit being removed:
--   cop      : wait for the cop to be destroyed (World:delete_unit after COP_FALLBACK frames)
--   attached : give the engine ATTACHED_GRACE frames to run the weapons' pre_destroy, then
--              delete any collected weapon/part/shield unit that is still alive
--   verify   : the unit counts as removed only when the cop AND every collected unit are gone
local function step_entry(job, entry, force)
	entry.frames = entry.frames + 1

	if force then
		force_delete_entry(job, entry)
		resolve(job, entry)
		return
	end

	if entry.stage == "cop" then
		if not alive(entry.unit) then
			entry.stage = "attached"
		elseif entry.frames >= QES.COP_FALLBACK_AFTER_FRAMES and not entry.cop_fallback then
			entry.cop_fallback = true
			job.cop_fallback = job.cop_fallback + 1
			local ok, err = pcall(World.delete_unit, World, entry.unit)
			if not ok then
				QES.log("World:delete_unit failed: " .. tostring(err))
			end
		end
		return
	end

	if entry.stage == "attached" then
		entry.gone_frames = entry.gone_frames + 1
		if entry.gone_frames < QES.ATTACHED_GRACE_FRAMES then
			return
		end
		local orphans = 0
		for _, u in ipairs(entry.attached) do
			if alive(u) then
				orphans = orphans + 1
				pcall(World.delete_unit, World, u)
			end
		end
		entry.orphans = orphans
		job.orphans_deleted = job.orphans_deleted + orphans
		entry.stage = "verify"
		return
	end

	if entry.stage == "verify" then
		if count_alive(entry.attached) == 0 then
			resolve(job, entry)
		end
	end
end

-- Cleanup jobs --------------------------------------------------------------------------------
-- scope: "qes" (tracked units), "vanilla" (registered enemies that QES did not spawn and that
-- are not converted minions), "all" (both).

local function hostile_to_players(unit)
	local movement = unit:movement()
	local team = movement and type(movement.team) == "function" and movement:team()
	return team and team.foes and team.foes.criminal1 and true or false
end

local function build_queue(scope, mode)
	local queue = {}
	if scope == "qes" or scope == "all" then
		for key, unit in pairs(QES.tracked) do
			if alive(unit) and not (mode == "kill" and (is_dead(unit) or not hostile_to_players(unit))) then
				table.insert(queue, unit)
				QES.tracked[key] = nil
			elseif not alive(unit) then
				QES.tracked[key] = nil
			end
		end
	end
	if (scope == "vanilla" or scope == "all") and managers.enemy then
		for key, u_data in pairs(managers.enemy:all_enemies()) do
			local unit = u_data.unit
			-- SecretLogger / SecretAuto: story units the mission watches (Garrett on Breakin' Feds)
			-- are never removed or killed, the heist cannot go on without them.
			local secret_auto = rawget(_G, "SecretAuto")
			local protected = secret_auto and type(secret_auto.is_protected) == "function" and secret_auto:is_protected(unit)
			if protected then
				QES.log("Protected mission unit skipped (SecretAuto)")
			end
			if alive(unit) and not protected and not QES.tracked[key] and not (mode == "kill" and is_dead(unit)) then
				local brain = unit:brain()
				local converted = brain and brain._logic_data and brain._logic_data.is_converted
				if not converted and (mode ~= "kill" or hostile_to_players(unit)) then
					table.insert(queue, unit)
				end
			end
		end
	end
	return queue
end

function QES.start_cleanup(mode, scope, reason, on_complete)
	if not QES.is_host() then
		log("[QuickEnemySpawner] Client attempted " .. tostring(mode) .. " - blocked")
		return false
	end
	if QES._job then
		QES.log("A " .. QES._job.mode .. " job is already running")
		return false
	end

	local queue = build_queue(scope, mode)
	QES._job = {
		mode = mode,
		scope = scope,
		reason = reason or mode,
		queue = queue,
		qi = 1,
		pending = {},
		total = #queue,
		resolved = 0,
		removed = 0,
		killed = 0,
		cop_fallback = 0,
		orphans_deleted = 0,
		weapons_left = 0,
		failed = 0,
		diag_left = QES.DIAG_UNITS_PER_JOB,
		started_rt = Application:time(),
		next_progress = QES.PROGRESS_LOG_EVERY,
		on_complete = on_complete
	}
	QES.log((QES._job.reason) .. " (" .. mode .. ", " .. scope .. ") total=" .. #queue)
	return true
end

function QES.clear_spawned()
	return QES.start_cleanup("remove", "qes", "Clear QES")
end

function QES.kill_spawned()
	return QES.start_cleanup("kill", "qes", "Kill QES")
end

function QES.clear_vanilla()
	return QES.start_cleanup("remove", "vanilla", "Clear vanilla")
end

function QES.kill_vanilla()
	return QES.start_cleanup("kill", "vanilla", "Kill vanilla")
end

function QES.clear_all()
	return QES.start_cleanup("remove", "all", "Clear all")
end

function QES.kill_all()
	return QES.start_cleanup("kill", "all", "Kill all")
end

local function finish_job(job)
	QES._job = nil
	if job.mode == "kill" then
		QES.log(job.reason .. " complete killed=" .. job.killed .. "/" .. job.total)
	else
		local units_left, weapons_left = 0, 0
		for _, entry in pairs(QES.pending_cleanup) do
			if alive(entry.unit) then
				units_left = units_left + 1
			end
			weapons_left = weapons_left + count_alive(entry.attached)
		end
		QES.log(job.reason .. " complete removed=" .. job.removed .. "/" .. job.total .. " cop_fallback=" .. job.cop_fallback .. " orphan_weapon_units_deleted=" .. job.orphans_deleted .. " failed=" .. job.failed)
		QES.log(job.reason .. " remaining units=" .. units_left .. " weapons=" .. weapons_left)
	end
	if job.on_complete then
		local ok, err = pcall(job.on_complete, job)
		if not ok then
			QES.log("Cleanup completion callback failed: " .. tostring(err))
		end
	end
end

local function step_job()
	local job = QES._job
	local last = math.min(job.qi + QES.BATCH_SIZE - 1, job.total)

	for i = job.qi, last do
		local unit = job.queue[i]
		job.queue[i] = nil
		if alive(unit) then
			if job.mode == "kill" then
				if not is_dead(unit) then
					local ok, err = pcall(kill_unit, unit)
					if ok then
						job.killed = job.killed + 1
					else
						QES.log("kill failed: " .. tostring(err))
					end
				end
				job.resolved = job.resolved + 1
			else
				local ok, err = pcall(begin_remove, job, unit)
				if not ok then
					QES.log("remove failed: " .. tostring(err))
					pcall(World.delete_unit, World, unit)
					job.cop_fallback = job.cop_fallback + 1
					job.resolved = job.resolved + 1
				end
			end
		else
			job.resolved = job.resolved + 1
			job.removed = job.removed + 1
		end
	end
	job.qi = last + 1

	local force = Application:time() - job.started_rt > QES.FORCE_AFTER_SECONDS
	if force and not job.force_logged then
		job.force_logged = true
		QES.log(job.reason .. ": " .. QES.FORCE_AFTER_SECONDS .. "s elapsed, forcing World:delete_unit on remaining units and weapons")
	end
	for _, entry in pairs(job.pending) do
		step_entry(job, entry, force)
	end

	if job.resolved >= job.next_progress and job.resolved < job.total then
		QES.log(job.reason .. " progress " .. job.resolved .. "/" .. job.total)
		job.next_progress = job.next_progress + QES.PROGRESS_LOG_EVERY
	end

	if job.qi > job.total and next(job.pending) == nil then
		finish_job(job)
	end
end

-- Deferred native calls (mission end, restart) -------------------------------------------------
-- The native call is stored with all its arguments, QES units are cleaned in batches, then the
-- native call is replayed exactly once. While it replays, QES._resume_allowed[kind] lets the
-- wrappers pass straight through, which prevents any recursion.

local function tracked_alive_count()
	local n = 0
	for _, unit in pairs(QES.tracked) do
		if alive(unit) then
			n = n + 1
		end
	end
	return n
end

function QES.should_defer(kind)
	if QES._resume_allowed[kind] then
		return false
	end
	local setting = kind == "restart" and "auto_clear_restart" or "auto_clear_mission_end"
	if not QES.settings[setting] or not QES.is_host() then
		return false
	end
	return QES._deferred ~= nil or tracked_alive_count() > 0 or QES._job ~= nil
end

function QES.defer(kind, resume)
	if QES._deferred then
		-- Never drop a native call: replay it right after the pending one.
		QES.log(kind .. " requested while a deferred " .. QES._deferred.kind .. " is pending - chained")
		table.insert(QES._deferred.chained, { kind = kind, resume = resume })
		return
	end
	QES._deferred = { kind = kind, resume = resume, chained = {} }
	QES._shutting_down = true
	QES._spawn_queue = {}

	local function run(call)
		QES._resume_allowed[call.kind] = true
		QES.log("Resuming native " .. call.kind)
		local ok, err = pcall(call.resume)
		QES._resume_allowed[call.kind] = false
		if not ok then
			log("[QES] Native " .. call.kind .. " failed after cleanup: " .. tostring(err))
		end
	end

	local function replay()
		local deferred = QES._deferred
		QES._deferred = nil
		run(deferred)
		for _, call in ipairs(deferred.chained) do
			run(call)
		end
	end

	local function start_own_cleanup()
		if tracked_alive_count() == 0 then
			replay()
			return
		end
		QES.start_cleanup("remove", "qes", "Pre-" .. kind .. " cleanup", function()
			replay()
		end)
	end

	if QES._job then
		local previous = QES._job.on_complete
		QES._job.on_complete = function(job)
			if previous then
				pcall(previous, job)
			end
			start_own_cleanup()
		end
	else
		start_own_cleanup()
	end
end

local function pack(...)
	return { n = select("#", ...), ... }
end

local function install_restart_wrapper()
	if QES._restart_hooked or not GamePlayCentralManager then
		return
	end
	QES._restart_hooked = true
	local original_restart = GamePlayCentralManager.restart_the_game

	function GamePlayCentralManager:restart_the_game(...)
		if not QES.should_defer("restart") then
			return original_restart(self, ...)
		end
		QES.log("Restart requested")
		local target, args = self, pack(...)
		QES.defer("restart", function()
			original_restart(target, unpack(args, 1, args.n))
		end)
	end
end

local function install_mission_end_wrapper()
	if QES._missionend_hooked or not ElementMissionEnd then
		return
	end
	QES._missionend_hooked = true
	local original_on_executed = ElementMissionEnd.on_executed

	function ElementMissionEnd:on_executed(...)
		local state = self._values and self._values.state
		if not (self._values and self._values.enabled and (state == "success" or state == "failed")) or not QES.should_defer("mission_end") then
			return original_on_executed(self, ...)
		end
		QES.log("Mission end intercepted (" .. tostring(state) .. ")")
		local target, args = self, pack(...)
		QES.defer("mission_end", function()
			original_on_executed(target, unpack(args, 1, args.n))
		end)
	end
end

-- Safety net for the other end-of-heist paths (point of no return, everyone in custody):
-- they switch state directly through the state machine.
local function install_state_change_wrapper()
	if QES._statechange_hooked or not GameStateMachine then
		return
	end
	QES._statechange_hooked = true
	local original_change_state_by_name = GameStateMachine.change_state_by_name

	function GameStateMachine:change_state_by_name(state_name, ...)
		if state_name == "victoryscreen" or state_name == "gameoverscreen" then
			QES.reset_level_modes(state_name)
		end
		if (state_name == "victoryscreen" or state_name == "gameoverscreen") and not QES._resume_allowed.mission_end and QES.should_defer("mission_end") then
			QES.log("Mission end intercepted (" .. tostring(state_name) .. ")")
			local target, args = self, pack(state_name, ...)
			QES.defer("mission_end", function()
				original_change_state_by_name(target, unpack(args, 1, args.n))
			end)
			return
		end
		return original_change_state_by_name(self, state_name, ...)
	end
end

-- Last resort before vanilla mass deletion (only reached if nothing was deferred, e.g. the
-- auto clear setting is off): make the units' objective callbacks harmless.
function QES.prepare_for_mission_end(reason)
	local total = 0
	for key, unit in pairs(QES.tracked) do
		total = total + 1
		if alive(unit) and not is_dead(unit) then
			pcall(neutralize_objective_callbacks, unit)
		end
		QES.tracked[key] = nil
	end
	QES._shutting_down = true
	QES._spawn_queue = {}
	if total > 0 then
		QES.log("AI disabled with " .. total .. " QES units still tracked (" .. tostring(reason) .. ")")
	end
end

-- Per-level states (follow target, fly, no clip) never survive the level: reset at level unload,
-- restart, mission end and return to the lobby.
function QES.reset_level_modes(reason)
	for _, name in ipairs({ "Teleport", "FlyMode", "Aimbot", "AutoRevive", "EnemyConvert", "AutoDrill", "AutoSteal", "AutoMission", "AutoToolbag", "AutoActions", "Vanish", "PlayerInvisibility" }) do
		local m = module_api(name)
		if m and type(m.reset) == "function" then
			local ok, err = pcall(m.reset)
			if not ok then
				log("[ModMenu] " .. name .. " reset failed: " .. tostring(err))
			end
		end
	end
	QES.log("Level modes reset (" .. tostring(reason) .. "): follow off, fly off, no clip off, aimbot target / revive / convert queue cleared")
end

-- Spawner catalog: built once per level (first GameSetupUpdate) and reused by every menu view,
-- instead of on the first F9 open. The menu rebuilds it only when the language changes.
function QES.build_catalog_once()
	if SpawnerMenu._catalog_entries then
		return
	end
	local uc = module_api("UnitCatalog")
	if not uc or type(uc.build) ~= "function" then
		return
	end
	local t0 = QES.clock_ms()
	local ok, entries, by_name = pcall(uc.build)
	if ok and type(entries) == "table" then
		SpawnerMenu._catalog_entries, SpawnerMenu._catalog_by_name = entries, by_name or {}
	else
		log("[QES] catalog build failed: " .. tostring(entries))
	end
	if QES.perf_enabled() then
		log(string.format("[QES][perf] catalog build ms=%.1f entries=%d", QES.clock_ms() - t0, ok and type(entries) == "table" and #entries or 0))
	end
end

-- Hooks ---------------------------------------------------------------------------------------

if not QES._update_hooked then
	QES._update_hooked = true
	Hooks:Add("GameSetupUpdate", "QES_JobUpdate", function(t, dt)
		if not QES._level_initialised then
			QES._level_initialised = true
			QES.apply_module_settings()
			NET.log_mode_change()
			QES.build_catalog_once()
		end
		if QES._job then
			step_job()
		end
		if #QES._spawn_queue > 0 and not QES._shutting_down then
			step_spawn_queue()
		end
	end)
	-- The pause menu (where solo restart is chosen) only runs paused_update.
	Hooks:Add("GameSetupPausedUpdate", "QES_JobPausedUpdate", function(t, dt)
		if QES._job then
			step_job()
		end
	end)
end

if RequiredScript == "lib/managers/group_ai_states/groupaistatebase" and not QES._groupai_hooked then
	QES._groupai_hooked = true
	Hooks:PreHook(GroupAIStateBase, "set_AI_enabled", "QES_PrepareBeforeAIDisabled", function(self, state)
		if not state then
			QES.prepare_for_mission_end("set_AI_enabled(false)")
		end
	end)
	Hooks:PostHook(GroupAIStateBase, "set_AI_enabled", "QES_AllowSpawnAfterAIEnabled", function(self, state)
		if state then
			QES._shutting_down = false
		end
	end)
elseif RequiredScript == "lib/managers/mission/elementmissionend" then
	install_mission_end_wrapper()
elseif RequiredScript == "lib/managers/gameplaycentralmanager" then
	install_restart_wrapper()
elseif RequiredScript == "lib/utils/game_state_machine/gamestatemachine" then
	install_state_change_wrapper()
elseif RequiredScript == "lib/setups/gamesetup" and not QES._unload_hooked then
	QES._unload_hooked = true
	Hooks:PreHook(GameSetup, "destroy", "QES_DiscardOnUnload", function()
		local count = table.size(QES.tracked) + table.size(QES.pending_cleanup)
		for key in pairs(QES.tracked) do
			QES.tracked[key] = nil
		end
		for key in pairs(QES.pending_cleanup) do
			QES.pending_cleanup[key] = nil
		end
		QES._spawn_queue = {}
		QES._job = nil
		QES._deferred = nil
		QES._resume_allowed = {}
		QES._shutting_down = false
		QES._manual_spawn_in_progress = false
		QES._level_initialised = false
		QES._last_enqueue_ms = nil
		SpawnerMenu._catalog_entries, SpawnerMenu._catalog_by_name = nil, nil
		QES.reset_level_modes("level unload")
		local ec = rawget(_G, "EnemyControl")
		if type(ec) == "table" then
			ec.mode = "NORMAL"
			ec.vanilla, ec.waves, ec.hard = true, true, false
			ec._level_reset_done = nil
		end
		QES.log("Level unload - discarded dead references (" .. count .. ")")
	end)
end
