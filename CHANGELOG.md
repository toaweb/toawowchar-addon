# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) ·
Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.1] - 2026-10-22

The first release made from this repository. The addon lived in `toaweb/toawowchar` until now; its
history came along. The addon itself behaves exactly as 0.4.0 did.

### Added
- The Lua tests run on their own, in Docker, without the wowchar app (`scripts/test.sh`), against a
  copy of the export contract that wowchar owns (`test/contract.json`).
- The tests write an example export for each format the addon makes (format 3, `WOWCHAR:3:`) to
  `dist/examples/`, from the test stub's invented data. wowchar checks its real import against them.
- `scripts/build-zip.py` makes `toawowchar-<version>.zip` (the same bytes on every machine and in every
  time zone) and `SHA256SUMS`; `scripts/check-version.py` checks that the TOC, the Lua, the README and
  this changelog agree on the version and that the TOC's interface list is valid.

### Fixed
- A comment in `toawowchar.lua` said Legacy is saved by a capture of its own with a chat line. It is
  saved while `/wowchar` reads it (`Read.Legacy`) and says nothing in the chat. Only the comment was wrong.

## [0.4.0] - 2026-10-21

Released with wowchar 3.11.0 (see wowchar's changelog).

### Added
- The addon is called **toawowchar** (folder, `.toc`, saved data `toawowcharDB`; it was WowcharExport
  before, and nothing is taken over from the old saved data). `/toawowchar` does the same as `/wowchar`.
- Export format 3 (`WOWCHAR:3:`): completed quests, the quest log, recipes with reagents, reputation,
  money and XP, talents, Legacy, flight paths, the season's PvP rank and class spells, each section
  with its source (live, cache, or missing with a reason code).
- A cache on disk (SavedVariables `toawowcharDB`) of what the game only lets the addon read while a
  window is open (bank, recipes, flight paths), plus completed quests and Legacy; `/wowchar reset`
  clears it for the character.
- A snapshot of the equipped items, bags, completed quests, professions and gold, level and XP is kept
  current by seven game events: at most one rebuild of a part every 5 seconds, none in combat, no chat
  lines; the level is read one second after a level-up. A quest turned in also refreshes gold and XP.
- A window with a checklist of every section and its state, and one short chat line when something is
  cached.

### Changed
- The export is format 3 instead of format 2. wowchar still reads formats 1 and 2.

[Unreleased]: https://github.com/toaweb/toawowchar-addon/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/toaweb/toawowchar-addon/releases/tag/v0.4.1
[0.4.0]: https://github.com/toaweb/toawowchar/blob/main/CHANGELOG.md
