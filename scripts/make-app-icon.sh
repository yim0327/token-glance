#!/bin/sh
# Rebuilds assets/AppIcon/AppIcon.icns from assets/AppIcon/AppIcon.svg.
# Every iconset size (16-1024 px) is rendered from the same SVG with the system renderer
# (scripts/render-svg.swift), then packed with iconutil. No third-party tools are needed.
# The .icns is committed so that bundling does not depend on this step; run this script and
# commit both files whenever the SVG changes.
set -eu
cd "$(dirname "$0")/.."

svg="assets/AppIcon/AppIcon.svg"
icns="assets/AppIcon/AppIcon.icns"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"

# Compile once instead of interpreting the script for every size.
swiftc -O scripts/render-svg.swift -o "$work/render-svg"

for size in 16 32 128 256 512; do
    "$work/render-svg" "$svg" "$iconset/icon_${size}x${size}.png" "$size"
    "$work/render-svg" "$svg" "$iconset/icon_${size}x${size}@2x.png" "$((size * 2))"
done

iconutil -c icns "$iconset" -o "$icns"
echo "$icns"
