-- Spawner catalog: the unit list is the game's own tweak_data.character:character_map() (the same
-- source QES always used). This module only adds metadata (category + French name) and never
-- spawns anything: spawning still goes through SpawnerMenu.spawn.

UnitCatalog = UnitCatalog or {}
local UC = UnitCatalog

UC.CATEGORIES = {
	{ id = "favorites", label_key = "fmmt_cat_favorites" },
	{ id = "normal", label_key = "fmmt_cat_normal" },
	{ id = "special", label_key = "fmmt_cat_special" },
	{ id = "dozer", label_key = "fmmt_cat_dozer" },
	{ id = "rare", label_key = "fmmt_cat_rare" },
	{ id = "allies", label_key = "fmmt_cat_allies" }
}

local function is_french()
	local fmm = rawget(_G, "FunnyModMenu")
	return fmm and type(fmm.language) == "function" and fmm.language() == "fr" or false
end

-- English names for KNOWN entries whose French name differs.
UC.KNOWN_EN = {
	ene_cop_1 = "Police officer 1", ene_cop_2 = "Police officer 2", ene_cop_3 = "Police officer 3", ene_cop_4 = "Police officer 4",
	ene_veteran_cop_1 = "Veteran cop", ene_security_1 = "Security guard", ene_security_gensec_1 = "GenSec guard",
	ene_swat_1 = "Light SWAT", ene_swat_2 = "Light SWAT (shotgun)", ene_swat_heavy_1 = "Heavy SWAT",
	ene_fbi_1 = "FBI agent", ene_fbi_2 = "FBI agent 2", ene_fbi_3 = "FBI agent 3",
	ene_fbi_swat_2 = "FBI SWAT (shotgun)", ene_fbi_heavy_1 = "Heavy FBI",
	ene_city_heavy_g36 = "Heavy GenSec", ene_city_heavy_r870 = "Heavy GenSec (shotgun)",
	ene_zeal_swat_heavy = "Heavy ZEAL SWAT", ene_murkywater_light = "Light Murkywater", ene_murkywater_heavy = "Heavy Murkywater",
	ene_shadow_cloaker_1 = "Shadow Cloaker", ene_shield_1 = "Shield (pistol)", ene_medic_r870 = "Medic (shotgun)",
	ene_bulldozer_1 = "Green Bulldozer", ene_bulldozer_2 = "Black Bulldozer", ene_bulldozer_3 = "Skull Bulldozer",
	ene_bulldozer_minigun_classic = "Minigun Dozer (classic)",
	ene_zeal_bulldozer = "Green ZEAL Bulldozer", ene_zeal_bulldozer_2 = "Black ZEAL Bulldozer", ene_zeal_bulldozer_3 = "Skull ZEAL Bulldozer",
	ene_captain = "Captain", ene_snowman_boss = "Snowman boss", ene_drug_lord_boss = "Sosa (boss)",
	ene_gang_biker_boss = "Biker boss", ene_gang_mobster_boss = "Mobster boss", ene_fbi_boss_1 = "FBI boss"
}

