#!/bin/sh
# Vedetta installer — quarantine-free by design.
#
#   curl -fsSL https://raw.githubusercontent.com/taurinexd/vedetta/main/install.sh | sh
#
# curl doesn't apply the macOS quarantine attribute, so the app installs
# and launches without any Gatekeeper dialog — no notarization needed.
set -eu

ZIP_URL="https://github.com/taurinexd/vedetta/releases/latest/download/Vedetta.zip"
DEST="/Applications/Vedetta.app"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Vedetta runs on macOS only." >&2
    exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
    echo "Vedetta requires an Apple Silicon Mac (this machine is $(uname -m))." >&2
    exit 1
fi

WORK="$(mktemp -d /tmp/vedetta-install.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading the latest Vedetta release…"
curl -fSL --progress-bar "$ZIP_URL" -o "$WORK/Vedetta.zip"

/usr/bin/ditto -x -k "$WORK/Vedetta.zip" "$WORK/unpacked"
APP="$WORK/unpacked/Vedetta.app"
if [ ! -d "$APP" ]; then
    echo "Unexpected archive layout: Vedetta.app not found." >&2
    exit 1
fi

# A running copy would keep stale code alive across the swap.
/usr/bin/pkill -x Vedetta 2>/dev/null || true

rm -rf "$DEST"
/usr/bin/ditto "$APP" "$DEST"
# Defensive: a no-op on the curl path, but heals a copy of this script
# whose download was quarantined by other means.
/usr/bin/xattr -rd com.apple.quarantine "$DEST" 2>/dev/null || true

echo "Installed $DEST — launching."
open "$DEST"
