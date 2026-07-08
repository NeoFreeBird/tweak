#!/usr/bin/env python3
"""IPA branding modifications applied to a freshly built .ipa/.tipa.

This is a standalone port of the former ipa-branding.sh. build.sh invokes it
as a subprocess after an IPA/TIPA has been produced:

    RESOURCE_PACK=... TWITTER_BRANDING=1 python3 ipa_branding.py <ipa_path>

It unpacks the IPA once, applies every enabled step — the theme pack in
RESOURCE_PACK and, when TWITTER_BRANDING=1, the "Twitter" display name — then
repackages once. When no branding is enabled it exits 0 without touching the
IPA. A non-zero exit means a requested step failed; build.sh treats that as
fatal.

The sibling helpers (car_extract.m, the .py steps) live alongside this file in
branding/, so they are resolved relative to this file rather than the caller.
"""

import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BRANDING_DIR = Path(__file__).resolve().parent

# --- console output, matching build.sh's say()/err()/die() styling ----------

_IS_TTY = sys.stdout.isatty()
_BOLD_GREEN = "\033[1;32m" if _IS_TTY else ""
_RESET = "\033[0m" if _IS_TTY else ""


def say(message):
    print(f"{_BOLD_GREEN}{message}{_RESET}")


def err(message):
    print(f"Error: {message}", file=sys.stderr)


class BrandingError(Exception):
    """Raised for a failed branding step; maps to a fatal non-zero exit."""


def _have(cmd):
    return shutil.which(cmd) is not None


def _run(args, **kwargs):
    """Run a command, returning True on success (exit 0)."""
    return subprocess.run(args, **kwargs).returncode == 0


def _find(root, predicate):
    """True if any file under root satisfies predicate(Path)."""
    root = Path(root)
    if not root.exists():
        return False
    for path in root.rglob("*"):
        if path.is_file() and predicate(path):
            return True
    return False


def _is_apple_double(path):
    return path.name.startswith("._")


# --- display name -----------------------------------------------------------

def _set_display_name_in_app(appdir):
    """Force the on-device app name back to "Twitter"."""
    plist = appdir / "Info.plist"
    if not plist.is_file():
        raise BrandingError("Branding: could not locate app Info.plist")

    # plistlib reads/writes both binary and XML plists, so no macOS-only plist
    # tools are needed. IPA Info.plists are binary, so we write binary back.
    with open(plist, "rb") as f:
        data = plistlib.load(f)
    data["CFBundleDisplayName"] = "Twitter"
    with open(plist, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)

    say('Set CFBundleDisplayName to "Twitter".')


# --- resource pack ----------------------------------------------------------

