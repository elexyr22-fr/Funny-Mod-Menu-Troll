local NET = FunnyMod and FunnyMod.Network or dofile((ModPath or (FunnyModMenu and FunnyModMenu.path) or "") .. "lua/network.lua")
SpawnerMenu = SpawnerMenu or {}
SpawnerMenu.objective_funcs = SpawnerMenu.objective_funcs or {
	inactive = function(brain)
		brain:set_active(false)
	end,

	none = function(brain)
	end,

	follow = function(brain)
		brain._logic_data.objective_complete_clbk = function(unit, objective)
			managers.groupai:state():on_criminal_jobless(unit)
		end
		brain._logic_data.objective_failed_clbk = function(unit, objective)
			managers.groupai:state():on_criminal_jobless(unit)
		end
		managers.groupai:state():on_criminal_jobless(brain._unit)
	end,

	defend = function(brain)
		local pos = brain._unit:position()
		local nav_seg = managers.navigation:get_nav_seg_from_pos(pos)
		local new_objective = {
			scan = true,
			type = "defend_area",
			nav_seg = nav_seg,
			area = managers.groupai:state():get_area_from_nav_seg_id(nav_seg)
		}
		brain._logic_data.objective_complete_clbk = function(unit, objective)
			brain:set_objective(clone(new_objective))
		end
		brain._logic_data.objective_failed_clbk = function(unit, objective)
			brain:set_objective(clone(new_objective))
		end
		brain:set_objective(clone(new_objective))
	end,

	sniper = function(brain)
		local pos = brain._unit:position()
		local nav_seg = managers.navigation:get_nav_seg_from_pos(pos)
		local new_objective = {
			scan = true,
			type = "sniper",
			pos = pos,
			nav_seg = nav_seg,
			area = managers.groupai:state():get_area_from_nav_seg_id(nav_seg)
		}
		brain._logic_data.objective_complete_clbk = function(unit, objective)
			brain:set_objective(clone(new_objective))
		end
		brain._logic_data.objective_failed_clbk = function(unit, objective)
			brain:set_objective(clone(new_objective))
		end
		brain:set_objective(clone(new_objective))
	end
}

function SpawnerMenu.is_host()
	-- Central check (lua/network.lua): solo or server of the session.
	local NET = FunnyMod and FunnyMod.Network
	return NET and NET.is_host() or false
end

SpawnerMenu.spawn = SpawnerMenu.spawn or function(unit_ids, hp_mult, team, objective)
	if not SpawnerMenu.is_host() then
		log("[QuickEnemySpawner] Client attempted spawn - blocked")
		if managers.chat and managers.chat.get_default_channel_id and tweak_data and tweak_data.system_chat_color then
			local fmm = rawget(_G, "FunnyModMenu")
			local text = fmm and fmm.L("fmmt_host_only_msg") or "Funny Mod Menu Troll: host only"
			managers.chat:_receive_message(managers.chat:get_default_channel_id(), fmm and fmm.NAME or "Funny Mod Menu Troll", text, tweak_data.system_chat_color)
		end
		return
	end

	local qes_core = rawget(_G, "QuickEnemySpawner")
	if qes_core and qes_core._shutting_down then
		return
	end

	if not PackageManager:has(Idstring("unit"), unit_ids) then
		return
	end

	local player = managers.player:local_player()
	if not alive(player) then
		return
	end

	if not managers.groupai or not managers.groupai:state() then
		return
	end

	log("[QuickEnemySpawner] Spawn request: " .. tostring(unit_ids))

	local pos = managers.hud and managers.hud.gcw_get_my_custom_waypoint and managers.hud:gcw_get_my_custom_waypoint() or Utils:GetPlayerAimPos(player)
	if not pos then
		return
	end

	local rot = Rotation(-player:camera():forward():with_z(0):normalized(), math.UP)
	local unit = World:spawn_unit(unit_ids, pos, rot)
	if not alive(unit) then
		return
	end

	if not qes_core or not qes_core.settings or qes_core.settings.show_qes_logs ~= false then
		log("[QES] spawned id=" .. tostring(unit:id()) .. " team=" .. tostring(team or "law1") .. " objective=" .. tostring(objective or "none"))
	end

	local team_data = managers.groupai:state():team_data(team or "law1")
	unit:movement():set_team(team_data)

	local dmg = unit:character_damage()
	local apply_dmg_reduction = dmg._apply_damage_reduction
	dmg._apply_damage_reduction = function(self, ...)
		return apply_dmg_reduction(self, ...) / (hp_mult or 1)
	end

	if team == "criminal1" or team_data.friends.criminal1 then
		unit:set_slot(16)

		dmg:set_mover_collision_state(false)
		dmg:set_mover_collision_state(false)

		local brain = unit:brain()
		brain._attention_handler:override_attention("enemy_team_cbt", PlayerMovement._create_attention_setting_from_descriptor(brain, tweak_data.attention.settings.team_enemy_cbt, "team_enemy_cbt"))
		brain._SO_access = managers.navigation:convert_access_flag(tweak_data.character.russian.access)
		brain._logic_data.SO_access = brain._SO_access
		brain._logic_data.SO_access_str = tweak_data.character.russian.access
		brain._slotmask_enemies = managers.slot:get_mask("enemies")
		brain._logic_data.enemy_slotmask = brain._slotmask_enemies

		local u_data = managers.groupai:state()._police[unit:key()]
		if u_data then
			u_data.so_access = brain:SO_access()
		end
	end

	if SpawnerMenu.objective_funcs[objective] then
		SpawnerMenu.objective_funcs[objective](unit:brain())
	end

	if team == "converted_enemy" then
		unit:brain():convert_to_criminal(managers.player:local_player())
	end

	if qes_core then
		qes_core.track(unit)
	else
		SpawnerMenu.spawned[unit:key()] = unit
	end

	return unit
end

SpawnerMenu.spawned = SpawnerMenu.spawned or {}

-- Manual clear goes through the core module (verified batched cleanup).
function SpawnerMenu.clear()
	local qes_core = rawget(_G, "QuickEnemySpawner")
	if qes_core then
		return qes_core.clear_spawned()
	end
	log("[QuickEnemySpawner] Clear unavailable: core module not loaded")
end

-- FUNNY MOD MENU TROLL menu ---------------------------------------------------------------------
-- Only an interface: every action calls the owning module's API. Every text goes through the
-- localization keys (localization/en.txt, localization/fr.txt). Views are rebuilt from live
-- state each time they are shown, and a missing module shows "not installed".
--
-- V17 layout: 8 categories (COMBAT, INTERACTIONS, SPAWNER, MONDE, MOI, ÉQUIPE, TROLL, PARAMÈTRES).
-- A category page lists its sections; a section page starts with "< Retour" and keeps about a
-- dozen rows. Rows stay short ("Label : ON"); explanations go in the item description (BeardLib
-- MenuUI "help", shown on hover) and network limits in a short tag ([HOST], [CLIENT OK]...).
-- No setting key was renamed. The TROLL rows are the very same row builders as their home rows
-- (ROWS.*), so they call the same module API and change the same settings.

local function T(key, macros)
	local fmm = rawget(_G, "FunnyModMenu")
	if fmm and type(fmm.L) == "function" then
		return fmm.L(key, macros)
	end
	return key
end

SpawnerMenu.CATEGORIES = {
	{ id = "combat", key = "fmmt_menu_combat" },
	{ id = "interactions", key = "fmmt_menu_interactions" },
	{ id = "spawner", key = "fmmt_menu_spawner" },
	{ id = "world", key = "fmmt_menu_world" },
	{ id = "me", key = "fmmt_menu_me" },
	{ id = "team", key = "fmmt_menu_team" },
	{ id = "troll", key = "fmmt_menu_troll" },
	{ id = "secret", key = "fmmt_menu_secret" },
	{ id = "settings", key = "fmmt_menu_settings" }
}
-- V17: JOUEUR -> MOI, JOUEURS -> ÉQUIPE (a view remembered from before the reload is remapped).
local RENAMED_VIEWS = { player = "me", players = "team", target = "team" }
if not SpawnerMenu.current_view or not SpawnerMenu.current_view.id then
	SpawnerMenu.current_view = { id = "combat" }
elseif RENAMED_VIEWS[SpawnerMenu.current_view.id] then
	SpawnerMenu.current_view = { id = RENAMED_VIEWS[SpawnerMenu.current_view.id] }
end
SpawnerMenu.views = {}

local function api(name)
	local t = rawget(_G, name)
	if type(t) == "table" then
		return t
	end
	return nil
end

local function core()
	return api("QuickEnemySpawner")
end

local function mlog(msg)
	local qes = core()
	if not (qes and qes.settings and qes.settings.show_admin_logs == false) then
		log("[ModMenu] " .. tostring(msg))
	end
end

local function not_installed(label_key)
	return T(label_key) .. " : " .. T("fmmt_not_installed")
end

local function onoff(v)
	return v and "ON" or "OFF"
end

local function state_text(v)
	return v and T("fmmt_on") or T("fmmt_off")
end

local function yes_no(v)
	return v and T("fmmt_yes") or T("fmmt_no")
end

local function is_host()
	return SpawnerMenu.is_host()
end

local function is_mp_host()
	return NET.can_affect_remote_players()
end

-- V17 interface settings (default ON; a missing core counts as ON).
local function ui_setting(key)
	local qes = core()
	local v = qes and type(qes.get_setting) == "function" and qes.get_setting(key)
	return v ~= false
end

-- Row colors (BeardLib MenuUI item "foreground" = text color, a plain item parameter).
local COLORS = {
	on = Color(0.35, 0.9, 0.45),
	off = Color(0.65, 0.65, 0.65),
	host = Color(1, 0.65, 0.2),
	error = Color(1, 0.35, 0.35)
}

-- Network capabilities (lua/network.lua) -------------------------------------------------------
-- Every option asks NET.capability(feature): unavailable actions are greyed (orange) with their
-- short tag and the long reason in the description. With "hide host-only options" on, the
-- unavailable rows are not drawn at all.
local function hide_host_only()
	local qes = core()
	return qes and type(qes.get_setting) == "function" and qes.get_setting("hide_host_only") == true or false
end

local function cap_ok(feature)
	return NET.capability(feature).available
end

local function hidden(feature)
	return not cap_ok(feature) and hide_host_only()
end
SpawnerMenu.hidden = hidden

-- Short tags. "local" features that reach the host through a real vanilla interaction / request
-- are shown [CLIENT OK] (display only: network.lua keeps deciding what is available).
local CLIENT_OK = {
	instant_interactions = true,
	ignore_requirements = true,
	c4_helper = true,
	auto_drill_place = true,
	auto_drill_restart = true,
	auto_pickup_collectibles = true,
	auto_mission = true,
	auto_revive = true,
	tp_me = true,
	follow = true,
	follow_player = true
}

