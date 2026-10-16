#!/bin/bash
# Usage: scripts/import-cert.sh <dir> >> "$GITHUB_ENV"
# Imports SIGNING_CERT_P12 (base64) with SIGNING_CERT_PASSWORD into a throwaway keychain in
# <dir> and prints the MFIX_* settings scripts/build.sh signs with.
set -euo pipefail
DIR="$1"
KEYCHAIN="$DIR/signing.keychain-db"
PASSWORD=$(openssl rand -hex 24)
P12="$DIR/signing.p12"
trap 'rm -f "$P12"' EXIT
printf '%s' "$SIGNING_CERT_P12" | base64 --decode > "$P12"
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$SIGNING_CERT_PASSWORD" -T /usr/bin/codesign >&2
# Lets codesign use the key without a prompt nobody is there to answer.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
# codesign only finds identities in keychains on the search list.
read -ra LISTED <<< "$(security list-keychains -d user | xargs)"
security list-keychains -d user -s "$KEYCHAIN" "${LISTED[@]}"
# A self-signed certificate is not trusted, so this lists it without -v.
IDENTITY=$(security find-identity -p codesigning "$KEYCHAIN" | awk '$1 == "1)" { print $2; exit }')
if [ -z "$IDENTITY" ]; then
    echo "no code signing identity in SIGNING_CERT_P12" >&2
    exit 1
fi
echo "MFIX_KEYCHAIN=$KEYCHAIN"
echo "MFIX_KEYCHAIN_PASSWORD=$PASSWORD"
echo "MFIX_SIGN_IDENTITY=$IDENTITY"
