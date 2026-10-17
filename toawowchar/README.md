# WowcharExport

A small, free addon for World of Warcraft: Forever. It makes a text string of what your character has (equipped items, bags, the bank if you opened it, professions, and who the character is) so you can paste it at wowchar: on «My characters» to add the character, or on the character's BiS page to mark the BiS items you already have as obtained.

## What it does and does not do

- Does something only when you type `/wowchar`. At login it only registers for events.
- Sends nothing anywhere. An addon cannot reach the internet; you copy the text and paste it yourself.
- Saves nothing to disk (no SavedVariables). Bank contents are remembered in memory while you are logged in and are forgotten at logout or `/reload`.
- Writes nothing to the chat window.
- Plain Lua, no libraries. Free.

## Install

Copy the `WowcharExport` folder into the Forever client's `Interface/AddOns/` folder. The Forever product folder is `_forever_` (product `wowf`), so the result is `World of Warcraft/_forever_/Interface/AddOns/WowcharExport/`. In the Battle.net app, "Show in Explorer" on the Forever entry opens the game folder.

## Use

1. Log in with the character. If you want items in the bank counted, open the bank first (the addon reads it while it is open).
2. Type `/wowchar`. A window opens with the text selected.
3. Press Ctrl+C to copy, close the window (Escape or Close; the text box lets go of the keyboard when the window closes).
4. At wowchar, either
   - **add the character**: «My characters» → «Add character from addon», paste the text. The character is created (or updated, if it is already yours) and you become its owner. The addon cannot prove who you are, so this ownership is unverified: if the character is later found on a Battle.net account, that account wins. A character that already belongs to another account is refused. Or
   - **update a character you own**: on its BiS page, paste the text and import.

   Either way the BiS items you already have are marked as obtained (it never takes an obtained mark back), and a snapshot of your gear and professions is stored.

## What is in the text

Character name, realm, class, level, GUID (sent, but wowchar does not store it), spec (if the client has one), whether the character is hardcore; the region: `US`, `KR`, `EU`, `TW` or `CN` when the game reports one of them (`GetCurrentRegion()` 1 to 5), otherwise no region but the number the client reported (`regionId`, for example 110 on the Forever test client) and its `portal` setting (for example `test`), in which case wowchar does not compare regions; the item id and link of each equipped item; the item ids in your bags and, if the bank was opened this session, in the bank (`bankSource` says which kind of bank was read: `tabs` for the character bank tabs, `classic` for the older bank with its bank bags; left out when the bank was not opened); your professions with their skill levels; the addon version and game build; and the time. Each list is cut at 500 items; when that happens the text says so (`truncated`) and the window shows «Some items were left out: a list was longer than 500 items.».

## The bank

The addon reads the character bank tabs first. If none of them can be read, it reads the older bank instead (the main bank and the bank bag slots). Which of the two World of Warcraft: Forever uses is not known until launch, so the export records the one that ran in `bankSource`. Either way the bank is only read while it is open.

## Status

Version 0.2.0, written before launch and not tested on a real Forever client. The way the text is packed (JSON, compressed, base64) depends on the client's `C_EncodingUtil`, which has to be checked on launch day; the wowchar server and this addon change together if it differs. The text format is described in wowchar's `app/server/utils/addon-export.ts`.
