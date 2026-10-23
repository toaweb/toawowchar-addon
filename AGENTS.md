# toawowchar-addon: agent guide

The **toawowchar** addon for World of Warcraft: Forever, its tests and the scripts that build its download. Public repository `toaweb/toawowchar-addon`. The web app that reads what the addon makes is a separate repository, `toaweb/toawowchar` («wowchar»).

Developer commands and the release steps are in [README.md](README.md); this file holds the rules. Standards come from the toa-rules MCP (`git`, `versioning`, `dependencies`, `security`, `deployment-strategy`).

## What lives where

| Here (toawowchar-addon) | In wowchar (toawowchar) |
|---|---|
| The addon: `toawowchar/toawowchar.lua`, `.toc` and the players' `README.md` | The web app, its database, its Docker image and deploy |
| The Lua tests and the stub of the game's API (`test/lua/`) | The import of the text (the real decoder) and its tests |
| The release scripts, CI and the release workflow | The pin of an addon release (`app/shared/addon-release.ts`): version, asset address, size, sha256, TOC interface numbers |
| The example exports of a release | The same examples, committed as fixtures that must import without error |
| `test/contract.json`, a **copy** of the limits | **The format itself** |

**The export formats are owned by wowchar.** The truth is in its `app/shared/addon-export-format.ts` (prefixes, formats, length limit), `app/shared/addon-sections.ts` (section names, missing reasons, cached sections) and the decoder in `app/server/utils/addon-export.ts` (`ADDON_BOUNDS`, `ADDON_LIST_CAPS`). `test/contract.json` is a copy taken at wowchar commit `dfba6fc`; when wowchar changes one of those values, the copy is changed in the matching pull request here. Never change the copy alone to make a test pass.

**A format change goes as two pull requests, one per repository, and the web-app session is told first** (the owner or the lead tells it; do not start the addon side alone). wowchar still reads older formats, so its pull request is merged and deployed first, then this repository's, then a release, then wowchar moves its pin.

## Release

Steps are in README.md, «Cut a release». The rules behind them:

- The version is in five places that must agree: `## Version:` in the TOC, `ADDON_VERSION` in the Lua, the first line of the Lua (`-- toawowchar X.Y.Z`), the `Version X.Y.Z` line in `toawowchar/README.md` (the first line that starts that way; keep it under «Status») and the newest `## [X.Y.Z] - date` in `CHANGELOG.md`. `scripts/check-version.py` checks them; `## Interface:` must be a comma-separated list of whole numbers (10000 to 999999), no repeats.
- **The pull-request version gate.** A change to any file in the zip (`toawowchar/*`) or to the scripts that decide its bytes (`scripts/build-zip.py`, `scripts/addon_info.py`) needs a new version, higher than the base branch's in all five places, and a CHANGELOG entry with text, even for a comment or a typo. `ci.yml` enforces it on every pull request with `scripts/check-bump.py origin/<base>` (the base comes through `env:`; the checkout has `fetch-depth: 0`). Docs, tests and workflows may change without a bump. A version never goes down. Do not weaken or skip the step to get a pull request through. SemVer; pre-1.0, so a MINOR may break.
- **The owner tags and pushes.** Agents do not commit, tag, push or run workflows without being told to. `vX.Y.Z` is annotated and is put on a commit on `main`; `release.yml` publishes the release. Tags are never moved or deleted.
- **Tag ruleset.** Before the first tag the owner sets up a tag ruleset on this repository (pattern `v*`, restrict updates and deletions). Tags are never moved or deleted; a bad release gets a new version.
- The release asset address is `https://github.com/toaweb/toawowchar-addon/releases/download/vX.Y.Z/toawowchar-X.Y.Z.zip`. wowchar pins that address with the size and sha256 of the file, so a release is never replaced after it is published: a fix is a new version. The size and sha256 to pin are in the release's `SHA256SUMS` and in the output of `python3 scripts/build-zip.py` (the build is deterministic: the local zip equals the release's).
- After a release, wowchar's pin is bumped: its `AGENTS.md`, «Addon release», has its side of the procedure.
- The zip holds exactly `toawowchar/README.md`, `toawowchar/toawowchar.lua` and `toawowchar/toawowchar.toc`, in that order. A new file in the zip means a change to `ZIP_FILES` in `scripts/addon_info.py` and in the TOC. Source files are LF only (`.gitattributes`); `build-zip.py` refuses a carriage return.

## CI and workflows

