#!/bin/bash
# bump-cask.sh <tap-checkout> <version> <dmg-sha256>
# Points Casks/mfix.rb at a new release. Refuses anything but a plain version and a sha256,
# and fails if the edit touched more than those two lines.
set -euo pipefail
TAP="$1" VERSION="$2" SHA="$3"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad version: $VERSION" >&2; exit 1; }
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "bad sha256: $SHA" >&2; exit 1; }
CASK="$TAP/Casks/mfix.rb"
[ -f "$CASK" ] || { echo "no cask at $CASK" >&2; exit 1; }
sed -i.bak -E "s/^  version \"[^\"]+\"$/  version \"$VERSION\"/; s/^  sha256 \"[0-9a-f]{64}\"$/  sha256 \"$SHA\"/" "$CASK"
rm -f "$CASK.bak"
changed=$(git -C "$TAP" diff --numstat -- Casks/mfix.rb | awk '{print $1+$2}')
others=$(git -C "$TAP" status --porcelain | grep -v ' Casks/mfix.rb$' || true)
[ -z "$others" ] || { echo "unexpected changes: $others" >&2; exit 1; }
case "${changed:-0}" in
    0) echo "cask already at $VERSION" ;;
    2|4) git -C "$TAP" diff -- Casks/mfix.rb ;;
    *) echo "edit changed $changed lines, expected the version and sha256 only" >&2; exit 1 ;;
esac
