# Funny Mod Menu Troll

All-in-one sandbox mod menu for **PAYDAY 2**. Press **F9** in game to open it.

Dev by [Elexyr22](https://elexyr22.fr/) - English / Français

> Sandbox / troll mod. Some features only work as host, and many are visible to other players. Use it with friends or solo.

## Features

The menu has nine categories:

| Category | What it holds |
|---|---|
| COMBAT | God Mode, One Shot, Auto Kill, Aimbot and more |
| INTERACTIONS | Instant interactions, requirement bypass, unbreakable drills, auto drill place / repair, auto pickup, auto steal, automatic mission actions, instant placement |
| SPAWNER | Enemy spawner with favorites and spawn speed options (host only) |
| WORLD | Enemy control (vanilla enemies, waves, block all enemies) and world options |
| ME | Fly / No Clip, movement, resources, Vanish |
| TEAM | Per-player page: teleport, follow, revive, custody, kick / ban, mod detection |
| TROLL | Shortcuts to the funniest options |
| SECRET | Secret puzzle door, piano and achievements tools (see below) |
| SETTINGS | Language (auto / FR / EN), network, gamepad, performance, about |

The menu tells you in a short tag whether a feature works locally, as host only, or as client.

### SECRET tab

Merged from the former *Auto Secret Door*, *Auto Secret Piano* and *Secret Logger* mods:

- **Puzzle door**: solves the 4 riddles of the Secret door (heist *The White House*).
- **Piano**: plays the 9-note Secret sequence (in your *Safe House*). Solving it redraws your 20 Secret achievements.
- **Achievements**: exports your 20 Secret achievements to `logs/secret_achievements.txt` and `.json` (read only), with an optional auto reroll until every locked achievement is doable without DLC.
- **Auto complete**: automates the Secret achievement of *Henry's Rock*, *Breakin' Feds*, *Diamond Store* and *No Mercy*.

The tab shows whether you are in the right level and, if not, explains where to go.

### Seamless Input Switch

[Seamless Input Switch](https://github.com/Lukituki6/Seamless-Input-Switch-PD2-Mod) by Lukituki6 (MIT) is bundled in `sis/`, so you can switch between keyboard / mouse and gamepad without restarting the game. Its settings are in SETTINGS > Gamepad.

## Requirements

- PAYDAY 2 with [SuperBLT](https://superblt.znix.xyz/)
- BeardLib (the F9 menu is a BeardLib MenuUI)

Remove the standalone *Auto Secret Door*, *Auto Secret Piano*, *Secret Logger* and *Seamless Input Switch* mods if you have them: they are included here and would load twice.

## Installation

1. Install SuperBLT and BeardLib.
2. Copy the `Funny Mod Menu Troll` folder into `PAYDAY 2/mods/`.
3. Start the game and press **F9** (a reminder appears in the top right when a level starts).

The key can be changed in Options > Mod Keybinds.

## Multiplayer note

Vanish (invisibility) and the mod detection use a small handshake between players who have the mod. A one-time "Funny Game lol" message is sent in the chat of online sessions (can be turned off in SETTINGS > Network).

## Credits and licenses

- Funny Mod Menu Troll by [Elexyr22](https://elexyr22.fr/) - see `LICENSE`.
- Seamless Input Switch by Lukituki6 - MIT, see `sis/LICENSE`.

---

# Français

Mod menu bac à sable tout-en-un pour **PAYDAY 2**. Appuie sur **F9** en jeu pour l'ouvrir.

**Fonctions**: God Mode, One Shot, aimbot, spawner d'ennemis, interactions instantanées, auto drill / steal, vol et No Clip, téléportation, gestion des joueurs (kick / ban), Vanish, et un onglet **SECRET** (porte à énigmes, piano, achievements). Interface en français et en anglais.

**Prérequis**: SuperBLT et BeardLib.

**Installation**: copie le dossier `Funny Mod Menu Troll` dans `PAYDAY 2/mods/`, lance le jeu et appuie sur F9. Retire les anciens mods *Auto Secret Door*, *Auto Secret Piano*, *Secret Logger* et *Seamless Input Switch* s'ils sont installés, ils sont déjà inclus.

L'onglet SECRET indique si tu es au bon niveau: la porte dans *La Maison Blanche*, le piano dans la *Safe House*, l'auto complétion dans *Henry's Rock*, *Breakin' Feds*, *Diamond Store* et *No Mercy*.
