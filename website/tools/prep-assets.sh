#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# One-off: resizes the exported icons into src/img (macOS sips; ffmpeg flattens the platform icons). Outputs are committed.
set -euo pipefail
cd "$(dirname "$0")/.."
A=assets
O=src/img
mkdir -p "$O"
z() { sips -Z "$1" "$2" --out "$3" >/dev/null; }

for name in rigel aurora hydrogenAlpha oxygenIII neptune mars betelgeuse io moon cosmicLatte; do
  for s in light dark; do
    for px in 128 192; do z "$px" "$A/icon-$name-$s.png" "$O/icon-$name-$s-$px.png"; done
  done
done
for s in light dark; do
  for px in 96 64; do z "$px" "$A/icon-rigel-$s.png" "$O/icon-rigel-$s-$px.png"; done
done
z 32 "$A/icon-rigel-light.png" "$O/favicon-32.png"
z 192 "$A/appicon-1024-light.png" "$O/icon-192.png"
z 512 "$A/appicon-1024-light.png" "$O/icon-512.png"

# Opaque squares: iOS paints transparent corners black, and a maskable icon keeps its art inside the central 80%.
# FAFAFB is the squircle's own fill near its corners (sampled), so the seam does not show.
tmp=$(mktemp -d)
ffmpeg -loglevel error -y -f lavfi -i color=c=0xFAFAFB:s=1024x1024 -i "$A/appicon-1024-light.png" \
  -filter_complex overlay -frames:v 1 "$tmp/flat.png"
ffmpeg -loglevel error -y -f lavfi -i color=c=0xFAFAFB:s=1024x1024 -i "$A/appicon-1024-light.png" \
  -filter_complex "[1]scale=820:820[i];[0][i]overlay=102:102" -frames:v 1 "$tmp/mask.png"
z 180 "$tmp/flat.png" "$O/apple-touch-icon.png"
z 512 "$tmp/mask.png" "$O/icon-maskable-512.png"
rm -rf "$tmp"
ls "$O" | wc -l | xargs echo "files in $O:"
