#!/bin/sh
# One-time: generates the EdDSA keypair that signs Vedetta releases.
# Private key → login Keychain (service "Vedetta Update Signing");
# public key → printed, to be pasted into UpdateChecker.publicKey.
# Refuses to overwrite an existing key: releases signed with a lost key
# can never be verified by shipped apps.
set -eu

SERVICE="Vedetta Update Signing"
if security find-generic-password -s "$SERVICE" -a "$USER" >/dev/null 2>&1; then
    echo "A signing key already exists in the Keychain (service '$SERVICE')." >&2
    echo "Delete it explicitly first if you REALLY mean to rotate it." >&2
    exit 1
fi

KEYS="$(swift - <<'EOF'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
EOF
)"
PRIVATE="$(printf '%s\n' "$KEYS" | sed -n 1p)"
PUBLIC="$(printf '%s\n' "$KEYS" | sed -n 2p)"

security add-generic-password -s "$SERVICE" -a "$USER" -w "$PRIVATE"
echo "Private key stored in the login Keychain (service '$SERVICE')."
echo "Public key (embed in the app):"
echo "$PUBLIC"
