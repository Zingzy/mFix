#!/bin/bash
# Builds build/Snap11.dmg: the signed app next to an Applications link, to drag across.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh release >/dev/null
DMG=build/Snap11.dmg
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Snap11.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# A mounted copy of an older image would make hdiutil fail or serve stale files.
hdiutil info | awk -v img="$PWD/$DMG" '$0 == "image-path      : " img {getline; while ($0 !~ /^=/) { if ($1 ~ /^\/dev\//) print $1; if (!getline) break }}' \
    | sort -u | while read -r dev; do hdiutil detach "$dev" -quiet || true; done
rm -f "$DMG"
hdiutil create -volname Snap11 -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" -quiet
echo "$DMG"
