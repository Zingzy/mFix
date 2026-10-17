#!/bin/bash
# Usage: scripts/build.sh [release|debug]
# MFIX_VERSION stamps the bundle version. MFIX_KEYCHAIN, MFIX_KEYCHAIN_PASSWORD and
# MFIX_SIGN_IDENTITY pick the signing certificate; with no keychain the app is signed ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG"
APP=build/mFix.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/mFix" "$APP/Contents/MacOS/mFix"
cp scripts/Info.plist "$APP/Contents/Info.plist"
xcrun actool Resources/mFix.icon --compile "$APP/Contents/Resources" --app-icon mFix \
    --platform macosx --target-device mac --minimum-deployment-target 26.0 \
    --output-partial-info-plist /dev/null >/dev/null
# actool exits 0 even when it compiles nothing.
[ -f "$APP/Contents/Resources/Assets.car" ] || { echo "actool did not write Assets.car" >&2; exit 1; }
if [ -n "${MFIX_VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "$MFIX_VERSION" "$APP/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$MFIX_VERSION" "$APP/Contents/Info.plist"
fi
# A stable certificate keeps the designated requirement fixed, so the Accessibility and
# Screen Recording grants survive rebuilds. Its own keychain means codesign never prompts.
KEYCHAIN="${MFIX_KEYCHAIN:-$HOME/Library/Keychains/mfix-signing.keychain-db}"
IDENTITY="${MFIX_SIGN_IDENTITY:-00D357E89CAB9CB0BEA6CBB8288B981863178965}"
if [ -f "$KEYCHAIN" ]; then
    security unlock-keychain -p "${MFIX_KEYCHAIN_PASSWORD:-mfix}" "$KEYCHAIN"
    codesign --force --sign "$IDENTITY" --identifier dev.zingzy.mfix "$APP"
else
    codesign --force --sign - --identifier dev.zingzy.mfix "$APP"
fi
echo "$APP"