def _apply_resource_pack_to_app(appdir, workdir, zip_path):
    """Overlay replacement images/glyphs from a zip onto the app.

    The pack is a .zip with two optional subfolders plus optional root files:
      icons/  loose images merged into the app's Assets.car (see
              build_merged_car.py). A flat zip (images at the root, no icons/
              folder) is still treated as icons.
      svgs/   vector glyphs copied over matching TwitterAppearance files (see
              override_appearance_svgs.py).
      <root>  non-image files at the zip root (e.g. LaunchScreen.nib) overwrite
              the same-named file in the app root.
    """
    zip_path = Path(zip_path)
    if not zip_path.is_file():
        raise BrandingError(f"Branding: image pack not found: {zip_path}")
    if not _have("unzip"):
        raise BrandingError("Branding: 'unzip' is required for --resource-pack")

    zip_path = zip_path.resolve()
    plist = appdir / "Info.plist"
    car = appdir / "Assets.car"

    pack = workdir / "pack"
    if not _run(["unzip", "-q", "-o", str(zip_path), "-d", str(pack)]):
        raise BrandingError(f"Branding: failed to unpack image pack {zip_path}")

    icons_dir = pack / "icons"
    if not icons_dir.is_dir():
        icons_dir = pack  # back-compat: flat zip
    svgs_dir = pack / "svgs"

    have_icons = _find(
        icons_dir,
        lambda p: p.suffix.lower() in (".png", ".jpg", ".jpeg") and not _is_apple_double(p),
    )
    have_svgs = svgs_dir.is_dir() and _find(
        svgs_dir, lambda p: p.suffix.lower() == ".svg" and not _is_apple_double(p)
    )
    # Non-image files at the pack root overwrite the same-named file in the app
    # root. (Root images belong to the flat-zip icons back-compat path.)
    root_files = [
        p for p in pack.iterdir()
        if p.is_file()
        and p.suffix.lower() not in (".png", ".jpg", ".jpeg", ".svg")
        and not _is_apple_double(p)
    ]
    have_root = bool(root_files)

    if not (have_icons or have_svgs or have_root):
        raise BrandingError(
            "Branding: image pack has no icons/ images, svgs/ glyphs, or root files"
        )

    # --- icons/: merge into Assets.car ---
    if have_icons:
        if not _have("assetutil"):
            raise BrandingError("Branding: 'assetutil' is required for icons/")
        clang_bin = shutil.which("clang") or _xcrun_find("clang")
        actool_bin = shutil.which("actool") or _xcrun_find("actool")
        if not clang_bin:
            raise BrandingError("Branding: 'clang' (Xcode) is required for icons/")
        if not actool_bin:
            raise BrandingError("Branding: 'actool' (Xcode) is required for icons/")
        if not car.is_file():
            raise BrandingError("Branding: app has no Assets.car to merge into")

        clang_log = workdir / "clang.log"
        car_extract = workdir / "car_extract"
        with open(clang_log, "w") as log:
            built = _run(
                [
                    clang_bin, "-fobjc-arc", "-O2",
                    "-framework", "Foundation",
                    "-framework", "CoreGraphics",
                    "-framework", "ImageIO",
                    "-F", "/System/Library/PrivateFrameworks", "-framework", "CoreUI",
                    str(BRANDING_DIR / "car_extract.m"), "-o", str(car_extract),
                ],
                stderr=log,
            )
        if not built:
            err("Branding: failed to build car_extract:")
            sys.stderr.write(clang_log.read_text())
            raise BrandingError("Branding: failed to build car_extract")

        # Aspect-preserving pad helper for master resizes (build_merged_car reads
        # it via NFB_PAD_TOOL); non-fatal if it fails to build (falls back to sips).
        pad_image = workdir / "pad_image"
        with open(clang_log, "a") as log:
            padded = _run(
                [
                    clang_bin, "-fobjc-arc", "-O2",
                    "-framework", "Foundation",
                    "-framework", "CoreGraphics",
                    "-framework", "ImageIO",
                    str(BRANDING_DIR / "pad_image.m"), "-o", str(pad_image),
                ],
                stderr=log,
            )
        if padded:
            os.environ["NFB_PAD_TOOL"] = str(pad_image)

        extract = workdir / "extract"
        if not _run([str(car_extract), str(car), str(extract)]):
            raise BrandingError(f"Branding: failed to extract {car}")

        new_car = workdir / "new.car"
        if not _run([
            sys.executable, str(BRANDING_DIR / "build_merged_car.py"),
            str(car), str(extract), str(icons_dir), str(new_car),
        ]):
            raise BrandingError("Branding: failed to rebuild Assets.car")
        shutil.copyfile(new_car, car)

        if plist.is_file():
            if not _run([
                sys.executable, str(BRANDING_DIR / "update_bundle_icons.py"),
                str(plist), str(car),
            ]):
                raise BrandingError("Branding: failed to update CFBundleIcons")

        # Sync the loose fallback icons in the app root (used by SpringBoard) to
        # the rebuilt catalog, else the home-screen icon stays stale.
        new_extract = workdir / "newextract"
        if _run([str(car_extract), str(car), str(new_extract)],
                stderr=subprocess.DEVNULL):
            _run([
                sys.executable, str(BRANDING_DIR / "overwrite_loose_icons.py"),
                str(appdir), str(new_extract),
            ])

    # --- svgs/: override TwitterAppearance vector glyphs ---
    if have_svgs:
        if not _run([
            sys.executable, str(BRANDING_DIR / "override_appearance_svgs.py"),
            str(appdir), str(svgs_dir),
        ]):
            raise BrandingError("Branding: failed to override TwitterAppearance glyphs")

    # --- root files (e.g. LaunchScreen.nib): overwrite the same file in app root ---
    if have_root:
        for rf in root_files:
            dest = appdir / rf.name
            if dest.exists():
                if dest.is_dir():
                    shutil.rmtree(dest)
                else:
                    dest.unlink()
                shutil.copyfile(rf, dest)
                say(f"Replaced {rf.name} in the app root.")
            else:
                err(f"Branding: '{rf.name}' is not present in the app root; skipped.")

    say(f"Applied image pack to {appdir.name}.")


def _xcrun_find(tool):
    try:
        out = subprocess.run(
            ["xcrun", "-f", tool], capture_output=True, text=True
        )
    except FileNotFoundError:
        return None
    return out.stdout.strip() if out.returncode == 0 else None


# --- entry point ------------------------------------------------------------

def apply_ipa_branding(ipa):
    """Unpack the IPA once, apply every enabled step, repackage once."""
    resource_pack = os.environ.get("RESOURCE_PACK", "")
    twitter_branding = os.environ.get("TWITTER_BRANDING", "0") == "1"
    if not resource_pack and not twitter_branding:
        return

    ipa = Path(ipa)
    if not ipa.is_file():
        raise BrandingError(f"Branding: IPA not found: {ipa}")
    if not _have("unzip"):
        raise BrandingError("Branding: 'unzip' is required")
    if not _have("zip"):
        raise BrandingError("Branding: 'zip' is required")

    workdir = Path(tempfile.mkdtemp())
    try:
        ipa_root = workdir / "ipa"
        if not _run(["unzip", "-q", str(ipa), "-d", str(ipa_root)]):
            raise BrandingError(f"Branding: failed to unpack {ipa}")

        payload = ipa_root / "Payload"
        apps = sorted(payload.glob("*.app")) if payload.is_dir() else []
        appdir = next((a for a in apps if a.is_dir()), None)
        if appdir is None:
            raise BrandingError(f"Branding: could not locate .app inside {ipa}")

        if resource_pack:
            _apply_resource_pack_to_app(appdir, workdir, resource_pack)
        if twitter_branding:
            _set_display_name_in_app(appdir)

        # Repackage once. Use the zip binary (not zipfile) to preserve symlinks
        # and permissions exactly as the original build produced them.
        ipa = ipa.resolve()
        tmp_ipa = ipa.with_name(ipa.name + ".branding.tmp")
        if tmp_ipa.exists():
            tmp_ipa.unlink()
        if not _run(["zip", "-qr", str(tmp_ipa), "Payload"], cwd=str(ipa_root)):
            if tmp_ipa.exists():
                tmp_ipa.unlink()
            raise BrandingError(f"Branding: failed to repackage {ipa}")
        os.replace(tmp_ipa, ipa)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def main(argv):
    if len(argv) != 2:
        err("usage: ipa_branding.py <ipa_path>")
        return 2
    try:
        apply_ipa_branding(argv[1])
    except BrandingError as exc:
        err(str(exc))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