-- Known units: French name and category.
UC.KNOWN = {
	ene_cop_1 = { "Policier 1", "normal" }, ene_cop_2 = { "Policier 2", "normal" },
	ene_cop_3 = { "Policier 3", "normal" }, ene_cop_4 = { "Policier 4", "normal" },
	ene_veteran_cop_1 = { "Policier vétéran", "normal" },
	ene_security_1 = { "Garde de sécurité", "normal" }, ene_security_gensec_1 = { "Garde GenSec", "normal" },
	ene_swat_1 = { "SWAT léger", "normal" }, ene_swat_2 = { "SWAT léger (pompe)", "normal" },
	ene_swat_heavy_1 = { "SWAT lourd", "normal" },
	ene_fbi_1 = { "Agent FBI", "normal" }, ene_fbi_2 = { "Agent FBI 2", "normal" }, ene_fbi_3 = { "Agent FBI 3", "normal" },
	ene_fbi_swat_1 = { "FBI SWAT", "normal" }, ene_fbi_swat_2 = { "FBI SWAT (pompe)", "normal" },
	ene_fbi_heavy_1 = { "FBI lourd", "normal" },
	ene_city_swat_1 = { "GenSec SWAT", "normal" }, ene_city_swat_2 = { "GenSec SWAT 2", "normal" },
	ene_city_swat_3 = { "GenSec SWAT 3", "normal" },
	ene_city_heavy_g36 = { "GenSec lourd", "normal" }, ene_city_heavy_r870 = { "GenSec lourd (pompe)", "normal" },
	ene_zeal_swat = { "SWAT ZEAL", "normal" }, ene_zeal_swat_heavy = { "SWAT ZEAL lourd", "normal" },
	ene_murkywater_light = { "Murkywater léger", "normal" }, ene_murkywater_heavy = { "Murkywater lourd", "normal" },

	ene_spook_1 = { "Cloaker", "special" }, ene_zeal_cloaker = { "Cloaker ZEAL", "special" },
	ene_murkywater_cloaker = { "Cloaker Murkywater", "special" }, ene_shadow_cloaker_1 = { "Cloaker de l'ombre", "special" },
	ene_tazer_1 = { "Taser", "special" }, ene_zeal_tazer = { "Taser ZEAL", "special" },
	ene_murkywater_tazer = { "Taser Murkywater", "special" },
	ene_shield_1 = { "Shield (pistolet)", "special" }, ene_shield_2 = { "Shield (SMG)", "special" },
	ene_zeal_swat_shield = { "Shield ZEAL", "special" }, ene_murkywater_shield = { "Shield Murkywater", "special" },
	ene_medic_m4 = { "Medic", "special" }, ene_medic_r870 = { "Medic (pompe)", "special" },
	ene_murkywater_medic = { "Medic Murkywater", "special" },
	ene_sniper_1 = { "Sniper", "special" }, ene_sniper_2 = { "Sniper 2", "special" }, ene_sniper_3 = { "Sniper 3", "special" },
	ene_zeal_swat_heavy_sniper = { "Sniper ZEAL", "special" }, ene_murkywater_sniper = { "Sniper Murkywater", "special" },

	ene_bulldozer_1 = { "Bulldozer vert", "dozer" }, ene_bulldozer_2 = { "Bulldozer noir", "dozer" },
	ene_bulldozer_3 = { "Bulldozer Skull", "dozer" }, ene_bulldozer_4 = { "Bulldozer 4", "dozer" },
	ene_bulldozer_minigun = { "Minigun Dozer", "dozer" }, ene_bulldozer_minigun_classic = { "Minigun Dozer (classique)", "dozer" },
	ene_bulldozer_medic = { "Medic Dozer", "dozer" },
	ene_zeal_bulldozer = { "Bulldozer ZEAL vert", "dozer" }, ene_zeal_bulldozer_2 = { "Bulldozer ZEAL noir", "dozer" },
	ene_zeal_bulldozer_3 = { "Bulldozer ZEAL Skull", "dozer" }, ene_zeal_bulldozer_halloween = { "Bulldozer Halloween", "dozer" },
	ene_dozer_piggy = { "Piggy Dozer", "dozer" },

	ene_vip_1 = { "Captain Winters", "rare" }, ene_phalanx_1 = { "Phalanx", "rare" }, ene_captain = { "Capitaine", "rare" },
	ene_snowman_boss = { "Boss bonhomme de neige", "rare" }, ene_drug_lord_boss = { "Sosa (boss)", "rare" },
	ene_gang_biker_boss = { "Boss biker", "rare" }, ene_gang_mobster_boss = { "Boss mafieux", "rare" },
	ene_fbi_boss_1 = { "Boss FBI", "rare" }, ene_gabriel = { "Gabriel", "rare" }, ene_locke = { "Locke", "rare" }
}

-- Allied / Joker shortlist (spawned on the allied team from their page).
UC.ALLIES = { "ene_swat_1", "ene_swat_heavy_1", "ene_fbi_heavy_1", "ene_spook_1", "ene_tazer_1",
	"ene_shield_1", "ene_medic_m4", "ene_sniper_1", "ene_bulldozer_1", "ene_bulldozer_minigun" }

-- English words for building a readable name for units not in KNOWN.
local WORDS_EN = {
	swat = "SWAT", heavy = "heavy", fbi = "FBI", zeal = "ZEAL", murkywater = "Murkywater",
	security = "security", guard = "guard", cop = "cop", sniper = "sniper", shield = "Shield",
	tazer = "Taser", spook = "Cloaker", cloaker = "Cloaker", medic = "Medic", bulldozer = "Bulldozer",
	tank = "Bulldozer", dozer = "Dozer", gang = "gang", biker = "biker", mobster = "mobster",
	triad = "triad", thug = "thug", boss = "boss", female = "female", male = "", city = "GenSec",
	policia = "", federale = "(Mexico)", akan = "(Akan)", hvh = "(Hoxvenge)", light = "light",
	office = "office", secret = "", service = "Secret Service", minigun = "minigun", lmg = "",
	r870 = "(shotgun)", saiga = "(Saiga)", indoor = "", outdoor = "", ene = "", the = "",
	cs = "", ass = "", smg = "", snp = "", dw = "", asval = "", akmsu = "", svd = "", sr2 = "",
	rpk = "", c45 = "", mp9 = "", g36 = "", m4 = "", m249 = "", ak47 = "", nomask = "(no mask)",
	no = "", pager = "(no pager)", mask = "", ["not"] = "not", casino = "(casino)", cruise = "(cruise)"
}

