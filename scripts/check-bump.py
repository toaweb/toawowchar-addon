#!/usr/bin/env python3
"""Fails when something that goes into the zip changed against a base and the version was not raised.

    scripts/check-bump.py origin/main            compare the working tree with origin/main
    --root DIR                                   a checkout other than this one (the tests use it)

The pull-request check of ci.yml runs it with the base branch. The inputs of the zip are the three
files `build-zip.py` reads (`toawowchar/README.md`, `.lua`, `.toc`) and the two scripts that decide
the bytes it writes (`scripts/build-zip.py`, `scripts/addon_info.py`). When none of them differs from
the base, the check passes (docs, tests, workflows may change freely). When one differs, the version
must be strictly higher than the base's in all five places, each place on its own:
  the TOC's `## Version:`, the Lua's `ADDON_VERSION`, the Lua's first line (`-- toawowchar X.Y.Z`),
  the README's `Version X.Y.Z` line and the newest `## [X.Y.Z] - date` entry of CHANGELOG.md,
and that entry must have text. In every case no place may be lower than the base's. That the five
places agree with each other is `check-version.py`'s job.

The base needs the git history of the base (`fetch-depth: 0`). Python 3.8 or newer, standard library
only; git is called with a list of arguments, never through a shell.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

import addon_info

FOLDER = addon_info.FOLDER

# What decides the bytes of the zip.
ZIP_INPUTS = tuple(f"{FOLDER}/{name}" for name in addon_info.ZIP_FILES) + ("scripts/build-zip.py", "scripts/addon_info.py")

PLACES = (
    ("the TOC's ## Version", f"{FOLDER}/{FOLDER}.toc", lambda text: addon_info.parse_toc(text)[0]),
    ("the Lua's ADDON_VERSION", f"{FOLDER}/{FOLDER}.lua", addon_info.lua_version),
    ("the Lua's first line", f"{FOLDER}/{FOLDER}.lua", addon_info.lua_header_version),
    ("the README's version line", f"{FOLDER}/README.md", addon_info.readme_version),
    ("the newest CHANGELOG entry", "CHANGELOG.md", lambda text: (addon_info.changelog_versions(text) or [None])[0]),
)


def git(root, *args):
    """Returns (exit status, stdout as text)."""
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, check=False)
    return result.returncode, result.stdout.decode("utf-8", "replace")


def triple(version):
    match = addon_info.SEMVER.fullmatch(version or "")
    return tuple(int(part) for part in match.groups()) if match else None


def changelog_entry(text, version):
    """The lines under `## [version] - date`, up to the next heading or link reference."""
    lines = []
    on = False
    for line in text.splitlines():
        if re.match(rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}$", line):
            on = True
        elif on and (line.startswith("## [") or re.match(r"^\[[^\]]+\]: ", line)):
            break
        elif on:
            lines.append(line)
    return "\n".join(lines).strip()


def check_bump(root, base):
    """Returns (summary, problems) for the tree at `root` against the git ref `base`."""
    root = Path(root)
    if not base or base.startswith("-"):
        return "", [f"the base {base!r} is not a git ref"]
    status, out = git(root, "rev-parse", "--verify", "--quiet", f"{base}^{{commit}}")
    if status != 0:
        return "", [f"the base {base!r} is not a commit here (the checkout needs fetch-depth: 0)"]
    sha = out.strip()

    status, out = git(root, "diff", "--name-only", sha, "--", *ZIP_INPUTS)
    if status != 0:
        return "", [f"git diff against {base} failed"]
    changed = [line for line in out.splitlines() if line]

    problems = []
    base_texts = {}
    head_texts = {}
    for label, path, read in PLACES:
        if path not in base_texts:
            status, out = git(root, "show", f"{sha}:{path}")
            base_texts[path] = out if status == 0 else None
            try:
                head_texts[path] = (root / path).read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                head_texts[path] = None
        if base_texts[path] is None:
            problems.append(f"cannot read {path} at {base}, so {label} cannot be compared")
            continue
        if head_texts[path] is None:
            problems.append(f"cannot read {path}")
            continue
        old = read(base_texts[path])
        new = read(head_texts[path])
        if triple(new) is None:
            problems.append(f"{label} is {new if new is not None else 'missing'}, not MAJOR.MINOR.PATCH")
            continue
        if triple(old) is None:
            problems.append(f"{label} at {base} is {old if old is not None else 'missing'}, so it cannot be compared")
            continue
        if triple(new) < triple(old):
            problems.append(f"{label} is {new}, lower than {old} at {base}")
        elif changed and triple(new) == triple(old):
            problems.append(f"{label} is still {old}: raise it ({', '.join(changed)} changed against {base})")

    if changed and not problems:
        version = (addon_info.changelog_versions(head_texts["CHANGELOG.md"]) or [""])[0]
        if not changelog_entry(head_texts["CHANGELOG.md"], version):
            problems.append(f"CHANGELOG.md: the entry for {version} has no text")

    if changed:
        summary = f"zip inputs changed against {base} ({', '.join(changed)})"
    else:
        summary = f"no zip input changed against {base}"
    return summary, problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("base", help="the git ref to compare with, e.g. origin/main")
    parser.add_argument("--root", default=str(addon_info.ROOT), help="the repository to check (default: this one)")
    args = parser.parse_args(argv)

    summary, problems = check_bump(args.root, args.base)
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    print(f"version bump: {'FAILED' if problems else 'OK'}" + (f" ({summary})" if summary else ""))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
