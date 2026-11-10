#!/usr/bin/env bash
# One-time setup: creates a local code-signing certificate so every build of Learn Anyway has the SAME identity.
#
# Why: builds are otherwise signed "ad-hoc", whose identity is the hash of that exact binary. macOS therefore sees every rebuild or
# update as a different app and asks again for permission to read your saved API keys from the Keychain. Signed with this certificate
# the app's identity stays the same across builds, so "Always Allow" sticks.
#
# What it does (and nothing else):
#   1. makes a self-signed certificate "Learn Anyway Local Signing" (code-signing only, valid 10 years) and its private key
#   2. imports them into your login Keychain, usable by /usr/bin/codesign
#   3. marks that one certificate as trusted for code signing, for your user only (macOS asks for your password or Touch ID)
# It does not touch your saved API keys, and it grants no application access to them.
# Remove it later in Keychain Access by deleting the "Learn Anyway Local Signing" certificate.
set -euo pipefail
NAME="Learn Anyway Local Signing"
KC="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then echo "✓ \"$NAME\" is already set up."; exit 0; fi
grep '^#' "$0" | sed -n '2,13p' | sed 's/^# \{0,1\}//'
if [ -z "${ASSUME_YES:-}" ]; then read -r -p "Create it now? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || { echo "Cancelled."; exit 1; }; fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/ext.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$NAME
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
P12PASS=$(uuidgen)
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.pem" -out "$T/c.pem" -days 3650 -config "$T/ext.cnf" >/dev/null 2>&1
/usr/bin/openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -out "$T/id.p12" -passout "pass:$P12PASS" >/dev/null 2>&1
security import "$T/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
if [ -z "${SKIP_TRUST:-}" ]; then
  echo "» macOS will now ask you to approve trusting this certificate for code signing."
  security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$T/c.pem"
fi
if security find-identity -v -p codesigning | grep -q "$NAME"; then echo "✓ Done. scripts/install-macos.sh will now sign with \"$NAME\"."
else echo "! The certificate was imported but isn't trusted for code signing yet. Re-run without SKIP_TRUST."; exit 1; fi
