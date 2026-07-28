#!/bin/sh
# Packages dist/Meowtch.app into dist/Meowtch.dmg with the 8-bit background.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Meowtch.app"
DMG="$ROOT/dist/Meowtch.dmg"
RW="$ROOT/dist/Meowtch-rw.dmg"
STAGE="$ROOT/dist/dmg-stage"
BG="$ROOT/dist/dmg-bg.png"

[ -d "$APP" ] || "$ROOT/Scripts/make-app.sh"
swift "$ROOT/Scripts/render-dmg-bg.swift" "$BG"

rm -rf "$STAGE" "$DMG" "$RW"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
cp "$BG" "$STAGE/.background/bg.png"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Meowtch" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
MOUNT_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")"
MOUNT="$(printf '%s\n' "$MOUNT_OUT" | awk -F'\t' '/\/Volumes\//{print $3}')"

osascript <<'EOF'
tell application "Finder"
    tell disk "Meowtch"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, 800, 540}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file ".background:bg.png"
        set position of item "Meowtch.app" of container window to {150, 185}
        set position of item "Applications" of container window to {450, 185}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

sync
hdiutil detach "$MOUNT" >/dev/null
hdiutil convert "$RW" -format UDZO -o "$DMG" >/dev/null
rm -rf "$STAGE" "$RW" "$BG"
echo "DMG: $DMG"