local function net_tag(feature)
	local class = NET.capability(feature).class
	if class == "host" or class == "mp_host" then
		return "fmmt_tag_s_host"
	elseif class == "client_partial" or class == "client_experimental" then
		return "fmmt_tag_s_client_limited"
	elseif class == "needs_mod" then
		return "fmmt_tag_s_mod"
	elseif class == "unsupported" then
		return "fmmt_tag_s_unsupported"
	elseif CLIENT_OK[feature] then
		return "fmmt_tag_s_client_ok"
	end
	return "fmmt_tag_s_local"
end

local function tag_suffix(feature)
	if not feature or not ui_setting("show_net_tags") then
		return ""
	end
	return "   " .. T(net_tag(feature))
end

-- Item description: the capability reason (when limited / unavailable) + the row's explanation.
-- desc = localization key, or a list of already localized strings.
local function describe(feature, desc)
	if not ui_setting("show_descriptions") then
		return nil
	end
	local parts = {}
	if feature then
		local k = NET.capability(feature)
		if k.tag then
			table.insert(parts, T(k.tag))
		end
	end
	if type(desc) == "string" then
		table.insert(parts, T(desc))
	elseif type(desc) == "table" then
		for _, text in ipairs(desc) do
			table.insert(parts, text)
		end
	end
	return #parts > 0 and table.concat(parts, "\n") or nil
end

function SpawnerMenu.render()
	local c = SpawnerMenu.content
	if not c then
		return
	end
	local qes = core()
	local perf = qes and type(qes.perf_enabled) == "function" and qes.perf_enabled()
	local t0 = perf and qes.clock_ms()
	-- The count label belongs to the view being destroyed.
	SpawnerMenu._count_label = nil
	c:ClearItems()
	local view = SpawnerMenu.current_view
	local builder = SpawnerMenu.views[view.id] or SpawnerMenu.views.combat
	local ok, err = pcall(builder, c, view.params or {})
	if not ok then
		c:Divider({ text = T("fmmt_menu_error", { ERR = tostring(err) }), size = 16, foreground = COLORS.error })
		log("[ModMenu] View '" .. tostring(view.id) .. "' error: " .. tostring(err))
	end
	if perf then
		local ms = qes.clock_ms() - t0
		log(string.format("[QES][perf] menu refresh ms=%.1f view=%s", ms, tostring(view.id)))
		if ms > (qes.SLOW_MS or 50) then
			log(string.format("[ModMenu][perf] SLOW REFRESH %.1f ms (%s)", ms, tostring(view.id)))
		end
	end
end

-- Deferred so an item never destroys itself from inside its own callback.
function SpawnerMenu.refresh()
	local function run()
		if SpawnerMenu.menu and SpawnerMenu.menu:Enabled() then
			SpawnerMenu.render()
		end
	end
	if DelayedCalls then
		DelayedCalls:Add("QES_ModMenu_Refresh", 0, run)
	else
		run()
	end
end

function SpawnerMenu.show(id, params)
	SpawnerMenu.current_view = { id = id, params = params }
	SpawnerMenu.refresh()
end

-- Item builders -------------------------------------------------------------------------------

local function header(c, text)
	return c:Divider({ text = text, background_color = Color.white, size = 20 })
end

-- Section title inside a page.
local function subtitle(c, text)
	return c:Divider({ text = text, background_color = Color.white:with_alpha(0.18), size = 17 })
end

local function info(c, text, color)
	return c:Divider({ text = text, size = 16, foreground = color })
end

local function missing(c, label_key)
	return info(c, not_installed(label_key), COLORS.error)
end

-- opts: size, help, color
local function button(c, text, enabled, clbk, opts)
	opts = opts or {}
	return c:Button({
		text = text,
		size = opts.size or 18,
		enabled = enabled ~= false,
		help = opts.help,
		foreground = opts.color,
		foreground_highlight = opts.color,
		on_callback = function()
			clbk()
		end
	})
end

-- "Label : ON" row. feature = capability (nil: always available, no tag).
-- opts: desc, enabled (extra condition)
local function state_row(c, feature, label, value, clbk, opts)
	opts = opts or {}
	if feature and hidden(feature) then
		return nil
	end
	local ok = not feature or cap_ok(feature)
	local color = not ok and COLORS.host or (value and COLORS.on or COLORS.off)
	return button(c, label .. " : " .. state_text(value) .. tag_suffix(feature), ok and opts.enabled ~= false, function()
		clbk(not value)
		SpawnerMenu.refresh()
	end, { help = describe(feature, opts.desc), color = color })
end

-- Action / value row. opts: desc, enabled, size, no_tag, color, refresh (refresh after click)
local function action_row(c, feature, text, clbk, opts)
	opts = opts or {}
	if feature and hidden(feature) then
		return nil
	end
	local ok = not feature or cap_ok(feature)
	return button(c, text .. (opts.no_tag and "" or tag_suffix(feature)), ok and opts.enabled ~= false, function()
		clbk()
		if opts.refresh then
			SpawnerMenu.refresh()
		end
	end, { help = describe(feature, opts.desc), color = not ok and COLORS.host or opts.color, size = opts.size })
end

-- Cycled value ("Rayon : 5 m"): no tag, refresh after click.
local function value_row(c, feature, text, clbk, desc)
	return action_row(c, feature, text, clbk, { desc = desc, no_tag = true, refresh = true })
end

local function combo(c, text, items, index, w)
	return c:ComboBox({
		w = w,
		text = text,
		items = items,
		value = index,
		free_typing = false,
		size = 18
	})
end

local function back_row(c, id, params)
	button(c, T("fmmt_back"), true, function()
		SpawnerMenu.show(id, params)
	end)
end

-- Sub-page: "< Retour" always first, then the page title.
local function page(c, title, back_id, back_params)
	back_row(c, back_id, back_params)
	header(c, title)
end

local function path(cat_key, sec_key)
	return T(cat_key) .. "  >  " .. T(sec_key)
end

local function section_link(c, key, view_id, params, extra)
	button(c, T(key) .. (extra or "") .. "   >", true, function()
		SpawnerMenu.show(view_id, params)
	end, { size = 22 })
end

local function confirm(action, params)
	params.action = action
	SpawnerMenu.show("confirm", params)
end

local function set_setting(key, value, label)
	local qes = core()
	if qes and type(qes.set_setting) == "function" then
		qes.set_setting(key, value)
	end
	if label then
		mlog(label .. " -> " .. onoff(value))
	end
end

