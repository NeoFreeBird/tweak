#!/usr/bin/env bash
# IPA branding modifications applied to a freshly built .ipa/.tipa.
#
# This file is meant to be sourced by build.sh. It is intentionally a
# separate unit so that further branding tweaks (icons, bundle name,
# etc.) can be added here without cluttering the main build script.
#
# Entry point:
#   apply_ipa_branding <ipa_path>   Unpacks the IPA once and applies every
#                                   enabled step — the theme pack in RESOURCE_PACK
#                                   and, when TWITTER_BRANDING=1, the "Twitter"
#                                   display name — then repackages once.
#
# The functions rely on say()/err()/die() being defined by the caller
# (build.sh). apply_ipa_branding no-ops gracefully when branding is disabled.

# Directory this script lives in, so we can find sibling helpers (car_extract.m,
# the .py steps, etc.). These are colocated with this file in branding/, so we
# resolve against this file's own location rather than the caller's SCRIPT_DIR.
BRANDING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Force the on-device app name back to "Twitter" in an already-unpacked app dir.
_set_display_name_in_app() {
  local appdir="$1"
  local plist="$appdir/Info.plist"
  [[ -f "$plist" ]] || { err "Branding: could not locate app Info.plist"; return 1; }

  if command -v plutil >/dev/null 2>&1; then
    plutil -replace CFBundleDisplayName -string "Twitter" "$plist" >/dev/null 2>&1 \
      || plutil -insert CFBundleDisplayName -string "Twitter" "$plist"
  else
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Twitter" "$plist" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Twitter" "$plist"
  fi

  say "Set CFBundleDisplayName to \"Twitter\"."
}

# Overlay replacement images from a zip onto the app's compiled asset catalog,
# preserving every image the zip does not touch, then rewrite CFBundleIcons.
#
# The pack is a .zip with two optional subfolders plus optional root files:
#   icons/  loose images (PNG/JPG) merged into the app's Assets.car. Name a file
#           after a rendition (the RenditionName, from `assetutil --info`) to
#           replace that size, or after an asset (e.g. AppIcon.png) to auto-resize
#           one master to every size. Un-overridden stock alternate icons are
#           dropped. See build_merged_car.py.
#   svgs/   vector glyphs copied over matching files in TwitterAppearance's
#           VectorImages/main across the app and its extensions. See
#           override_appearance_svgs.py.
#   <root>  non-image files at the zip root (e.g. LaunchScreen.nib) overwrite the
#           same-named file in the app root.
# A flat zip (images at the root, no icons/ folder) is still treated as icons.
_apply_resource_pack_to_app() {
  local appdir="$1"
  local workdir="$2"
  local zip="$3"
  [[ -f "$zip" ]] || { err "Branding: image pack not found: $zip"; return 1; }
  command -v python3 >/dev/null 2>&1 || { err "Branding: 'python3' is required for --resource-pack"; return 1; }
  command -v unzip   >/dev/null 2>&1 || { err "Branding: 'unzip' is required for --resource-pack"; return 1; }

  # Resolve the pack to an absolute path before we cd around while zipping.
  zip="$(cd "$(dirname "$zip")" && pwd)/$(basename "$zip")"

  local plist="$appdir/Info.plist" car="$appdir/Assets.car"

  # Unpack the theme pack and resolve its icons/ and svgs/ sections.
  if ! unzip -q -o "$zip" -d "$workdir/pack"; then
    err "Branding: failed to unpack image pack $zip"; return 1
  fi
  local icons_dir="$workdir/pack/icons" svgs_dir="$workdir/pack/svgs"
  [[ -d "$icons_dir" ]] || icons_dir="$workdir/pack"   # back-compat: flat zip
  # Detect content via command substitution rather than `find | grep -q` — under
  # `set -o pipefail`, grep -q closes the pipe on the first match and find dies
  # with SIGPIPE, which would falsely report "empty" for large trees (e.g. svgs/).
  local have_icons=0 have_svgs=0
  if [[ -n "$(find "$icons_dir" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) ! -name '._*' 2>/dev/null)" ]]; then
    have_icons=1
  fi
  if [[ -d "$svgs_dir" && -n "$(find "$svgs_dir" -type f -iname '*.svg' ! -name '._*' 2>/dev/null)" ]]; then
    have_svgs=1
  fi
  # Non-image files at the pack root (e.g. LaunchScreen.nib) overwrite the
  # same-named file in the app root. (Root images belong to the flat-zip icons
  # back-compat path, so they are excluded here.)
  local have_root=0
  if [[ -n "$(find "$workdir/pack" -maxdepth 1 -type f \
        ! -iname '*.png' ! -iname '*.jpg' ! -iname '*.jpeg' ! -iname '*.svg' ! -name '._*' 2>/dev/null)" ]]; then
    have_root=1
  fi
  if [[ "$have_icons" -eq 0 && "$have_svgs" -eq 0 && "$have_root" -eq 0 ]]; then
    err "Branding: image pack has no icons/ images, svgs/ glyphs, or root files"; return 1
  fi

  # --- icons/: merge into Assets.car ---
  if [[ "$have_icons" -eq 1 ]]; then
    command -v assetutil >/dev/null 2>&1 || { err "Branding: 'assetutil' is required for icons/"; return 1; }
    local clang_bin actool_bin
    clang_bin="$(command -v clang || xcrun -f clang 2>/dev/null)"
    actool_bin="$(command -v actool || xcrun -f actool 2>/dev/null)"
    [[ -n "$clang_bin"  ]] || { err "Branding: 'clang' (Xcode) is required for icons/"; return 1; }
    [[ -n "$actool_bin" ]] || { err "Branding: 'actool' (Xcode) is required for icons/"; return 1; }
    if [[ ! -f "$car" ]]; then
      err "Branding: app has no Assets.car to merge into"; return 1
    fi
    if ! "$clang_bin" -fobjc-arc -O2 \
          -framework Foundation -framework CoreGraphics -framework ImageIO \
          -F /System/Library/PrivateFrameworks -framework CoreUI \
          "$BRANDING_DIR/car_extract.m" -o "$workdir/car_extract" 2>"$workdir/clang.log"; then
      err "Branding: failed to build car_extract:"; cat "$workdir/clang.log" >&2
      return 1
    fi
    # Aspect-preserving pad helper for master resizes (build_merged_car reads it
    # via NFB_PAD_TOOL); non-fatal if it fails to build (falls back to sips).
    if "$clang_bin" -fobjc-arc -O2 \
          -framework Foundation -framework CoreGraphics -framework ImageIO \
          "$BRANDING_DIR/pad_image.m" -o "$workdir/pad_image" 2>>"$workdir/clang.log"; then
      export NFB_PAD_TOOL="$workdir/pad_image"
    fi
    if ! "$workdir/car_extract" "$car" "$workdir/extract"; then
      err "Branding: failed to extract $car"; return 1
    fi
    if ! python3 "$BRANDING_DIR/build_merged_car.py" \
          "$car" "$workdir/extract" "$icons_dir" "$workdir/new.car"; then
      err "Branding: failed to rebuild Assets.car"; return 1
    fi
    cp -f "$workdir/new.car" "$car"
    if [[ -f "$plist" ]] && ! python3 "$BRANDING_DIR/update_bundle_icons.py" "$plist" "$car"; then
      err "Branding: failed to update CFBundleIcons"; return 1
    fi
    # Sync the loose fallback icons in the app root (used by SpringBoard) to the
    # rebuilt catalog, else the home-screen icon stays stale.
    if "$workdir/car_extract" "$car" "$workdir/newextract" 2>/dev/null; then
      python3 "$BRANDING_DIR/overwrite_loose_icons.py" "$appdir" "$workdir/newextract" || true
    fi
  fi

  # --- svgs/: override TwitterAppearance vector glyphs ---
  if [[ "$have_svgs" -eq 1 ]]; then
    if ! python3 "$BRANDING_DIR/override_appearance_svgs.py" "$appdir" "$svgs_dir"; then
      err "Branding: failed to override TwitterAppearance glyphs"; return 1
    fi
  fi

  # --- root files (e.g. LaunchScreen.nib): overwrite the same file in app root ---
  if [[ "$have_root" -eq 1 ]]; then
    local rf base
    while IFS= read -r -d '' rf; do
      base="$(basename "$rf")"
      if [[ -e "$appdir/$base" ]]; then
        rm -rf "$appdir/$base"
        cp -f "$rf" "$appdir/$base"
        say "Replaced $base in the app root."
      else
        err "Branding: '$base' is not present in the app root; skipped."
      fi
    done < <(find "$workdir/pack" -maxdepth 1 -type f \
              ! -iname '*.png' ! -iname '*.jpg' ! -iname '*.jpeg' ! -iname '*.svg' ! -name '._*' -print0)
  fi

  say "Applied image pack to $(basename "$appdir")."
}