- **No self-hosted runners.** This repository is public, and `deployment-strategy` forbids self-hosted runners for public repositories. Every job is `runs-on: ubuntu-latest`. Do not add `runs-on` variables that could point elsewhere.
- Actions are pinned to a full commit SHA with the version as a comment: `actions/checkout`, `actions/upload-artifact` and `actions/download-artifact` today (resolve a SHA with `gh api repos/actions/<name>/git/ref/tags/<tag>`, and peel an annotated tag; never write one from memory). Each workflow has `permissions: contents: read` at the top; only the `publish` job in `release.yml` has `contents: write`. `persist-credentials: false` on checkout, because the tests run repository code. Values from the event go through `env:`, never `${{ }}` inside a `run:` script.
- **Build and publish are separate jobs, and the job that holds the write token runs no repository code.** `release.yml`'s `build` job (`contents: read`) runs the repository's code and uploads `release/` and `release-notes.md` as a workflow artifact (retention one day). The `publish` job (`needs: build`, `contents: write`) has no checkout: it downloads the artifact, runs `sha256sum --check SHA256SUMS` (and refuses files SHA256SUMS does not list) and then `gh release create --verify-tag --repo "$GITHUB_REPOSITORY"`. Never add a checkout, a script from this repository or a third-party action that builds or runs code to `publish`; new build steps go in `build`.
- `ci.yml` (push to `main`, pull requests): `scripts/test.sh`, `scripts/check-version.py`, on a pull request `scripts/check-bump.py` against the base branch, and the zip built twice in different time zones with the sha256 compared.
- `release.yml` (tag `v*.*.*`): job `build`: the tag must be on `main`; `check-version.py <tag>`; tests; zip; `SHA256SUMS` over the zip and the examples; the CHANGELOG section of the version as notes; upload as an artifact. Job `publish`: verify the artifact, then create the release with the preinstalled `gh` (`gh release create --verify-tag`, which fails on an existing release; no third-party action holds the write token).
- `.github/dependabot.yml`: weekly version updates for `github-actions` and for the base image of `test/Dockerfile`. The image is pinned by digest (`FROM node:24-alpine@sha256:…`); Dependabot moves the digest.
- No secrets exist or are needed. This repository does not deploy anything; wowchar's pipeline downloads the release.
- Workflows are checked with `docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.12` (includes shellcheck).

## Decisions of the owner (run 024)

These are intended behaviour, not bugs; change them only when the owner says so.

- **The snapshot is throttled to one rebuild of a part every 5 seconds** (`SNAPSHOT_INTERVAL`). The first event rebuilds at once; the events inside the interval share one rebuild at its end. Nothing is read in combat; the parts that changed are rebuilt once when combat ends. The snapshot never writes to the chat.
- **A quest turned in also refreshes gold and XP** (`QUEST_TURNED_IN` asks for the `player` part as well as the completed quests), because the reward changes them.
- **The level is read 1 second after `PLAYER_LEVEL_UP`** (`LEVEL_UP_DELAY`): some clients still answer the old level and XP maximum while the event fires.
- The addon is called toawowchar (folder, TOC, SavedVariables `toawowcharDB`); `/wowchar` and `/toawowchar` are the same command. Nothing is taken over from the old `WowcharExportDB`.

## Verified in a real client

On 2026-10-22, in a real Forever client (build 70450, addon 0.4.0):

- SavedVariables are read back after `/reload`.
- The completed quests come back in full right after login.
- `GetProfessions` gives the skill without the profession window open (Mining is skill line 186).
- Every quest id checked exists in Questie.
- Seen in a real export: a character with no spec chosen yet gets the class as its spec (spec id 1485, name «Hunter»). The addon sends what the game says; the web app handles it.

**Not tested in a real client:** the bank and warband bank capture, and the recipes read from the profession window (not reachable yet). The flight map was not part of the check. Say so when writing about them; do not call them verified.

## Rules for work here

- **Commits in this repository use the owner's GitHub noreply address `241168682+toaweb@users.noreply.github.com`**, not a personal address (the history is public). It is set per repository: `git config user.email 241168682+toaweb@users.noreply.github.com` in each clone. The history before this rule carries two personal addresses and `Claude-Session:` URLs in commit messages; that was seen, is accepted, and is not rewritten (the owner may decide otherwise).
- Conventional Commits, English, lowercase (`git` standard). Branch from `main`; short branches (`feat/…`, `fix/…`, `chore/…`).
- The completed quests only ever grow (the union of the game's list and the cache); an empty answer never empties anything. A value outside wowchar's limits is left out, never cut, because wowchar refuses the whole text for one bad value.
- The Lua is the WoW client's Lua 5.1. Every game call is guarded (`pcall` or an existence check): a missing function makes one section `missing`, never an error. The text is written by the addon's own serializer; no `|` may reach the copy box.
- Do not weaken a test to make it pass. `UPDATE_FIXTURES=1` is for a deliberate change to what the addon exports, and the diff of `test/fixtures/` is then read.
- The players' README is player-facing and must be true to the code. Check a claim against `toawowchar/toawowchar.lua` before you write it; say «not tested in a real client» where that is the case.
- Dependencies: none (Node's built-in test runner, Python's standard library, no `package.json`). A new dependency needs a reason (`dependencies` standard).

## License

MIT, copyright toaweb (`LICENSE`).
