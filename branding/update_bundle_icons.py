#!/usr/bin/env python3
"""Rewrite an app's CFBundleIcons to match a compiled asset catalog.

Usage: update_bundle_icons.py <Info.plist> <Assets.car>

Enumerates the app-icon renditions inside <Assets.car> (via `assetutil`),
groups them by idiom, and rewrites CFBundleIcons / CFBundleIcons~ipad in the
given Info.plist so they reference the icons actually present in the catalog.

Kept as a sibling of ipa-branding.sh; invoked from replace_app_images().
"""

import collections
import json
import plistlib
import subprocess
import sys


def point_size(entry):
    """Icon size in points, e.g. 120px @2x -> "60x60"."""
    scale = float(entry.get("Scale", 1)) or 1.0
    w = float(entry.get("PixelWidth", 0)) / scale
    h = float(entry.get("PixelHeight", 0)) / scale
    return "%gx%g" % (w, h)


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("usage: update_bundle_icons.py <Info.plist> <Assets.car>\n")
        return 2
    plist_path, car_path = sys.argv[1], sys.argv[2]

    try:
        raw = subprocess.run(
            ["assetutil", "--info", car_path],
            capture_output=True, text=True, check=True,
        ).stdout
        entries = json.loads(raw)
    except subprocess.CalledProcessError as exc:
        sys.stderr.write("assetutil failed: %s\n" % (exc.stderr or exc))
        return 1
    except (ValueError, OSError) as exc:
        sys.stderr.write("could not read asset catalog: %s\n" % exc)
        return 1

    with open(plist_path, "rb") as fh:
        info = plistlib.load(fh)

    # App-icon renditions are typed "Icon Image"; a catalog may hold several sets
    # (the primary plus alternate icons). We only rewrite the PRIMARY set and
    # leave CFBundleAlternateIcons untouched, so pick the primary's name.
    icon_rows = [e for e in entries if isinstance(e, dict)
                 and e.get("AssetType") == "Icon Image"
                 and (e.get("Idiom") or "").lower() != "marketing"]
    icon_names = [e.get("Name") for e in icon_rows if e.get("Name")]
    if not icon_names:
        sys.stderr.write("no app-icon renditions found in %s\n" % car_path)
        return 3

    def existing_primary_name(key):
        d = info.get(key)
        if isinstance(d, dict) and isinstance(d.get("CFBundlePrimaryIcon"), dict):
            return d["CFBundlePrimaryIcon"].get("CFBundleIconName")
        return None

    primary_name = existing_primary_name("CFBundleIcons") \
        or existing_primary_name("CFBundleIcons~ipad")
    if primary_name not in set(icon_names):
        # No usable hint from the plist: prefer a "production" set, else the one
        # with the most renditions (the real home-screen icon).
        prod = [n for n in icon_names if "production" in n.lower()]
        primary_name = prod[0] if prod else \
            collections.Counter(icon_names).most_common(1)[0][0]

    # idiom bucket -> [base, ...] (unique, ordered) for the primary set only.
    buckets = {"phone": [], "pad": []}

    def add(key, base):
        if base not in buckets[key]:
            buckets[key].append(base)

    for entry in icon_rows:
        if entry.get("Name") != primary_name:
            continue
        # CFBundleIconFiles base name, e.g. "AppIcon" + "60x60" -> "AppIcon60x60".
        base = "%s%s" % (primary_name, point_size(entry))
        idiom = (entry.get("Idiom") or "").lower()
        if idiom == "phone":
            add("phone", base)
        elif idiom in ("pad", "ipad"):
            add("pad", base)
        elif idiom in ("universal", ""):
            add("phone", base)
            add("pad", base)

    def make_primary(files):
        return {"CFBundleIconFiles": files, "CFBundleIconName": primary_name} if files else None

    phone_primary = make_primary(buckets["phone"])
    pad_primary = make_primary(buckets["pad"])

    present = set(icon_names)

    def set_primary(key, primary):
        # Replace only CFBundlePrimaryIcon; keep other sub-keys. Prune
        # CFBundleAlternateIcons to icon sets still present in the catalog, so
        # dropped stock icons are not left dangling in the picker.
        icons = info.get(key)
        if not isinstance(icons, dict):
            icons = {}
        icons["CFBundlePrimaryIcon"] = primary
        alts = icons.get("CFBundleAlternateIcons")
        if isinstance(alts, dict):
            for k in [k for k in alts if k not in present]:
                del alts[k]
            if not alts:
                del icons["CFBundleAlternateIcons"]
        info[key] = icons

    if phone_primary is None and pad_primary is None:
        sys.stderr.write("no app-icon renditions found in %s\n" % car_path)
        return 3

    if phone_primary is not None:
        set_primary("CFBundleIcons", phone_primary)
        # Modern asset-catalog apps also carry a top-level icon name.
        info["CFBundleIconName"] = primary_name
    if pad_primary is not None:
        set_primary("CFBundleIcons~ipad", pad_primary)

    with open(plist_path, "wb") as fh:
        plistlib.dump(info, fh, fmt=plistlib.FMT_BINARY)

    print("icons: primary=%s | phone files=%s | pad files=%s" % (
        primary_name, buckets["phone"], buckets["pad"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
