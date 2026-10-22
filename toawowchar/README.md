# toawowchar

A small, free addon for World of Warcraft: Forever. It makes a text string of what your character has and has done, so you can paste it at [wowchar](https://wowchar.toaweb.com): on «My characters» to add the character, or on the character's BiS page to mark the BiS items you already have as obtained.

The text holds who the character is, the equipped items, the bags, the bank and the warband bank, the professions and their recipes, the completed quests and the quest log, reputation, gold and XP, talents, Legacy, the flight paths, the season's PvP rank and the class spells you know.

## What it does and does not do

- Makes the text when you type `/wowchar` (or `/toawowchar`, the same command). Between those moments it only listens for game events: it remembers the bank while you have it open, the recipes of a profession while its window is open and the flight paths while a flight map is open, and it quietly keeps a current copy of your equipped items, bags, completed quests, professions and gold, level and XP (see «The snapshot»).
- Sends nothing anywhere. You copy the text and paste it yourself.
- Saves a **cache** to disk (SavedVariables `toawowcharDB`): what the game lets an addon read only while a window is open, plus the completed quests, Legacy and the snapshot. It is only a cache: the addon works the same when nothing was saved, or when the game does not keep the file. See «The cache».
- Says one short line in the chat window when it has cached something new («toawowchar: saved 212 Tailoring recipes.»), one when you type `/wowchar` in combat, and one for `/wowchar reset`. Nothing else.
- Plain Lua, no libraries. Free.

## Install

1. Download `toawowchar-<version>.zip` from the [latest release](https://github.com/toaweb/toawowchar-addon/releases/latest). Next to it are `SHA256SUMS` (to check the download) and an example of the text the addon makes.
2. Unzip it into the Forever client's `Interface/AddOns/` folder, so the result is `World of Warcraft/_forever_/Interface/AddOns/toawowchar/` (`_forever_` is the Forever product folder, product `wowf`). In the Battle.net app, «Show in Explorer» on the Forever entry opens the game folder.
3. If you have 0.3.x, **delete the old `WowcharExport` folder first**: since 0.4.0 the addon is a new addon with a new name (`toawowchar`) and it does not read the old saved data (SavedVariables `WowcharExportDB`; the cache is made again the first time you open the windows).

wowchar offers the same zip for download on its «Addon» page.

## Use

1. Log in with the character. To get more into the text, open the windows the game only lets the addon read while they are open, and leave each open for a moment: the **bank** (it also reads the warband bank), a **profession window** (once for each profession; it reads the recipes you know) and a **flight map** at a flight master. The cache remembers them for next time.
2. Type `/wowchar`. The window opens with the text selected. In combat the game hides some values from addons, so the addon says so and opens the window when combat ends.
3. Press Ctrl+C to copy, then close the window (Escape or «Close»). The text box lets go of the keyboard when the window closes.
4. At wowchar, either
   - **add the character**: «My characters» → «Add character from addon», paste the text. The character is added to your list (or updated, if it is already yours) and it is your character. The addon cannot prove who you are, so this is not verified. If the character already belongs to another account, you get an error and nothing is changed. A way for the player whose Battle.net account has the character to take it over is planned for after launch; it is not built yet. Character names must be 2 to 12 letters (no spaces or digits). Or
   - **update one of your characters**: on its BiS page, paste the text and import.

   Either way the BiS items you already have are marked as obtained (an obtained mark is never taken back), and a snapshot of your gear and professions is stored.

`/wowchar reset` (or `/toawowchar reset`) clears this character's cache (and forgets what was read in this play session); it does not open the window.

## The window

A frame made from Blizzard's own templates, 620 by 470, centred, in wowchar's colours. Drag it anywhere; Escape closes it (when the client supports that; not verified on Forever).

- Title «wowchar export».
- The character line: name, level, race, class, realm.
- A checklist with a row for each section and its state, in words and with a small icon: a green tick for **read now**, an hourglass for **saved … ago** (from the cache) and a red cross for **missing**, with what to do about it («open your bank», «open a profession window», «open a flight map», «not loaded yet, try again», «hidden in combat», «not in this game version», «left out: text too long»). Lists show how many they hold.
- The export text, selected and ready for Ctrl+C. Under it the size in characters and KB.
- The buttons «Select all» and «Close», and the line «Paste it on wowchar.toaweb.com > My characters».

## What is in the text

The text starts with `WOWCHAR:3:` and then plain, readable JSON (format 3). It is not compressed or encoded, so you can read it, and it contains no `|`, which the game would treat as the start of a colour code or link.

**Every section says where it came from**: read now, from the cache (with the time it was read) or missing with a reason. Missing is never the same as «you do not have it»: it only means the addon could not read it at that moment.

- **Completed quests only ever grow.** The game's list can be empty just after login, so a missing id is never «not done»: the text carries everything the game's list and the cache have ever shown. With nothing saved and an empty list, the section is missing, not «no quests done». The list is read when you type `/wowchar`.
- **The quest log** lists the quests the game shows. Quests under a collapsed zone header are not listed (the addon does not open your quest log's headers); the text says how many such quests there are. Hidden, task and world-quest rows are skipped.
- **Reputation** opens collapsed faction headers to read the rows under them and collapses again the ones you had collapsed.
- **Recipes** are read from the profession window. The window can hide recipes behind a filter or a collapsed category, so recipes are **merged** into what is saved, never replaced. Windows of other players (linked recipes), guild recipes and NPC crafting are not read.
- **Flight paths** are read from the flight map and merged into the cache.
- **Class spells** come from the spell book: guild and hidden lines, lines named like one of your professions, off-spec items, flyouts and future spells are skipped.
- **Honor** is this season's PvP rank. Forever has no Classic honor rank; the rank is the renown level of a major faction.
- **Legacy**: the three Legacy trees' ranks and points. It is cached per character; whether Legacy is account-wide is not known. The Legacy challenges (achievements) have no reliable source yet and are not in the text.
- **Combat**: nothing is captured in combat, and `/wowchar` in combat waits for the end of combat. A value the game hides from addons makes its section missing («hidden in combat»).
- **Safety net.** wowchar refuses a whole text when one value is outside its limits, so the addon checks the same limits itself and leaves out a value that does not fit, instead of cutting or changing it. This is not expected to happen with the real game. A character name longer than 64 characters (no real one is) gives no text at all.
- **Length.** Lists are cut at fixed numbers (the ones wowchar checks) and the text says when one was cut; the window then shows «Some lists were cut at their limit.». If the whole text would be longer than wowchar takes (128 KiB, or 144 KiB for the request the browser makes of it), the addon leaves out the lowest-priority sections (class spells, flight paths, Legacy, talents, honor rank, then reputation, quest log and recipes) and marks them «left out: text too long». A test character with everything full (level 60, 1,500 completed quests, full bags and banks, 80 reputations) made 62,740 characters (61.3 KiB), so this is not expected in practice.

The rest is the character data wowchar uses to show what fits your character:

- Name, realm, class, level, race, faction, GUID (sent, but wowchar does not store it), spec (if the client has one) and whether the character is hardcore. The race is the race's file token (`NightElf`, `Scourge`, ...), not the name in your language; the faction is `Alliance`, `Horde` or `Neutral`. A value the game does not give is left out.
- The region: `US`, `KR`, `EU`, `TW` or `CN` when the game reports one of them, otherwise no region but the number the client reported and its `portal` setting (for example `test`); wowchar then does not compare regions.
- For each equipped item: the slot, the item id, the enchant id, the gem ids, the suffix id and the bonus ids. They are read from the item's link by position and the link itself is not sent. wowchar marks BiS items by item id only.
- The item ids in your bags and, if the bank was read, in the bank and the warband bank.
- Your professions with their skill levels, the addon version and game build, and the time.

## The cache

SavedVariables `toawowcharDB[realm][name]` holds, for each character:

| Saved | Merged or replaced | Time |
|---|---|---|
| bank, warband bank | replaced by a full new read | when it was read |
| recipes, one entry per profession | **merged** (never replaced, never shortened) | per profession |
| flight paths | **merged** | when last read |
| completed quests | **merged** with the game's list | when last read |
| Legacy | replaced by a new read that found a tree | when it was read |
| equipped items, bags, professions, gold/level/XP (the snapshot) | replaced by a full new read | when it was read |

- The cache is checked field by field the first time it is used: only whole numbers in range are kept, strings are cut at their limits and lists at the export's caps, so a damaged or edited file cannot make a bigger text than the game could.
- When `toawowcharDB` is nil or not a table (nothing saved, or SavedVariables not kept), it starts empty and the addon works from what the game answers now, keeping what it reads in memory for the play session.
- `/wowchar reset` removes this character's record. Other characters' records are not touched.

## The snapshot

Seven game events keep a copy of five parts of the character in the cache, so SavedVariables holds a current copy when you log out, whether or not you typed `/wowchar`:

| Event | Refreshes |
|---|---|
| `PLAYER_EQUIPMENT_CHANGED` | the equipped items |
| `BAG_UPDATE_DELAYED` | the bags (the bank is scanned as before while it is open) |
| `QUEST_TURNED_IN` | the completed quests (the turned-in quest at once) and gold, level and XP |
| `SKILL_LINES_CHANGED` | the professions |
| `PLAYER_MONEY` | gold, level and XP |
| `PLAYER_XP_UPDATE` | gold, level and XP |
| `PLAYER_LEVEL_UP` | gold, level and XP, read **one second after** the event: some game clients still answer the old level and XP maximum while the event fires |

- **Throttled.** At most one rebuild of a part every 5 seconds. The first event rebuilds at once; the ones that follow share one rebuild when the 5 seconds are over, so the last change is never lost.
- **Not in combat.** Nothing is read in combat; the parts that changed are rebuilt once when combat ends. A level-up in combat is read when combat ends.
- **Silent.** No chat line.
- Typing `/wowchar` also refreshes the copy. The equipped items and the bags are always read from the game for the text; the professions and gold/level/XP are taken from the copy (marked as from the cache, with its time) only when the game gives nothing at that moment.

## The bank

The addon reads the character bank tabs first. If none of them can be read, it reads the older bank instead (the main bank and the bank bag slots). Which of the two Forever uses is not known until launch, so the text records the one that ran. Either way the bank is only read while it is open.

**The warband bank** is read in the same pass, tab by tab, into its own list. A tab you have not bought has no slots and gives nothing. If the game has no warband bank, the section says «not in this game version».

**A scan only counts if the bank is still open at the end.** If you close the bank while the addon is still reading it, the game answers «empty» for the slots it has not read yet, and a partial list would wrongly replace the good one. So the addon checks, at the end of the scan, that the bank has not been closed and that the last slot that held an item still shows an item. If not, the list from the earlier full scan is kept. The same check is made for the warband bank, separately. A scan that finds no item at all also keeps the earlier list, because there is nothing to check it against; this means that emptying the whole bank is not noticed until something is in it again.

In wowchar, bank items and warband bank items count as obtained only when the text says that bank was read (now or from the cache).

## What is new

**0.4.1.** The first release made from the addon's own repository, `toaweb/toawowchar-addon`. The code is the same as 0.4.0; one wrong comment about the Legacy cache was corrected.

**0.4.0.** The addon is renamed **toawowchar** (folder, TOC, SavedVariables `toawowcharDB`; no data is taken over from `WowcharExportDB`), and `/toawowchar` works like `/wowchar`. A snapshot of the equipped items, bags, completed quests, professions and gold/level/XP is kept current by game events (the level one second after a level-up). Format 3 (`WOWCHAR:3:`): completed quests, the quest log, recipes with reagents, reputation, money and XP, talents, Legacy, flight paths, the season's PvP rank and class spells, each with its source (read now, cache or missing with a reason). A SavedVariables cache of the bank, recipes, flight paths, Legacy and completed quests, and `/wowchar reset`. A new window with a checklist. The addon says one short line when it caches something. wowchar still reads formats 2 and 1.

The full history is in the [changelog](https://github.com/toaweb/toawowchar-addon/blob/main/CHANGELOG.md).

## Status

Version 0.4.1. In a real Forever client (build 70450, addon 0.4.0) these were checked on 2026-10-22: SavedVariables are read back after `/reload`, the completed quests come back in full right after login, and the professions are read without the profession window. **Not yet tried in a real client:** the bank and the warband bank, and the recipes from the profession window; the flight map was not part of that check either. Earlier versions (0.1 and 0.2) made format 1 (`WOWCHAR:1:`, compressed and base64), which depended on a game function that was never checked on a real client; wowchar still accepts such a text, but the addon no longer makes it.

Source, bug reports and the text format's contract with wowchar: <https://github.com/toaweb/toawowchar-addon>.