local function cycle(list, current)
	local index = table.index_of(list, current)
	return list[(index > 0 and index or 0) % #list + 1]
end

local function radius_text(r)
	return r > 0 and (tostring(r) .. " m") or "MAX"
end

-- Shared rows (home category + TROLL shortcuts) -------------------------------------------------

local ROWS = {}

function ROWS.one_shot(c)
	local m = api("OneShot")
	if not (m and type(m.is_enabled) == "function") then
		return missing(c, "fmmt_oneshot_total")
	end
	local d = { T(NET.is_client() and "fmmt_oneshot_scope_client" or "fmmt_oneshot_scope_host") }
	if type(m.friendly_fire_mutator_active) == "function" then
		table.insert(d, T("fmmt_oneshot_ff_state", { STATE = m.friendly_fire_mutator_active() and T("fmmt_active") or T("fmmt_inactive") }))
	end
	state_row(c, "one_shot", T("fmmt_oneshot_total"), m:is_enabled(), function(v)
		m:set_enabled(v)
	end, { desc = d })
end

local function aimbot_api()
	local ab = api("Aimbot")
	return ab and type(ab.is_enabled) == "function" and ab or nil
end

function ROWS.aimbot(c)
	local ab = aimbot_api()
	if not ab then
		return missing(c, "fmmt_aimbot")
	end
	state_row(c, "aimbot", T("fmmt_aimbot"), ab:is_enabled(), function(v)
		ab:set_enabled(v)
	end, { desc = "fmmt_desc_aimbot" })
end

function ROWS.auto_kill(c)
	local ab = aimbot_api()
	if not ab then
		return missing(c, "fmmt_auto_kill")
	end
	state_row(c, "auto_kill", T("fmmt_auto_kill"), ab:auto_kill_enabled(), function(v)
		ab:set_auto_kill(v)
	end, { desc = NET.is_client() and "fmmt_auto_kill_scope_client" or "fmmt_auto_kill_scope_host" })
end

function ROWS.god_all(c)
	local gm = api("GodMode")
	if not (gm and type(gm.all_players_enabled) == "function") then
		return missing(c, "fmmt_godmode_all")
	end
	local d = { T("fmmt_godmode_all_scope") }
	if NET.mode() == "HOST" then
		table.insert(d, T("fmmt_godmode_all_clients"))
	end
	state_row(c, "god_all", T("fmmt_godmode_all"), gm:all_players_enabled(), function(v)
		gm:set_all_players_enabled(v)
	end, { desc = d })
end

function ROWS.vanish_full(c)
	local vn, pinv = api("Vanish"), api("PlayerInvisibility")
	if not (vn and type(vn.is_enabled) == "function" and pinv and type(pinv.is_enabled) == "function") then
		return missing(c, "fmmt_vanish_full")
	end
	state_row(c, "vanish", T("fmmt_vanish_full"), vn:is_enabled() and pinv:is_enabled(), function(v)
		vn:set_enabled(v)
		pinv:set_enabled(v)
	end, { desc = "fmmt_desc_vanish_full" })
end

function ROWS.convert_all(c)
	local cv = api("EnemyConvert")
	if not (cv and type(cv.convert_all) == "function") then
		return missing(c, "fmmt_convert_all")
	end
	local d = cap_ok("convert_all") and { T("fmmt_convert_hint", { COUNT = #cv.candidates() }) } or nil
	action_row(c, "convert_all", T("fmmt_convert_all"), function()
		cv.convert_all()
	end, { desc = d, refresh = true })
end

function ROWS.tp_all(c)
	local tp = api("Teleport")
	if not (tp and type(tp.all_to_me) == "function") then
		return missing(c, "fmmt_tp_all_to_me")
	end
	action_row(c, "tp_all", T("fmmt_tp_all_to_me"), function()
		tp.all_to_me()
	end, { desc = "fmmt_tp_all_hint", refresh = true })
end

-- V18: "Ennemis vanilla" and "Vagues" are two separate switches again (V17 had merged them into
-- NORMAL <-> NO_ENEMIES_HARD and the waves switch was gone). Both reset ON every level.
local function enemy_control_api()
	local ec = api("EnemyControl")
	return ec and type(ec.set_waves) == "function" and ec or nil
end

function ROWS.vanilla_enemies(c)
	local ec = enemy_control_api()
	if not ec then
		return missing(c, "fmmt_vanilla_enemies")
	end
	state_row(c, "enemy_control", T("fmmt_vanilla_enemies"), ec.vanilla_enabled(), function(v)
		ec.set_vanilla(v)
	end, { desc = { T("fmmt_desc_vanilla_enemies"), T("fmmt_reset_level_hint") } })
end

function ROWS.waves(c)
	local ec = enemy_control_api()
	if not ec then
		return missing(c, "fmmt_waves")
	end
	state_row(c, "enemy_control", T("fmmt_waves"), ec.waves_enabled(), function(v)
		ec.set_waves(v)
	end, { desc = { T("fmmt_desc_waves"), T("fmmt_reset_level_hint") } })
end

function ROWS.enemies_hard(c)
	local ec = enemy_control_api()
	if not ec then
		return
	end
	state_row(c, "enemy_control", T("fmmt_enemies_hard"), ec.hard_enabled(), function(v)
		ec.set_hard(v)
	end, { desc = { T("fmmt_desc_enemies_hard"), T("fmmt_warning_scripted"), T("fmmt_reset_level_hint") } })
end

function ROWS.fly_noclip(c)
	local fm = api("FlyMode")
	if not (fm and type(fm.is_both) == "function") then
		return missing(c, "fmmt_fly_noclip")
	end
	state_row(c, "fly", T("fmmt_fly_noclip"), fm:is_both(), function(v)
		fm:set_both(v)
	end, { desc = "fmmt_fly_hint" })
end

function ROWS.kill_all(c)
	local qes = core()
	if not (qes and type(qes.kill_all) == "function") then
		return
	end
	action_row(c, "kill_remove", T("fmmt_kill_all_enemies"), function()
		mlog("kill all")
		qes.kill_all()
	end, { desc = "fmmt_kill_hint", refresh = true })
end

-- SPAWNER -------------------------------------------------------------------------------------

local HP_CHOICES = { 1, 2, 5, 10 }
local BEHAVIOURS = {
	{ key = "fmmt_beh_attack", objective = "none" },
	{ key = "fmmt_beh_defend", objective = "defend" },
	{ key = "fmmt_beh_follow", objective = "follow" },
	{ key = "fmmt_beh_idle", objective = "inactive" }
}
local TEAM_ENEMY, TEAM_ALLY = "law1", "converted_enemy"
local SPAWN_RATES = { "SAFE", "FAST", "EXTREME" }

local function hp_label(m)
	return m == 1 and T("fmmt_hp_normal") or ("x" .. tostring(m))
end

local function catalog()
	if not SpawnerMenu._catalog_entries then
		local uc = api("UnitCatalog")
		if uc and type(uc.build) == "function" then
			SpawnerMenu._catalog_entries, SpawnerMenu._catalog_by_name = uc.build()
		else
			SpawnerMenu._catalog_entries, SpawnerMenu._catalog_by_name = {}, {}
		end
	end
	return SpawnerMenu._catalog_entries, SpawnerMenu._catalog_by_name
end

local function favorites()
	local qes = core()
	local fav = qes and qes.get_setting("spawner_favorites")
	return type(fav) == "table" and fav or {}
end

-- "QES actifs : X / Y  |  File : N" (QES tracking table + spawn queue only, no World scan).
local function count_text()
	local q = core()
	if not q then
		return T("fmmt_qes_active", { COUNT = "?", MAX = "?" })
	end
	local max = q.max_alive()
	local queued = type(q.get_queue_count) == "function" and q.get_queue_count() or 0
	return T("fmmt_qes_active", { COUNT = tostring(q.get_spawned_count()), MAX = max and tostring(max) or T("fmmt_unlimited") })
		.. "   |   " .. T("fmmt_qes_queue", { COUNT = tostring(queued) })
end

-- Light refresh: only the text of the counter label of the current view (no ClearItems, no
-- view rebuild). Called after a click and by core.lua after each processed spawn, at most every
-- COUNT_REFRESH seconds.
SpawnerMenu.COUNT_REFRESH = 0.2
function SpawnerMenu.update_count(force)
	local label = SpawnerMenu._count_label
	if not label then
		return
	end
	local now = Application:time()
	if not force and SpawnerMenu._count_t and now - SpawnerMenu._count_t < SpawnerMenu.COUNT_REFRESH then
		SpawnerMenu._count_pending = true
		return
	end
	SpawnerMenu._count_t = now
	SpawnerMenu._count_pending = nil
	local ok = pcall(label.SetText, label, count_text())
	if not ok then
		SpawnerMenu._count_label = nil
	end
end

local function spawn_entry(entry, team)
	if not is_host() then
		log("[QuickEnemySpawner] Client attempted spawn - blocked")
		return
	end
	local behaviour = BEHAVIOURS[SpawnerMenu._behaviour or 1] or BEHAVIOURS[1]
	local params = {
		unit_ids = entry.unit_ids,
		hp_mult = SpawnerMenu._hp or 1,
		team = team,
		objective = behaviour.objective
	}
	-- Never a World / network spawn inside a UI callback: the click only queues one spawn,
	-- GameSetupUpdate (core.lua step_spawn_queue) creates it later at the chosen rate.
	local q = core()
	if q and type(q.enqueue_spawn) == "function" then
		q.enqueue_spawn(params)
	else
		log("[QuickEnemySpawner] Spawn unavailable: core module not loaded")
	end
end

SpawnerMenu.views.spawner = function(c)
	header(c, T("fmmt_menu_spawner"))
	-- Enemies are server units (World:spawn_unit on a client would create a unit only this client
	-- has): the whole spawner is host only, nothing is attempted as a client.
	if not cap_ok("spawner") then
		info(c, T("fmmt_tag_s_host") .. "  " .. T("fmmt_tag_host_only"), COLORS.host)
		info(c, T("fmmt_spawner_client_hint"))
		return
	end
	local uc = api("UnitCatalog")
	if not uc then
		missing(c, "fmmt_catalog")
		return
	end
	local entries, by_name = catalog()
	SpawnerMenu._count_label = info(c, count_text())

	subtitle(c, T("fmmt_cat_favorites"))
	local favs = uc.list("favorites", entries, by_name, favorites())
	if #favs == 0 then
		info(c, T("fmmt_no_favorites"))
	end
	for _, entry in ipairs(favs) do
		button(c, entry.label, true, function()
			SpawnerMenu.show("spawner_unit", { name = entry.name, home = true })
		end)
	end

	subtitle(c, T("fmmt_sec_categories"))
	for _, cat in ipairs(uc.CATEGORIES) do
		if cat.id ~= "favorites" then
			local n = #uc.list(cat.id, entries, by_name, favorites())
			button(c, T(cat.label_key) .. "  (" .. n .. ")   >", n > 0, function()
				SpawnerMenu.show("spawner_list", { category = cat.id, label_key = cat.label_key })
			end)
		end
	end

	subtitle(c, T("fmmt_sec_options"))
	section_link(c, "fmmt_sec_spawner_options", "spawner_options")
	action_row(c, "spawner", T("fmmt_clear_all_qes"), function()
		mlog("Clear all QES")
		SpawnerMenu.clear()
	end, { enabled = core() ~= nil, no_tag = true, refresh = true })
end

SpawnerMenu.views.spawner_list = function(c, params)
	page(c, path("fmmt_menu_spawner", params.label_key or "fmmt_menu_spawner"), "spawner")
	local uc = api("UnitCatalog")
	if not uc then
		return
	end
	local entries, by_name = catalog()
	local list = uc.list(params.category, entries, by_name, favorites())
	if #list == 0 then
		info(c, T("fmmt_no_units_category"))
	end
	for _, entry in ipairs(list) do
		button(c, entry.label, true, function()
			SpawnerMenu.show("spawner_unit", { name = entry.name, category = params.category, label_key = params.label_key })
		end)
	end
end

SpawnerMenu.views.spawner_unit = function(c, params)
	local _, by_name = catalog()
	local entry = by_name[params.name]
	if params.home or not params.category then
		back_row(c, "spawner")
	else
		back_row(c, "spawner_list", { category = params.category, label_key = params.label_key })
	end
	if not entry then
		header(c, T("fmmt_unit"))
		info(c, T("fmmt_unit_unavailable"), COLORS.error)
		return
	end
	local host = is_host()
	header(c, entry.label)
	SpawnerMenu._count_label = info(c, count_text())

	local order = params.category == "allies"
		and { { "fmmt_spawn_ally", TEAM_ALLY }, { "fmmt_spawn_enemy", TEAM_ENEMY } }
		or { { "fmmt_spawn_enemy", TEAM_ENEMY }, { "fmmt_spawn_ally", TEAM_ALLY } }
	for i, choice in ipairs(order) do
		action_row(c, "spawner", ">>>  " .. T(choice[1]) .. "  <<<", function()
			spawn_entry(entry, choice[2])
			SpawnerMenu.update_count(true)
		end, { enabled = host, size = i == 1 and 24 or 20, no_tag = true })
	end

	subtitle(c, T("fmmt_sec_options"))
	button(c, T("fmmt_hp", { VALUE = hp_label(SpawnerMenu._hp or 1) }), true, function()
		SpawnerMenu._hp = cycle(HP_CHOICES, SpawnerMenu._hp or 1)
		SpawnerMenu.refresh()
	end, { help = describe(nil, "fmmt_desc_hp") })
	local behaviour = BEHAVIOURS[SpawnerMenu._behaviour or 1] or BEHAVIOURS[1]
	button(c, T("fmmt_behaviour", { VALUE = T(behaviour.key) }), true, function()
		SpawnerMenu._behaviour = (SpawnerMenu._behaviour or 1) % #BEHAVIOURS + 1
		SpawnerMenu.refresh()
	end)

	local qes = core()
	if qes then
		local fav = favorites()
		local is_fav = table.contains(fav, entry.name)
		button(c, is_fav and T("fmmt_fav_remove") or T("fmmt_fav_add"), true, function()
			local new = {}
			for _, name in ipairs(fav) do
				if name ~= entry.name then
					table.insert(new, name)
				end
			end
			if not is_fav then
				table.insert(new, entry.name)
			end
			qes.set_setting("spawner_favorites", new)
			SpawnerMenu.refresh()
		end)
	end
end

SpawnerMenu.views.spawner_options = function(c)
	page(c, path("fmmt_menu_spawner", "fmmt_sec_spawner_options"), "spawner")
	local qes = core()
	if not qes then
		missing(c, "fmmt_menu_spawner")
		return
	end
	SpawnerMenu._count_label = info(c, count_text())
	local max_alive = qes.get_setting("max_alive")
	value_row(c, nil, T("fmmt_max_alive", { VALUE = (max_alive and max_alive > 0) and tostring(max_alive) or T("fmmt_unlimited") }), function()
		qes.set_setting("max_alive", cycle(qes.MAX_ALIVE_CHOICES, qes.get_setting("max_alive")))
	end, "fmmt_desc_max_alive")
	value_row(c, nil, T("fmmt_spawn_rate", { VALUE = tostring(qes.get_setting("spawn_rate")) }), function()
		local rates = {}
		for _, id in ipairs(SPAWN_RATES) do
			if not qes.SPAWN_RATES or qes.SPAWN_RATES[id] then
				table.insert(rates, id)
			end
		end
		qes.set_setting("spawn_rate", cycle(rates, qes.get_setting("spawn_rate")))
	end, "fmmt_desc_spawn_rate")
	state_row(c, nil, T("fmmt_auto_clear_restart"), qes.get_setting("auto_clear_restart"), function(v)
		set_setting("auto_clear_restart", v, "Auto clear restart")
	end)
	state_row(c, nil, T("fmmt_auto_clear_end"), qes.get_setting("auto_clear_mission_end"), function(v)
		set_setting("auto_clear_mission_end", v, "Auto clear mission end")
	end)
end

-- COMBAT --------------------------------------------------------------------------------------

-- InfinitePlayerResources key -> network feature.
local RESOURCE_FEATURES = {
	ammo = "ammo",
	no_reload = "no_reload",
	throwables = "throwables",
	deployables = "deployables",
	body_bags = "body_bags"
}

local function resource_row(c, key, label_key, desc)
	local ipr = api("InfinitePlayerResources")
	if ipr and type(ipr.is_enabled) == "function" then
		state_row(c, RESOURCE_FEATURES[key] or key, T(label_key), ipr:is_enabled(key), function(v)
			ipr:set_enabled(key, v)
		end, { desc = desc })
	else
		missing(c, label_key)
	end
end

SpawnerMenu.views.combat = function(c)
	header(c, T("fmmt_menu_combat"))
	section_link(c, "fmmt_sec_damage", "combat_damage")
	section_link(c, "fmmt_sec_invincibility", "combat_god")
	section_link(c, "fmmt_sec_ammo", "combat_ammo")

	local gm, os_mod, ipr, sa = api("GodMode"), api("OneShot"), api("InfinitePlayerResources"), api("SentryAmmo")
	local function set_all(v)
		if gm and type(gm.set_enabled) == "function" then
			gm:set_enabled(v)
		end
		if os_mod and type(os_mod.set_enabled) == "function" then
			os_mod:set_enabled(v)
		end
		if ipr and type(ipr.set_enabled) == "function" then
			for _, key in ipairs({ "ammo", "no_reload", "throwables" }) do
				ipr:set_enabled(key, v)
			end
		end
		if sa and type(sa.set_enabled) == "function" then
			sa:set_enabled(v)
		end
		SpawnerMenu.refresh()
	end
	subtitle(c, T("fmmt_sec_quick"))
	button(c, T("fmmt_enable_all"), true, function()
		set_all(true)
	end, { help = describe(nil, "fmmt_desc_combat_all") })
	button(c, T("fmmt_disable_all"), true, function()
		set_all(false)
	end, { help = describe(nil, "fmmt_desc_combat_all") })
end

SpawnerMenu.views.combat_damage = function(c)
	page(c, path("fmmt_menu_combat", "fmmt_sec_damage"), "combat")
	ROWS.one_shot(c)
	ROWS.aimbot(c)
	ROWS.auto_kill(c)
	local ab = aimbot_api()
	if not ab then
		return
	end
	value_row(c, "aimbot", T("fmmt_aimbot_targets", { VALUE = T("fmmt_aimbot_t_" .. ab:target_mode()) }), function()
		ab:set_target_mode(cycle(ab.TARGET_MODES, ab:target_mode()))
	end)
	value_row(c, "aimbot", T("fmmt_aimbot_fov", { VALUE = tostring(ab:fov()) }), function()
		ab:set_fov(cycle(ab.FOVS, ab:fov()))
	end)
	local dist = ab:max_distance()
	value_row(c, "aimbot", T("fmmt_aimbot_distance", { VALUE = dist > 0 and (tostring(dist) .. " m") or T("fmmt_unlimited") }), function()
		ab:set_max_distance(cycle(ab.DISTANCES, ab:max_distance()))
	end)
	value_row(c, "auto_kill", T("fmmt_auto_kill_delay", { VALUE = tostring(ab:kill_delay()) }), function()
		ab:set_kill_delay(cycle(ab.KILL_DELAYS, ab:kill_delay()))
	end)
end

SpawnerMenu.views.combat_god = function(c)
	page(c, path("fmmt_menu_combat", "fmmt_sec_invincibility"), "combat")
	local gm = api("GodMode")
	if gm and type(gm.is_enabled) == "function" then
		state_row(c, "god_personal", T("fmmt_godmode_personal"), gm:is_enabled(), function(v)
			gm:set_enabled(v)
		end, { desc = "fmmt_desc_god_personal" })
	else
		missing(c, "fmmt_godmode")
	end
	ROWS.god_all(c)
end

SpawnerMenu.views.combat_ammo = function(c)
	page(c, path("fmmt_menu_combat", "fmmt_sec_ammo"), "combat")
	resource_row(c, "ammo", "fmmt_infinite_ammo")
	resource_row(c, "no_reload", "fmmt_no_reload")
	resource_row(c, "throwables", "fmmt_infinite_grenades")
	local sa = api("SentryAmmo")
	if sa and type(sa.is_enabled) == "function" then
		state_row(c, "sentry_ammo", T("fmmt_sentry_ammo"), sa:is_enabled(), function(v)
			sa:set_enabled(v)
		end)
	else
		missing(c, "fmmt_sentry_ammo")
	end
end

-- INTERACTIONS --------------------------------------------------------------------------------

local function helper_row(c, key, label_key, desc)
	local ix = api("InteractionHelpers")
	if not (ix and type(ix.is_enabled) == "function") then
		return missing(c, label_key)
	end
	state_row(c, key, T(label_key), ix:is_enabled(key), function(v)
		ix:set_enabled(key, v)
	end, { desc = desc })
end

SpawnerMenu.views.interactions = function(c)
	header(c, T("fmmt_menu_interactions"))
	section_link(c, "fmmt_sec_fast", "ix_fast")
	section_link(c, "fmmt_sec_auto", "ix_auto")
	section_link(c, "fmmt_sec_stealth", "ix_stealth")
end

SpawnerMenu.views.ix_fast = function(c)
	page(c, path("fmmt_menu_interactions", "fmmt_sec_fast"), "interactions")
	helper_row(c, "instant_interactions", "fmmt_instant_interactions", "fmmt_desc_instant_interactions")
	-- V15: instant placement (deployables + mission devices), local timers only.
	local ip = api("InstantPlace")
	if ip and type(ip.is_enabled) == "function" then
		state_row(c, "instant_place", T("fmmt_instant_place"), ip:is_enabled(), function(v)
			ip:set_enabled(v)
		end, { desc = "fmmt_desc_instant_place" })
	else
		missing(c, "fmmt_instant_place")
	end
	helper_row(c, "ignore_requirements", "fmmt_ignore_requirements", "fmmt_requirements_hint")
	helper_row(c, "unbreakable_drills", "fmmt_unbreakable_drills", "fmmt_drill_hint")
end

SpawnerMenu.views.ix_auto = function(c)
	page(c, path("fmmt_menu_interactions", "fmmt_sec_auto"), "interactions")

	-- Auto drill (V14): place + restart through the real interactions (local player, host or client).
	subtitle(c, T("fmmt_auto_drill_header"))
	local ad = api("AutoDrill")
	if ad and type(ad.place_enabled) == "function" then
		state_row(c, "auto_drill_place", T("fmmt_auto_drill_place"), ad:place_enabled(), function(v)
			ad:set_place_enabled(v)
		end, { desc = "fmmt_auto_drill_hint" })
		state_row(c, "auto_drill_restart", T("fmmt_auto_drill"), ad:restart_enabled(), function(v)
			ad:set_restart_enabled(v)
		end, { desc = "fmmt_auto_drill_hint" })
		value_row(c, "auto_drill_place", T("fmmt_auto_drill_radius", { VALUE = radius_text(ad:radius()) }), function()
			ad:set_radius(cycle(ad.RADII, ad:radius()))
		end)
	else
		missing(c, "fmmt_auto_drill")
	end

	subtitle(c, T("fmmt_auto_revive_header"))
	local ar = api("AutoRevive")
	if ar and type(ar.is_enabled) == "function" then
		state_row(c, "auto_revive", T("fmmt_auto_revive"), ar:is_enabled(), function(v)
			ar:set_enabled(v)
		end, { desc = "fmmt_desc_auto_revive" })
		value_row(c, "auto_revive", T("fmmt_auto_revive_radius", { VALUE = radius_text(ar:radius()) }), function()
			ar:set_radius(cycle(ar.RADII, ar:radius()))
		end)
	else
		missing(c, "fmmt_auto_revive")
	end

	-- Auto steal (V15): vanilla pickup interactions, host and client.
	subtitle(c, T("fmmt_auto_steal_header"))
	local st = api("AutoSteal")
	if st and type(st.is_enabled) == "function" then
		state_row(c, "auto_steal", T("fmmt_auto_steal"), st:is_enabled(), function(v)
			st:set_enabled(v)
		end, { desc = "fmmt_auto_steal_hint" })
		value_row(c, "auto_steal", T("fmmt_auto_steal_radius", { VALUE = radius_text(st:radius()) }), function()
			st:set_radius(cycle(st.RADII, st:radius()))
		end)
		-- V18: real per-type result of this session (HOST / CLIENT), never a global "CLIENT OK".
		if type(st.status) == "function" and type(st.TYPES) == "table" and ui_setting("show_descriptions") then
			local status_color = { ok = COLORS.on, fail = COLORS.error, unsupported = COLORS.error }
			local current = NET.is_client() and "CLIENT" or "HOST"
			for _, kind in ipairs(st.TYPES) do
				local h, cl = st.status(kind, "HOST"), st.status(kind, "CLIENT")
				info(c, T("fmmt_steal_type_" .. kind) .. " :  HOST " .. T("fmmt_steal_st_" .. h) .. "   ·   CLIENT " .. T("fmmt_steal_st_" .. cl),
					status_color[current == "CLIENT" and cl or h] or COLORS.off)
			end
		end
	else
		missing(c, "fmmt_auto_steal")
	end

	-- V18: mission interactions (C4, drill, hack, terminal, insert...) through RealInteract.
	subtitle(c, T("fmmt_auto_mission_header"))
	local am = api("AutoMission")
	if am and type(am.is_enabled) == "function" then
		state_row(c, "auto_mission", T("fmmt_auto_mission"), am:is_enabled(), function(v)
			am:set_enabled(v)
		end, { desc = "fmmt_desc_auto_mission" })
		value_row(c, "auto_mission", T("fmmt_auto_mission_radius", { VALUE = radius_text(am:radius()) }), function()
			am:set_radius(cycle(am.RADII, am:radius()))
		end)
		-- V18.x: runtime pause (client + Auto Steal + stealth), the settings stay as they are.
		local aam = FunnyMod and FunnyMod.AutoActions
		if aam and type(aam.mission_paused) == "function" and aam.mission_paused() then
			info(c, T("fmmt_auto_mission_paused"), COLORS.error)
		end
		-- V18.4: tool bags (thermal drill / equipment / breaching charges): pick up + deliver.
		local tb = api("AutoToolbag")
		if tb and type(tb.is_enabled) == "function" then
			state_row(c, "auto_mission", T("fmmt_auto_toolbag"), tb:is_enabled(), function(v)
				tb:set_enabled(v)
			end, { desc = "fmmt_desc_auto_toolbag" })
			value_row(c, "auto_mission", T("fmmt_auto_toolbag_radius", { VALUE = radius_text(tb:radius()) }), function()
				tb:set_radius(cycle(tb.RADII, tb:radius()))
			end)
		end
	else
		missing(c, "fmmt_auto_mission")
	end

	-- V15: common auto-action engine radius (overrides the per-feature radii when set).
	local aa = api("AutoActions") or (FunnyMod and FunnyMod.AutoActions)
	if aa and type(aa.global_radius) == "function" then
		local gr = aa.global_radius()
		value_row(c, nil, T("fmmt_auto_actions_radius", { VALUE = gr < 0 and T("fmmt_per_feature") or radius_text(gr) }), function()
			aa.set_global_radius(cycle(aa.GLOBAL_RADII, aa.global_radius()))
		end, "fmmt_desc_auto_actions_radius")
	end
end

SpawnerMenu.views.ix_stealth = function(c)
	page(c, path("fmmt_menu_interactions", "fmmt_sec_stealth"), "interactions")
	local np = api("NoPagers")
	if np and type(np.is_enabled) == "function" then
		local text = T("fmmt_no_pagers")
		if np:is_enabled() and np:status() == "BYPASSED (LOUD)" then
			text = text .. " " .. T("fmmt_bypassed_loud")
		end
		state_row(c, "no_pagers", text, np:is_enabled(), function(v)
			np:set_enabled(v)
		end)
	else
		missing(c, "fmmt_no_pagers")
	end
	helper_row(c, "c4_helper", "fmmt_c4", "fmmt_c4_hint")
	helper_row(c, "infinite_cable_ties", "fmmt_cable_ties")

	subtitle(c, T("fmmt_stealth"))
	local qes = core()
	local nd = api("NeverDetectedV212")
	if nd and type(nd.is_enabled) == "function" then
		local text = T("fmmt_never_detected")
		if nd:is_enabled() and type(nd.status) == "function" and nd:status() == "BYPASSED (LOUD)" then
			text = text .. " " .. T("fmmt_bypassed_loud")
		end
		state_row(c, "never_detected", text, nd:is_enabled(), function(v)
			if qes then set_setting("nd_enabled", v, "Never Detected") else nd:set_enabled(v) end
		end)
		state_row(c, "cameras_blind", T("fmmt_cameras_blind"), nd:is_cameras_blind(), function(v)
			if qes then set_setting("nd_cameras_blind", v, "Cameras blind") else nd:set_cameras_blind(v) end
		end)
	else
		missing(c, "fmmt_never_detected")
	end
	local noise = api("NoStealthNoiseAlerts")
	if noise and type(noise.is_enabled) == "function" then
		state_row(c, "noise_alerts", T("fmmt_noise_off"), noise:is_enabled(), function(v)
			if qes then set_setting("noise_alerts_enabled", v, "Noise alerts off") else noise:set_enabled(v) end
		end)
	else
		missing(c, "fmmt_noise_off")
	end
	if qes then
		state_row(c, nil, T("fmmt_auto_stealth_loud"), qes.get_setting("auto_disable_stealth_in_loud"), function(v)
			set_setting("auto_disable_stealth_in_loud", v, "Stealth auto off in loud")
		end)
	end
end

-- MONDE / WORLD -------------------------------------------------------------------------------

SpawnerMenu.views.world = function(c)
	header(c, T("fmmt_menu_world"))
	section_link(c, "fmmt_sec_collectibles", "world_collect")
	section_link(c, "fmmt_highlight_header", "world_highlight")
	section_link(c, "fmmt_sec_enemies", "world_enemies")
	section_link(c, "fmmt_loot", "world_loot")
end

local function highlight_api()
	local oh = api("ObjectHighlight")
	return oh and type(oh.collectibles_enabled) == "function" and oh or nil
end

SpawnerMenu.views.world_collect = function(c)
	page(c, path("fmmt_menu_world", "fmmt_sec_collectibles"), "world")
	local oh = highlight_api()
	if not oh then
		missing(c, "fmmt_highlight_collectibles")
		return
	end
	state_row(c, "highlight_collectibles", T("fmmt_highlight_collectibles"), oh:collectibles_enabled(), function(v)
		oh:set_collectibles_enabled(v)
	end)
	if type(oh.auto_pickup_enabled) == "function" then
		state_row(c, "auto_pickup_collectibles", T("fmmt_auto_pickup"), oh:auto_pickup_enabled(), function(v)
			oh:set_auto_pickup_enabled(v)
		end, { desc = "fmmt_auto_pickup_hint" })
		value_row(c, "auto_pickup_collectibles", T("fmmt_auto_pickup_radius", { VALUE = radius_text(oh:pickup_radius()) }), function()
			oh:set_pickup_radius(cycle(oh.PICKUP_RADII, oh:pickup_radius()))
		end)
	end
end

SpawnerMenu.views.world_highlight = function(c)
	page(c, path("fmmt_menu_world", "fmmt_highlight_header"), "world")
	local oh = highlight_api()
	if not oh then
		missing(c, "fmmt_highlight_objectives")
		return
	end
	state_row(c, "highlight", T("fmmt_highlight_objectives"), oh:objectives_enabled(), function(v)
		oh:set_objectives_enabled(v)
	end)
	if type(oh.loot_enabled) == "function" then
		state_row(c, "highlight", T("fmmt_highlight_loot"), oh:loot_enabled(), function(v)
			oh:set_loot_enabled(v)
		end)
	end
end

-- Kill / remove target group (menu state only; same QES functions as before).
local KILL_GROUPS = {
	{ key = "fmmt_enemies_all", kill = "kill_all", remove = "clear_all" },
	{ key = "fmmt_enemies_vanilla", kill = "kill_vanilla", remove = "clear_vanilla" },
	{ key = "fmmt_enemies_qes", kill = "kill_spawned", remove = "clear_spawned" }
}

SpawnerMenu.views.world_enemies = function(c)
	page(c, path("fmmt_menu_world", "fmmt_sec_enemies"), "world")
	ROWS.vanilla_enemies(c)
	ROWS.waves(c)

	local cv = api("EnemyConvert")
	if cv and type(cv.convert_aimed) == "function" then
		action_row(c, "convert_target", T("fmmt_convert_target"), function()
			local ok, reason = cv.convert_aimed()
			if not ok and managers.hud and managers.hud.show_hint then
				managers.hud:show_hint({ text = T("fmmt_convert_failed", { REASON = tostring(reason) }) })
			end
		end, { refresh = true })
	end
	ROWS.convert_all(c)

	local qes = core()
	if qes and not hidden("kill_remove") then
		subtitle(c, T("fmmt_sec_kill_remove"))
		local group = KILL_GROUPS[SpawnerMenu._kill_group or 1] or KILL_GROUPS[1]
		value_row(c, "kill_remove", T("fmmt_kill_target", { VALUE = T(group.key) }), function()
			SpawnerMenu._kill_group = (SpawnerMenu._kill_group or 1) % #KILL_GROUPS + 1
		end)
		action_row(c, "kill_remove", T("fmmt_kill_enemies"), function()
			mlog(group.key .. " kill")
			qes[group.kill]()
		end, { desc = "fmmt_kill_hint", enabled = qes[group.kill] ~= nil, refresh = true })
		action_row(c, "kill_remove", T("fmmt_remove_enemies"), function()
			mlog(group.key .. " remove")
			qes[group.remove]()
		end, { desc = "fmmt_kill_hint", enabled = qes[group.remove] ~= nil, refresh = true })
	end
	subtitle(c, T("fmmt_sec_advanced"))
	ROWS.enemies_hard(c)
end

SpawnerMenu.views.world_loot = function(c)
	page(c, path("fmmt_menu_world", "fmmt_loot"), "world")
	local ls = api("LootSpawner")
	if hidden("loot") then
		info(c, T("fmmt_tag_s_host") .. "  " .. T("fmmt_tag_host_only"), COLORS.host)
		return
	end
	if not ls or type(ls.spawn) ~= "function" then
		missing(c, "fmmt_loot")
		return
	end
	local types = ls.available_types()
	local items = {}
	for i, t in ipairs(types) do
		items[i] = T(t.label_key)
	end
	items[#items + 1] = T("fmmt_loot_random")
	local type_box = combo(c, T("fmmt_loot_type"), items, SpawnerMenu._loot_index or 1, c:W())
	local count_label = info(c, T("fmmt_loot_count", { COUNT = ls.count(), MAX = ls.max_bags() }))
	local function spawn(where)
		local index = type_box:Value()
		SpawnerMenu._loot_index = index
		local chosen = types[index]
		ls.spawn(chosen and chosen.id or "random", where)
		count_label:SetText(T("fmmt_loot_count", { COUNT = ls.count(), MAX = ls.max_bags() }))
	end
	action_row(c, "loot", T("fmmt_loot_throw"), function()
		spawn("throw")
	end, { size = 20 })
	action_row(c, "loot", T("fmmt_loot_feet"), function()
		spawn("feet")
	end)
	action_row(c, "loot", T("fmmt_loot_clear"), function()
		ls.clear()
	end, { no_tag = true, refresh = true })
	local qes = core()
	if qes then
		value_row(c, nil, T("fmmt_loot_max", { VALUE = tostring(qes.get_setting("loot_max")) }), function()
			qes.set_setting("loot_max", cycle({ 25, 50, 100 }, qes.get_setting("loot_max")))
		end)
	end
end

-- MOI / ME: only what affects the local player's own character ---------------------------------

SpawnerMenu.views.me = function(c)
	header(c, T("fmmt_menu_me"))
	section_link(c, "fmmt_sec_movement", "me_move")
	section_link(c, "fmmt_sec_resources", "me_res")
	section_link(c, "fmmt_vanish_header", "me_vanish")
	section_link(c, "fmmt_sec_follow", "me_follow")
end

SpawnerMenu.views.me_move = function(c)
	page(c, path("fmmt_menu_me", "fmmt_sec_movement"), "me")
	local ps, fm = api("PlayerSpeed"), api("FlyMode")
	if ps and type(ps.is_enabled) == "function" then
		state_row(c, "speed", T("fmmt_speed_mode"), ps:is_enabled(), function(v)
			ps:set_enabled(v)
		end)
		value_row(c, "speed", T("fmmt_speed", { VALUE = tostring(ps:multiplier()) }), function()
			ps:set_multiplier(cycle(ps.MULTIPLIERS, ps:multiplier()))
		end)
		state_row(c, "ignore_bag_weight", T("fmmt_ignore_bag_weight"), ps:ignores_bag_weight(), function(v)
			ps:set_ignore_bag_weight(v)
		end)
	else
		missing(c, "fmmt_speed_mode")
	end
	if fm and type(fm.is_fly) == "function" then
		local d = { T("fmmt_fly_hint") }
		if NET.is_client() then
			table.insert(d, T("fmmt_fly_client_hint"))
		end
		state_row(c, "fly", T("fmmt_fly"), fm:is_fly(), function(v)
			fm:set_fly(v)
		end, { desc = d })
		state_row(c, "noclip", T("fmmt_noclip"), fm:is_noclip(), function(v)
			fm:set_noclip(v)
		end, { desc = d })
		ROWS.fly_noclip(c)
	else
		missing(c, "fmmt_fly")
	end
end

SpawnerMenu.views.me_res = function(c)
	page(c, path("fmmt_menu_me", "fmmt_sec_resources"), "me")
	resource_row(c, "deployables", "fmmt_infinite_deployables")
	resource_row(c, "body_bags", "fmmt_infinite_bodybags")
	helper_row(c, "infinite_cable_ties", "fmmt_cable_ties_me")
end

SpawnerMenu.views.me_vanish = function(c)
	page(c, path("fmmt_menu_me", "fmmt_vanish_header"), "me")
	local vn, pinv = api("Vanish"), api("PlayerInvisibility")
	if vn and type(vn.is_enabled) == "function" then
		state_row(c, "vanish", T("fmmt_vanish_ai"), vn:is_enabled(), function(v)
			vn:set_enabled(v)
		end, { desc = "fmmt_vanish_hint" })
	else
		missing(c, "fmmt_vanish_ai")
	end
	if pinv and type(pinv.is_enabled) == "function" then
		state_row(c, "vanish_players", T("fmmt_vanish_players"), pinv:is_enabled(), function(v)
			pinv:set_enabled(v)
		end, { desc = "fmmt_vanish_players_hint" })
		ROWS.vanish_full(c)
		if NET.has_session() and not NET.is_singleplayer() and type(pinv.compatible_count) == "function" then
			local ok_n, total = pinv.compatible_count()
			info(c, T("fmmt_vanish_players_compat", { OK = tostring(ok_n), TOTAL = tostring(total) }))
		end
	else
		missing(c, "fmmt_vanish_players")
	end
end

SpawnerMenu.views.me_follow = function(c)
	page(c, path("fmmt_menu_me", "fmmt_sec_follow"), "me")
	local tp = api("Teleport")
	if not (tp and type(tp.follow_name) == "function") then
		missing(c, "fmmt_teleport")
		return
	end
	local name = tp.follow_name()
	info(c, T("fmmt_follow_current", { NAME = name or T("fmmt_follow_none") }), name and COLORS.on or nil)
	if type(tp.follow_delay) == "function" then
		value_row(c, nil, T("fmmt_follow_delay", { SEC = tostring(tp.follow_delay()) }), function()
			tp.set_follow_delay(cycle(tp.FOLLOW_DELAYS, tp.follow_delay()))
		end)
	else
		info(c, T("fmmt_follow_interval", { SEC = tostring(tp.FOLLOW_INTERVAL or 3) }))
	end
	action_row(c, nil, T("fmmt_follow_stop"), function()
		tp.stop_follow("menu")
	end, { enabled = name ~= nil, refresh = true })
	info(c, T("fmmt_follow_pick_hint"))
end

-- ÉQUIPE / TEAM: other human players + bots ----------------------------------------------------

local function custody_entry(target)
	local ct = api("CustodyTrade")
	if target.kind ~= "human" or not ct or type(ct.custody_entry_for_peer) ~= "function" then
		return nil
	end
	return ct.custody_entry_for_peer(target.peer_id)
end

-- V18: compat entry of a human teammate (FunnyMod.CompatPeers, FMMT_VAN hello / ack), or nil.
local function mod_entry(target)
	local pinv = api("PlayerInvisibility")
	if target.kind ~= "human" or not pinv or type(pinv.peer_compat) ~= "function" then
		return nil
	end
	return pinv.peer_compat(target.peer_id)
end

-- The stored target, re-read from the live list (new unit after custody / respawn).
local function resolve_target(target)
	local tp = api("Teleport")
	if not target or not tp or type(tp.get_targets) ~= "function" then
		return target
	end
	for _, t in ipairs(tp.get_targets()) do
		if t.kind == target.kind and ((t.kind == "human" and t.peer_id == target.peer_id) or (t.kind == "bot" and t.unit == target.unit)) then
			return t
		end
	end
	return target
end

SpawnerMenu.views.team = function(c)
	header(c, T("fmmt_menu_team"))
	local tp, admin, ct = api("Teleport"), api("ModMenuAdmin"), api("CustodyTrade")
	if tp and type(tp.get_targets) == "function" then
		local n = 0
		for _, target in ipairs(tp.get_targets()) do
			if target.kind ~= "self" then
				n = n + 1
				local tags = "  [" .. T(target.kind == "bot" and "fmmt_bot" or "fmmt_human") .. "]"
				if type(tp.is_following) == "function" and tp.is_following(target) then
					tags = tags .. "  [" .. T("fmmt_tag_following") .. "]"
				end
				if custody_entry(target) then
					tags = tags .. "  [" .. T("fmmt_in_custody") .. "]"
				end
				button(c, target.name .. tags .. "   >", true, function()
					SpawnerMenu._target = target
					SpawnerMenu.show("team_member")
				end, { size = 20 })
			end
		end
		if n == 0 then
			info(c, T("fmmt_team_empty"))
		end
	else
		missing(c, "fmmt_teleport")
	end

	subtitle(c, T("fmmt_sec_team_manage"))
	if ct and type(ct.in_custody) == "function" and not hidden("custody") then
		section_link(c, "fmmt_custody", "team_custody", nil, "  (" .. #ct.in_custody() .. ")")
	end
	if admin and type(admin.get_bans) == "function" and not hidden("kick_ban") then
		section_link(c, "fmmt_sec_bans", "team_bans", nil, "  (" .. #admin.get_bans() .. ")")
	end
	button(c, T("fmmt_refresh"), true, SpawnerMenu.refresh)
end

SpawnerMenu.views.team_member = function(c)
	back_row(c, "team")
	local target = resolve_target(SpawnerMenu._target)
	local tp, admin = api("Teleport"), api("ModMenuAdmin")
	if not target or not tp then
		info(c, T("fmmt_team_empty"))
		return
	end
	SpawnerMenu._target = target
	local human = target.kind == "human"
	local unit_ok = alive(target.unit)
	header(c, target.name)

	-- TÉLÉPORTATION
	subtitle(c, T("fmmt_teleport_header"))
	action_row(c, "tp_me", T("fmmt_tp_me_to_player"), function()
		tp.me_to(target.unit)
	end, { enabled = unit_ok })
	if human then
		action_row(c, "tp_player_to_me", T("fmmt_tp_player_to_me"), function() end, { desc = "fmmt_tp_player_to_me_unsupported" })
	else
		action_row(c, "tp_bots", T("fmmt_tp_player_to_me"), function()
			tp.bot_to_me(target.unit)
		end, { enabled = unit_ok })
	end
	if type(tp.follow) == "function" and not hidden("follow") then
		local following = tp.is_following(target)
		state_row(c, "follow_player", T("fmmt_follow"), following, function(v)
			if v then
				tp.follow(target)
			else
				tp.stop_follow("menu")
			end
		end, { enabled = unit_ok or following, desc = "fmmt_desc_follow" })
	end

	-- AIDE: the same vanilla revive interaction as Auto revive (FunnyMod.RealInteract).
	local ar = api("AutoRevive")
	if ar and type(ar.is_enabled) == "function" and not hidden("auto_revive") then
		subtitle(c, T("fmmt_sec_help"))
		local ri = FunnyMod and FunnyMod.RealInteract
		local downed = unit_ok and type(ar.is_downed) == "function" and ar.is_downed(target.unit)
		action_row(c, "auto_revive", T("fmmt_revive_now"), function()
			local ok, why = ri.trigger(target.unit)
			log("[AutoRevive] Manual revive of " .. tostring(target.name) .. ": " .. (ok and "sent" or tostring(why)))
			if not ok and managers.hud and managers.hud.show_hint then
				managers.hud:show_hint({ text = T("fmmt_revive_failed", { REASON = tostring(why) }) })
			end
		end, { enabled = downed and ri ~= nil and type(ri.trigger) == "function", desc = "fmmt_desc_revive_now", no_tag = true, refresh = true })
		state_row(c, "auto_revive", T("fmmt_auto_revive_near"), ar:is_enabled(), function(v)
			ar:set_enabled(v)
		end, { desc = "fmmt_desc_auto_revive" })
	end

	-- CUSTODY (human players; team AI in custody are listed in ÉQUIPE > PRISON)
	local ct = api("CustodyTrade")
	if human and ct and not hidden("custody") then
		subtitle(c, T("fmmt_custody"))
		local entry = custody_entry(target)
		if entry then
			local count = type(ct.tradeable_count) == "function" and ct.tradeable_count() or 0
			action_row(c, "instant_trade", T("fmmt_trade_now"), function()
				local ok, reason = ct.free_with_hostage(entry.crim)
				if not ok and reason == "no_hostage" and managers.hud and managers.hud.show_hint then
					managers.hud:show_hint({ text = T("fmmt_no_tradeable_hostage") })
				end
			end, { enabled = count > 0, desc = { count > 0 and T("fmmt_tradeable_hostages", { COUNT = count }) or T("fmmt_no_tradeable_hostage") }, refresh = true })
			action_row(c, "force_respawn", T("fmmt_force_respawn"), function()
				ct.force_respawn(entry.crim)
			end, { refresh = true })
		else
			info(c, T("fmmt_not_in_custody"))
		end
	end

	-- ADMIN (never for a bot)
	if human and admin and not hidden("kick_ban") then
		subtitle(c, T("fmmt_sec_admin"))
		local qes = core()
		action_row(c, "kick_ban", T("fmmt_kick"), function()
			if not is_mp_host() then return end
			if not qes or qes.get_setting("confirm_kick") ~= false then
				confirm("kick", { id = target.peer_id, name = target.name, back = "team" })
			else
				admin.kick_peer(target.peer_id)
				SpawnerMenu.show("team")
			end
		end)
		action_row(c, "kick_ban", T("fmmt_ban"), function()
			if not is_mp_host() then return end
			if not qes or qes.get_setting("confirm_ban") ~= false then
				confirm("ban", { id = target.peer_id, name = target.name, back = "team" })
			else
				admin.ban_peer(target.peer_id)
				SpawnerMenu.show("team")
			end
		end)
	end

	-- INFOS
	subtitle(c, T("fmmt_sec_infos"))
	if human then
		info(c, T("fmmt_peer_id", { ID = tostring(target.peer_id) }) .. "   ·   " .. T("fmmt_human"))
		info(c, T("fmmt_info_custody", { VALUE = yes_no(custody_entry(target) ~= nil) }))
		local entry = mod_entry(target)
		info(c, T("fmmt_info_fmmt", { VALUE = entry and T("fmmt_mod_installed", { VERSION = tostring(entry.version) }) or T("fmmt_mod_not_detected") }), entry and COLORS.on or COLORS.off)
	else
		info(c, T("fmmt_bot") .. "   ·   " .. T("fmmt_info_custody", { VALUE = yes_no(false) }))
	end
end

SpawnerMenu.views.team_custody = function(c)
	page(c, path("fmmt_menu_team", "fmmt_custody"), "team")
	local ct = api("CustodyTrade")
	if not (ct and type(ct.in_custody) == "function") then
		missing(c, "fmmt_custody")
		return
	end
	state_row(c, "instant_trade", T("fmmt_instant_trades"), ct:instant_enabled(), function(v)
		ct:set_instant_enabled(v)
	end)
	if type(ct.converted_tradeable) == "function" then
		state_row(c, "instant_trade", T("fmmt_converted_tradeable"), ct:converted_tradeable(), function(v)
			ct:set_converted_tradeable(v)
		end)
	end
	local custody = ct.in_custody()
	if #custody == 0 then
		info(c, T("fmmt_nobody_in_custody"))
		return
	end
	local count = type(ct.tradeable_count) == "function" and ct.tradeable_count() or 0
	info(c, count > 0 and T("fmmt_tradeable_hostages", { COUNT = count }) or T("fmmt_no_tradeable_hostage"))
	for _, entry in ipairs(custody) do
		local name = tostring(entry.id)
		local session = NET.session()
		if entry.peer_id and session then
			local peer = session:peer(entry.peer_id)
			name = peer and peer:name() or name
		end
		subtitle(c, name .. " - " .. T("fmmt_in_custody"))
		action_row(c, "instant_trade", T("fmmt_trade_now"), function()
			local ok, reason = ct.free_with_hostage(entry.crim)
			if not ok and reason == "no_hostage" and managers.hud and managers.hud.show_hint then
				managers.hud:show_hint({ text = T("fmmt_no_tradeable_hostage") })
			end
		end, { enabled = type(ct.tradeable_count) ~= "function" or count > 0, refresh = true })
		action_row(c, "force_respawn", T("fmmt_force_respawn"), function()
			ct.force_respawn(entry.crim)
		end, { refresh = true })
	end
end

SpawnerMenu.views.team_bans = function(c)
	page(c, path("fmmt_menu_team", "fmmt_sec_bans"), "team")
	local admin = api("ModMenuAdmin")
	if not (admin and type(admin.get_bans) == "function") then
		missing(c, "fmmt_sec_bans")
		return
	end
	local bans = admin.get_bans()
	info(c, T("fmmt_banned_count", { COUNT = #bans }))
	for _, entry in ipairs(bans) do
		action_row(c, "kick_ban", T("fmmt_unban", { NAME = tostring(entry.name) }), function()
			admin.unban(entry.identifier)
		end, { refresh = true })
	end
	if #bans > 0 then
		action_row(c, "kick_ban", T("fmmt_unban_all"), function()
			confirm("unban_all", { name = "*", back = "team_bans" })
		end)
	end
end

SpawnerMenu.views.confirm = function(c, params)
	local questions = {
		kick = T("fmmt_confirm_kick", { NAME = tostring(params.name) }),
		ban = T("fmmt_confirm_ban", { NAME = tostring(params.name) }),
		unban_all = T("fmmt_confirm_unban_all")
	}
	back_row(c, params.back or "team")
	header(c, questions[params.action] or T("fmmt_confirm"))
	button(c, T("fmmt_yes"), is_mp_host(), function()
		local admin = api("ModMenuAdmin")
		if admin and is_mp_host() then
			if params.action == "kick" then
				admin.kick_peer(params.id)
			elseif params.action == "ban" then
				admin.ban_peer(params.id)
			elseif params.action == "unban_all" then
				admin.unban_all()
			end
		end
		SpawnerMenu.show(params.back or "team")
	end, { color = COLORS.error })
	button(c, T("fmmt_no"), true, function()
		SpawnerMenu.show(params.back or "team")
	end)
end

-- TROLL: shortcuts only (same row builders, same API, same settings as their home rows) --------

SpawnerMenu.views.troll = function(c)
	header(c, T("fmmt_menu_troll"))
	info(c, T("fmmt_troll_hint"))
	ROWS.tp_all(c)
	ROWS.convert_all(c)
	ROWS.kill_all(c)
	ROWS.vanilla_enemies(c)
	ROWS.waves(c)
	ROWS.one_shot(c)
	ROWS.auto_kill(c)
	ROWS.aimbot(c)
	ROWS.god_all(c)
	ROWS.vanish_full(c)
	ROWS.fly_noclip(c)
end

-- PARAMÈTRES / SETTINGS -----------------------------------------------------------------------

local LANGUAGES = { "auto", "fr", "en" }
local LANGUAGE_KEYS = { auto = "fmmt_lang_auto", fr = "fmmt_lang_fr", en = "fmmt_lang_en" }
local MODE_KEYS = { SOLO = "fmmt_mode_solo", HOST = "fmmt_mode_host", CLIENT = "fmmt_mode_client", MENU = "fmmt_mode_menu" }

-- Seamless Input Switch (separate mod by Lukituki6, never modified or copied here). It registers
-- its settings as a SuperBLT MenuHelper node "sis_options" (menus/options.json, parent
-- "blt_options") in the main and pause menus. The button closes this menu, opens the game's pause
-- menu with the native toggle (MenuManager:toggle_menu_state, which also pauses solo) and selects
-- that node with MenuManager:open_node IN THE SAME CALL: BLT's DelayedCalls only run from
-- GameSetupUpdate (base/req/core/DelayedCalls.lua), which is frozen while solo is paused, so a
-- delayed open_node only ran after the pause menu was closed again (V10 log: "not reachable").
-- Back returns to the pause menu and runs its own sis_flush_settings callback.
local function sis_installed()
	return type(rawget(_G, "SeamlessInputSwitch")) == "table"
end

local function pause_menu_node(name)
	local mm = managers.menu
	local registered = mm and mm._registered_menus
	local pause = registered and registered.menu_pause
	local data = pause and pause.logic and pause.logic._data
	local nodes = data and data._nodes
	return type(nodes) == "table" and nodes[name] ~= nil
end

function SpawnerMenu.open_seamless_input_switch()
	local mm = managers.menu
	if not sis_installed() or not mm then
		return false
	end
	if SpawnerMenu.menu then
		SpawnerMenu.menu:Disable()
	end
	local function fallback(reason)
		log("[ModMenu] Seamless Input Switch: " .. reason .. " -> native path shown")
		if managers.hud and managers.hud.show_hint then
			managers.hud:show_hint({ text = T("fmmt_sis_unavailable") })
		end
	end
	-- One frame so the F9 menu releases the mouse / controller before the pause menu opens
	-- (the game is not paused yet, GameSetupUpdate still runs).
	DelayedCalls:Add("FMMT_OpenSIS", 0.05, function()
		if not mm:is_open("menu_pause") then
			pcall(mm.toggle_menu_state, mm)
		end
		if not mm:is_open("menu_pause") then
			fallback("pause menu refused to open")
			return
		end
		local node = pause_menu_node("sis_options") and "sis_options" or (pause_menu_node("blt_options") and "blt_options")
		if not node then
			fallback("node sis_options missing")
			return
		end
		local ok, err = pcall(mm.open_node, mm, node)
		log("[ModMenu] Seamless Input Switch -> open_node(" .. node .. ") " .. (ok and "OK" or tostring(err)))
		if not ok then
			fallback("open_node failed")
		end
	end)
	return true
end

-- SECRET: Secret puzzle door / piano / achievements (modules in secret/, merged from the former
-- Auto Secret Door, Auto Secret Piano and Secret Logger mods).
local function secret_msg(title, text)
	if rawget(_G, "QuickMenu") then
		QuickMenu:new(title, text, { { text = "OK", is_cancel_button = true } }, true)
	end
end

local SECRET_ZONES = {
	door = { vit = true },
	piano = { chill = true, chill_combat = true },
	auto = { des = true, tag = true, family = true, nmh = true }
}

local function secret_here(kind)
	local level = managers.job and managers.job:current_level_id() or (Global.game_settings and Global.game_settings.level_id)
	return SECRET_ZONES[kind][level] == true, level
end

-- Runs fn only in the right level; otherwise explains where and how (popup).
local function secret_guard(kind, fn)
	local here, level = secret_here(kind)
	if here then
		return fn()
	end
	secret_msg(T("fmmt_secret_wrong_title"), T("fmmt_secret_zone_" .. kind) .. "

" .. T("fmmt_secret_current_level", { VALUE = tostring(level or "-") }))
end

local function zone_info(c, kind)
	local here = secret_here(kind)
	info(c, T("fmmt_secret_zone_" .. kind .. "_short") .. "  -  " .. (here and T("fmmt_secret_here") or T("fmmt_secret_not_here")), here and COLORS.on or COLORS.error)
end

SpawnerMenu.views.secret = function(c)
	header(c, T("fmmt_menu_secret"))
	info(c, T("fmmt_secret_hint"))
	local door, piano = api("AutoSecretDoor"), api("AutoSecretPiano")
	local sl, auto = api("SecretLogger"), api("SecretAuto")
	subtitle(c, T("fmmt_secret_door"))
	zone_info(c, "door")
	if door and type(door.toggle) == "function" then
		button(c, T("fmmt_secret_door_btn", { STATE = state_text(door.active == true) }), true, function()
			secret_guard("door", function()
				pcall(door.toggle, door)
			end)
			SpawnerMenu.rebuild()
		end, { help = T("fmmt_secret_door_help") })
	else
		missing(c, "fmmt_secret_door")
	end
	subtitle(c, T("fmmt_secret_piano"))
	zone_info(c, "piano")
	if piano and type(piano.trigger) == "function" then
		button(c, T("fmmt_secret_piano_btn"), true, function()
			secret_guard("piano", function()
				pcall(piano.trigger, piano)
			end)
		end, { help = T("fmmt_secret_piano_help") })
	else
		missing(c, "fmmt_secret_piano")
	end
	subtitle(c, T("fmmt_secret_logger"))
	if sl and type(sl.export) == "function" then
		button(c, T("fmmt_secret_export"), true, function()
			local ok, data = pcall(sl.export, sl, "FMMT export", true)
			secret_msg("Secret", ok and "OK" or tostring(data))
		end, { help = T("fmmt_secret_export_help") })
		local rr = sl._reroll and sl._reroll.active
		button(c, T("fmmt_secret_reroll", { STATE = state_text(rr == true) }), true, function()
			if sl._reroll and sl._reroll.active then
				sl:stop_auto_reroll("FMMT stop")
			elseif not sl:start_auto_reroll() then
				secret_msg("Secret Auto Reroll", sl:reroll_status_text())
			end
			SpawnerMenu.rebuild()
		end, { help = T("fmmt_secret_reroll_help") })
		button(c, T("fmmt_secret_status"), true, function()
			secret_msg("Secret", sl:reroll_status_text())
		end)
	else
		missing(c, "fmmt_secret_logger")
	end
	if auto and type(auto.start) == "function" then
		zone_info(c, "auto")
		button(c, T("fmmt_secret_auto", { STATE = state_text(auto.active == true) }), true, function()
			if auto.active then
				auto:stop("FMMT stop")
			else
				secret_guard("auto", function()
					if not auto:start() then
						secret_msg("AUTO COMPLETE", T("fmmt_secret_auto_fail"))
					end
				end)
			end
			SpawnerMenu.rebuild()
		end, { help = T("fmmt_secret_auto_help") })
		button(c, T("fmmt_secret_status"), true, function()
			secret_msg("AUTO COMPLETE", type(auto.status_text) == "function" and auto:status_text() or "-")
		end)
	else
		missing(c, "fmmt_secret_auto_name")
	end
end

SpawnerMenu.views.settings = function(c)
	header(c, T("fmmt_menu_settings"))
	section_link(c, "fmmt_sec_interface", "set_ui")
	section_link(c, "fmmt_network", "set_net")
	section_link(c, "fmmt_gamepad", "set_pad")
	section_link(c, "fmmt_sec_performance", "set_perf")
	section_link(c, "fmmt_sec_about", "set_about")
	info(c, T("fmmt_autosave"))
end

SpawnerMenu.views.set_ui = function(c)
	page(c, path("fmmt_menu_settings", "fmmt_sec_interface"), "settings")
	local qes = core()
	if not qes then
		missing(c, "fmmt_menu_settings")
		return
	end
	local lang = qes.get_setting("language") or "auto"
	button(c, T("fmmt_language", { VALUE = T(LANGUAGE_KEYS[lang] or "fmmt_lang_auto") }), true, function()
		local nxt = cycle(LANGUAGES, qes.get_setting("language") or "auto")
		qes.set_setting("language", nxt)
		SpawnerMenu._catalog_entries = nil
		mlog("Language -> " .. nxt)
		SpawnerMenu.rebuild()
	end)
	local hide = hide_host_only()
	button(c, T("fmmt_hide_host_only_short") .. " : " .. state_text(hide), true, function()
		qes.set_setting("hide_host_only", not hide_host_only())
		mlog("Hide host-only options -> " .. onoff(not hide))
		SpawnerMenu.rebuild()
	end, { help = describe(nil, "fmmt_desc_hide_host_only"), color = hide and COLORS.on or COLORS.off })
	state_row(c, nil, T("fmmt_show_descriptions"), qes.get_setting("show_descriptions") ~= false, function(v)
		set_setting("show_descriptions", v, "Show descriptions")
	end, { desc = "fmmt_desc_show_descriptions" })
	state_row(c, nil, T("fmmt_show_net_tags"), qes.get_setting("show_net_tags") ~= false, function(v)
		set_setting("show_net_tags", v, "Show network tags")
	end, { desc = "fmmt_desc_show_net_tags" })
end

SpawnerMenu.views.set_net = function(c)
	page(c, path("fmmt_menu_settings", "fmmt_network"), "settings")
	local mode = NET.mode()
	info(c, T("fmmt_network_mode", { MODE = T(MODE_KEYS[mode] or "fmmt_mode_menu") }))
	local host = NET.is_host()
	info(c, T("fmmt_network_host", { STATE = yes_no(host) }), host and COLORS.on or COLORS.host)
	-- V18: players that answered the FMMT_VAN hello / ack handshake (local player included).
	local pinv = api("PlayerInvisibility")
	if NET.has_session() and not NET.is_singleplayer() and pinv and type(pinv.compat_list) == "function" then
		local list, total = pinv.compat_list()
		section_link(c, "fmmt_network_compat_players", "set_net_peers", nil, " : " .. #list .. " / " .. total)
	else
		info(c, T("fmmt_network_compat_players") .. " : -")
	end
	local qes = core()
	if not qes then
		return
	end
	state_row(c, nil, T("fmmt_join_chat"), qes.get_setting("join_chat_message") ~= false, function(v)
		set_setting("join_chat_message", v, "Join chat message")
	end, { desc = "fmmt_desc_join_chat" })
	subtitle(c, T("fmmt_sec_admin"))
	state_row(c, nil, T("fmmt_confirm_kick_setting"), qes.get_setting("confirm_kick"), function(v)
		set_setting("confirm_kick", v, "Confirm kick")
	end)
	state_row(c, nil, T("fmmt_confirm_ban_setting"), qes.get_setting("confirm_ban"), function(v)
		set_setting("confirm_ban", v, "Confirm ban")
	end)
end

SpawnerMenu.views.set_net_peers = function(c)
	page(c, path("fmmt_menu_settings", "fmmt_network") .. "  >  " .. T("fmmt_compat_players_title"), "set_net")
	local pinv = api("PlayerInvisibility")
	if not (pinv and type(pinv.compat_list) == "function") or not NET.has_session() then
		info(c, T("fmmt_compat_none"))
		return
	end
	local list, total = pinv.compat_list()
	info(c, T("fmmt_network_compat_players") .. " : " .. #list .. " / " .. total)
	for _, e in ipairs(list) do
		info(c, "- " .. tostring(e.name) .. "  -  v" ..tostring(e.version) .. (e.is_local and ("  (" .. T("fmmt_you") .. ")") or ""), COLORS.on)
	end
	info(c, T("fmmt_compat_hint"))
	button(c, T("fmmt_refresh"), true, SpawnerMenu.refresh)
end

SpawnerMenu.views.set_pad = function(c)
	page(c, path("fmmt_menu_settings", "fmmt_gamepad"), "settings")
	local sis = sis_installed()
	info(c, T("fmmt_sis_status", { STATE = sis and T("fmmt_installed") or T("fmmt_not_installed") }), sis and COLORS.on or COLORS.off)
	button(c, T("fmmt_sis_open"), sis, function()
		SpawnerMenu.open_seamless_input_switch()
	end, { help = describe(nil, "fmmt_sis_hint") })
end

SpawnerMenu.views.set_perf = function(c)
	page(c, path("fmmt_menu_settings", "fmmt_sec_performance"), "settings")
	local qes = core()
	if not qes then
		missing(c, "fmmt_menu_settings")
		return
	end
	state_row(c, nil, T("fmmt_debug_perf"), qes.get_setting("debug_perf") == true, function(v)
		set_setting("debug_perf", v, "Debug perf")
	end, { desc = "fmmt_desc_debug_perf" })
	state_row(c, nil, T("fmmt_debug_auto_actions"), qes.get_setting("debug_auto_actions") == true, function(v)
		set_setting("debug_auto_actions", v, "Debug auto actions")
	end, { desc = "fmmt_desc_debug_auto_actions" })
	state_row(c, nil, T("fmmt_logs"), qes.get_setting("show_qes_logs") ~= false, function(v)
		qes.set_setting("show_qes_logs", v)
		qes.set_setting("show_admin_logs", v)
		log("[ModMenu] Logs -> " .. onoff(v))
	end, { desc = "fmmt_desc_logs" })
end

SpawnerMenu.views.set_about = function(c)
	page(c, path("fmmt_menu_settings", "fmmt_sec_about"), "settings")
	local fmm = api("FunnyModMenu")
	info(c, T("fmmt_title"))
	info(c, T("fmmt_version", { VERSION = fmm and fmm.VERSION or "?" }))
	-- Credits: clickable -> https://elexyr22.fr/ (FunnyModMenu.open_website).
	button(c, T("fmmt_credits_dev"), true, function()
		if fmm and type(fmm.open_website) == "function" then
			fmm.open_website()
		end
	end, { size = 20, help = fmm and fmm.WEBSITE or nil })
end

-- Menu shell ----------------------------------------------------------------------------------

local function build_nav(nav)
	local fmm = api("FunnyModMenu")
	nav:ClearItems()
	nav:Divider({ text = T("fmmt_title"), background_color = Color.white, size = 20 })
	for _, cat in ipairs(SpawnerMenu.CATEGORIES) do
		-- With "hide host-only options", the spawner category (host only as a whole) disappears.
		if not (cat.id == "spawner" and hidden("spawner")) then
			nav:Button({
				text = T(cat.key),
				size = 21,
				on_callback = function()
					SpawnerMenu.show(cat.id)
				end
			})
		end
	end
	nav:Button({
		text = T("fmmt_close"),
		size = 16,
		on_callback = function()
			if SpawnerMenu.menu then
				SpawnerMenu.menu:Disable()
			end
		end
	})
	nav:Divider({ text = "----------------------", size = 14 })
	-- Credits: a single clickable line -> https://elexyr22.fr/ (FunnyModMenu.open_website).
	nav:Button({
		text = T("fmmt_credits_dev"),
		size = 16,
		on_callback = function()
			if fmm and type(fmm.open_website) == "function" then
				fmm.open_website()
			end
		end
	})
	nav:Divider({ text = "v" .. (fmm and fmm.VERSION or "?"), size = 14 })
end

-- Rebuilds navigation labels and the current view (used when the language changes).
function SpawnerMenu.rebuild()
	if SpawnerMenu.nav then
		build_nav(SpawnerMenu.nav)
	end
	SpawnerMenu.refresh()
end

SpawnerMenu.menu = SpawnerMenu.menu or MenuUI:new({
	name = "FunnyModMenuTroll",
	layer = 1000,
	background_blur = true,
	animate_toggle = true,
	offset = 0,
	text_offset = 4,
	-- Item descriptions ("help") appear quickly on hover.
	show_help_time = 0.35,
	use_default_close_key = true,
	disable_player_controls = true,
	create_items = function(menu)
		local w = menu._panel:w() * 0.7
		local h = menu._panel:h() * 0.8
		SpawnerMenu.panel_h = h

		local root = menu:Menu({
			name = "fmmt_root",
			w = w,
			h = h,
			auto_height = false,
			position = "CenterCenter",
			align_method = "grid",
			background_color = Color.black:with_alpha(0.6),
			size = 18
		})

		SpawnerMenu.nav = root:Menu({
			name = "fmmt_nav",
			w = w * 0.24,
			h = h,
			auto_height = false,
			background_color = Color.black:with_alpha(0.3),
			size = 20
		})
		build_nav(SpawnerMenu.nav)

		SpawnerMenu.content = root:Menu({
			name = "fmmt_content",
			w = w * 0.74,
			h = h,
			auto_height = false,
			size = 18
		})
	end
})

if SpawnerMenu.menu:Enabled() then
	SpawnerMenu.menu:Disable()
else
	mlog("Opened (" .. NET.mode() .. ")")
	local id = SpawnerMenu.current_view and SpawnerMenu.current_view.id
	if RENAMED_VIEWS[id] then
		SpawnerMenu.current_view = { id = RENAMED_VIEWS[id] }
	elseif (id == "spawner" or (id and id:find("^spawner_"))) and hidden("spawner") then
		SpawnerMenu.current_view = { id = "combat" }
	end
	if SpawnerMenu.nav then
		build_nav(SpawnerMenu.nav)
	end
	SpawnerMenu.menu:Enable()
	SpawnerMenu.render()
end
