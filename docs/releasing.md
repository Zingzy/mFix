# Releasing

## Cutting a release

1. Add the version's entry to `CHANGELOG.md` and merge it to `main`.
2. Tag `main` and push the tag:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

The Release workflow builds `mFix.app` with the tag's version stamped into `CFBundleShortVersionString` and `CFBundleVersion`, signs it, and publishes a GitHub release with generated notes and three files: `mFix.dmg`, `mFix.zip` and `SHA256SUMS.txt`. The file names carry no version, so `releases/latest/download/mFix.dmg` always points at the newest one.

Tags must look like `v1.2.3`. macOS only accepts numbers and dots in `CFBundleVersion`, so the workflow stops on anything else, such as `v1.2.3-beta`.

## Signing

mFix has no Apple Developer ID, so it can't be notarized. It can still be signed with a self-signed certificate, and that matters. macOS ties Accessibility and Screen Recording grants to the app's designated requirement. With a stable certificate the requirement stays the same across releases and the grants survive updates. Signed ad hoc, every release looks like a new app and people have to grant the permissions again.

The workflow signs with a certificate when the repository has these secrets, and ad hoc when it doesn't:

| Secret | Value |
|---|---|
| `SIGNING_CERT_P12` | The certificate and its private key as a `.p12` file, base64 encoded. |
| `SIGNING_CERT_PASSWORD` | The `.p12` file's password. |

### Making the certificate

Keychain Access can make one: Keychain Access, Certificate Assistant, Create a Certificate, with Identity Type "Self Signed Root" and Certificate Type "Code Signing". Export it with its private key as a `.p12` file.

Or with the command line. Use the system's `/usr/bin/openssl`. A Homebrew OpenSSL 3 or later writes `.p12` files that `security import` rejects with "MAC verification failed", unless you pass `-legacy`.

```sh
cat > cert.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = mFix Release Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout key.pem -out cert.pem -config cert.cnf
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -out mfix.p12
base64 -i mfix.p12 | pbcopy
```

Paste the clipboard into the `SIGNING_CERT_P12` secret and the export password into `SIGNING_CERT_PASSWORD`. Then delete `key.pem` and keep `mfix.p12` somewhere safe. A new certificate means a new designated requirement, and every user grants the permissions again.

### Signing locally

`scripts/build.sh` reads the same settings from the environment:

| Variable | Default |
|---|---|
| `MFIX_KEYCHAIN` | `~/Library/Keychains/mfix-signing.keychain-db` |
| `MFIX_KEYCHAIN_PASSWORD` | `mfix` |
| `MFIX_SIGN_IDENTITY` | The SHA-1 of the maintainer's local certificate |
| `MFIX_VERSION` | Unset, which keeps the version in `scripts/Info.plist` |

If the keychain file doesn't exist, the build is signed ad hoc. The keychain has to be on your search list (`security list-keychains -d user -s ...`), because `codesign` only looks there. `scripts/import-cert.sh` does all of this for CI from the two secrets.

Check what a build was signed with:

```sh
codesign -dv --verbose=4 build/mFix.app 2>&1 | grep Authority
codesign -d -r- build/mFix.app
```
