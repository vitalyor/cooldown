#!/bin/sh
# Renders Resources/AppIcon.icon the way the system does, for a look without Icon Composer:
#   scripts/icon-preview.sh [out-dir]   (default: ../screenshots/icon)
cd "$(dirname "$0")/.." || exit 1
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
OUT=${1:-../screenshots/icon}
mkdir -p "$OUT"
for platform in macOS iOS; do
  for rendition in Default Dark TintedLight TintedDark ClearLight ClearDark; do
    "$ICTOOL" Resources/AppIcon.icon --export-image --output-file "$OUT/$platform-$rendition.png" \
      --platform $platform --rendition $rendition --width 512 --height 512 --scale 1 \
      --tint-color 0.6 --tint-strength 0.8 2>&1 | grep -v '^$' | head -3
  done
done
ls "$OUT"
