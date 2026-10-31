#!/bin/sh
# Builds Cooldown.app with the Command Line Tools (no Xcode needed).
#   ./build.sh            build into build/Cooldown.app
#   ./build.sh --install  also copy it to /Applications and start it
set -eu
cd "$(dirname "$0")"

# The bundle id decides where macOS keeps Cooldown's settings and permissions. A fork that is
# built alongside the original can set its own in local.env (ignored by git):
#   COOLDOWN_BUNDLE_ID=com.yourname.cooldown
[ -f local.env ] && . ./local.env
BUNDLE_ID="${COOLDOWN_BUNDLE_ID:-com.vitalyor.cooldown}"

# Command Line Tools ship the macOS 27 SDK, where SwiftUI's @State is a macro whose plugin only
# comes with Xcode. Without Xcode, build against the macOS 26 SDK that the tools also include.
if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk; do
    if [ -d "$sdk" ]; then SDKROOT="$sdk"; fi
  done
  if [ -n "${SDKROOT:-}" ]; then export SDKROOT; echo "SDK: $SDKROOT"; fi
fi


swift build -c release --product Cooldown
BIN="$(swift build -c release --show-bin-path)/Cooldown"

APP="build/Cooldown.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cooldown"
sed "s/__BUNDLE_ID__/$BUNDLE_ID/" Resources/Info.plist > "$APP/Contents/Info.plist"
# Release builds drop debug symbols: smaller, and the build machine's folder paths that the
# linker records for debugging do not travel to other Macs.
if [ -n "${COOLDOWN_RELEASE:-}" ]; then
  strip -S -x "$APP/Contents/MacOS/Cooldown"
fi
# Release builds carry the version being released and a build number from the history.
if [ -n "${COOLDOWN_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $COOLDOWN_VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" "$APP/Contents/Info.plist"
fi
cp Resources/Scriptable/Cooldown.js "$APP/Contents/Resources/Cooldown.js"
# Translations: Russian is the source text; every other language has a Localizable.strings.
for folder in Resources/Localization/*.lproj; do
  [ -d "$folder" ] && cp -R "$folder" "$APP/Contents/Resources/"
done
# The icon is an Icon Composer document (Resources/AppIcon.icon, made by scripts/make_icon.py):
# layers that macOS renders as Liquid Glass, with its dark, tinted and clear looks. Xcode's actool
# compiles it into Assets.car (the layered icon) and AppIcon.icns (for older places), and the
# .icns is kept in Resources so a build with only the Command Line Tools still has an icon.
ICON_OUT="build/icon"
# actool comes only with Xcode; use it even when the active developer folder is the Command Line Tools.
ICON_DEV="$(xcode-select -p 2>/dev/null)"
[ -d /Applications/Xcode.app/Contents/Developer ] && ICON_DEV=/Applications/Xcode.app/Contents/Developer
if DEVELOPER_DIR="$ICON_DEV" xcrun --find actool >/dev/null 2>&1 && [ -d Resources/AppIcon.icon ]; then
  rm -rf "$ICON_OUT"; mkdir -p "$ICON_OUT"
  if DEVELOPER_DIR="$ICON_DEV" xcrun actool Resources/AppIcon.icon --compile "$ICON_OUT" --platform macosx --minimum-deployment-target 26.0 \
       --app-icon AppIcon --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null 2>&1 \
     && [ -f "$ICON_OUT/Assets.car" ]; then
    cp "$ICON_OUT/Assets.car" "$APP/Contents/Resources/Assets.car"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
    [ -f "$ICON_OUT/AppIcon.icns" ] && ! cmp -s "$ICON_OUT/AppIcon.icns" Resources/AppIcon.icns && cp "$ICON_OUT/AppIcon.icns" Resources/AppIcon.icns
  else
    echo "actool could not compile Resources/AppIcon.icon; using Resources/AppIcon.icns"
  fi
fi
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Where this build lives, so the installed app can notice a newer build here and offer it.
# Not in release builds: they go to other Macs, where this path means nothing (and is private).
if [ -z "${COOLDOWN_RELEASE:-}" ]; then
  echo "$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")" > "$APP/Contents/Resources/build-source.txt"
fi
# Signing, in order of preference:
# 1. The developer's Developer ID certificate (Apple-issued; releases are also notarized).
#    The hardened runtime is what notarization requires. COOLDOWN_SIGN=local forces 2.
# 2. A stable local identity, so macOS keeps its permissions across builds
#    (created once by scripts/make_signing_identity.sh).
# 3. Ad-hoc.
DEV_ID=""
if [ "${COOLDOWN_SIGN:-}" != "local" ]; then
  DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application: .*\(PB68QTT4YR\)/ {print $2; exit}')
fi
KC="$HOME/Library/Keychains/cooldown-signing.keychain-db"
IDENTITY=""
if [ -z "$DEV_ID" ] && [ -f "$KC" ]; then
  # Its password is random, made by make_signing_identity.sh and kept in the login keychain.
  KC_PASS=$(security find-generic-password -s "Cooldown signing keychain" -w 2>/dev/null || true)
  [ -n "$KC_PASS" ] && security unlock-keychain -p "$KC_PASS" "$KC" 2>/dev/null || true
  IDENTITY=$(security find-identity -p codesigning "$KC" 2>/dev/null | awk '/Cooldown Local Signing/ {print $2; exit}')
fi
# Installing over /Applications with a local/ad-hoc signature makes macOS forget the app's
# Keychain access and ask for the login password again. A normal install must use Developer ID.
if [ "${1:-}" = "--install" ] && [ -z "$DEV_ID" ] && [ "${COOLDOWN_ALLOW_LOCAL_INSTALL:-0}" != "1" ]; then
  echo "Refusing to install without a Developer ID signature. Set COOLDOWN_ALLOW_LOCAL_INSTALL=1 only for a private test."
  exit 1
fi

if [ -n "$DEV_ID" ]; then
  # Releases get a secure timestamp from Apple (notarization needs it); everyday builds skip the round trip.
  if [ -n "${COOLDOWN_RELEASE:-}" ]; then STAMP="--timestamp"; else STAMP="--timestamp=none"; fi
  codesign --force --options runtime $STAMP --sign "$DEV_ID" "$APP"
elif [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --keychain "$KC" --timestamp=none "$APP"
else
  codesign --force --sign - --timestamp=none "$APP"
fi
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x Cooldown 2>/dev/null || true
  rm -rf "/Applications/Cooldown.app" "$HOME/Applications/Cooldown.app"
  cp -R "$APP" "/Applications/Cooldown.app"
  open "/Applications/Cooldown.app"
  echo "Installed to /Applications/Cooldown.app"
fi
