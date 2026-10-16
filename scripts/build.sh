#!/bin/bash
# Usage: scripts/build.sh [release|debug]
# SNAP11_VERSION stamps the bundle version. SNAP11_KEYCHAIN, SNAP11_KEYCHAIN_PASSWORD and
# SNAP11_SIGN_IDENTITY pick the signing certificate; with no keychain the app is signed ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG"
APP=build/Snap11.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Snap11" "$APP/Contents/MacOS/Snap11"
cp scripts/Info.plist "$APP/Contents/Info.plist"
if [ -n "${SNAP11_VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "$SNAP11_VERSION" "$APP/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$SNAP11_VERSION" "$APP/Contents/Info.plist"
fi
# A stable certificate keeps the designated requirement fixed, so the Accessibility and
# Screen Recording grants survive rebuilds. Its own keychain means codesign never prompts.
KEYCHAIN="${SNAP11_KEYCHAIN:-$HOME/Library/Keychains/snap11-signing.keychain-db}"
IDENTITY="${SNAP11_SIGN_IDENTITY:-929CD75027787AFEB6EEE6CAEF46A975BCEF24DB}"
if [ -f "$KEYCHAIN" ]; then
    security unlock-keychain -p "${SNAP11_KEYCHAIN_PASSWORD:-snap11}" "$KEYCHAIN"
    codesign --force --sign "$IDENTITY" --identifier dev.zingzy.snap11 "$APP"
else
    codesign --force --sign - --identifier dev.zingzy.snap11 "$APP"
fi
echo "$APP"
