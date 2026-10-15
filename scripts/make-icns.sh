#!/bin/bash
# Rasterize an SVG app icon into a macOS .icns with resvg + iconutil.
#
# Usage: scripts/make-icns.sh <icon.svg> <out.icns>
#
# The SVG sources live in Resources/icon/ (see the comments inside them):
#   kanata-bar-icon.svg        full-bleed squircle — the cross-platform master
#   kanata-bar-icon-macos.svg  the same icon with the Icon Composer treatment
#                              baked in (inset, shadow, rim light) — what macOS wants
set -euo pipefail

svg="${1:?Usage: $0 <icon.svg> <out.icns>}"
out="${2:?Usage: $0 <icon.svg> <out.icns>}"

if ! command -v resvg &>/dev/null; then
  echo "error: resvg not found (needed to rasterize $svg)" >&2
  echo "Install it: brew install resvg" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
iconset="$tmp/AppIcon.iconset"
mkdir -p "$iconset"

# Each distinct pixel size is rendered once; @2x entries are copies.
for px in 16 32 64 128 256 512 1024; do
  resvg -w "$px" -h "$px" "$svg" "$tmp/$px.png"
done
for pt in 16 32 128 256 512; do
  cp "$tmp/$pt.png" "$iconset/icon_${pt}x${pt}.png"
  cp "$tmp/$((pt * 2)).png" "$iconset/icon_${pt}x${pt}@2x.png"
done

mkdir -p "$(dirname "$out")"
iconutil -c icns "$iconset" -o "$out"
echo "Wrote $out"
