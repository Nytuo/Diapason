#!/bin/bash
# Regenerates the Linux icon set from the rounded macOS-style icon.
# Requires ImageMagick. Source of truth: icon.svg (rendered to icon_combined*.png).
cd "$(dirname "$0")"
for dim in 16 32 48 64 128 256 384 512 1024; do
  mkdir -p "linux/${dim}x${dim}/apps"
  magick icon_combined_macos.png -resize ${dim}x${dim} "PNG32:linux/${dim}x${dim}/apps/diapason.png"
done
