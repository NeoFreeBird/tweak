#!/usr/bin/env python3
"""Rebuild an app's Assets.car with selected bitmap images replaced.

Usage: build_merged_car.py <app_Assets.car> <extract_dir> <overlay_dir> <out.car> [actool_partial_plist]

Pipeline (see ipa-branding.sh: replace_app_images):
  1. `assetutil --info` on the app's Assets.car is the authoritative list of
     renditions (Name / RenditionName / Idiom / Scale / pixel size / type).
  2. <extract_dir> holds the app's bitmap pixels dumped by car_extract, with a
     manifest.json keyed by (Name, idiom, scale, width, height).
  3. <overlay_dir> holds the user's loose replacement PNGs, each named after the
     rendition it replaces (i.e. the app's RenditionName, discoverable via
     `assetutil --info`).

For every bitmap rendition we pick a pixel source: the overlay file if one is
named after this rendition (REPLACE), otherwise the extracted original
(PRESERVE). Non-bitmap assets (colors/vectors/data), appearance variants (dark)
and wide-gamut (P3) renditions are out of scope and reported as DROPPED. Overlay
files that match no existing rendition are reported and ignored (we never add
icons that did not already exist).

We reconstruct a source .xcassets from those choices and compile it with actool.
"""

import json
import os
import shutil
import subprocess
import sys


def find_actool():
    tool = shutil.which("actool")
    if tool:
        return tool
    try:
        return subprocess.run(["xcrun", "-f", "actool"], capture_output=True,
                              text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, OSError):
        return "actool"


_resize_cache = {}


def resize_to(master, w, h, workdir):
    """Scale `master` to exactly w x h (px), cached per (master,w,h).

    Prefers the aspect-preserving pad_image helper (NFB_PAD_TOOL) so a square
    master isn't stretched into a non-square slot — it's centered on a
    transparent canvas instead. Falls back to a plain sips stretch."""
    key = (master, w, h)
    if key in _resize_cache:
        return _resize_cache[key]
    out = os.path.join(workdir, "resized_%d_%dx%d.png" % (len(_resize_cache), w, h))
    pad_tool = os.environ.get("NFB_PAD_TOOL")
    if pad_tool and os.path.exists(pad_tool):
        subprocess.run([pad_tool, master, str(w), str(h), out],
                       capture_output=True, text=True, check=True)
    else:
        subprocess.run(["sips", "-z", str(h), str(w), master, "--out", out],
                       capture_output=True, text=True, check=True)
    _resize_cache[key] = out
    return out

BITMAP_TYPES = {"Image", "Icon Image"}
IDIOM_INT_TO_STR = {0: "universal", 1: "phone", 2: "pad", 3: "tv", 4: "car", 5: "watch", 6: "marketing"}
# assetutil idiom string -> actool Contents.json idiom value
IDIOM_ASSETUTIL_TO_ACTOOL = {
    "universal": "universal", "phone": "iphone", "pad": "ipad",
    "tv": "tv", "car": "car", "watch": "watch", "mac": "mac",
    "marketing": "ios-marketing",
}


def fmt_scale(scale):
    return "%dx" % int(round(float(scale)))


def fmt_size(px, scale):
    pts = float(px) / float(scale)
    s = ("%g" % pts)
    return "%sx%s" % (s, s)


def is_wide_gamut(entry):
    cs = (entry.get("Colorspace") or "").lower()
    return "p3" in cs or "display" in cs


def has_nondefault_appearance(entry):
    ap = entry.get("Appearance")
    return bool(ap) and "any" not in str(ap).lower()


