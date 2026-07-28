#!/bin/sh
# Cuts a Meowtch release: tests, app, signed archive, DMG, git tag and a
# GitHub release carrying exactly what the in-app updater expects
# (Meowtch.zip + Meowtch.zip.sig).
#
# Usage: Scripts/make-release.sh [--notes "text"]
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
TAG="v$VERSION"
APP="$ROOT/dist/Meowtch.app"
ZIP="$ROOT/dist/Meowtch.zip"
SIG="$ROOT/dist/Meowtch.zip.sig"
SERVICE="Vedetta Update Signing"
NOTES="Meowtch $TAG"
[ "${1:-}" = "--notes" ] && NOTES="$2"

if git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG already exists — bump VERSION first." >&2
    exit 1
fi
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "Working tree is dirty — commit before releasing." >&2
    exit 1
fi

echo "→ tests"
make -C "$ROOT" test >/dev/null

echo "→ app bundle ($VERSION)"
"$ROOT/scripts/make-app.sh"

echo "→ archive + signature"
rm -f "$ZIP" "$SIG"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
security find-generic-password -s "$SERVICE" -a "$USER" -w >/dev/null 2>&1 || {
    echo "No signing key in the Keychain — run Scripts/update-keygen.sh." >&2
    exit 1
}
VEDETTA_SIGNING_KEY="$(security find-generic-password -s "$SERVICE" -a "$USER" -w)" \
VEDETTA_ARCHIVE="$ZIP" swift - <<'EOF' > "$SIG"
import CryptoKit
import Foundation
let env = ProcessInfo.processInfo.environment
guard let keyBase64 = env["VEDETTA_SIGNING_KEY"],
      let raw = Data(base64Encoded: keyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw),
      let path = env["VEDETTA_ARCHIVE"],
      let archive = FileManager.default.contents(atPath: path),
      let signature = try? key.signature(for: archive)
else {
    FileHandle.standardError.write(Data("signing failed\n".utf8))
    exit(1)
}
print(signature.base64EncodedString())
EOF

echo "→ dmg"
sh "$ROOT/scripts/make-dmg.sh" >/dev/null

echo "→ tag + github release"
git -C "$ROOT" tag "$TAG"
git -C "$ROOT" push origin "$TAG"
gh release create "$TAG" \
    "$ZIP" "$SIG" "$ROOT/dist/Meowtch.dmg" \
    --repo taurinexd/meowtch \
    --title "Meowtch $TAG" \
    --notes "$NOTES"

echo "Released $TAG"
