# WowcharExport

A small, free addon for World of Warcraft: Forever. It makes a text string of what your character has (equipped items, bags, the bank if you opened it, professions, and the character's name and region) so you can paste it on the character's BiS page at wowchar, which then ticks off the BiS items you already have.

## What it does and does not do

- Does something only when you type `/wowchar`. At login it only registers for events.
- Sends nothing anywhere. An addon cannot reach the internet; you copy the text and paste it yourself.
- Saves nothing to disk (no SavedVariables). Bank contents are remembered in memory while you are logged in and are forgotten at logout or `/reload`.
- Writes nothing to the chat window.
- Plain Lua, no libraries. Free.

## Install

Copy the `WowcharExport` folder into the Forever client's `Interface/AddOns/` folder. The product folder that holds `Interface` is not known until launch (the beta used `_classic_beta_`); in the Battle.net app, use "Show in Explorer" on the Forever entry to find it.

## Use

1. Log in with the character. If you want items in the bank counted, open the bank first (the addon reads it while it is open).
2. Type `/wowchar`. A window opens with the text selected.
3. Press Ctrl+C to copy, close the window (Escape or Close; the text box lets go of the keyboard when the window closes).
4. On that character's BiS page at wowchar, paste the text and import. It only ticks items off; it never un-ticks one.

## What is in the text

Character name, realm, region, class, level, GUID, spec (if the client has one), whether the character is hardcore; the item id and link of each equipped item; the item ids in your bags and, if the bank was opened this session, in the bank; your professions with their skill levels; the addon version and game build; and the time. Each list is cut at 500 items; when that happens the text says so (`truncated`) and the window shows «Some items were left out: a list was longer than 500 items.».

## Status

Version 0.1.0, written before launch and not tested on a real Forever client. The way the text is packed (JSON, compressed, base64) depends on the client's `C_EncodingUtil`, which has to be checked on launch day; the wowchar server and this addon change together if it differs. The text format is described in wowchar's `app/server/utils/addon-export.ts`.
