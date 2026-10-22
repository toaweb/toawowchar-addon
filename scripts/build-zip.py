#!/usr/bin/env python3
"""Builds the addon download: toawowchar-<version>.zip and SHA256SUMS.

    scripts/build-zip.py                 writes dist/toawowchar-<version>.zip and dist/SHA256SUMS
    scripts/build-zip.py --out DIR       writes them to DIR
    --root DIR                           build from another checkout (the tests use it)

The zip is the same bytes on every machine, in every time zone, on every day:
  * exactly three entries, in this order, under `toawowchar/`: README.md, toawowchar.lua,
    toawowchar.toc (no directory entries, nothing else);
  * every entry is stamped 2026-01-01 00:00:00 (the DOS date and time, no time zone), the
    same stamp wowchar's app/build/addon-release.ts used, and has the attributes of a
    regular file, mode 0644, made by Unix;
  * entries are STORED, not compressed. Deflate output depends on the zlib that makes it
    (zlib, zlib-ng, Chromium's fork all differ), so a compressed zip could not be promised
    identical everywhere; the cost is about 100 KB;
  * the container is written here byte by byte (no zipfile module), so a new Python cannot
    change it.
The build first runs the version check and stops if anything disagrees. A source file with
a carriage return stops it too: line endings are LF (see .gitattributes).

Python 3.8 or newer, standard library only.
"""
import argparse
import hashlib
import io
import struct
import sys
import zipfile
import zlib
from pathlib import Path

import addon_info

# 2026-01-01 00:00:00 as MS-DOS date and time.
DOS_TIME = 0
DOS_DATE = ((2026 - 1980) << 9) | (1 << 5) | 1
# Regular file, rw-r--r--, in the high 16 bits of the external attributes; "made by" Unix (3), spec 2.0.
EXTERNAL_ATTRIBUTES = (0o100000 | 0o644) << 16
VERSION_MADE_BY = (3 << 8) | 20
VERSION_NEEDED = 20
STORED = 0


def build_zip(entries):
    """The bytes of a zip with `entries` (a list of (path in the zip, bytes)), stored, in that order."""
    body = bytearray()
    directory = bytearray()
    for name, data in entries:
        raw_name = name.encode("ascii")  # a non-ASCII name would need a flag: not needed, not allowed
        crc = zlib.crc32(data) & 0xFFFFFFFF
        offset = len(body)
        body += struct.pack(
            "<IHHHHHIIIHH",
            0x04034B50, VERSION_NEEDED, 0, STORED, DOS_TIME, DOS_DATE, crc, len(data), len(data), len(raw_name), 0,
        )
        body += raw_name + data
        directory += struct.pack(
            "<IHHHHHHIIIHHHHHII",
            0x02014B50, VERSION_MADE_BY, VERSION_NEEDED, 0, STORED, DOS_TIME, DOS_DATE, crc, len(data), len(data),
            len(raw_name), 0, 0, 0, 0, EXTERNAL_ATTRIBUTES, offset,
        )
        directory += raw_name
    end = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(entries), len(entries), len(directory), len(body), 0)
    return bytes(body + directory + end)


def read_sources(root):
    addon = Path(root) / addon_info.FOLDER
    entries = []
    for name in addon_info.ZIP_FILES:
        data = (addon / name).read_bytes()
        if b"\r" in data:
            raise SystemExit(f"error: {addon / name} has a carriage return; the zip is built from LF files only")
        entries.append((f"{addon_info.FOLDER}/{name}", data))
    return entries


def verify(zip_bytes, entries):
    """Reads the zip back with the standard library and compares it with the sources."""
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as archive:
        if archive.testzip() is not None:
            raise SystemExit("error: the zip fails its own CRC check")
        names = archive.namelist()
        if names != [name for name, _ in entries]:
            raise SystemExit(f"error: the zip holds {names}")
        for name, data in entries:
            if archive.read(name) != data:
                raise SystemExit(f"error: {name} in the zip differs from its source")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(addon_info.ROOT), help="the repository to build from (default: this one)")
    parser.add_argument("--out", default=None, help="where to write the zip and SHA256SUMS (default: <root>/dist)")
    args = parser.parse_args(argv)

    root = Path(args.root)
    version, problems = addon_info.check(root)
    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        print("no zip is made: the version check failed", file=sys.stderr)
        return 1

    entries = read_sources(root)
    zip_bytes = build_zip(entries)
    verify(zip_bytes, entries)

    out = Path(args.out) if args.out else root / "dist"
    out.mkdir(parents=True, exist_ok=True)
    name = f"{addon_info.FOLDER}-{version}.zip"
    digest = hashlib.sha256(zip_bytes).hexdigest()
    (out / name).write_bytes(zip_bytes)
    # The format `sha256sum -c` reads: hash, two spaces, name.
    (out / "SHA256SUMS").write_text(f"{digest}  {name}\n", encoding="ascii")
    print(f"{name}  {len(zip_bytes)} bytes  sha256 {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
