# WowcharExport

A small, free addon for World of Warcraft: Forever. It makes a text string of what your character has and has done (equipped items, bags, the bank and the warband bank, professions with their recipes, completed quests and the quest log, reputation, gold and XP, talents, Legacy, flight paths, the season's PvP rank and the class spells you know, and who the character is) so you can paste it at wowchar: on «My characters» to add the character, or on the character's BiS page to mark the BiS items you already have as obtained.

## What it does and does not do

- Makes the text when you type `/wowchar`. Between those moments it only listens for events: it quietly remembers the bank while you have it open, the recipes of a profession while its window is open, and the flight paths while a flight map is open.
- Sends nothing anywhere. An addon cannot reach the internet; you copy the text and paste it yourself.
- Saves a **cache** to disk (SavedVariables `WowcharExportDB`), only of what the game lets an addon read while a window is open, plus the completed quests and Legacy. It is a cache: the addon works exactly the same when nothing was saved, or when the game does not keep the file (it is not known whether the Forever beta does). See «The cache».
- Says one short line in the chat window when it has cached something new («wowchar: saved 212 Tailoring recipes.»), one when you type `/wowchar` in combat, and one for `/wowchar reset`. Nothing else.
- Plain Lua, no libraries. Free.

## Install

Copy the `WowcharExport` folder into the Forever client's `Interface/AddOns/` folder. The Forever product folder is `_forever_` (product `wowf`), so the result is `World of Warcraft/_forever_/Interface/AddOns/WowcharExport/`. In the Battle.net app, "Show in Explorer" on the Forever entry opens the game folder.

## Use

1. Log in with the character. To get more into the text, open the windows the game only lets the addon read while they are open, and leave each open for a moment: the **bank** (also reads the warband bank), a **profession window** (once for each profession; it reads the recipes you know), a **flight map** at a flight master. The cache remembers them for next time.
2. Type `/wowchar`. The window opens with the text selected. In combat the game hides some values from addons, so the addon says so and opens the window when combat ends.
3. Press Ctrl+C to copy, then close the window (Escape or «Close»). The text box lets go of the keyboard when the window closes.
4. At wowchar, either
   - **add the character**: «My characters» → «Add character from addon», paste the text. The character is added to your list (or updated, if it is already yours) and it is your character. The addon cannot prove who you are, so this is not verified. If the character already belongs to another account, you get an error and nothing is changed. A way for the player whose Battle.net account has the character to take it over is planned for after launch; it is not built yet. Character names must be 2 to 12 letters (no spaces or digits). Or
   - **update one of your characters**: on its BiS page, paste the text and import.

   Either way the BiS items you already have are marked as obtained (it never takes an obtained mark back), and a snapshot of your gear and professions is stored.

`/wowchar reset` clears this character's cache (and forgets what was read in this play session); it does not open the window.

## The window

A frame made from Blizzard's own templates (`BasicFrameTemplateWithInset`, `InputScrollFrameTemplate`, `UIPanelButtonTemplate`; each has a fallback if a client lacks it), 620 by 470, centred, in the app's colours (indigo `#131129` background, primary `#8B7CFF`, accent `#5FD4E6`). Drag it anywhere; Escape closes it.

- Title «wowchar export».
- The character line: name, level, race, class, realm.
- A checklist with a row for each section and its state, in words and with Blizzard's ready-check icons: a green tick for **read now**, a hourglass for **saved N min/h/d ago** (from the cache) and a red cross for **missing**, with what to do («open your bank», «open a profession window», «open a flight map», «not loaded yet, try again», «hidden in combat», «not in this game version», «left out: text too long»). Lists show how many they hold.
- The export text, selected, ready for Ctrl+C; typing in the box puts the text back. Under it the size in characters and KB.
- «Select all» and «Close» buttons, and the line «Paste it on wowchar.toaweb.com > My characters».

## What is in the text

The text starts with `WOWCHAR:3:` and then plain, readable JSON (format 3). It is not compressed or encoded, so you can read it, and it contains no `|`, which the game would treat as the start of a colour code or link. The addon writes the JSON itself; it needs nothing from the game for that. The shape is described in wowchar's `docs/addon-export-format-3.md` and decoded by `app/server/utils/addon-export.ts`.

Format 3 is everything format 2 had (below, «From earlier versions») plus a `sections` object. **Every section says where it came from**: `live` (read now, or captured while its window was open earlier in this play session), `cache` (from an earlier play session, with the unix time it was read) or `missing` with a reason code. The codes are `open_bank`, `open_profession_window`, `open_flight_map`, `not_loaded` (the game had not loaded it yet), `in_combat` (the game hid the values), `not_available` (this game version has no such function) and `too_large` (left out to keep the text short enough).

In priority order, with the game functions each section reads (Blizzard's `forever` UI source, build 1.60.1.70450; **nothing was run in a live client**, every call is guarded, and a failing one makes only that section `missing`):

| Section | Reads | Live | Cache | Missing |
|---|---|---|---|---|
| **P1** `questsDone`: completed quest ids | `C_QuestLog.GetAllCompletedQuestIDs()` | the game's list, **joined** with every id seen before | the saved ids, when the game's list is empty (just after login or at logout) | `not_loaded` when empty and nothing saved; `not_available` |
| `questLog`: quest id, finished, objectives (text, have, need, done) | `C_QuestLog.GetNumQuestLogEntries`, `GetInfo`, `GetQuestObjectives`, `IsComplete` | always | no | `not_available` |
| `professions`: skill line, rank, max rank | `GetProfessions`, `GetProfessionInfo` | always | no | `not_available` |
| `recipes`: recipes you know with their reagents (item id, count), per profession | `C_TradeSkillUI.GetBaseProfessionInfo`, `GetAllRecipeIDs` / `GetFilteredRecipeIDs`, `GetRecipeInfo`, `GetRecipeSchematic` | read in this session | earlier sessions | `open_profession_window` |
| `reputation`: faction id, reaction, standing, where the reaction starts and ends, name | `C_Reputation.GetNumFactions`, `GetFactionDataByIndex` | always | no | `not_loaded`, `not_available` |
| `player`: money (copper), level, XP, XP max, rested XP | `GetMoney`, `UnitLevel`, `UnitXP`, `UnitXPMax`, `GetXPExhaustion` | always | no | `in_combat`, `not_available` |
| **P2** `talents`: trait tree, node, rank, chosen entry | `C_ClassTalents.GetActiveConfigID`, `C_Traits.GetConfigInfo`, `GetTreeNodes`, `GetNodeInfo` | always | no | `not_loaded`, `not_available` |
| `legacy`: points available, cap, spent; the three trees' ranks | `C_Traits.GetConfigIDByTreeID`, `GetTreeCurrencyInfo`, `GetTreeNodes`, `GetNodeInfo` for trees 1187, 1188, 1189 | the game's answer | the last good read | `not_loaded` (no tree ready) |
| `flightPaths`: taxi node ids | `C_TaxiMap.GetAllTaxiNodes`, `GetTaxiNodesForMap` | read in this session | earlier sessions | `open_flight_map` |
| `honor`: this season's PvP rank | `C_MajorFactions.GetMajorFactionProgressionInfo(2800)` | always | no | `not_loaded`, `not_available` |
| `classSpells`: spell ids from the spell book | `C_SpellBook.GetNumSpellBookSkillLines`, `GetSpellBookSkillLineInfo`, `GetSpellBookItemInfo` | always | no | `not_loaded`, `not_available` |

Details that matter:

- **Completed quests only ever grow.** The game's list can be empty just after login and at logout, so a missing id is never «not done»: the text carries the union of the game's list and everything seen before, and an empty list never empties anything. With nothing saved, an empty list is `missing`/`not_loaded`, not «no quests done». The list is read when you type `/wowchar`, not at logout.
- **The quest log** lists the quests the game shows. Quests under a collapsed zone header are not listed (the addon does not open your quest log's headers); `hidden` is how many such quests there are. Hidden, task and world-quest rows are skipped.
- **Reputation** opens collapsed faction headers to read the rows under them (only when the game has both `ExpandAllFactionHeaders` and `CollapseFactionHeader`) and collapses again the ones you had collapsed.
- **Recipes**: the profession window can hide recipes behind a filter or a collapsed category, so the recipes are **merged** into what is saved, never replaced. A recipe counts when `learned` is true. Reagents come from the recipe's schematic: for each required slot the first reagent's item id and the quantity. Skipped: optional and finishing slots, currency reagents and other quality tiers. Windows of other players (linked recipes), guild recipes and NPC crafting are not read. The profession is the window's base profession (`parentProfessionID` or `professionID`); the text sends the game's own skill line id and name, the addon keeps no table of them (the ids 2937-2948 the owner mentioned have no source).
- **Flight paths**: Forever does not load Blizzard's old taxi frame, so `TaxiNodeName`/`TaxiNodeGetType` are not used. The nodes with state «current» or «reachable» on the flight map, and the discovered nodes of that map, are merged into the cache.
- **Class spells** come from the spell book, not the trainer window: guild and hidden lines, lines named like one of your professions, off-spec items, flyouts and future spells are skipped.
- **Honor**: Forever has no Classic honor rank; its PvP rank is the renown level of major faction 2800, per season, so the keys are `seasonRank` and `seasonMax`, not «highest».
- **Legacy**: the third tree is «Progression» in the game's code; the addon keys on the tree ids 1187, 1188 and 1189 (`Constants.LegacyConsts` when the game has it). Whether Legacy is account-wide is not proven, so it is cached per character like the rest. The **challenges** (achievements) have no reliable source yet and are always `missing`/`not_available`.
- **Combat**: nothing is captured in combat, and `/wowchar` in combat waits for the end of combat. A value the game hides from addons (a «secret» value) makes its section `missing`/`in_combat`.
- **What the addon leaves out, and why.** wowchar's server checks every number and text in the export against fixed limits and refuses the whole text if one value is outside its limit, so the addon checks the same limits itself and leaves out whatever does not fit, so that one odd value never makes the paste fail. Left out: a reputation row whose reaction is not 0 to 20 or whose standing, start or end is beyond 1,000,000,000 either way; a quest objective whose count is outside 0 to 1,000,000,000; a trait node whose rank is above 255 or whose chosen entry is not a valid id; a Legacy tree whose points spent is outside 0 to 1,000,000,000 (its points-available, cap and spent numbers are left out one by one when they are); a recipe reagent whose count is above 9,999; any id (item, spell, quest, recipe, faction, trait node, flight path) that is not a whole number from 1 to 2,147,483,647; a profession whose name is empty or longer than 64 characters (or only its skill line, rank or max rank when one is outside 0 to 1,000,000); an equipped slot with such an item id. Left out of the character data when they do not fit: the realm (over 100 characters), the spec name (over 50), the class id and region id (outside 0 to 1,000,000), the level (outside 1 to 255), money, XP and rested XP (outside their ranges), the season's maximum rank (above 1,000). A season rank above 1,000 makes the honor section `missing`. A clock that gives a time before 2001 or after 2100 leaves out `capturedAt` and the times of live sections, and makes a saved (cache) section, or a profession's saved recipes, `missing`. A character name longer than 64 characters (no real one is) gives no text at all. Nothing is cut or changed to fit: a value either fits as it is or it is left out. None of this is expected to happen with the real game; it is a safety net. wowchar's own limits are in `app/server/utils/addon-export.ts` (`ADDON_BOUNDS` and `ADDON_LIST_CAPS`) and a test compares them with this file's `BOUNDS` and `CAPS`, name by name.
- Lists are cut at fixed numbers (the same ones wowchar's server checks): 500 item ids in a bag list, 5,000 completed quests, 50 quest log entries, 200 factions, 600 recipes in a profession, 150 nodes in a trait tree, 200 flight paths, 400 class spells. When one is cut the text says so (`truncated`) and the window shows «Some lists were cut at their limit.».
- If the whole text would be longer than 128 KiB (wowchar's limit), or the request the browser makes of it would be longer than 144 KiB (the text is sent as `{"export": "…"}`, which writes each `"` and `\` of it as two bytes, so a text of mostly quotes can be under 128 KiB and still over the request limit; real texts have a few thousand at most), the addon leaves out the lowest-priority sections (class spells, flight paths, Legacy, talents, honor rank, then reputation, quest log and recipes) and marks them `missing`/`too_large`. A maxed character's text (level 60, 1,500 completed quests, a full quest log, two full professions of 260 recipes and three small ones, all bags, the bank and the warband bank full, 80 reputations, talents, three Legacy trees, 60 flight paths, 150 spells) measured 62,740 characters (61.3 KiB).

### From earlier versions (format 2's content, unchanged)

- Character name, realm, class, level, race, faction, GUID (sent, but wowchar does not store it), spec (if the client has one), whether the character is hardcore.
- The race is the race's file token (`NightElf`, `Scourge`, ...), not the name in your language, and the faction is `Alliance`, `Horde` or `Neutral`. wowchar uses them to show the quests that fit your character. If the game gives no value, the addon leaves that key out and the import works as before.
- The region: `US`, `KR`, `EU`, `TW` or `CN` when the game reports one of them (`GetCurrentRegion()` 1 to 5), otherwise no region but the number the client reported (`regionId`, for example 110 on the Forever test client) and its `portal` setting (for example `test`), in which case wowchar does not compare regions.
- For each equipped item: the slot, the item id, the enchant id, the gem ids, the suffix id (always a positive number) and the bonus ids. They are read from the item's link by position and the link itself is not sent. wowchar marks BiS items by item id only; it keeps the other numbers with the gear snapshot.
- The item ids in your bags and, if the bank was read, in the bank (`bankSource` says which kind of bank was read: `tabs` for the character bank tabs, `classic` for the older bank with its bank bags; left out when the bank was not read), and in the warband bank (`warbank`, with `warbankSeen`). `bankSeen` and `warbankSeen` are true when the bank section is live or cache.
- Your professions with their skill levels, the addon version and game build, and the time.

## The cache

SavedVariables `WowcharExportDB[realm][name]` holds, for each character:

| Saved | Merged or replaced | Time |
|---|---|---|
| bank, warband bank | replaced by a full new read | when it was read |
| recipes, one entry per profession | **merged** (never replaced, never shortened) | per profession |
| flight paths | **merged** | when last read |
| completed quests | **merged** with the game's list | when last read |
| Legacy | replaced by a new read that found a tree | when it was read |

- The cache is rebuilt field by field the first time it is used: only whole numbers in range, strings cut at their limits and lists cut at the export's caps are kept, so a damaged or edited file cannot make a bigger text than the game could.
- When `WowcharExportDB` is nil or not a table (nothing saved, or SavedVariables not kept), it starts empty and the addon works from what the game answers now, keeping what it reads in memory for the play session.
- `/wowchar reset` removes this character's record. Other characters' records are not touched.
- The addon never reads the cache to change what the game shows; it only adds to the text.

## The bank

The addon reads the character bank tabs first. If none of them can be read, it reads the older bank instead (the main bank and the bank bag slots). Which of the two World of Warcraft: Forever uses is not known until launch, so the text records the one that ran in `bankSource`. Either way the bank is only read while it is open.

**The warband bank** is read in the same pass, tab by tab (`AccountBankTab_1`, `_2`, ... up to the first tab the game does not have), into its own list. A tab you have not bought has no slots and gives nothing. If the game has no warband bank, the list is empty and the section says `not_available`.

**A scan only counts if the bank is still open at the end.** If you close the bank while the addon is still reading it, the game answers "empty" for the slots it has not read yet, and a partial list would wrongly replace the good one. So the addon checks, at the end of the scan, that the bank has not been closed and that the last slot that held an item still shows an item. If not, the list from the earlier full scan is kept. The same check is made for the warband bank, separately. A scan that finds no item at all also keeps the earlier list, because there is nothing to check it against; this means that emptying the whole bank is not noticed until something is in it again.

In wowchar, bank items and warband bank items count as obtained only when the text says that bank was read (live or from the cache).

## What is new

**0.4.0.** Format 3 (`WOWCHAR:3:`): completed quests, the quest log, recipes with reagents, reputation, money and XP, talents, Legacy, flight paths, the season's PvP rank and class spells, each with its source (live, cache or missing with a reason). A SavedVariables cache of the bank, recipes, flight paths, Legacy and completed quests, and `/wowchar reset`. A new window with a checklist. The addon now says one short line when it caches something. wowchar still reads formats 2 and 1.

**0.3.1.** The text also has the character's race and faction. Nothing else changed.

## Status

Version 0.4.0, written before launch and not tested on a real Forever client. Earlier versions (0.1 and 0.2) made format 1 (`WOWCHAR:1:`, compressed and base64), which depended on a game function that was never checked on a real client; wowchar still accepts such a text, but the addon no longer makes it. The text format is described in wowchar's `docs/addon-export-format-3.md` and decoded in `app/server/utils/addon-export.ts`.
