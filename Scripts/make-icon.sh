#!/bin/sh
# Renders dist/AppIcon.icns from the pixel sprite.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist/icon"
mkdir -p "$ROOT/dist" "$OUT.iconset"
swift "$ROOT/Scripts/render-icon.swift" "$OUT.png"
for s in 16 32 128 256 512; do
	sips -z $s $s "$OUT.png" --out "$OUT.iconset/icon_${s}x${s}.png" >/dev/null
	d=$((s * 2))
	sips -z $d $d "$OUT.png" --out "$OUT.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$OUT.iconset" -o "$ROOT/dist/AppIcon.icns"
rm -rf "$OUT.iconset" "$OUT.png"
echo "Icon: $ROOT/dist/AppIcon.icns"
