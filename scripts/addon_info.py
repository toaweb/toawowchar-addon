"""What the addon's own files say about its version and its zip.

Shared by check-version.py and build-zip.py. Python 3.8 or newer, standard library
only. The rules are the ones wowchar's app/build/addon-release.ts used when the addon
lived in that repository: the zip holds the addon's README, Lua and TOC under
`toawowchar/`, and the TOC, the Lua, the README and the CHANGELOG agree on the version.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The folder at the root of the zip, and the stem of the addon's files.
FOLDER = "toawowchar"

# What goes into the zip, in this order (sorted by code unit, not by locale). Nothing else:
# no tests, no scripts. The TOC may only load files that are in this list.
ZIP_FILES = ("README.md", f"{FOLDER}.lua", f"{FOLDER}.toc")

SEMVER = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)")

# A game interface number is five or six digits (11507 Classic Era, 16001 Forever, 120105 Retail).
INTERFACE_MIN = 10000
INTERFACE_MAX = 999999


def read_text(path):
    return Path(path).read_text(encoding="utf-8")


def parse_toc(text):
    """Returns (version, interface_values, files): `## Version:` text, the raw comma-separated
    items of `## Interface:` (None when the line is missing) and the files the TOC loads."""
    version = None
    interface = None
    files = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        meta = re.match(r"^##\s*([A-Za-z0-9-]+)\s*:\s*(.*)$", line)
        if meta:
            key = meta.group(1).lower()
            if key == "version":
                version = meta.group(2).strip()
            elif key == "interface":
                interface = [item.strip() for item in meta.group(2).split(",")]
        elif not line.startswith("#"):
            files.append(line)
    return version, interface, files


def interface_problems(items):
    """What is wrong with the items of `## Interface:`, as a list of sentences. Empty when valid."""
    if items is None:
        return ["the TOC has no ## Interface: line"]
    problems = []
    numbers = []
    for item in items:
        if not re.fullmatch(r"\d+", item):
            problems.append(f"the TOC's ## Interface: has {item!r}, which is not a whole number (the list is comma-separated)")
            continue
        number = int(item)
        if not INTERFACE_MIN <= number <= INTERFACE_MAX:
            problems.append(f"the TOC's ## Interface: number {number} is outside {INTERFACE_MIN} to {INTERFACE_MAX}")
        numbers.append(number)
    if not items or items == [""]:
        problems.append("the TOC's ## Interface: list is empty")
    duplicates = sorted({n for n in numbers if numbers.count(n) > 1})
    if duplicates:
        problems.append(f"the TOC's ## Interface: lists {', '.join(map(str, duplicates))} more than once")
    return problems


def lua_version(text):
    """`local ADDON_VERSION = "0.4.1"` in the addon's Lua."""
    match = re.search(r'^local ADDON_VERSION = "([^"\r\n]*)"', text, re.MULTILINE)
    return match.group(1) if match else None


def lua_header_version(text):
    """The first line of the addon's Lua: `-- toawowchar 0.4.1` (None when it is not that)."""
    match = re.match(rf"-- {FOLDER} (\S+)[ \t]*(?:\r?\n|\Z)", text)
    return match.group(1) if match else None


def readme_version(text):
    """The README's current-version line: `Version 0.4.1, written ...` (under «Status»)."""
    match = re.search(r"^Version (\d+(?:\.\d+)+)\b", text, re.MULTILINE)
    return match.group(1) if match else None


def changelog_versions(text):
    """The versions of the `## [X.Y.Z] - YYYY-MM-DD` headings, newest first (file order)."""
    return re.findall(r"^## \[(\d+\.\d+\.\d+)\] - \d{4}-\d{2}-\d{2}$", text, re.MULTILINE)


def check(root):
    """Returns (version, problems): the TOC's version and everything that disagrees."""
    root = Path(root)
    addon = root / FOLDER
    problems = []

    def get(path):
        try:
            return read_text(path)
        except (OSError, UnicodeDecodeError) as error:
            problems.append(f"cannot read {path.relative_to(root)}: {error}")
            return None

    toc_text = get(addon / f"{FOLDER}.toc")
    toc_version, interface, toc_files = parse_toc(toc_text or "")
    version = toc_version or ""
    if toc_text is None:
        pass
    elif not toc_version:
        problems.append("the TOC has no ## Version: line")
    elif not SEMVER.fullmatch(toc_version):
        problems.append(f"the TOC's ## Version is {toc_version!r}, not MAJOR.MINOR.PATCH")

    lua_text = get(addon / f"{FOLDER}.lua")
    lua = lua_version(lua_text or "")
    if lua_text is not None and lua != toc_version:
        problems.append(f"the Lua's ADDON_VERSION is {lua if lua is not None else 'missing'}, the TOC's ## Version is {toc_version or 'missing'}")

    header = lua_header_version(lua_text or "")
    if lua_text is not None and header != toc_version:
        problems.append(
            f"the Lua's first line says {header if header is not None else 'no version (expected \'-- ' + FOLDER + ' X.Y.Z\')'}, "
            f"the TOC's ## Version is {toc_version or 'missing'}"
        )

    readme_text = get(addon / "README.md")
    readme = readme_version(readme_text or "")
    if readme_text is not None and readme != toc_version:
        problems.append(f"the README's version line is {readme if readme is not None else 'missing'}, the TOC's ## Version is {toc_version or 'missing'}")

    changelog_text = get(root / "CHANGELOG.md")
    changelog = changelog_versions(changelog_text or "")
    if changelog_text is not None and (not changelog or changelog[0] != toc_version):
        problems.append(
            f"CHANGELOG.md: the newest entry is {changelog[0] if changelog else 'missing'}, "
            f"the TOC's ## Version is {toc_version or 'missing'} (add '## [{toc_version}] - YYYY-MM-DD')"
        )

    if toc_text is not None:
        problems += interface_problems(interface)

    for name in toc_files:
        if name not in ZIP_FILES:
            problems.append(f"the TOC loads {name}, which the zip does not contain (ZIP_FILES in scripts/addon_info.py)")
    return version, problems
