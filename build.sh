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

if [ ! -f Resources/AppIcon.icns ] || [ scripts/make_icon.swift -nt Resources/AppIcon.icns ]; then
  swift scripts/make_icon.swift .
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
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
# Auto-continue for Codex is a Swift port of codex-auto-resume (MIT); its notice travels with the app.
cp Resources/ThirdParty/codex-auto-resume-LICENSE.txt "$APP/Contents/Resources/codex-auto-resume-LICENSE.txt"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Where this build lives, so the installed app can notice a newer build here and offer it.
# Not in release builds: they go to other Macs, where this path means nothing (and is private).
if [ -z "${COOLDOWN_RELEASE:-}" ]; then
  echo "$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")" > "$APP/Contents/Resources/build-source.txt"
fi
# A stable local identity keeps macOS permissions (Accessibility, notifications) across builds.
# Created once by scripts/make_signing_identity.sh; ad-hoc signing is the fallback.
KC="$HOME/Library/Keychains/cooldown-signing.keychain-db"
IDENTITY=""
if [ -f "$KC" ]; then
  # Its password is random, made by make_signing_identity.sh and kept in the login keychain.
  KC_PASS=$(security find-generic-password -s "Cooldown signing keychain" -w 2>/dev/null || true)
  [ -n "$KC_PASS" ] && security unlock-keychain -p "$KC_PASS" "$KC" 2>/dev/null || true
  IDENTITY=$(security find-identity -p codesigning "$KC" 2>/dev/null | awk '/Cooldown Local Signing/ {print $2; exit}')
fi
if [ -n "$IDENTITY" ]; then
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
