Funny Mod Menu Troll - version 1.7
Dev by Elexyr22
https://elexyr22.fr/

======================================================================
ENGLISH
======================================================================

Version 1.7
- New SECRET tab: puzzle door, piano, achievements export / auto reroll and auto complete, with a clear message when you are in the wrong level.
- Seamless Input Switch is now bundled.
- Top-right popup at level start with the key that opens the menu.

Version 1.6 (V18)
- WORLD > ENEMIES: "Vanilla enemies" and "Waves" are two separate switches again (host only,
  reset ON every level). "Block all enemies" (also blocks mission-scripted enemies) is under
  ADVANCED.
- INTERACTIONS > AUTO > "Automatic mission actions" (default ON): C4 / charges, drills, saws,
  thermal drills, hacking, terminals, insert / plug items, only when the vanilla interaction is
  active and in range. Never bags, pickups, people, weapons or escape / extraction.
- Auto Steal: per-type HOST / CLIENT results shown in the menu (tag CLIENT LIMITED until the
  host confirms each type in game).
- SETTINGS > NETWORK: players that have Funny Mod Menu Troll (X / Y) and their version.
  TEAM > player > INFO: INSTALLED vX / NOT DETECTED.

Version 1.6 (V17)
- New menu layout: COMBAT, INTERACTIONS, SPAWNER, WORLD, ME, TEAM, TROLL, SETTINGS. The old
  PLAYER / PLAYERS categories are gone: ME = only your own character (movement, resources,
  Vanish, follow status), TEAM = the other human players and the bots.
- Every category page lists its sections; a section page starts with "< Back" and keeps about
  a dozen short rows ("Team God Mode : ON"). Explanations moved to the item description (hover),
  network limits to short tags: [LOCAL] [HOST] [CLIENT OK] [CLIENT LIMITED] [MOD REQUIRED].
  Colors: ON green, OFF grey, unavailable here orange, errors red.
- TEAM: click a teammate for teleport / follow, revive now / auto revive, custody (trade now,
  force respawn), kick / ban (humans only) and info (peer ID, human / bot, custody, Funny Mod).
  TEAM > CUSTODY and TEAM > BANNED hold the global custody options and the ban list.
- TROLL: shortcuts (TP everyone to me, convert all, kill all, vanilla enemies, One Shot,
  Auto Kill, Aimbot, Team God Mode, Full Vanish, Fly + No Clip). They are the same rows as in
  their home category and change the same settings.
- SETTINGS: Interface (language, hide host-only features, show descriptions, show network
  tags), Network (mode, host features, compatible players, join message, kick / ban
  confirmation), Gamepad (Seamless Input Switch), Performance (debug / logs), About.
- Spawner: favorites and the "QES alive : X / Y | Queue : N" counter on the main SPAWNER page,
  spawn speed SAFE / FAST / EXTREME in SPAWNER > OPTIONS.
- New: "Funny Game lol" is sent ONCE per online session in the real game chat (everyone sees
  it). Client: when the host accepts the join. Host: when the first player has finished
  joining. Never in solo / offline, never again on the next day of the same job; sent again
  after going back to the main menu and joining / hosting a new lobby. Option in
  SETTINGS > NETWORK (default ON). lua/join_chat.lua.
- No setting key renamed: the saved configuration is kept. No gameplay change.

Version 1.4 (V15)
- Fix: Auto drill / Auto pick up never ran in V14. SuperBLT's dofile() does not return the
  file's value, so the RealInteract helper was nil ("attempt to index upvalue 'RI'" every
  0.3 s in the log). real_interact.lua is now loaded by mod.txt and read at call time.
- ONE engine for every automatic action (lua/auto_actions.lua): Auto pick up, Auto steal, Auto
  drill place / restart, Auto revive. DETECT -> VALIDATE -> START (vanilla interact_start) ->
  vanilla timer -> COMPLETE (interact_interupt + interact) -> WAIT FOR CONFIRMATION (the game's
  own state: unit removed, interaction deactivated / changed, host answer). ~3 checks per second
  per system, one unit per check, one pending entry per unit (no double interaction), 3 s
  cooldown after a failure, 20 s after 3 failures. No crosshair needed: distance only.
- Auto pick up no longer needs the highlight option. The collectible marker is kept until the
  game confirms the pickup (host refusal / no answer = marker kept, retry later).
- Interactions > AUTO STEAL (OFF, radius 2/5/10/20 m/MAX, default 5 m), host AND client:
  collectibles > mission items (keycards, crowbar...) > small valuables > other pickups, through
  the vanilla interaction. Never loot bags, deployables or non-pickup mission interactions.