-- French words for building a readable name for units not in KNOWN.
local WORDS = {
	swat = "SWAT", heavy = "lourd", fbi = "FBI", zeal = "ZEAL", murkywater = "Murkywater",
	security = "sécurité", guard = "garde", cop = "policier", sniper = "sniper", shield = "Shield",
	tazer = "Taser", spook = "Cloaker", cloaker = "Cloaker", medic = "Medic", bulldozer = "Bulldozer",
	tank = "Bulldozer", dozer = "Dozer", gang = "gang", biker = "biker", mobster = "mafieux",
	triad = "triade", thug = "voyou", boss = "boss", female = "femme", male = "", city = "GenSec",
	policia = "", federale = "(Mexique)", akan = "(Akan)", hvh = "(Hoxvenge)", light = "léger",
	office = "bureau", secret = "", service = "Secret Service", minigun = "minigun", lmg = "",
	r870 = "(pompe)", saiga = "(Saiga)", indoor = "", outdoor = "", ene = "", the = "",
	cs = "", ass = "", smg = "", snp = "", dw = "", asval = "", akmsu = "", svd = "", sr2 = "",
	rpk = "", c45 = "", mp9 = "", g36 = "", m4 = "", m249 = "", ak47 = "", nomask = "(sans masque)",
	no = "", pager = "(sans pager)", mask = "", ["not"] = "non", casino = "(casino)", cruise = "(croisière)"
}

local function readable(name)
	local words = is_french() and WORDS or WORDS_EN
	local parts = {}
	for token in name:gmatch("[^_]+") do
		local w = words[token]
		if w == nil then
			if not token:match("^%d+$") and not token:match("%d") then
				w = token:sub(1, 1):upper() .. token:sub(2)
			elseif token:match("^%d+$") then
				w = token
			else
				w = ""
			end
		end
		if w ~= "" then
			parts[#parts + 1] = w
		end
	end
	local label = table.concat(parts, " ")
	return label ~= "" and label or name
end

local function classify(name)
	if name:find("bulldozer", 1, true) or name:find("tank", 1, true) or name:find("dozer", 1, true) then
		return "dozer"
	end
	for _, key in ipairs({ "spook", "cloaker", "tazer", "shield", "medic", "sniper", "marksman" }) do
		if name:find(key, 1, true) then
			return "special"
		end
	end
	for _, key in ipairs({ "gang", "biker", "triad", "thug", "mobster", "boss", "phalanx", "vip", "captain",
		"snowman", "gabriel", "locke", "bain", "commissioner", "crew", "hector", "des", "tgt", "auctioneer",
		"ranchmanager", "undercover", "bolivian" }) do
		if name:find(key, 1, true) then
			return "rare"
		end
	end
	return "normal"
end

-- Every enemy unit of character_map() loaded on the current map, with metadata.
function UC.build()
	local entries, by_name, used, labels_seen = {}, {}, {}, {}
	local char_map = tweak_data.character:character_map()
	for _, group_name in pairs(table.map_keys(char_map)) do
		local group_data = char_map[group_name]
		for _, name in pairs(table.sorted_copy(group_data.list)) do
			local unit_ids = Idstring(group_data.path .. name .. "/" .. name)
			if not name:match("^civ_") and not used[unit_ids:key()] and PackageManager:has(Idstring("unit"), unit_ids) then
				used[unit_ids:key()] = true
				local known = UC.KNOWN[name]
				local label = known and (is_french() and known[1] or UC.KNOWN_EN[name] or known[1]) or readable(name)
				labels_seen[label] = (labels_seen[label] or 0) + 1
				if labels_seen[label] > 1 then
					label = label .. " " .. labels_seen[label]
				end
				local entry = {
					name = name,
					unit_ids = unit_ids,
					label = label,
					category = known and known[2] or classify(name)
				}
				table.insert(entries, entry)
				by_name[name] = entry
			end
		end
	end
	table.sort(entries, function(a, b)
		return a.label < b.label
	end)
	return entries, by_name
end

function UC.list(category, entries, by_name, favorites)
	local out = {}
	if category == "favorites" then
		for _, name in ipairs(favorites or {}) do
			if by_name[name] then
				table.insert(out, by_name[name])
			end
		end
	elseif category == "allies" then
		for _, name in ipairs(UC.ALLIES) do
			if by_name[name] then
				table.insert(out, by_name[name])
			end
		end
	else
		for _, entry in ipairs(entries) do
			if entry.category == category then
				table.insert(out, entry)
			end
		end
	end
	return out
end
