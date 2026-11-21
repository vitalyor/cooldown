#!/bin/sh
# Draws the README pictures into docs/images, in English and Russian, on made-up data and off screen:
# nothing appears on the screen, no VPN guard or phone link starts, no real address is shown.
#   scripts/readme-shots.sh [version-for-the-notes]
set -eu
cd "$(dirname "$0")/.."
./build.sh > /dev/null
B=build/Cooldown.app/Contents/MacOS/Cooldown
NOTES_VERSION="${1:-$(ls docs/releases | sed 's/\.md$//' | sort -V | tail -1)}"
for lang in en ru; do
  "$B" --render --dark --cards guard,exit,request,paused --out "docs/images/cards-$lang.png" -AppleLanguages "($lang)" > /dev/null
  "$B" --settings-snapshot vpn "docs/images/vpn-$lang.png" --height 760 -AppleLanguages "($lang)"
  "$B" --settings-snapshot updates "docs/images/updates-$lang.png" --height 720 \
    --notes "docs/releases/$NOTES_VERSION.md" "$NOTES_VERSION" -AppleLanguages "($lang)"
done
chmod 644 docs/images/*.png
echo "docs/images: cards, vpn, updates (en, ru); notes of $NOTES_VERSION"
