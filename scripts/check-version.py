#!/usr/bin/env python3
"""Fails unless the addon's version is the same everywhere and the TOC is valid.

    scripts/check-version.py            the TOC's ## Version, the Lua's ADDON_VERSION and its first
                                        line (`-- toawowchar X.Y.Z`), the README's
                                        «Version X.Y.Z» line and the newest CHANGELOG entry agree;
                                        ## Interface: is a comma-separated list of whole numbers
                                        (10000 to 999999), at least one, no repeats; the TOC loads
                                        only files the zip contains
    scripts/check-version.py v0.4.1     and the tag equals v<version> (the release workflow passes
                                        the tag it was started for)
    --root DIR                          check another checkout (the tests use it)

Exit status 0 when everything agrees, 1 with one line for each problem otherwise.
Python 3.8 or newer, standard library only.
"""
import argparse
import re
import sys

import addon_info


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("tag", nargs="?", help="a release tag, vX.Y.Z, that must equal the version")
    parser.add_argument("--root", default=str(addon_info.ROOT), help="the repository to check (default: this one)")
    args = parser.parse_args(argv)

    version, problems = addon_info.check(args.root)
    if args.tag is not None:
        match = re.fullmatch(r"v(\d+\.\d+\.\d+)", args.tag)
        if not match:
            problems.append(f"the tag {args.tag!r} is not vMAJOR.MINOR.PATCH")
        elif match.group(1) != version:
            problems.append(f"the tag is {args.tag}, the TOC's ## Version is {version or 'missing'}")

    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    print(f"version {version or '?'}: {'FAILED' if problems else 'OK'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
