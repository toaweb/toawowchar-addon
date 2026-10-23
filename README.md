# toawowchar-addon

The **toawowchar** addon for World of Warcraft: Forever. It makes a text string of what a character has and has done, which the player pastes at [wowchar](https://wowchar.toaweb.com) (a character tracker; its source is the separate repository `toaweb/toawowchar`).

This repository holds the addon, its tests and the scripts that build the download. Players: the addon's own [README](toawowchar/README.md) (it is inside the zip) explains install and use, and the [releases](https://github.com/toaweb/toawowchar-addon/releases) hold the downloads.

## Layout

| Path | What |
|---|---|
| `toawowchar/` | The addon, exactly what goes in the zip: `toawowchar.toc`, `toawowchar.lua` and the players' `README.md` |
| `test/` | The tests (Node's built-in `node:test`, no packages) and the Lua stubs of the game they run the addon against (`test/lua/`) |
| `test/contract.json` | A **copy** of the limits wowchar's server checks; see «The contract with wowchar» |
| `test/fixtures/` | Example exports the addon must keep making byte for byte |
| `scripts/` | `test.sh` (runs the tests in Docker), `check-version.py`, `check-bump.py` (the pull request's version gate), `build-zip.py` |
| `.github/workflows/` | `ci.yml` (tests on every push to `main` and every pull request), `release.yml` (a tag builds, then publishes a release in a second job) |
| `CHANGELOG.md` | Keep a Changelog; every release has an entry |

## Run the tests

Only Docker is needed.

```sh
scripts/test.sh                          # everything
scripts/test.sh test/release.test.mjs    # one file (arguments go to `node --test`)
UPDATE_FIXTURES=1 scripts/test.sh        # write test/fixtures/*.txt again after a deliberate change
```

The tests run in the image of `test/Dockerfile`: Node (the runner), Lua 5.1 (the game's Lua) and Python 3 (the scripts). The Lua tests load `toawowchar/toawowchar.lua` into a stub of the game's API (`test/lua/`) and check the text it makes; the same run checks that text against the contract, and tests the two release scripts. A missing tool fails the run; nothing is skipped.

The run also writes `dist/examples/export-format-3.txt`, an example export made from the stub's invented data. It is a release asset, and wowchar commits it as a fixture.

## Build the zip

```sh
python3 scripts/check-version.py        # the TOC, the Lua, the README and CHANGELOG.md agree on the version
python3 scripts/build-zip.py            # dist/toawowchar-<version>.zip and dist/SHA256SUMS
```

Python 3.8 or newer, standard library only. The zip is the same bytes on every machine: three entries under `toawowchar/` (`README.md`, `toawowchar.lua`, `toawowchar.toc`, in that order), a fixed time stamp, stored and not compressed. CI builds it in two time zones and compares the sha256.

The zip is stored without compression on purpose (131 KB): the same sha256 on every machine matters more than the size, so do not "fix" it.

## Cut a release

1. On a branch from `main`, make the change and bump the version in **all five places** together: `## Version:` in `toawowchar/toawowchar.toc`, `ADDON_VERSION` and the first line (`-- toawowchar X.Y.Z`) in `toawowchar/toawowchar.lua`, the `Version X.Y.Z` line under «Status» in `toawowchar/README.md`, and a new `## [X.Y.Z] - YYYY-MM-DD` entry in `CHANGELOG.md` (with its link at the bottom). The pull request's CI fails otherwise (`scripts/check-bump.py`). Any change to a file in the zip needs a new version, even a typo: wowchar serves the zip under a name that carries the version and caches it for a year.
2. `scripts/test.sh` and `python3 scripts/check-version.py` pass. Open a pull request; CI runs the same, and `python3 scripts/check-bump.py origin/main` (the version is higher than `main`'s whenever a file in the zip changed).
3. Merge to `main`. The owner then tags that commit and pushes the tag:

   ```sh
   git tag -a vX.Y.Z -m vX.Y.Z
   git push origin vX.Y.Z
   ```

4. The tag starts `release.yml`. It checks that the tag is on `main` and equals the version, runs the tests and builds the zip (job `build`, read-only token); a second job (`publish`, no checkout) verifies the files against `SHA256SUMS` and publishes a GitHub Release with the CHANGELOG text of the version and these assets:

   | Asset | What |
   |---|---|
   | `toawowchar-X.Y.Z.zip` | the addon |
   | `SHA256SUMS` | sha256 of the zip and of the example exports (`sha256sum --check SHA256SUMS`) |
   | `export-format-3.txt` | the example export of the format the addon makes (one file per format) |

   The zip's address, which wowchar pins:

   ```
   https://github.com/toaweb/toawowchar-addon/releases/download/vX.Y.Z/toawowchar-X.Y.Z.zip
   ```

5. Then wowchar moves its pin to the new release (version, address, size, sha256, the TOC's interface numbers, and the example exports as fixtures). That is a pull request in the `toaweb/toawowchar` repository.

Tags are never moved or deleted. A bad release is fixed by the next version.

## The contract with wowchar

The text format is **owned by wowchar** (`toaweb/toawowchar`): the prefixes, formats and length limit in `app/shared/addon-export-format.ts`, the section names, reason codes and cached sections in `app/shared/addon-sections.ts`, and the decoder with its limits in `app/server/utils/addon-export.ts`. This repository only makes the text.

- `test/contract.json` is a copy of those values (taken at wowchar commit `dfba6fc`), and `test/lib/contract.mjs` is a test-only port of the strict format 3 check. They are weaker than the real decoder; wowchar's own tests, which import the release's example exports through the real import path, are the check that counts.
- A change to the format goes as **two pull requests, one in each repository**, and the web-app session is told first. wowchar still reads older formats, so its change goes out before the addon release that makes the new one.
- A test fails if the addon makes a format other than 3 without a new example.

## License

MIT, copyright toaweb; see [LICENSE](LICENSE).