def main():
    if len(sys.argv) not in (5, 6):
        sys.stderr.write(__doc__)
        return 2
    app_car, extract_dir, overlay_dir, out_car = sys.argv[1:5]
    partial_plist = sys.argv[5] if len(sys.argv) == 6 else None

    # 1. Authoritative rendition list.
    info = json.loads(subprocess.run(
        ["assetutil", "--info", app_car], capture_output=True, text=True, check=True).stdout)
    rows = [e for e in info if isinstance(e, dict) and e.get("RenditionName")]

    # 2. Extracted pixels, indexed by (Name, idiom_str, scale, w, h).
    with open(os.path.join(extract_dir, "manifest.json")) as fh:
        manifest = json.load(fh)
    extracted = {}
    for m in manifest:
        key = (m["renditionName"], IDIOM_INT_TO_STR.get(int(m["idiom"]), "universal"),
               int(round(float(m["scale"]))), int(m["width"]), int(m["height"]))
        extracted[key] = os.path.join(extract_dir, m["file"])

    # 3. Overlay files by basename (exact rendition overrides) and by stem
    #    (single "master" images that get auto-resized to every size).
    overlays = {}   # exact filename -> path
    masters = {}    # stem (asset name / "AppIcon") -> path, lowercased
    if os.path.isdir(overlay_dir):
        for root, dirs, files in os.walk(overlay_dir):
            dirs[:] = [d for d in dirs if d != "__MACOSX"]  # skip macOS zip cruft
            for f in files:
                if f.startswith("._"):  # AppleDouble resource-fork sidecars
                    continue
                if not f.lower().endswith((".png", ".jpg", ".jpeg")):
                    continue
                path = os.path.join(root, f)
                overlays.setdefault(f, path)
                masters.setdefault(os.path.splitext(f)[0].lower(), path)
    used_files = set()
    resize_dir = os.path.join(os.path.dirname(out_car) or ".", "_resized")
    os.makedirs(resize_dir, exist_ok=True)

    # Which asset names are app icons (so an "AppIcon" master can target them all).
    icon_names = {e.get("Name") for e in rows if e.get("AssetType") == "Icon Image"}

    # Settings-picker thumbnails (<Icon>-settings) reuse their base icon's image.
    SETTINGS_SPECIAL = {"icon-production-settings": "ProductionAppIcon"}

    def settings_base(name):
        low = (name or "").lower()
        if low in SETTINGS_SPECIAL:
            return SETTINGS_SPECIAL[low]
        if low.endswith("-settings"):
            return name[:-len("-settings")]
        return None

    def master_for(name):
        """Master image chosen for an asset: its own, its base icon's (for
        -settings thumbnails), or the catch-all AppIcon master."""
        m = masters.get((name or "").lower())
        if m:
            return m
        base = settings_base(name)
        if base:
            m = masters.get(base.lower())
            if m:
                return m
            if base in icon_names and "appicon" in masters:
                return masters["appicon"]
        if name in icon_names and "appicon" in masters:
            return masters["appicon"]
        return None

    # Group renditions into assets and choose a pixel source for each.
    assets = {}  # name -> {"icon": bool, "entries": [ {idiom,scale,size,src,replaced} ]}
    dropped, missing = [], []
    for e in rows:
        name = e.get("Name")
        rname = e.get("RenditionName")
        atype = e.get("AssetType")
        if atype not in BITMAP_TYPES:
            dropped.append((name, rname, atype)); continue
        if is_wide_gamut(e):
            dropped.append((name, rname, "wide-gamut")); continue
        if has_nondefault_appearance(e):
            dropped.append((name, rname, "appearance-variant")); continue

        idiom = (e.get("Idiom") or "universal").lower()
        scale = int(round(float(e.get("Scale", 1))))
        w, h = int(e.get("PixelWidth", 0)), int(e.get("PixelHeight", 0))
        # Size classes distinguish otherwise-identical renditions (e.g. the
        # LaunchStoryboardBackgroundImage A/B/D launch variants); without them
        # actool would collapse the set to one image per scale.
        wclass = e.get("SizeClass Horizontal")
        hclass = e.get("SizeClass Vertical")

        # Source priority: exact rendition file > per-asset master (incl. a
        # -settings thumbnail inheriting its base icon) > preserved original.
        master = master_for(name)
        if rname in overlays:
            src, replaced = overlays[rname], True
            used_files.add(overlays[rname])
        elif master:
            src, replaced = resize_to(master, w, h, resize_dir), True
            used_files.add(master)
        else:
            src = extracted.get((name, idiom, scale, w, h))
            replaced = False
            if not src:
                missing.append((name, rname, idiom, scale, "%dx%d" % (w, h)))
                continue

        a = assets.setdefault(name, {"icon": False, "entries": []})
        a["icon"] = a["icon"] or (atype == "Icon Image")
        a["entries"].append({"idiom": idiom, "scale": scale, "w": w, "h": h,
                             "wclass": wclass, "hclass": hclass,
                             "src": src, "replaced": replaced})

    # Drop stock alternate app icons that were not overridden: keep the primary
    # icon plus any alternate that actually received replacement art. A dropped
    # icon's -settings picker thumbnail is dropped too (unless overridden).
    def overridden(n):
        return any(e["replaced"] for e in assets[n]["entries"])

    icon_asset_names = {n for n, a in assets.items() if a["icon"]}
    primary = None
    for n in icon_asset_names:
        if primary is None or "production" in n.lower():
            primary = n
    drop = {n for n in icon_asset_names if n != primary and not overridden(n)}
    for n in list(assets):
        if not assets[n]["icon"] and settings_base(n) in drop and not overridden(n):
            drop.add(n)
    for n in drop:
        del assets[n]
    dropped_icons = sorted(n for n in drop if n in icon_asset_names)

    # Build a source .xcassets.
    xcassets = os.path.join(os.path.dirname(out_car) or ".", "_merge.xcassets")
    if os.path.isdir(xcassets):
        shutil.rmtree(xcassets)
    os.makedirs(xcassets)
    with open(os.path.join(xcassets, "Contents.json"), "w") as fh:
        json.dump({"info": {"version": 1, "author": "xcode"}}, fh)

    icon_name = None
    alt_icons = []
    for name, a in assets.items():
        is_icon = a["icon"]
        setdir = os.path.join(xcassets, "%s.%s" % (name, "appiconset" if is_icon else "imageset"))
        os.makedirs(setdir, exist_ok=True)
        if is_icon:
            alt_icons.append(name)
            if icon_name is None or "production" in name.lower():
                icon_name = name  # prefer the production icon as the primary
        entries = a["entries"]
        # Single-size app icon (one 1024x1024 @1x, e.g. modern alternate icons):
        # emit the universal single-size format actool expects, not per-idiom.
        if is_icon and {fmt_size(e["w"], e["scale"]) for e in entries} == {"1024x1024"}:
            ent = entries[0]
            fn = "%s_0.png" % name
            shutil.copyfile(ent["src"], os.path.join(setdir, fn))
            images = [{"idiom": "universal", "platform": "ios",
                       "size": "1024x1024", "filename": fn}]
        else:
            images = []
            for i, ent in enumerate(entries):
                fn = "%s_%d.png" % (name, i)
                shutil.copyfile(ent["src"], os.path.join(setdir, fn))
                img = {"idiom": IDIOM_ASSETUTIL_TO_ACTOOL.get(ent["idiom"], ent["idiom"]),
                       "scale": fmt_scale(ent["scale"]), "filename": fn}
                if is_icon:
                    img["size"] = fmt_size(ent["w"], ent["scale"])
                if ent.get("wclass"):
                    img["width-class"] = ent["wclass"]
                if ent.get("hclass"):
                    img["height-class"] = ent["hclass"]
                images.append(img)
        with open(os.path.join(setdir, "Contents.json"), "w") as fh:
            json.dump({"images": images, "info": {"version": 1, "author": "xcode"}}, fh)

    # Compile.
    out_dir = os.path.dirname(out_car) or "."
    cmd = [find_actool(), xcassets, "--compile", out_dir,
           "--platform", "iphoneos", "--minimum-deployment-target", "14.0"]
    if icon_name:
        cmd += ["--app-icon", icon_name]
        # Every other app-icon set is kept as an alternate icon; the app's
        # existing CFBundleIcons.CFBundleAlternateIcons already references them.
        for alt in alt_icons:
            if alt != icon_name:
                cmd += ["--alternate-app-icon", alt]
    if partial_plist:
        cmd += ["--output-partial-info-plist", partial_plist]
    else:
        cmd += ["--output-partial-info-plist", os.path.join(out_dir, "_merge_partial.plist")]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        sys.stderr.write("actool failed:\n%s\n%s\n" % (res.stdout, res.stderr))
        return 1

    produced = os.path.join(out_dir, "Assets.car")
    if produced != out_car:
        shutil.move(produced, out_car)
    shutil.rmtree(xcassets, ignore_errors=True)
    shutil.rmtree(resize_dir, ignore_errors=True)

    replaced = sum(1 for a in assets.values() for e in a["entries"] if e["replaced"])
    preserved = sum(1 for a in assets.values() for e in a["entries"] if not e["replaced"])
    unused = sorted(p for p in set(overlays.values()) if p not in used_files)
    print("merge: %d replaced, %d preserved, %d dropped, %d overlay files unused" % (
        replaced, preserved, len(dropped), len(unused)))
    if dropped_icons:
        print("  dropped %d un-overridden stock icon set(s): %s" % (
            len(dropped_icons), ", ".join(dropped_icons)))
    for name, rname, why in dropped:
        print("  dropped: %s (%s) [%s]" % (name, rname, why))
    for p in unused:
        print("  overlay-unmatched: %s (no rendition or asset with that name)" % os.path.basename(p))
    for name, rname, idiom, scale, dims in missing:
        print("  no-pixels: %s (%s) %s@%dx %s" % (name, rname, idiom, scale, dims))
    return 0


if __name__ == "__main__":
    sys.exit(main())