- Interactions > Instant object placement (ON): deployables (ammo / doctor bag, ECM, sentry,
  trip mine...) and mission devices (drill, saw, thermal drill, hack, mission C4) take 0.05 s to
  place. Only the duration changes, the placement is the game's own code.
- Auto drill also places mission C4 / door devices without TimerGui. Detailed [AutoDrill] logs.
- Player > Vanish (OFF, HOST ONLY): the AI ignores you only (detection reset, no focus), the
  others are still targets. Not God Mode.
- V16 Player > VANISH > Player invisibility (OFF, host AND client): your character, weapons,
  mask, melee prop, carried bag and every attached unit disappear for the other players, with no
  name label, muzzle flash or tracers. PAYDAY 2 has NO vanilla visibility sync (no RPC, each client
  renders its own copy of you): REQUIRES THE MOD ON THE OTHER PLAYERS, a player without it keeps
  seeing you. "Full Vanish" toggles AI + invisibility. Both reset OFF on level change.
- Settings: Auto Actions radius (PER FEATURE / 2 / 5 / 10 / 20 m / MAX) and Debug Auto Actions
  ([AutoActions] phase logs, ON by default in this version).
- Collectible highlight turned back ON once (it was OFF in the saved settings).

Version 1.3 (V14)
- Interactions > AUTO DRILL: Auto place (ON) + Auto restart (ON), radius 2/5/10/20 m/MAX
  (default 5 m), measured from the interaction position.
  * Auto place runs the REAL placement interaction that already exists (drill, saw, thermal
    drill, hack: TimerGui units, MissionDoorDeviceInteractionExt or the computer's interaction),
    same path as a player holding the key (interact_start + interact). Host and client (vanilla
    server_place_mission_door_device request). No device is ever created. Without the required
    item only when "Ignore requirements" is ON.
  * Auto restart: host = Drill:on_autorepair (Kickstarter); client or computers = vanilla repair
    interaction. Unpowered devices (scripted power cut) are never touched. Repair before
    placement, one action per check (~3/s), 3 s per unit.
  * Stealth: placing a drill is loud, turn "Auto place" off if needed.
- World > Highlight: Auto pick up (ON, radius 2/5/10/20 m/MAX, default 5 m). Gage packages,
  turtles, horseshoes only, through the real pickup interaction (client: sync_pickup request
  validated by the host). Uses the highlight list (no world scan): needs "Packages /
  Collectibles" ON. Closest first, one per tick, pending 2 s until the game's callback.

Hotfix V13 (1.2)
- Menu spawn: the SPAWN button only queues one spawn (FunnyMod.QES.enqueue_spawn), 125 ms
  double-click protection, the queue creates the units later (SAFE = 1 every 3 frames, forced
  while the menu is open). No menu rebuild after a spawn: only the "Active QES" label text is
  updated (count from the QES tracking table, "+N" = waiting in the queue). Spawn catalog built
  once per level.
- Settings > Perf debug: logs [QES][perf] spawn / menu refresh times, SLOW SPAWN / SLOW REFRESH
  above 50 ms.
- Highlight: the marker (contour + waypoint) of a collectible disappears the moment it is picked
  up or removed by a script (GageAssignmentManager / Pickup / interaction callbacks), the
  periodic rescan only cleans leftovers.
- Interactions > Auto drill (host, ON, radius 2/5/10/20 m/MAX, default 5 m): jammed drills / saws
  / hacking devices in range are restarted through the vanilla automatic repair
  (Drill:on_autorepair, the Kickstarter skill path: unit "interact" sequence, synced to clients),
  about 3 checks per second, one device per check.

Version 1.2 (V12)
- Highlight fixed: Gage packages are Pickup units registered in managers.gage_assignment
  (not always in the interaction list): now found from that list + slot 23/20 pickups.
  Collectibles get a contour and a local HUD marker; mission objects and loot (off by
  default) get a contour. Rescan every 4 s, cleared at level end. Local only.
- Aimbot (OFF by default): targets Enemies / NPC / All, FOV 30-180, distance 25 m-unlimited,
  no target behind walls. Auto Kill (OFF by default, needs Aimbot): one native kill per target,
  delay 0.1-2 s. Host: synced native death. Client: enemies only (native bullet damage).
- Convert aimed enemy / Convert all enemies (host): native GroupAI conversion, no Joker limit,
  Dozers and specials included.
- Instant custody trade (host): vanilla blocks trades during every assault and adds ~10 s of
  dialog; now a player in custody is traded at once when a hostage or a converted enemy
  exists (not in stealth; the "Trade now" button works anytime). Force respawn (native).
- Auto revive teammates (players + bots) in a 2/5/10/20 m or MAX radius, through the vanilla
  revive interaction (works as client).
- Follow delay 1-30 s (saved, applied on the next cycle), landing next to the target.

All-in-one sandbox mod menu for PAYDAY 2, made for private lobbies you host
with friends.

Requirements
- PAYDAY 2 (64-bit)
- SuperBLT
- BeardLib (the menu uses BeardLib's MenuUI)

Installation
1. Extract the "Funny Mod Menu Troll" folder into PAYDAY2/mods/
2. IMPORTANT: disable the old standalone versions before enabling this mod
   (Quick Enemy Spawner, God Mode, Infinite Player Resources / Infinite Reserve Ammo,
   Never Detected, No Stealth Noise Alerts, No Player Gun Alerts).
   A warning is written in the SuperBLT log if one of them is still enabled.
3. Start PAYDAY 2
4. F9 opens / closes the menu in game (the only key of the mod; it can be changed in
   Options > Mod Keybinds). God Mode and Never Detected are toggled from the menu.

Features
- Enemy spawner by category (normal, special, dozers, rare, allies/Jokers, favorites)
- Kill (real death) or Remove (instant cleanup) QES / vanilla / all enemies
- Enemy Control: disable vanilla enemies (reset to normal on every new level)
- Personal God Mode, God Mode all players (host: host + bots), One Shot total
  (anything you hit dies through its native damage path), infinite ammo, no reload,
  infinite grenades
- Infinite sentry ammo, infinite deployables, infinite body bags
- Instant interactions, ignore interaction requirements (keycard, crowbar, C4... only on
  interactions that already exist), unbreakable drills (host), unlimited C4, infinite cable ties
- Stealth: never detected, blind cameras, no noise alerts, no pagers (auto off in loud)
- Speed mode, ignore bag weight, Fly Mode, No Clip, Fly + No Clip (local player only)
- Loot bag spawner (real thrown bags, network synced)
- Highlight collectibles / mission objectives
- Teleport (to players and bots, bots / everyone to you, auto follow a player every 3 s).
  Moving another human player is not possible: the game has no network message for it.
- Seamless Input Switch shortcut in Settings (opens that mod's own menu, if installed)
- Custody: instant trades, free with a hostage, force respawn
- Host administration: kick, ban (game ban list), unban
- French / English (automatic from the game language, or chosen in Settings)

Host / client
- Spawner, enemy control, stealth options, drills/hacks, loot, custody and
  administration are host only (the host runs the AI and the session).
- Player cheats (God Mode, ammo, speed...) only affect the player who has the mod.

======================================================================
FRANÇAIS
======================================================================

Version 1.6 (V18)
- MONDE > ENNEMIS : "Ennemis vanilla" et "Vagues" redeviennent deux options séparées (hôte,
  remises sur ON à chaque niveau). "Blocage total ennemis" (bloque aussi les ennemis scriptés)
  est dans AVANCÉ.
- INTERACTIONS > AUTO > "Actions de mission automatiques" (ON par défaut) : C4 / charges,
  perceuses, scies, lances thermiques, piratage, terminaux, insérer / brancher un objet,
  seulement si l'interaction vanilla est active et dans le rayon. Jamais de sacs, pickups,
  personnes, armes ni sortie / extraction.
- Auto Steal : résultat HOST / CLIENT par type affiché dans le menu (tag CLIENT LIMITÉ tant que
  l'hôte n'a pas confirmé chaque type en jeu).
- PARAMÈTRES > RÉSEAU : joueurs ayant Funny Mod Menu Troll (X / Y) et leur version.
  ÉQUIPE > joueur > INFOS : INSTALLÉ vX / NON DÉTECTÉ.

Version 1.6 (V17)
- Nouveau menu : COMBAT, INTERACTIONS, SPAWNER, MONDE, MOI, ÉQUIPE, TROLL, PARAMÈTRES. Les
  anciennes catégories JOUEUR / JOUEURS n'existent plus : MOI = uniquement ton personnage
  (mouvement, ressources, Vanish, état du suivi), ÉQUIPE = les autres joueurs humains et les bots.
- Chaque catégorie liste ses sections ; une section commence par « < Retour » et garde une
  douzaine de lignes courtes (« God Mode équipe : ON »). Les explications passent dans la
  description de l'item (survol), les limites réseau en tags courts : [LOCAL] [HOST] [CLIENT OK]
  [CLIENT LIMITÉ] [MOD REQUIS]. Couleurs : ON vert, OFF gris, indisponible ici orange, erreur rouge.
- ÉQUIPE : clic sur un coéquipier = téléportation / suivi, relever maintenant / auto relever,
  custody (échanger maintenant, respawn forcé), kick / ban (humains uniquement) et infos (Peer ID,
  humain / bot, custody, Funny Mod). ÉQUIPE > CUSTODY et ÉQUIPE > BANNIS regroupent les options
  globales de custody et la liste des bannis.
- TROLL : raccourcis (TP tous vers moi, convertir tous, tuer tous, ennemis vanilla, One Shot,
  Auto Kill, Aimbot, God Mode équipe, Vanish complet, Fly + No Clip). Ce sont les mêmes lignes
  que dans leur catégorie d'origine : mêmes réglages.
- PARAMÈTRES : Interface (langue, masquer fonctions hôte, descriptions, tags réseau), Réseau
  (mode, fonctions host, joueurs compatibles, message à la connexion, confirmation kick / ban),
  Manette (Seamless Input Switch), Performance (debug / logs), À propos.
- Spawner : favoris et compteur « QES actifs : X / Y | File : N » sur l'écran principal SPAWNER,
  vitesse de spawn SAFE / FAST / EXTREME dans SPAWNER > OPTIONS.
- Nouveau : « Funny Game lol » est envoyé UNE SEULE FOIS par session en ligne dans le vrai chat
  du jeu (visible par tous). Client : quand l'hôte accepte la connexion. Hôte : quand le premier
  joueur a fini de rejoindre. Jamais en solo / hors ligne, jamais au jour suivant d'un même
  contrat ; renvoyé après retour au menu principal puis nouveau lobby. Option dans
  PARAMÈTRES > RÉSEAU (ON par défaut). lua/join_chat.lua.
- Aucune clé de réglage renommée : la configuration sauvegardée est conservée. Aucun changement
  de gameplay.

Version 1.4 (V15)
- Correctif : Auto perceuse / Auto ramasser ne tournaient jamais en V14. Le dofile() de SuperBLT
  ne renvoie pas la valeur du fichier : l'aide RealInteract était nil (« attempt to index upvalue
  'RI' » toutes les 0,3 s dans le log). real_interact.lua est maintenant chargé par mod.txt et lu
  au moment de l'appel.
- UN seul moteur pour toutes les actions automatiques (lua/auto_actions.lua) : Auto ramasser,
  Auto Steal, Auto poser / relancer perceuse, Auto relever. DÉTECTER -> VALIDER -> DÉMARRER
  (interact_start vanilla) -> timer vanilla -> TERMINER (interact_interupt + interact) -> ATTENDRE
  LA CONFIRMATION (état réel du jeu : unité supprimée, interaction désactivée / changée, réponse
  de l'hôte). ~3 vérifications/s par système, une unité par vérification, une entrée par unité
  (pas de double interaction), 3 s d'attente après un échec, 20 s après 3 échecs. Pas besoin de
  viser : distance seulement.
- Auto ramasser ne dépend plus de la surbrillance. Le marqueur du colis reste jusqu'à la
  confirmation du jeu (refus / pas de réponse de l'hôte = marqueur conservé, nouvel essai).
- Interactions > AUTO VOL (DÉSACTIVÉ, rayon 2/5/10/20 m/MAX, défaut 5 m), hôte ET client :
  collectibles > objets de mission (cartes, pied-de-biche...) > petits objets de valeur > autres
  pickups, via l'interaction vanilla. Jamais de sac de loot, de déployable ni d'interaction de
  mission autre qu'un ramassage.
- Interactions > Pose instantanée objets (ACTIVÉ) : déployables (sac de munitions / médical, ECM,
  tourelle, mine...) et appareils de mission (perceuse, scie, lance thermique, hack, C4 de
  mission) posés en 0,05 s. Seule la durée change, la pose reste le code du jeu.
- Auto perceuse pose aussi le C4 de mission / appareils de porte sans TimerGui. Logs [AutoDrill]
  détaillés.
- Joueur > Vanish (DÉSACTIVÉ, HÔTE UNIQUEMENT) : l'IA t'ignore toi seul (détection remise à zéro,
  plus de cible), les autres restent des cibles. Ce n'est pas un God Mode.
- V16 Joueur > VANISH > Invisibilité joueurs (DÉSACTIVÉ, hôte ET client) : ton personnage, tes
  armes, ton masque, l'arme de mêlée, le sac porté et tout ce qui est attaché disparaissent chez
  les autres joueurs, sans nom au-dessus de la tête, flash de bouche ni traçantes. PAYDAY 2 n'a
  AUCUNE synchro vanilla de visibilité (pas de RPC, chaque client affiche sa propre copie de toi) :
  NÉCESSITE LE MOD CHEZ LES AUTRES JOUEURS, un joueur sans le mod continue de te voir.
  "Vanish complet" active IA + invisibilité. Les deux repassent à OFF au changement de niveau.
- Paramètres : Rayon Auto Actions (PAR FONCTION / 2 / 5 / 10 / 20 m / MAX) et Debug Auto Actions
  (logs [AutoActions] par phase, ACTIVÉ par défaut dans cette version).
- Surbrillance des collectibles remise sur ACTIVÉ une fois (elle était DÉSACTIVÉE dans la
  sauvegarde).

Version 1.3 (V14)
- Interactions > AUTO PERCEUSE : Auto poser (ACTIVÉ) + Auto relancer (ACTIVÉ), rayon
  2/5/10/20 m/MAX (défaut 5 m), mesuré depuis la position d'interaction (interact_position).
  * Auto poser : déclenche la VRAIE interaction de pose déjà présente (perceuse, scie, lance
    thermique, hack : unités à TimerGui, MissionDoorDeviceInteractionExt ou interaction du
    PC). Même chemin qu'un joueur qui maintient la touche : interact_start (callbacks mission)
    puis interact. Hôte : server_place_mission_door_device ; client : requête vanilla à l'hôte.
    Jamais d'appareil créé. Sans l'équipement requis : seulement si « Ignorer prérequis » est ON.
  * Auto relancer : hôte = Drill:on_autorepair (Kickstarter) ; client ou PC sans base Drill =
    interaction de réparation vanilla. Un appareil sans courant (coupure scriptée) n'est jamais
    touché. Priorité réparation > pose, une action par vérification (~3/s), 3 s par unité,
    3 s sans nouvelle pose après une pose (porte proposant perceuse + scie).
  * Attention en infiltration : poser une perceuse est bruyant, désactivez « Auto poser » si besoin.
- Monde > Surbrillance : Auto ramasser (ACTIVÉ, rayon 2/5/10/20 m/MAX, défaut 5 m). Colis Gage,
  tortues, fers à cheval seulement, via la vraie interaction de ramassage (client : requête
  sync_pickup validée par l'hôte, récompense / stats / son vanilla). Utilise la liste de la
  surbrillance (pas de scan du monde) : nécessite « Colis / Collectibles » ON. Le plus proche
  d'abord, un par tick, en attente 2 s jusqu'au callback du jeu, 3 essais max par objet.
  pick_up_item (générique) est surligné mais jamais ramassé automatiquement.

Hotfix V13 (1.2)
- Spawn menu : le bouton SPAWN ajoute seulement 1 spawn à la file (FunnyMod.QES.enqueue_spawn),
  anti double-clic 125 ms, la file crée les unités ensuite (SAFE = 1 toutes les 3 frames, forcé
  quand le menu est ouvert). Plus de reconstruction du menu après un spawn : seul le texte
  « QES actifs » est mis à jour (table de suivi QES, « +N » = en attente). Catalogue construit
  une fois par niveau.
- Paramètres > Debug perf : logs [QES][perf] des temps de spawn / refresh menu, SLOW SPAWN /
  SLOW REFRESH au-delà de 50 ms.
- Surbrillance : le marqueur (contour + waypoint) d'un colis disparaît dès qu'il est ramassé ou
  retiré par script (callbacks GageAssignmentManager / Pickup / interaction), le rescan
  périodique ne fait plus que le nettoyage de secours.
- Interactions > Auto perceuse (hôte, ACTIVÉ, rayon 2/5/10/20 m/MAX, défaut 5 m) : perceuses /
  scies / hacks bloqués dans le rayon relancés par la réparation automatique vanilla
  (Drill:on_autorepair, chemin de la compétence Kickstarter : séquence "interact" de l'unité,
  synchronisée aux clients), environ 3 vérifications par seconde, un appareil à la fois.

Version 1.2 (V12)
- Surbrillance corrigée : les colis Gage sont des unités Pickup enregistrées dans
  managers.gage_assignment (pas toujours dans la liste d'interactions) : ils sont maintenant
  trouvés via cette liste + les pickups des slots 23/20. Collectibles = contour + marqueur HUD
  local ; objets de mission et loot (désactivé par défaut) = contour. Rescan toutes les 4 s,
  nettoyé en fin de niveau. Local uniquement.
- Aimbot (désactivé par défaut) : cibles Ennemis / NPC / Tous, FOV 30-180, distance 25 m à
  illimitée, pas de cible derrière un mur. Auto Kill (désactivé par défaut, nécessite l'Aimbot) :
  une mort native par cible, délai 0,1 à 2 s. Hôte : mort native synchronisée. Client : ennemis
  uniquement (dégâts balle natifs).
- Convertir l'ennemi visé / Convertir tous les ennemis (hôte) : conversion GroupAI native,
  sans limite de Jokers, Dozers et spéciaux inclus.
- Échange prison instantané (hôte) : le jeu bloque les échanges pendant chaque assaut et ajoute
  ~10 s de dialogue ; maintenant un joueur en prison est échangé tout de suite s'il existe un
  otage ou un ennemi converti (hors infiltration ; le bouton « Échanger maintenant » marche
  toujours). Respawn forcé (natif).
- Auto relevage des alliés (joueurs + bots) dans un rayon 2/5/10/20 m ou MAX, via
  l'interaction de relevage vanilla (fonctionne en client).
- Délai du suivi 1 à 30 s (sauvegardé, appliqué au cycle suivant), arrivée à côté de la cible.

Mod menu sandbox tout-en-un pour PAYDAY 2, pensé pour les parties privées que
tu héberges avec tes amis.

Prérequis
- PAYDAY 2 (64 bits)
- SuperBLT
- BeardLib (le menu utilise MenuUI de BeardLib)

Installation
1. Extraire le dossier "Funny Mod Menu Troll" dans PAYDAY2/mods/
2. IMPORTANT : désactiver les anciennes versions séparées avant d'activer ce mod
   (Quick Enemy Spawner, God Mode, Infinite Player Resources / Infinite Reserve Ammo,
   Never Detected, No Stealth Noise Alerts, No Player Gun Alerts).
   Un avertissement est écrit dans le log SuperBLT si l'une d'elles est encore active.
3. Lancer PAYDAY 2
4. F9 ouvre / ferme le menu en jeu (seule touche du mod, modifiable dans
   Options > Raccourcis des mods). God Mode et Jamais détecté se règlent dans le menu.

Fonctions
- Spawner d'ennemis par catégories (normales, spéciales, dozers, rares, alliés/Jokers, favoris)
- Tuer (vraie mort) ou Supprimer (nettoyage direct) les ennemis QES / vanilla / tous
- Contrôle des ennemis : désactiver les ennemis vanilla (remis à normal à chaque niveau)
- God Mode personnel, God Mode tous les joueurs (hôte : hôte + bots), One Shot total
  (tout ce que tu touches meurt via le vrai chemin de dégâts du jeu), munitions infinies,
  pas de rechargement, grenades infinies
- Munitions tourelles infinies, équipements infinis, sacs mortuaires infinis
- Interactions instantanées, ignorer prérequis (carte, pied de biche, C4... seulement sur les
  interactions existantes), perceuses incassables (hôte), C4 illimité, liens civils infinis
- Furtif : jamais détecté, caméras aveugles, alertes sonores et pagers désactivés (auto en loud)
- Mode vitesse, ignorer le poids des sacs, Fly Mode, No Clip, Fly + No Clip (ton joueur seulement)
- Spawn de sacs de loot (vrais sacs jetés, synchronisés en réseau)
- Surbrillance des collectibles / objectifs de mission
- Téléportation (vers joueurs et bots, bots / tous vers toi, suivi automatique toutes les 3 s).
  Déplacer un autre joueur humain est impossible : le jeu n'a aucun message réseau pour ça.
- Raccourci Seamless Input Switch dans Paramètres (ouvre le menu de ce mod s'il est installé)
- Prison : échanges instantanés, libération avec otage, respawn forcé
- Administration hôte : expulser, bannir (liste de bannis du jeu), débannir
- Français / English (automatique selon la langue du jeu, ou choisi dans Paramètres)

======================================================================
COMPATIBILITÉ RÉSEAU / NETWORK COMPATIBILITY (V11)
======================================================================

Vérifié dans la source PAYDAY 2 248.2 (chemin réseau / propriétaire de chaque action).
Verified in the PAYDAY 2 248.2 source (network path / owner of every action).
Le mode est détecté en direct (Paramètres > Réseau) : solo, hôte, client, menu.
✅ fonctionne / works   ⚠ partiel ou expérimental / partial or experimental
❌ grisé "HÔTE UNIQUEMENT" / greyed "HOST ONLY"   — sans objet / n/a

FRANÇAIS
| Fonction                      | Solo | Hôte | Client | Pourquoi (source)                                            |
|-------------------------------|------|------|--------|--------------------------------------------------------------|
| God Mode personnel            | ✅   | ✅   | ✅     | chaque joueur calcule ses propres dégâts (PlayerDamage)      |
| God Mode tous les joueurs     | ✅   | ✅*  | ❌     | *hôte + bots ; clients distants non protégeables             |
| One Shot total                | ✅   | ✅   | ⚠      | client : balles + mêlée OK (l'hôte accepte la mort envoyée) ; |
|                               |      |      |        | grenades, Jokers, bots calculés par l'hôte ; humains = mutator Friendly Fire |
| Munitions infinies            | ✅   | ✅   | ✅     | les munitions ne sont jamais synchronisées                   |
| Pas de rechargement           | ✅   | ✅   | ✅     | chargeur local                                               |
| Grenades infinies             | ✅   | ✅   | ✅     | le refund natif fait baisser le compteur anti-triche de l'hôte |
| Munitions tourelles infinies  | ✅   | ✅   | ❌     | les tourelles ne dépensent que sur l'hôte                    |
| Interactions instantanées     | ✅   | ✅   | ✅     | timer local, l'hôte ne vérifie pas la durée                  |
|   (timer perceuse/hack 1 s)   | ✅   | ✅   | ❌     | TimerGui géré par l'hôte                                     |
| Ignorer prérequis             | ✅   | ✅   | ✅     | l'hôte ne revérifie pas l'objet (sync_interacted, unit_tied) |
| Perceuses incassables         | ✅   | ✅   | ❌     | les blocages sont décidés par l'hôte                         |
| C4 illimité                   | ✅   | ✅   | ✅     | même chemin que les prérequis                                |
| Liens civils infinis          | ✅   | ✅   | ✅     | compteur local, unit_tied non vérifié                        |
| Pagers désactivés             | ✅   | ✅   | ❌     | la logique IA (pagers) tourne sur l'hôte                     |
| Vitesse (x1 à x3)             | ✅   | ✅   | ✅     | aucune correction de position ni contrôle de vitesse         |
| Ignorer poids des sacs        | ✅   | ✅   | ✅     | malus calculé localement                                     |
| Fly / No Clip                 | ✅   | ✅   | ⚠      | pas de rollback ; les autres voient une position approchée   |
| Équipements infinis           | ✅   | ✅   | ❌     | l'hôte compte les équipements (verify_deployable = tricheur) |
| Sacs mortuaires infinis       | ✅   | ✅   | ✅     | compteur local                                               |
| Jamais détecté / caméras /    | ✅   | ✅   | ❌     | détection et alertes calculées par l'hôte                    |
|   alertes sonores             |      |      |        |                                                              |
| Surbrillance objets           | ✅   | ✅   | ✅     | contour local uniquement                                     |
| Contrôle ennemis / Tuer /     | ✅   | ✅   | ❌     | IA et unités ennemies appartiennent à l'hôte                 |
|   Supprimer                   |      |      |        |                                                              |
| Spawner QES                   | ✅   | ✅   | ❌     | unités réseau créées par l'hôte                              |
| Loot spawner                  | ✅   | ✅   | ❌     | sacs réseau (server_drop_carry)                              |
| Me téléporter vers joueur/bot | ✅   | ✅   | ✅     | téléport de ton propre joueur + action_teleport natif        |
| Suivi automatique             | ✅   | ✅   | ✅     | même chemin que la téléportation                             |
| TP bots / TP tous vers moi    | ✅   | ✅   | ❌     | les bots sont simulés par l'hôte                             |
| TP un joueur vers moi         | ❌   | ❌   | ❌     | aucun message réseau du jeu pour déplacer un autre joueur    |
| Kick / Ban                    | —    | ✅   | ❌     | hôte d'une partie en ligne                                   |
| Prison / échanges             | ✅   | ✅   | ❌     | TradeManager tourne sur l'hôte                               |
| Auto ramasser / Auto Steal    | ✅   | ✅   | ✅     | vraie interaction ; client : requête sync_pickup /            |
|                               |      |      |        | sync_interacted, l'hôte décide (V15)                          |
| Auto poser / relancer perceuse| ✅   | ✅   | ✅     | client : server_place_mission_door_device vanilla (V15)       |
| Auto relever                  | ✅   | ✅   | ✅     | ReviveInteractionExt : revive_player / revive_unit (V15)      |
| Pose instantanée objets       | ✅   | ✅   | ✅     | timers locaux (deploy timer, _get_timer) (V15)                |
| Vanish                        | ✅   | ✅   | ❌     | détection / ciblage IA calculés par l'hôte (V15)              |
| Invisibilité joueurs          | —    | ✅*  | ✅*    | *pas de RPC visibilité : message BLT, mod requis chez l'autre |
| Seamless Input Switch         | ✅   | ✅   | ✅     | menu local                                                   |

ENGLISH
| Feature                       | Solo | Host | Client | Why (source)                                                 |
|-------------------------------|------|------|--------|--------------------------------------------------------------|
| Personal God Mode             | ✅   | ✅   | ✅     | every player computes their own damage (PlayerDamage)        |
| God Mode all players          | ✅   | ✅*  | ❌     | *host + bots; remote clients cannot be protected             |
| One Shot total                | ✅   | ✅   | ⚠      | client: bullets + melee OK (the host accepts the sent death); |
|                               |      |      |        | grenades, Jokers, bots computed by the host; humans = Friendly Fire mutator |
| Infinite ammo                 | ✅   | ✅   | ✅     | ammo is never synced                                         |
| No reload                     | ✅   | ✅   | ✅     | local magazine                                               |
| Infinite grenades             | ✅   | ✅   | ✅     | the native refund lowers the host's anti-cheat counter       |
| Infinite sentry ammo          | ✅   | ✅   | ❌     | sentries only spend ammo on the host                         |
| Instant interactions          | ✅   | ✅   | ✅     | local timer, the host does not check the duration            |
|   (drill / hack 1 s timer)    | ✅   | ✅   | ❌     | TimerGui is run by the host                                  |
| Ignore requirements           | ✅   | ✅   | ✅     | the host does not re-check the item                          |
| Unbreakable drills            | ✅   | ✅   | ❌     | jams are decided by the host                                 |
| Unlimited C4                  | ✅   | ✅   | ✅     | same path as requirements                                    |
| Infinite cable ties           | ✅   | ✅   | ✅     | local counter, unit_tied not checked                         |
| No pagers                     | ✅   | ✅   | ❌     | AI logic (pagers) runs on the host                           |
| Speed (x1 to x3)              | ✅   | ✅   | ✅     | no position correction, no speed check                       |
| Ignore bag weight             | ✅   | ✅   | ✅     | penalty computed locally                                     |
| Fly / No Clip                 | ✅   | ✅   | ⚠      | no rollback; others see an approximate position              |
| Infinite deployables          | ✅   | ✅   | ❌     | the host counts deployables (verify_deployable = cheater)    |
| Infinite body bags            | ✅   | ✅   | ✅     | local counter                                                |
| Never detected / cameras /    | ✅   | ✅   | ❌     | detection and alerts are computed by the host                |
|   noise alerts                |      |      |        |                                                              |
| Highlight                     | ✅   | ✅   | ✅     | local contour only                                           |
| Enemy control / Kill / Remove | ✅   | ✅   | ❌     | AI and enemy units belong to the host                        |
| QES spawner                   | ✅   | ✅   | ❌     | network units created by the host                            |
| Loot spawner                  | ✅   | ✅   | ❌     | network bags (server_drop_carry)                             |
| Teleport me to player / bot   | ✅   | ✅   | ✅     | moves your own player + native action_teleport               |
| Auto follow                   | ✅   | ✅   | ✅     | same path as teleport                                        |
| TP bots / everyone to me      | ✅   | ✅   | ❌     | bots are simulated by the host                               |
| TP a player to me             | ❌   | ❌   | ❌     | the game has no network message to move another player       |
| Kick / Ban                    | —    | ✅   | ❌     | host of an online game                                       |
| Custody / trades              | ✅   | ✅   | ❌     | TradeManager runs on the host                                |
| Auto pick up / Auto Steal     | ✅   | ✅   | ✅     | real interaction; client: sync_pickup / sync_interacted       |
|                               |      |      |        | request, the host decides (V15)                               |
| Auto drill place / restart    | ✅   | ✅   | ✅     | client: vanilla server_place_mission_door_device (V15)        |
| Auto revive                   | ✅   | ✅   | ✅     | ReviveInteractionExt: revive_player / revive_unit (V15)       |
| Instant object placement      | ✅   | ✅   | ✅     | local timers (deploy timer, _get_timer) (V15)                 |
| Vanish                        | ✅   | ✅   | ❌     | AI detection / targeting computed by the host (V15)           |
| Player invisibility           | —    | ✅*  | ✅*    | *no visibility RPC: BLT message, mod required on the observer |
| Seamless Input Switch         | ✅   | ✅   | ✅     | local menu                                                   |
