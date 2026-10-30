#!/usr/bin/env bash
# Assembles the GitHub Pages artifact: site/ plus the existing screenshots and app icon
# (also used as favicon and touch icon), so the images have a single source of truth in the repo.
# Used by .github/workflows/pages.yml and for local preview. Fails if any source image is missing.
#
# Usage: bash scripts/build-site.sh [OUT_DIR]   (default: _site)
set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:-_site}"
rm -rf "$out"
mkdir -p "$out/img/screenshots"
cp -R site/. "$out/"
cp screenshots/*.png "$out/img/screenshots/"

cp Ambrosia/Assets.xcassets/AppIcon.appiconset/icon_512x512.png "$out/img/icon.png"
cp Ambrosia/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png "$out/favicon.png"
cp Ambrosia/Assets.xcassets/AppIcon.appiconset/icon_256x256.png "$out/apple-touch-icon.png"

echo "wrote $out"
