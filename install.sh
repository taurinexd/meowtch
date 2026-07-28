#!/bin/sh
# Meowtch installer — quarantine-free by design.
#
#   curl -fsSL https://raw.githubusercontent.com/taurinexd/meowtch/main/install.sh | sh
#
# curl doesn't apply the macOS quarantine attribute, so the app installs
# and launches without any Gatekeeper dialog — no notarization needed.
set -eu

ZIP_URL="https://github.com/taurinexd/meowtch/releases/latest/download/Meowtch.zip"
DEST="/Applications/Meowtch.app"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Meowtch runs on macOS only." >&2
    exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
    echo "Meowtch requires an Apple Silicon Mac (this machine is $(uname -m))." >&2
    exit 1
fi

WORK="$(mktemp -d /tmp/meowtch-install.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading the latest Meowtch release…"
curl -fSL --progress-bar "$ZIP_URL" -o "$WORK/Meowtch.zip"

/usr/bin/ditto -x -k "$WORK/Meowtch.zip" "$WORK/unpacked"
APP="$WORK/unpacked/Meowtch.app"
if [ ! -d "$APP" ]; then
    echo "Unexpected archive layout: Meowtch.app not found." >&2
    exit 1
fi

# A running copy would keep stale code alive across the swap. The
# executable inside the bundle is named Vedetta (the project codename).
/usr/bin/pkill -x Vedetta 2>/dev/null || true

rm -rf "$DEST"
# Pre-rename installs live at Vedetta.app: replace, don't duplicate.
rm -rf "/Applications/Vedetta.app"
/usr/bin/ditto "$APP" "$DEST"
# Defensive: a no-op on the curl path, but heals a copy of this script
# whose download was quarantined by other means.
/usr/bin/xattr -rd com.apple.quarantine "$DEST" 2>/dev/null || true

echo "Installed $DEST — launching."
open "$DEST"
