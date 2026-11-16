#!/bin/sh
# Assembles dist/Meowtch.app from the SwiftPM build.
# Usage: Scripts/make-app.sh [debug|release]  (default: release)
set -eu

# Prefer full Xcode when present: recent Command Line Tools ship without the
# SwiftUI macro plugins (@State fails with "SwiftUIMacros not found").
XCODE_DEV=/Applications/Xcode.app/Contents/Developer
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "$XCODE_DEV" ]; then
    export DEVELOPER_DIR="$XCODE_DEV"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="${1:-release}"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)"

cd "$ROOT/App"
swift build -c "$CONF"
BINDIR="$(swift build -c "$CONF" --show-bin-path)"

APP="$ROOT/dist/Meowtch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

cp "$BINDIR/Vedetta" "$APP/Contents/MacOS/Vedetta"
cp "$BINDIR/VedettaBridge" "$APP/Contents/Helpers/vedetta-bridge"
cp -R "$ROOT/extensions/vscode" "$APP/Contents/Resources/vscode-extension"
cp "$ROOT/App/Resources/"provider-*.png "$APP/Contents/Resources/"

[ -f "$ROOT/dist/AppIcon.icns" ] || "$ROOT/Scripts/make-icon.sh"
cp "$ROOT/dist/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Meowtch</string>
	<key>CFBundleDisplayName</key>
	<string>Meowtch</string>
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
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Meowtch listens to your microphone during a call to know when you are speaking.</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>Meowtch listens to the meeting audio during a call to transcribe what the other side says, on this Mac.</string>
</dict>
</plist>
PLIST

# Stable self-signed identity when available: TCC grants (Accessibility)
# survive rebuilds, unlike ad-hoc signing whose cdhash changes each build.
IDENTITY="Vedetta Dev Signing"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $APP"
