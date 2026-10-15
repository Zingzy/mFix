#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG"
APP=build/Snap11.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Snap11" "$APP/Contents/MacOS/Snap11"
cp scripts/Info.plist "$APP/Contents/Info.plist"
# A stable certificate keeps the designated requirement fixed, so the Accessibility and
# Screen Recording grants survive rebuilds. Its own keychain means codesign never prompts.
KEYCHAIN="$HOME/Library/Keychains/snap11-signing.keychain-db"
IDENTITY="${SNAP11_SIGN_IDENTITY:-929CD75027787AFEB6EEE6CAEF46A975BCEF24DB}"
if [ -f "$KEYCHAIN" ]; then
    security unlock-keychain -p snap11 "$KEYCHAIN"
    codesign --force --sign "$IDENTITY" --identifier dev.zingzy.snap11 "$APP"
else
    codesign --force --sign - --identifier dev.zingzy.snap11 "$APP"
fi
echo "$APP"