# Entry point used by build.sh after an IPA/TIPA has been produced. Unpacks the
# IPA once, applies every enabled branding step (image pack, then display name)
# to the shared app dir, and repackages once — so a large IPA is only unzipped
# and re-zipped a single time regardless of how many steps run.
apply_ipa_branding() {
  local ipa="$1"
  [[ -n "${RESOURCE_PACK:-}" || "${TWITTER_BRANDING:-0}" == "1" ]] || return 0
  [[ -f "$ipa" ]] || die "Branding: IPA not found: $ipa"
  command -v unzip >/dev/null 2>&1 || die "Branding: 'unzip' is required"

  local workdir appdir
  workdir="$(mktemp -d)" || die "Branding: could not create temp dir"
  if ! unzip -q "$ipa" -d "$workdir/ipa"; then
    rm -rf "$workdir"; die "Branding: failed to unpack $ipa"
  fi
  appdir="$(find "$workdir/ipa/Payload" -maxdepth 1 -type d -name '*.app' | head -n1)"
  if [[ -z "$appdir" || ! -d "$appdir" ]]; then
    rm -rf "$workdir"; die "Branding: could not locate .app inside $ipa"
  fi

  if [[ -n "${RESOURCE_PACK:-}" ]]; then
    _apply_resource_pack_to_app "$appdir" "$workdir" "$RESOURCE_PACK" \
      || { rm -rf "$workdir"; die "Failed to apply image pack."; }
  fi
  if [[ "${TWITTER_BRANDING:-0}" == "1" ]]; then
    _set_display_name_in_app "$appdir" \
      || { rm -rf "$workdir"; die "Failed to apply Twitter branding."; }
  fi

  # Repackage once.
  local tmp_ipa
  tmp_ipa="$(cd "$(dirname "$ipa")" && pwd)/$(basename "$ipa").branding.tmp"
  rm -f "$tmp_ipa"
  if ! ( cd "$workdir/ipa" && zip -qr "$tmp_ipa" Payload ); then
    rm -rf "$workdir" "$tmp_ipa"; die "Branding: failed to repackage $ipa"
  fi
  mv -f "$tmp_ipa" "$ipa"
  rm -rf "$workdir"
}
