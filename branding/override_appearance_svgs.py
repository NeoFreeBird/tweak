#!/usr/bin/env python3
"""Override vector glyphs inside the app's TwitterAppearance bundles.

Usage: override_appearance_svgs.py <app_dir> <svg_dir>

The app ships several copies of TwitterAppearance_TwitterAppearance.bundle (one
in the main app plus one per PlugIns/*.appex), each holding VectorImages/main/
(UI glyphs) and VectorImages/twemoji/ (emoji). We target VectorImages/main only.
For each *.svg in <svg_dir> we replace every existing main glyph of the same
name across all those bundles, so every surface (app, widgets, notifications,
share sheet) stays consistent.

Only existing glyphs are replaced; a provided svg matching nothing is reported
and ignored (we never add new glyphs). Invoked from ipa-branding.sh.
"""

import os
import shutil
import sys


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: override_appearance_svgs.py <app_dir> <svg_dir>\n")
        return 2
    app_dir, svg_dir = sys.argv[1], sys.argv[2]

    # Index the VectorImages/main glyphs of every TwitterAppearance bundle by
    # basename (twemoji and other subfolders are intentionally left alone). Each
    # entry also records the bundle root so we can drop its stale seal later.
    index = {}  # basename -> [(path, bundle_root)]
    bundle_roots = []
    for root, dirs, _files in os.walk(app_dir):
        dirs[:] = [d for d in dirs if d != "__MACOSX"]
        for d in dirs:
            if "TwitterAppearance" in d and d.endswith(".bundle"):
                broot = os.path.join(root, d)
                bundle_roots.append(broot)
                maindir = os.path.join(broot, "VectorImages", "main")
                if not os.path.isdir(maindir):
                    continue
                for f in os.listdir(maindir):
                    if f.lower().endswith(".svg"):
                        index.setdefault(f, []).append((os.path.join(maindir, f), broot))

    # Apply each provided svg to all matching targets.
    replaced_files = 0
    applied, unmatched = [], []
    modified_bundles = set()
    for sroot, sdirs, sfiles in os.walk(svg_dir):
        sdirs[:] = [d for d in sdirs if d != "__MACOSX"]
        for f in sfiles:
            if f.startswith("._") or not f.lower().endswith(".svg"):
                continue
            targets = index.get(f)
            if not targets:
                unmatched.append(f)
                continue
            for path, broot in targets:
                shutil.copyfile(os.path.join(sroot, f), path)
                modified_bundles.add(broot)
            replaced_files += len(targets)
            applied.append(f)

    # A resource bundle's own _CodeSignature seals its files by hash; once we
    # replace glyphs that seal is stale. Drop it so the containing app/appex
    # re-seal (by cyan and the installer) is authoritative and nothing chokes on
    # a mismatch. The bundle stays valid, sealed by its parent's CodeResources.
    for broot in sorted(modified_bundles):
        shutil.rmtree(os.path.join(broot, "_CodeSignature"), ignore_errors=True)

    print("svg override: %d glyph(s) applied across %d location(s) in %d bundle(s); "
          "stripped %d stale bundle seal(s)" % (
              len(applied), replaced_files, len(bundle_roots), len(modified_bundles)))
    for f in sorted(unmatched):
        print("  svg-unmatched: %s (no such glyph in TwitterAppearance bundles)" % f)
    return 0


if __name__ == "__main__":
    sys.exit(main())
