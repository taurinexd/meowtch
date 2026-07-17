#!/bin/sh
# Packages dist/Vedetta.app into dist/Vedetta.dmg.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Vedetta.app"
DMG="$ROOT/dist/Vedetta.dmg"
STAGE="$ROOT/dist/dmg-stage"

[ -d "$APP" ] || "$ROOT/Scripts/make-app.sh"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Vedetta" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "DMG: $DMG"
