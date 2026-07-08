#!/usr/bin/env python3
"""Sync loose fallback icon PNGs in the app root to the merged catalog.

Usage: overwrite_loose_icons.py <app_dir> <extract_dir>

Twitter.app ships loose primary-icon files at its root (e.g.
ProductionAppIcon60x60@2x.png, ProductionAppIcon76x76@2x~ipad.png) that
SpringBoard uses for the home-screen icon. Replacing icons only inside
Assets.car leaves these stale, so the home screen keeps the old art. Here we
overwrite each loose root icon with the matching rendition from the freshly
rebuilt catalog (car_extract output in <extract_dir>), matched by the icon
asset name (filename prefix) and pixel dimensions.
"""

import json
import os
import shutil
import struct
import sys


def png_dims(path):
    # Scan chunks for IHDR. iOS "CgBI" PNGs prepend a CgBI chunk before IHDR,
    # so we can't assume IHDR is first.
    with open(path, "rb") as f:
        if f.read(8) != b"\x89PNG\r\n\x1a\n":
            return None
        while True:
            head = f.read(8)
            if len(head) < 8:
                return None
            length = struct.unpack(">I", head[:4])[0]
            if head[4:8] == b"IHDR":
                return struct.unpack(">II", f.read(8))
            f.seek(length + 4, 1)  # skip chunk data + CRC


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: overwrite_loose_icons.py <app_dir> <extract_dir>\n")
        return 2
    app_dir, extract_dir = sys.argv[1], sys.argv[2]

    with open(os.path.join(extract_dir, "manifest.json")) as fh:
        manifest = json.load(fh)
    # (asset name, w, h) -> extracted png; and the set of asset names.
    by_key = {}
    names = set()
    for m in manifest:
        names.add(m["renditionName"])
        by_key[(m["renditionName"], int(m["width"]), int(m["height"]))] = \
            os.path.join(extract_dir, m["file"])

    synced, skipped = [], []
    for f in os.listdir(app_dir):
        if f.startswith("._") or not f.lower().endswith((".png", ".jpg", ".jpeg")):
            continue
        fp = os.path.join(app_dir, f)
        if not os.path.isfile(fp):
            continue
        dims = png_dims(fp)
        if not dims:
            continue
        # Longest asset name that prefixes this loose filename (e.g.
        # "ProductionAppIcon60x60@2x.png" -> "ProductionAppIcon").
        cands = [n for n in names if f.startswith(n)]
        if not cands:
            continue
        name = max(cands, key=len)
        src = by_key.get((name, dims[0], dims[1]))
        if src:
            shutil.copyfile(src, fp)
            synced.append((f, "%dx%d" % dims))
        else:
            skipped.append((f, "%dx%d" % dims))

    print("loose icons: %d synced to catalog" % len(synced))
    for f, d in synced:
        print("  synced: %s (%s)" % (f, d))
    for f, d in skipped:
        print("  no-match: %s (%s) has no catalog rendition of that size" % (f, d))
    return 0


if __name__ == "__main__":
    sys.exit(main())
