#!/bin/sh
# Assembles dist/Vedetta.app from the SwiftPM build.
# Usage: Scripts/make-app.sh [debug|release]  (default: release)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="${1:-release}"
VERSION="0.1.0"

cd "$ROOT/App"
swift build -c "$CONF"
BINDIR="$(swift build -c "$CONF" --show-bin-path)"

APP="$ROOT/dist/Vedetta.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

cp "$BINDIR/Vedetta" "$APP/Contents/MacOS/Vedetta"
cp "$BINDIR/VedettaBridge" "$APP/Contents/Helpers/vedetta-bridge"
cp -R "$ROOT/extensions/vscode" "$APP/Contents/Resources/vscode-extension"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Vedetta</string>
	<key>CFBundleDisplayName</key>
	<string>Vedetta</string>
	<key>CFBundleIdentifier</key>
	<string>app.vedetta.macos</string>
	<key>CFBundleExecutable</key>
	<string>Vedetta</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
