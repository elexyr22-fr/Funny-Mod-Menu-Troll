--[[
	Secret Logger - read-only export of YOUR 20 PAYDAY 2 Secret achievements.

	Where the game keeps the selection (decompiled lib/managers/custom_safehouse/unoachievementchallenge.lua):
	  * UnoAchievementChallenge:generate_challenge() shuffles tweak_data.safehouse.uno_achievements_pool
	    (57 ids), removes ids of DLCs you do not own, keeps 20 and stores them in
	    Global.custom_safehouse_manager.uno_achievements_challenge.challenge (saved in your save file).
	  * managers.custom_safehouse:uno_achievement_challenge():challenge() returns that list.
	  * The game itself checks completion with managers.achievment:get_info(id).awarded.

	This mod only reads that list, the achievement manager and the localization.
	Export never changes anything. Only the optional Auto Reroll (menu button) calls generate_challenge
	(the function the piano triggers) and save_progress once when it stops. Nothing ever calls award,
	stats or network functions.
]]

SecretLogger = SecretLogger or {}
local SL = SecretLogger

if not SL._core then
	SL._core = true
	SL.mod_path = ModPath or "mods/SecretLogger/"
	SL.logs_dir = SL.mod_path .. "logs/"
	SL.txt_path = SL.logs_dir .. "secret_achievements.txt"
	SL.json_path = SL.logs_dir .. "secret_achievements.json"
	SL.debug_path = SL.logs_dir .. "debug.txt"
	SL.EXPECTED_COUNT = 20
	SL.DEBUG_MAX_SIZE = 512 * 1024
	SL.RETRY_DELAY = 5
	SL.RETRY_MAX = 120

	local function ensure_logs_dir()
		if SL._dir_ok then
			return
		end

		pcall(function()
			local dir = SL.logs_dir:sub(1, -2)

			if file and file.DirectoryExists and not file.DirectoryExists(dir) then
				file.CreateDirectory(dir)
			end
		end)

		SL._dir_ok = true
	end

	local function read_file(path)
		local f = io.open(path, "r")

		if not f then
			return nil
		end

		local content = f:read("*all")

		f:close()

		return content
	end

	local function write_file(path, content)
		ensure_logs_dir()

		local f, err = io.open(path, "w")

		if not f then
			return false, err
		end

		f:write(content)
		f:close()

		return true
	end

	function SL:debug(msg)
		ensure_logs_dir()

		if not self._debug_rotated then
			self._debug_rotated = true

			local f = io.open(self.debug_path, "r")

			if f then
				local size = f:seek("end")

				f:close()

				if size and size > self.DEBUG_MAX_SIZE then
					os.remove(self.debug_path .. ".old")
					os.rename(self.debug_path, self.debug_path .. ".old")
				end
			end
		end

		local line = os.date("[%Y-%m-%d %H:%M:%S] ") .. tostring(msg)
		local f = io.open(self.debug_path, "a")

		if f then
			f:write(line .. "\n")
			f:close()
		end

		log("[SecretLogger] " .. tostring(msg))
	end

	local function safe(func, ...)
		local ok, res = pcall(func, ...)

		if not ok then
			SL:debug("ERREUR: " .. tostring(res))

			return nil
		end

		return res
	end

	local function localize(id)
		if not id or not managers.localization then
			return nil
		end

		local ok, exists = pcall(managers.localization.exists, managers.localization, id)

		if ok and exists == false then
			return nil
		end

		local ok2, text = pcall(managers.localization.text, managers.localization, id)

		return ok2 and text or nil
	end

	-- Returns a copy of the personal 20-id selection, or nil + reason.
	function SL:get_challenge()
		local list

		if managers.custom_safehouse and managers.custom_safehouse.uno_achievement_challenge then
			local ok, challenge = pcall(function()
				return managers.custom_safehouse:uno_achievement_challenge():challenge()
			end)

			if ok and type(challenge) == "table" then
				list = challenge
			end
		end

		if not list then
			local g = Global.custom_safehouse_manager and Global.custom_safehouse_manager.uno_achievements_challenge

			if g and type(g.challenge) == "table" then
				list = g.challenge
			end
		end

		if not list then
			if not managers.custom_safehouse and not Global.custom_safehouse_manager then
				return nil, "CustomSafehouseManager pas encore charge"
			end

			return nil, "aucune selection du Secret dans la sauvegarde (challenge = nil)"
		end

		local copy, seen = {}, {}

		for _, id in ipairs(list) do
			if type(id) == "string" and not seen[id] then
				seen[id] = true
				table.insert(copy, id)
			elseif seen[id] then
				self:debug("Doublon ignore: " .. tostring(id))
			end
		end

		return copy
	end

	local function pool_info()
		local pool, pool_set, dlc_of = {}, {}, {}
		local sh = tweak_data and tweak_data.safehouse

		if sh and type(sh.uno_achievements_pool) == "table" then
			pool = sh.uno_achievements_pool

			for _, id in ipairs(pool) do
				pool_set[id] = true
			end
		end

		if sh and type(sh.uno_achievements_pool_ip) == "table" then
			for dlc, ids in pairs(sh.uno_achievements_pool_ip) do
				for _, id in pairs(ids) do
					dlc_of[id] = dlc
				end
			end
		end

		return pool, pool_set, dlc_of
	end

	function SL:collect()
		local ids, reason = self:get_challenge()

		if not ids then
			return nil, reason
		end

		local pool, pool_set, dlc_of = pool_info()
		local entries, completed = {}, 0

		for i, id in ipairs(ids) do
			local info = managers.achievment and managers.achievment:get_info(id)
			local visual = tweak_data.achievement and tweak_data.achievement.visual and tweak_data.achievement.visual[id] or {}
			local name_id = visual.name_id or "achievement_" .. id
			local desc_id = visual.desc_id or "achievement_" .. id .. "_desc"
			local unlocked = info and info.awarded == true or (self._session_awarded and self._session_awarded[id]) or false
			local unlock_time = info and tonumber(info.unlock_time)

			if unlocked then
				completed = completed + 1
			end

			entries[i] = {
				index = i,
				id = id,
				name = localize(name_id) or id,
				description = localize(desc_id) or "",
				unlocked = unlocked,
				platform_id = info and info.id or nil,
				internal_name = info and info.name or nil,
				name_id = name_id,
				desc_id = desc_id,
				unlock_time = unlock_time and unlock_time > 0 and os.date("%Y-%m-%d %H:%M:%S", unlock_time) or nil,
				dlc_required = dlc_of[id],
				in_secret_pool = pool_set[id] == true,
				known_achievement = info ~= nil
			}
		end

		return {
			ids = ids,
			entries = entries,
			count = #entries,
			completed = completed,
			remaining = #entries - completed,
			pool_size = #pool,
			pool_set = pool_set,
			-- fetch_achievments() always sets oldest_achievement_date (number) once the platform answered.
			fetched = self._fetched == true or managers.achievment ~= nil and managers.achievment.oldest_achievement_date ~= nil or completed > 0
		}
	end

	-- Checks that the list is the personal selection and not the global pool.
	function SL:validate(data)
		local ok = true

		if data.count == self.EXPECTED_COUNT then
			self:debug("OK: exactement " .. self.EXPECTED_COUNT .. " achievements trouves")
		else
			ok = false
			self:debug("ATTENTION: " .. data.count .. " achievements trouves au lieu de " .. self.EXPECTED_COUNT)
		end

		if data.pool_size > 0 and data.count >= data.pool_size then
			ok = false
			self:debug("ATTENTION: la liste a la taille du pool global (" .. data.pool_size .. "), ce n'est pas une selection personnelle")
		else
			self:debug("Source: selection personnelle (UnoAchievementChallenge:challenge(), sauvegarde), pool global = " .. data.pool_size .. " ids")
		end

		for _, e in ipairs(data.entries) do
			if not e.in_secret_pool then
				ok = false
				self:debug("ATTENTION: " .. e.id .. " n'est pas dans tweak_data.safehouse.uno_achievements_pool")
			end

			if not e.known_achievement then
				ok = false
				self:debug("ATTENTION: " .. e.id .. " inconnu de managers.achievment")
			end
		end

		return ok
	end

	local function pad2(n)
		return string.format("%02d", n)
	end

	function SL:build_txt(data)
		local sep = string.rep("=", 50)
		local out = {}
		local function add(s)
			table.insert(out, s or "")
		end

		add(sep)
		add("PAYDAY 2 - THE SECRET")
		add("Achievements requis : " .. data.count)
		add("Mis a jour : " .. os.date("%Y-%m-%d %H:%M:%S"))

		if not data.fetched then
			add("NOTE : statut Steam/Epic pas encore recu, les etats debloque peuvent etre incomplets")
		end

		add(sep)
		add()

		for _, e in ipairs(data.entries) do
			add("[" .. pad2(e.index) .. "]")
			add("Achievement ID : " .. e.id)
			add("Nom : " .. e.name)
			add("Description : " .. e.description)
			add("Deja debloque : " .. (e.unlocked and "OUI" or "NON"))

			if e.unlock_time then
				add("Debloque le : " .. e.unlock_time)
			end

			if e.platform_id and e.platform_id ~= e.id then
				add("ID plateforme : " .. tostring(e.platform_id))
			end

			if e.dlc_required then
				add("DLC requis : " .. e.dlc_required)
			end

			add()
		end

		add(sep)
		add("PROGRESSION")
		add("Debloques : " .. data.completed .. "/" .. data.count)
		add("Restants : " .. data.remaining .. "/" .. data.count)
		add(sep)
		add()
		add("ACHIEVEMENTS RESTANTS :")

		local any = false

		for _, e in ipairs(data.entries) do
			if not e.unlocked then
				any = true
				add("- [" .. pad2(e.index) .. "] " .. e.name .. " (" .. e.id .. ") : " .. e.description)
			end
		end

		if not any then
			add("- Aucun, les 20 sont debloques !")
		end

		add()

		return table.concat(out, "\n")
	end

	-- Small ordered JSON writer (stable key order, readable diff).
	local function json_str(s)
		s = tostring(s)
		s = s:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
		s = s:gsub("[%z\1-\31]", function(c)
			return string.format("\\u%04x", c:byte())
		end)

		return "\"" .. s .. "\""
	end

	local function json_val(v)
		if v == nil then
			return "null"
		elseif type(v) == "boolean" then
			return v and "true" or "false"
		elseif type(v) == "number" then
			return tostring(v)
		end

		return json_str(v)
	end

	local ENTRY_KEYS = {
		"index",
		"id",
		"name",
		"description",
		"unlocked",
		"unlock_time",
		"platform_id",
		"internal_name",
		"name_id",
		"desc_id",
		"dlc_required"
	}

	function SL:build_json(data)
		local out = {
			"{",
			"  \"count\": " .. data.count .. ",",
			"  \"completed\": " .. data.completed .. ",",
			"  \"remaining\": " .. data.remaining .. ",",
			"  \"expected_count\": " .. self.EXPECTED_COUNT .. ",",
			"  \"valid\": " .. json_val(data.valid) .. ",",
			"  \"unlock_status_fetched\": " .. json_val(data.fetched) .. ",",
			"  \"source\": \"managers.custom_safehouse:uno_achievement_challenge():challenge()\",",
			"  \"updated\": " .. json_str(os.date("%Y-%m-%d %H:%M:%S")) .. ",",
			"  \"achievements\": ["
		}

		for i, e in ipairs(data.entries) do
			local fields = {}

			for _, k in ipairs(ENTRY_KEYS) do
				table.insert(fields, "      " .. json_str(k) .. ": " .. json_val(e[k]))
			end

			table.insert(out, "    {")
			table.insert(out, table.concat(fields, ",\n"))
			table.insert(out, "    }" .. (i < #data.entries and "," or ""))
		end

		table.insert(out, "  ]")
		table.insert(out, "}")

		return table.concat(out, "\n") .. "\n"
	end

	local function strip_date(s)
		return s and s:gsub("Mis a jour : [^\n]*", ""):gsub("\"updated\": \"[^\"]*\"", "") or nil
	end

	-- Appends the selection to selection_history.txt each time it differs from the last one
	-- recorded (the game draws a new selection every time the piano puzzle is solved).
	SL.history_path = SL.logs_dir .. "selection_history.txt"

	function SL:record_history(data)
		local key = table.concat(data.ids, ",")
		local content = read_file(self.history_path) or ""
		local last

		for line in content:gmatch("IDS: ([^\n]*)") do
			last = line
		end

		if last == key then
			return
		end

		if last then
			self:debug("ATTENTION: la selection du Secret a CHANGE depuis le dernier export (nouveau tirage du jeu)")

			if managers.hud then
				pcall(managers.hud.show_hint, managers.hud, { text = "Secret Logger : nouvelle selection du Secret detectee", time = 4 })
			end
		end

		local names = {}

		for _, e in ipairs(data.entries) do
			table.insert(names, string.format("  %s%s - %s", e.unlocked and "[X] " or "[ ] ", e.id, e.name))
		end

		ensure_logs_dir()

		local f = io.open(self.history_path, "a")

		if f then
			f:write(string.format("=== %s  (%d/%d debloques)\nIDS: %s\n%s\n\n", os.date("%Y-%m-%d %H:%M:%S"), data.completed, data.count, key, table.concat(names, "\n")))
			f:close()
		end
	end

	-- Export the files. force = rewrite even if nothing changed.
	function SL:export(reason, force)
		self:debug("Export demande (" .. tostring(reason) .. ")")

		local data, err = self:collect()

		if not data then
			self:debug("Liste du Secret non disponible: " .. tostring(err))
			self:schedule_retry()

			return false, err
		end

		self._retries = 0
		self:debug("Secret detecte: " .. data.count .. " achievements dans la selection")
		self:debug("IDs: " .. table.concat(data.ids, ", "))
		data.valid = self:validate(data)
		self:debug(string.format("Progression: %d/%d debloques, %d restants (statut plateforme recu: %s)", data.completed, data.count, data.remaining, data.fetched and "oui" or "non"))

		self:record_history(data)

		local txt = self:build_txt(data)
		local json = self:build_json(data)

		if not force and strip_date(txt) == strip_date(read_file(self.txt_path)) and strip_date(json) == strip_date(read_file(self.json_path)) then
			self:debug("Aucun changement, fichiers conserves")
			self._last_data = data

			return true, data
		end

		local ok1, e1 = write_file(self.txt_path, txt)
		local ok2, e2 = write_file(self.json_path, json)

		if ok1 and ok2 then
			self:debug("Fichiers ecrits: " .. self.txt_path .. " et " .. self.json_path)
		else
			self:debug("ERREUR ecriture: " .. tostring(e1 or e2))
		end

		self._last_data = data

		return ok1 and ok2, data
	end

	function SL:schedule_retry()
		if not DelayedCalls then
			return
		end

		self._retries = (self._retries or 0) + 1

		if self._retries > self.RETRY_MAX then
			self:debug("Abandon des tentatives automatiques (utiliser le bouton Export)")

			return
		end

		DelayedCalls:Add("SecretLogger_retry", self.RETRY_DELAY, function()
			safe(SL.export, SL, "nouvelle tentative " .. tostring(SL._retries))
		end)
	end

	-- Deferred export so several triggers in the same moment produce one write.
	function SL:request_export(reason)
		if not DelayedCalls then
			return safe(self.export, self, reason)
		end

		DelayedCalls:Add("SecretLogger_export", 1, function()
			safe(SL.export, SL, reason)
		end)
	end

	function SL:is_in_challenge(id)
		local ids = self:get_challenge()

		for _, v in ipairs(ids or {}) do
			if v == id then
				return true
			end
		end

		return false
	end

	--[[ AUTO REROLL SECRET

		Reroll: solving the piano runs UnoAchievementChallenge:generate_challenge(), which draws 20 new
		ids from tweak_data.safehouse.uno_achievements_pool (it already drops the berry / mad / spa /
		rvd ids when that DLC is not owned) and saves. The auto reroll calls the same function with
		trigger_save = false for every attempt and saves ONCE (managers.savefile:save_progress(),
		exactly what the game does) when it stops, so the save always holds a list the game drew.

		DLC check: each pool id is mapped to the heist(s) it is done on (from its achievement icon in
		generatedachievementtweakdata), and the heist's tweak_data.narrative.jobs[job].dlc is checked
		live with managers.dlc:is_dlc_unlocked() (owned or free on this install/platform). An id with
		an unknown heist is treated as blocked (never accepted by mistake).
	]]
	SL.REROLL_DELAY = 0
	SL.REROLL_BATCH = 25
	SL.REROLL_MAX = 50000
	SL.ACH_JOBS = {
		armored_1 = { "arm_for" },
		armored_2 = { "arm_cro", "arm_und", "arm_hcm", "arm_fac", "arm_par" },
		bat_2 = { "mus" },
		berry_2 = { "pbr" },
		bigbank_5 = { "big" },
		bob_3 = { "election_day" },
		born_5 = { "born" },
		bph_11 = { "bph" },
		brb_8 = { "brb" },
		cac_13 = { "mad" },
		cac_26 = { "hox" },
		cac_9 = { "flat" },
		cane_2 = { "cane" },
		charliesierra_5 = { "roberts" },
		cow_10 = { "crojob1" },
		cow_4 = { "crojob2" },
		dah_9 = { "dah" },
		dark_3 = { "dark" },
		diamonds_are_forever = { "jewelry_store" },
		doctor_fantastic = { "welcome_to_the_jungle_wrapper" },
		fish_5 = { "fish" },
		fort_4 = { "cage" },
		green_6 = { "red2" },
		halloween_2 = { "alex" },
		i_wasnt_even_there = { "framing_frame" },
		jerry_4 = { "pbr2" },
		kenaz_4 = { "kenaz" },
		kosugi_2 = { "kosugi" },
		lets_do_this = { "ukrainian_job" },
		live_2 = { "arena" },
		lord_of_war = { "firestarter" },
		man_2 = { "man" },
		melt_3 = { "shoutout_raid" },
		moon_5 = { "moon" },
		nmh_10 = { "nmh" },
		pal_2 = { "pal" },
		payback_2 = { "hox_3" },
		peta_3 = { "peta" },
		pig_2 = { "mia" },
		run_10 = { "run" },
		rvd_11 = { "rvd" },
		sah_10 = { "sah" },
		spa_5 = { "spa" },
		tag_10 = { "tag" },
		trk_af_3 = { "jolly" },
		trk_fs_3 = { "four_stores" },
		trk_sh_3 = { "dinner" },
		uno_1 = { "branchbank", "branchbank_gold", "branchbank_cash", "branchbank_deposit" },
		uno_2 = { "family" },
		uno_3 = { "mallcrasher" },
		uno_4 = { "glace" },
		uno_5 = { "des" },
		uno_6 = { "nightclub" },
		uno_7 = { "friend" },
		uno_8 = { "watchdogs_wrapper" },
		uno_9 = { "pines" },
		wwh_9 = { "wwh" }
	}

	SL._reroll = SL._reroll or { active = false, attempts = 0, rerolls = 0 }

	-- During a reroll step lines are buffered and written to debug.txt in one go (many attempts per frame).
	local rbuf

	local function rlog(msg)
		msg = "[SecretAutoReroll] " .. msg

		if rbuf then
			table.insert(rbuf, msg)
			log("[SecretLogger] " .. msg)
		else
			SL:debug(msg)
		end
	end

	local function rflush()
		local lines = rbuf

		rbuf = nil

		if not lines or #lines == 0 then
			return
		end

		ensure_logs_dir()

		local f = io.open(SL.debug_path, "a")

		if f then
			local stamp = os.date("[%Y-%m-%d %H:%M:%S] ")

			for _, line in ipairs(lines) do
				f:write(stamp .. line .. "\n")
			end

			f:close()
		end
	end

	-- Max attempts, configurable in the menu, kept in SavePath.
	SL.max_path = (SavePath or "mods/saves/") .. "secret_logger_reroll_max.txt"

	do
		local saved = tonumber(read_file(SL.max_path) or "")

		if saved and saved >= 1 then
			SL.REROLL_MAX = math.floor(saved)
		end
	end

	function SL:set_reroll_max(value)
		value = math.max(100, math.floor((tonumber(value) or self.REROLL_MAX) / 100 + 0.5) * 100)
		self.REROLL_MAX = value
		write_file(self.max_path, tostring(value))
	end

	local function job_name(job_id)
		local job = tweak_data.narrative and tweak_data.narrative.jobs and tweak_data.narrative.jobs[job_id]

		return job and localize(job.name_id) or job_id
	end

	-- true | false, dlc
	function SL:job_available(job_id)
		local jobs = tweak_data.narrative and tweak_data.narrative.jobs
		local job = jobs and jobs[job_id]

		if not job then
			return false, "casse inconnu"
		end

		if job.dlc then
			local ok, unlocked = pcall(managers.dlc.is_dlc_unlocked, managers.dlc, job.dlc)

			if not ok or not unlocked then
				return false, job.dlc
			end
		end

		return true
	end

	-- nil when doable with what is installed/owned, otherwise a readable reason.
	function SL:dlc_blocker(id)
		local jobs = self.ACH_JOBS[id]

		if not jobs then
			return "casse inconnu pour cet achievement"
		end

		local reasons = {}

		for _, job_id in ipairs(jobs) do
			local ok, dlc = self:job_available(job_id)

			if ok then
				return nil
			end

			table.insert(reasons, job_name(job_id) .. " [dlc " .. tostring(dlc) .. "]")
		end

		return table.concat(reasons, ", ")
	end

	function SL:analyze(ids)
		local result = { count = #ids, unlocked = 0, remaining = 0, blockers = {} }

		for _, id in ipairs(ids) do
			local info = managers.achievment and managers.achievment:get_info(id)

			if info and info.awarded or (self._session_awarded and self._session_awarded[id]) then
				result.unlocked = result.unlocked + 1
			else
				result.remaining = result.remaining + 1

				local reason = self:dlc_blocker(id)

				if reason then
					table.insert(result.blockers, { id = id, reason = reason })
				end
			end
		end

		return result
	end

	function SL:reroll_status_text()
		local r = self._reroll
		local lines = {
			"Etat : " .. (r.active and "ON" or "OFF"),
			"Tentatives : " .. r.attempts .. " (rerolls : " .. r.rerolls .. ")"
		}

		if r.last_blocker then
			table.insert(lines, "Dernier DLC bloquant : " .. r.last_blocker)
		end

		if r.best then
			table.insert(lines, string.format("Meilleur tirage vu : %d DLC bloquant(s), %d/%d debloques", r.best.blockers, r.best.unlocked, r.best.count))
		end

		if r.result then
			table.insert(lines, r.result)
		end

		return table.concat(lines, "\n")
	end

	local function uno()
		local ok, challenge = pcall(function()
			return managers.custom_safehouse:uno_achievement_challenge()
		end)

		return ok and challenge or nil
	end

	function SL:start_auto_reroll()
		local r = self._reroll

		if r.active then
			rlog("Deja en cours, ignore")

			return false
		end

		local challenge = uno()

		if not challenge or not challenge.generate_challenge or not managers.dlc or not managers.achievment then
			rlog("Impossible: managers du Secret non charges (attendre le menu principal)")

			return false
		end

		-- Unlock states are loaded once any achievement reads as awarded (Epic does not always set
		-- oldest_achievement_date nor go through fetch_achievments).
		local any_awarded = false

		for _, info in pairs(managers.achievment.achievments or {}) do
			if info.awarded then
				any_awarded = true

				break
			end
		end

		if not self._fetched and not managers.achievment.oldest_achievement_date and not any_awarded then
			rlog("Impossible: statut des achievements pas encore recu de la plateforme, reessayer dans quelques secondes")

			return false
		end

		self._reroll = { active = true, attempts = 0, rerolls = 0, max = self.REROLL_MAX }
		DelayedCalls:Remove("SecretLogger_reroll")
		rlog("===== AUTO REROLL demarre (max " .. self.REROLL_MAX .. " tentatives) =====")

		-- What the game itself reports for each DLC used by the pool's heists (owned or free).
		local seen, status = {}, {}

		for _, jobs in pairs(self.ACH_JOBS) do
			for _, job_id in ipairs(jobs) do
				local job = tweak_data.narrative.jobs[job_id]

				if job and job.dlc and not seen[job.dlc] then
					seen[job.dlc] = true

					local ok, unlocked = pcall(managers.dlc.is_dlc_unlocked, managers.dlc, job.dlc)

					table.insert(status, job.dlc .. "=" .. ((ok and unlocked) and "OK" or "NON"))
				elseif not job then
					rlog("ATTENTION: casse " .. job_id .. " inconnu de tweak_data.narrative (achievements lies refuses)")
				end
			end
		end

		table.sort(status)
		rlog("DLC selon le jeu : " .. table.concat(status, ", "))
		DelayedCalls:Add("SecretLogger_reroll", 0.1, function()
			safe(SL._reroll_step, SL)
		end)

		return true
	end

	-- reason: text; good = GOOD ROLL found.
	function SL:stop_auto_reroll(reason, good)
		local r = self._reroll

		if not r.active then
			return
		end

		rflush()
		r.active = false
		DelayedCalls:Remove("SecretLogger_reroll")
		r.result = reason
		rlog(reason)

		if r.rerolls > 0 then
			-- Same save call as generate_challenge() makes on its own after a piano reroll.
			local ok, err = pcall(managers.savefile.save_progress, managers.savefile)

			rlog(ok and "Tirage final sauvegarde (save_progress)" or "ERREUR sauvegarde: " .. tostring(err))
		end

		self:export(good and "GOOD ROLL" or "auto reroll arrete", true)

		local text = reason .. "\n\n" .. self:reroll_status_text()

		if managers.hud then
			pcall(managers.hud.show_hint, managers.hud, { text = reason, time = 6 })
		end

		pcall(function()
			QuickMenu:new("Secret Auto Reroll", text, { { text = "OK", is_cancel_button = true } }, true)
		end)
	end

	-- One attempt: analyse the current list, accept it or reroll once. true = continue.
	function SL:_reroll_attempt()
		local r = self._reroll

		if not r.active then
			return
		end

		local challenge = uno()
		local ids = self:get_challenge()

		if not challenge or not ids then
			return self:stop_auto_reroll("ARRET: selection du Secret introuvable")
		end

		r.attempts = r.attempts + 1

		local a = self:analyze(ids)

		rlog("Tentative #" .. r.attempts)
		rlog(string.format("%d/%d deja debloques, %d restants", a.unlocked, a.count, a.remaining))

		if not r.best or #a.blockers < r.best.blockers or (#a.blockers == r.best.blockers and a.unlocked > r.best.unlocked) then
			r.best = { blockers = #a.blockers, unlocked = a.unlocked, count = a.count }
		end

		if a.count == self.EXPECTED_COUNT and #a.blockers == 0 then
			rlog("Aucun DLC necessaire")

			return self:stop_auto_reroll(string.format("GOOD ROLL - STOP : %d/%d debloques, %d restants, aucun DLC necessaire (tentative #%d)", a.unlocked, a.count, a.remaining, r.attempts), true)
		end

		if a.count ~= self.EXPECTED_COUNT then
			rlog("Tirage de " .. a.count .. " ids au lieu de " .. self.EXPECTED_COUNT .. ", refuse")
		end

		for _, b in ipairs(a.blockers) do
			rlog("DLC detecte : " .. b.id .. " / " .. b.reason)
		end

		r.last_blocker = a.blockers[1] and (a.blockers[1].id .. " / " .. a.blockers[1].reason) or r.last_blocker

		if r.attempts >= r.max then
			return self:stop_auto_reroll("ARRET: limite de " .. r.max .. " tentatives atteinte, tirage actuel conserve")
		end

		rlog("REROLL")

		local before = table.concat(ids, ",")

		self._suppress_hook = true

		local ok, err = pcall(challenge.generate_challenge, challenge, false)

		self._suppress_hook = false

		if not ok then
			return self:stop_auto_reroll("ARRET: erreur generate_challenge: " .. tostring(err))
		end

		r.rerolls = r.rerolls + 1

		local after_ids = self:get_challenge()

		if not after_ids or table.concat(after_ids, ",") == before then
			rlog("La liste n'a pas change apres le reroll, nouvel essai")
		end

		return true
	end

	-- Several attempts per frame (the reroll is synchronous), then yield to the game.
	function SL:_reroll_step()
		if not self._reroll.active then
			return
		end

		rbuf = {}

		local ok, go_on = pcall(function()
			for _ = 1, self.REROLL_BATCH do
				if not self:_reroll_attempt() then
					return false
				end
			end

			return true
		end)

		rflush()

		if not ok then
			return self:stop_auto_reroll("ARRET: erreur " .. tostring(go_on))
		end

		if go_on and self._reroll.active then
			DelayedCalls:Add("SecretLogger_reroll", self.REROLL_DELAY, function()
				safe(SL._reroll_step, SL)
			end)
		end
	end

	SL:debug("===== Secret Logger charge (" .. SL.mod_path .. ") =====")
end

local script = type(RequiredScript) == "string" and RequiredScript:lower() or ""

if script == "lib/managers/customsafehousemanager" and CustomSafehouseManager and not SL._csm_hooked then
	SL._csm_hooked = true

	-- Save data (with the challenge) has just been loaded.
	Hooks:PostHook(CustomSafehouseManager, "load", "SecretLogger_CSM_load", function(self)
		SL:request_export("sauvegarde chargee")
	end)
elseif script == "lib/managers/custom_safehouse/unoachievementchallenge" and UnoAchievementChallenge and not SL._uno_hooked then
	SL._uno_hooked = true

	-- The game drew a new selection (piano puzzle solved): export it right away.
	Hooks:PostHook(UnoAchievementChallenge, "generate_challenge", "SecretLogger_generate_challenge", function(self)
		if SL._suppress_hook then
			return
		end

		SL:debug("Le jeu vient de tirer une NOUVELLE selection du Secret (generate_challenge)")
		SL:request_export("nouvelle selection tiree par le jeu")
	end)
elseif script == "lib/managers/achievmentmanager" and AchievmentManager and not SL._ach_hooked then
	SL._ach_hooked = true

	-- Steam/Epic unlock states received.
	Hooks:PostHook(AchievmentManager, "fetch_achievments", "SecretLogger_fetch", function(error_str)
		SL._fetched = error_str == "success"
		SL:debug("Statut des achievements recu de la plateforme: " .. tostring(error_str))
		SL:request_export("statut plateforme recu")
	end)

	-- Epic / Steam: award() only sends the unlock; info.awarded becomes true later, in the platform
	-- callback (epic_unlock_result -> _give_reward). Awards sent this session count as unlocked
	-- right away (same early exits as AchievmentManager:award: unknown id, mutators).
	SL._session_awarded = SL._session_awarded or {}

	Hooks:PostHook(AchievmentManager, "award", "SecretLogger_award", function(self, id)
		local disabled = managers.mutators and managers.mutators.are_achievements_disabled and managers.mutators:are_achievements_disabled()

		if self:exists(id) and not disabled then
			SL._session_awarded[id] = true
		end

		if SecretAuto and SecretAuto.on_award then
			pcall(SecretAuto.on_award, SecretAuto, id)
		end

		if SL:is_in_challenge(id) then
			SL:debug("Achievement du Secret debloque: " .. tostring(id))
			SL:request_export("achievement debloque: " .. tostring(id))
		end
	end)

	Hooks:PostHook(AchievmentManager, "_give_reward", "SecretLogger_give_reward", function(self, id)
		if SL:is_in_challenge(id) then
			SL:debug("Deblocage confirme par la plateforme: " .. tostring(id))
			SL:request_export("confirme par la plateforme: " .. tostring(id))
		end
	end)
elseif script == "lib/setups/gamesetup" and GameSetup and not SL._gs_hooked then
	SL._gs_hooked = true

	Hooks:PostHook(GameSetup, "init_finalize", "SecretLogger_GameSetup_init_finalize", function()
		local level = managers.job and managers.job:current_level_id()

		if level == "chill" then
			SL:debug("Safe House chargee")
			SL:request_export("Safe House chargee")
		end
	end)
elseif script == "lib/managers/menumanager" and not SL._menu_hooked then
	SL._menu_hooked = true

	local MENU_ID = "secret_logger_menu"

	Hooks:Add("LocalizationManagerPostInit", "SecretLogger_Localization", function(loc)
		loc:add_localized_strings({
			secret_logger_menu_title = "Secret Logger",
			secret_logger_menu_desc = "Exporte tes 20 achievements du Secret (lecture seule)",
			secret_logger_export_title = "Export Secret Achievements",
			secret_logger_export_desc = "Genere maintenant logs/secret_achievements.txt et .json",
			secret_logger_refresh_title = "Open/Refresh Secret Data",
			secret_logger_refresh_desc = "Relit la selection et affiche la progression",
			secret_logger_reroll_start_title = "Auto Reroll jusqu'a tirage sans DLC",
			secret_logger_reroll_start_desc = "Retire le Secret (comme le piano) jusqu'a ce que tous les achievements NON soient faisables sans DLC",
			secret_logger_reroll_stop_title = "Stop Auto Reroll",
			secret_logger_reroll_stop_desc = "Arrete l'auto reroll et sauvegarde le tirage actuel",
			secret_auto_start_title = "AUTO COMPLETE / AUTO STEALTH - SECRET ACHIEVEMENT",
			secret_auto_start_desc = "Detecte l'achievement du Secret du niveau (uno_5 Henry's Rock, tag_10 Visite officieuse, uno_2 Magasin de diamants, nmh_10 No Mercy en AUTO STEALTH) et l'automatise",
			secret_auto_status_title = "Etat AUTO COMPLETE",
			secret_auto_status_desc = "Etat, objectif actuel, Garrett detecte/marque, condition encore valide",
			secret_auto_stop_title = "STOP AUTO COMPLETE / AUTO STEALTH",
			secret_auto_stop_desc = "Arrete l'automatisation uno_5",
			secret_logger_reroll_max_title ="Limite de tentatives (Auto Reroll)",
			secret_logger_reroll_max_desc = "Nombre maximum de tirages avant arret automatique",
			secret_logger_reroll_status_title = "Etat Auto Reroll",
			secret_logger_reroll_status_desc = "ON/OFF, tentatives, dernier DLC bloquant, meilleur tirage"
		})
	end)

	Hooks:Add("MenuManagerSetupCustomMenus", "SecretLogger_Setup", function(menu_manager, nodes)
		MenuHelper:NewMenu(MENU_ID)
	end)

	Hooks:Add("MenuManagerPopulateCustomMenus", "SecretLogger_Populate", function(menu_manager, nodes)
		MenuCallbackHandler.secret_logger_export = function(self, item)
			local ok, data = SL:export("bouton Export", true)
			local text

			if ok and type(data) == "table" then
				text = string.format("%d achievements exportes (%d/%d debloques).\n\n%s", data.count, data.completed, data.count, SL.txt_path)
			else
				text = "Liste du Secret non disponible : " .. tostring(data) .. "\nVoir logs/debug.txt"
			end

			QuickMenu:new("Secret Logger", text, { { text = "OK", is_cancel_button = true } }, true)
		end

		MenuCallbackHandler.secret_logger_refresh = function(self, item)
			local ok, data = SL:export("bouton Refresh", false)

			if not ok or type(data) ~= "table" then
				QuickMenu:new("Secret Logger", "Liste du Secret non disponible : " .. tostring(data), { { text = "OK", is_cancel_button = true } }, true)

				return
			end

			local lines = { string.format("Debloques : %d/%d  -  Restants : %d", data.completed, data.count, data.remaining), "" }

			for _, e in ipairs(data.entries) do
				if not e.unlocked then
					table.insert(lines, "- " .. e.name .. " (" .. e.id .. ")")
				end
			end

			QuickMenu:new("Secret - restants", table.concat(lines, "\n"), { { text = "OK", is_cancel_button = true } }, true)
		end

		MenuHelper:AddButton({
			id = "secret_logger_export",
			title = "secret_logger_export_title",
			desc = "secret_logger_export_desc",
			callback = "secret_logger_export",
			menu_id = MENU_ID,
			priority = 2
		})

		MenuHelper:AddButton({
			id = "secret_logger_refresh",
			title = "secret_logger_refresh_title",
			desc = "secret_logger_refresh_desc",
			callback = "secret_logger_refresh",
			menu_id = MENU_ID,
			priority = 1
		})

		MenuCallbackHandler.secret_logger_reroll_start = function(self, item)
			if not SL:start_auto_reroll() then
				QuickMenu:new("Secret Auto Reroll", "Impossible de demarrer (deja en cours, ou donnees pas encore chargees).\nVoir logs/debug.txt\n\n" .. SL:reroll_status_text(), { { text = "OK", is_cancel_button = true } }, true)
			end
		end

		MenuCallbackHandler.secret_logger_reroll_stop = function(self, item)
			if SL._reroll.active then
				SL:stop_auto_reroll("ARRET manuel de l'auto reroll")
			else
				QuickMenu:new("Secret Auto Reroll", SL:reroll_status_text(), { { text = "OK", is_cancel_button = true } }, true)
			end
		end

		MenuCallbackHandler.secret_auto_start = function(self, item)
			if not SecretAuto or not SecretAuto:start() then
				QuickMenu:new("AUTO COMPLETE", "Impossible de demarrer : niveau sans achievement automatise (Henry's Rock OVERKILL+, Visite officieuse), ou deja en cours.\nVoir logs/debug.txt", { { text = "OK", is_cancel_button = true } }, true)
			end
		end

		MenuCallbackHandler.secret_auto_stop = function(self, item)
			if SecretAuto then
				SecretAuto:stop("bouton STOP")
			end
		end

		MenuHelper:AddButton({
			id = "secret_auto_start",
			title = "secret_auto_start_title",
			desc = "secret_auto_start_desc",
			callback = "secret_auto_start",
			menu_id = MENU_ID,
			priority = 7
		})

		MenuCallbackHandler.secret_auto_status = function(self, item)
			QuickMenu:new("AUTO COMPLETE", SecretAuto and SecretAuto.status_text and SecretAuto:status_text() or "secret_auto.lua non charge", { { text = "OK", is_cancel_button = true } }, true)
		end

		MenuHelper:AddButton({
			id = "secret_auto_status",
			title = "secret_auto_status_title",
			desc = "secret_auto_status_desc",
			callback = "secret_auto_status",
			menu_id = MENU_ID,
			priority = 5.5
		})

		MenuHelper:AddButton({
			id = "secret_auto_stop",
			title = "secret_auto_stop_title",
			desc = "secret_auto_stop_desc",
			callback = "secret_auto_stop",
			menu_id = MENU_ID,
			priority = 6
		})

		MenuCallbackHandler.secret_logger_reroll_status = function(self, item)
			QuickMenu:new("Secret Auto Reroll", SL:reroll_status_text(), { { text = "OK", is_cancel_button = true } }, true)
		end

		MenuHelper:AddButton({
			id = "secret_logger_reroll_start",
			title = "secret_logger_reroll_start_title",
			desc = "secret_logger_reroll_start_desc",
			callback = "secret_logger_reroll_start",
			menu_id = MENU_ID,
			priority = 5
		})

		MenuHelper:AddButton({
			id = "secret_logger_reroll_stop",
			title = "secret_logger_reroll_stop_title",
			desc = "secret_logger_reroll_stop_desc",
			callback = "secret_logger_reroll_stop",
			menu_id = MENU_ID,
			priority = 4
		})

		MenuCallbackHandler.secret_logger_reroll_max = function(self, item)
			SL:set_reroll_max(item:value())
		end

		MenuHelper:AddSlider({
			id = "secret_logger_reroll_max",
			title = "secret_logger_reroll_max_title",
			desc = "secret_logger_reroll_max_desc",
			callback = "secret_logger_reroll_max",
			value = SL.REROLL_MAX,
			min = 100,
			max = 100000,
			step = 100,
			show_value = true,
			display_precision = 0,
			menu_id = MENU_ID,
			priority = 2.5
		})

		MenuHelper:AddButton({
			id = "secret_logger_reroll_status",
			title = "secret_logger_reroll_status_title",
			desc = "secret_logger_reroll_status_desc",
			callback = "secret_logger_reroll_status",
			menu_id = MENU_ID,
			priority = 3
		})
	end)

	Hooks:Add("MenuManagerBuildCustomMenus", "SecretLogger_Build", function(menu_manager, nodes)
		nodes[MENU_ID] = MenuHelper:BuildMenu(MENU_ID)
		MenuHelper:AddMenuItem(nodes.blt_options, MENU_ID, "secret_logger_menu_title", "secret_logger_menu_desc")
	end)

	-- Game start: the save may already be loaded, otherwise retries until it is.
	SL:request_export("demarrage du jeu")
end
