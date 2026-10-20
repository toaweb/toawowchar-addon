# WowcharExport

A small, free addon for World of Warcraft: Forever. It makes a text string of what your character has (equipped items, bags, the bank and the warband bank if you opened the bank, professions, and who the character is) so you can paste it at wowchar: on «My characters» to add the character, or on the character's BiS page to mark the BiS items you already have as obtained.

## What it does and does not do

- Does something only when you type `/wowchar`. At login it only registers for events.
- Sends nothing anywhere. An addon cannot reach the internet; you copy the text and paste it yourself.
- Saves nothing to disk (no SavedVariables). Bank and warband bank contents are remembered in memory while you are logged in and are forgotten at logout or `/reload`.
- Writes nothing to the chat window.
- Plain Lua, no libraries. Free.

## Install

Copy the `WowcharExport` folder into the Forever client's `Interface/AddOns/` folder. The Forever product folder is `_forever_` (product `wowf`), so the result is `World of Warcraft/_forever_/Interface/AddOns/WowcharExport/`. In the Battle.net app, "Show in Explorer" on the Forever entry opens the game folder.

## Use

1. Log in with the character. If you want items in the bank and the warband bank counted, open the bank first and leave it open for a moment (the addon reads it while it is open).
2. Type `/wowchar`. A window opens with the text selected.
3. Press Ctrl+C to copy, close the window (Escape or Close; the text box lets go of the keyboard when the window closes).
4. At wowchar, either
   - **add the character**: «My characters» → «Add character from addon», paste the text. The character is added to your list (or updated, if it is already yours) and it is your character. The addon cannot prove who you are, so this is not verified. If the character already belongs to another account, you get an error and nothing is changed. A way for the player whose Battle.net account has the character to take it over is planned for after launch; it is not built yet. Character names must be 2 to 12 letters (no spaces or digits). Or
   - **update one of your characters**: on its BiS page, paste the text and import.

   Either way the BiS items you already have are marked as obtained (it never takes an obtained mark back), and a snapshot of your gear and professions is stored.

## What is in the text

The text starts with `WOWCHAR:2:` and then plain, readable JSON (format 2). It is not compressed or encoded, so you can read it, and it contains no `|`, which the game would treat as the start of a colour code or link. The addon writes the JSON itself; it needs nothing from the game for that.

- Character name, realm, class, level, race, faction, GUID (sent, but wowchar does not store it), spec (if the client has one), whether the character is hardcore.
- The race is the race's file token (`NightElf`, `Scourge`, ...), not the name in your language, and the faction is `Alliance`, `Horde` or `Neutral`. wowchar uses them to show the quests that fit your character. If the game gives no value, the addon leaves that key out and the import works as before.
- The region: `US`, `KR`, `EU`, `TW` or `CN` when the game reports one of them (`GetCurrentRegion()` 1 to 5), otherwise no region but the number the client reported (`regionId`, for example 110 on the Forever test client) and its `portal` setting (for example `test`), in which case wowchar does not compare regions.
- For each equipped item: the slot, the item id, the enchant id, the gem ids, the suffix id (always a positive number) and the bonus ids. They are read from the item's link by position and the link itself is not sent. wowchar marks BiS items by item id only; it keeps the other numbers with the gear snapshot.
- The item ids in your bags and, if the bank was read this session, in the bank (`bankSource` says which kind of bank was read: `tabs` for the character bank tabs, `classic` for the older bank with its bank bags; left out when the bank was not read), and in the warband bank (`warbank`, with `warbankSeen`).
- Your professions with their skill levels, the addon version and game build, and the time.

Each list of item ids is cut at 500 items; when that happens the text says so (`truncated`) and the window shows «Some items were left out: a list was longer than 500 items.».

## The bank

The addon reads the character bank tabs first. If none of them can be read, it reads the older bank instead (the main bank and the bank bag slots). Which of the two World of Warcraft: Forever uses is not known until launch, so the export records the one that ran in `bankSource`. Either way the bank is only read while it is open.

**The warband bank** is read in the same pass, tab by tab (`AccountBankTab_1`, `_2`, ... up to the first tab the game does not have), into its own list. A tab you have not bought has no slots and gives nothing. If the game has no warband bank, the list is empty and wowchar is told it was not read.

**A scan only counts if the bank is still open at the end.** If you close the bank while the addon is still reading it, the game answers "empty" for the slots it has not read yet, and a partial list would wrongly replace the good one. So the addon checks, at the end of the scan, that the bank has not been closed and that the last slot that held an item still shows an item. If not, the list from the earlier full scan is kept, together with the fact that the bank was seen. The same check is made for the warband bank, separately. A scan that finds no item at all also keeps the earlier list, because there is nothing to check it against; this means that emptying the whole bank is not noticed until something is in it again.

In wowchar, bank items and warband bank items count as obtained only when the export says that bank was read.

## What is new

**0.3.1.** The text now also has the character's race (`identity.race`, the race file token from `UnitRace("player")`) and faction (`identity.faction`, from `UnitFactionGroup("player")`). Both are optional: a game that gives nothing leaves the key out, and an older text without them still imports. The format is still `WOWCHAR:2:`. Nothing else changed.

## Status

Version 0.3.1, written before launch and not tested on a real Forever client. Earlier versions (0.1 and 0.2) made format 1 (`WOWCHAR:1:`, compressed and base64), which depended on a game function that was never checked on a real client; wowchar still accepts such a text, but the addon no longer makes it. The text format is described in wowchar's `app/server/utils/addon-export.ts`.
