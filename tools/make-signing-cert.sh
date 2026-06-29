#!/bin/bash
# One-time setup: create a STABLE self-signed code-signing identity for Shoum so
# the app's designated requirement stays constant across rebuilds. That makes the
# macOS Accessibility (TCC) grant SURVIVE every rebuild, instead of breaking on
# each ad-hoc re-sign (ARCHITECTURE.md invariant 11 — "don't re-toggle, reset").
#
# How: ad-hoc signing (`codesign --sign -`) mints a fresh code hash each build and
# TCC binds the grant to that hash, so every upgrade needs a re-grant. A real
# signing identity makes the requirement cert-based (constant) instead.
#
# We keep the identity in a DEDICATED keychain with a throwaway password, not the
# login keychain — so this is fully scriptable (no interactive password) and the
# cert, which is self-signed and used only for local signing, protects nothing
# sensitive. build.sh / upgrade.sh detect this identity and use it automatically,
# unlocking the keychain as needed.
#
# Idempotent. Safe to re-run (recreates the keychain from scratch).
set -e

IDENTITY="Shoum Local Signing"
KEYCHAIN="$HOME/Library/Keychains/shoum-signing.keychain-db"
KCPASS="shoum"
BUNDLE_ID="org.pipad.shoum"

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✅ '$IDENTITY' already present — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "▶ Generating self-signed code-signing certificate…"
cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $IDENTITY
[ v3 ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null

echo "▶ Creating dedicated signing keychain…"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"            # no auto-lock timeout
security unlock-keychain -p "$KCPASS" "$KEYCHAIN"
# Prepend to the user keychain search list so codesign/find-identity see it,
# WITHOUT dropping the existing keychains (login etc.) or duplicating ourselves.
OLD=$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//' \
      | grep -v 'shoum-signing.keychain-db' || true)
security list-keychains -d user -s "$KEYCHAIN" $OLD

# Import the key + cert as separate PEMs — Security pairs them into an identity.
# (Avoids the OpenSSL↔Apple PKCS12 MAC-algorithm incompatibility that breaks
# `security import` of a .p12.)
echo "▶ Importing identity + authorizing codesign…"
security import "$TMP/key.pem"  -k "$KEYCHAIN" -T /usr/bin/codesign -A
security import "$TMP/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KEYCHAIN" >/dev/null

# The signing identity is about to change (ad-hoc → this cert), so the current
# Accessibility grant won't match. Clear it; the next upgrade + grant establishes
# the persistent one.
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true

echo
echo "Installed identity:"
security find-identity -p codesigning "$KEYCHAIN" | grep "$IDENTITY" || true
cat <<EOF

✅ Created '$IDENTITY'. build.sh / upgrade.sh now sign with it automatically.

Next: run ./upgrade.sh and grant Accessibility ONE more time (the identity changed
from ad-hoc). After that the grant persists across every future rebuild — no more
re-granting.
EOF
