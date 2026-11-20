#!/bin/sh
# Publishes a release on GitHub: builds Cooldown, packs it as a .dmg (drag to Applications) and a
# .zip, tags the commit and creates the release with the notes from docs/releases/<version>.md.
# GitHub adds the source code archives to every release by itself.
#   scripts/release.sh 1.0.0
# A version with a suffix (1.4.6-beta.1) is a beta: a prerelease on GitHub, which only Cooldowns
# with "Beta versions" on take, and no Homebrew update.
set -eu
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v$VERSION"
case "$VERSION" in *-*) BETA=1 ;; *) BETA= ;; esac
NOTES="docs/releases/$VERSION.md"
[ -f "$NOTES" ] || { echo "Write $NOTES first."; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit or stash changes first."; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "$TAG already exists."; exit 1; }

# The version goes into the source too, so builds made from here know which release they are
# (and the updater does not take a local build for an old one).
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION%%-*}" Resources/Info.plist
if [ -n "$(git status --porcelain)" ]; then
  git commit -q -am "Version $VERSION"
fi
# Always: the release's commits must be on GitHub's main, not only under the tag.
git push -q

# Everything that can be checked without a Mac app bundle is checked before publishing.
python3 scripts/l10n_build.py
swift test
# COOLDOWN_SIGN=local publishes a build signed like 1.2.x (the bridge release that teaches the
# updater to accept Developer ID builds); otherwise the Developer ID certificate is used.
COOLDOWN_VERSION="$VERSION" COOLDOWN_RELEASE=1 ./build.sh
# The rules that must never break are checked on the very build being published.
build/Cooldown.app/Contents/MacOS/Cooldown --selftest || { echo "Self-test failed: not publishing."; exit 1; }
codesign --verify --deep --strict build/Cooldown.app || { echo "Signature check failed: not publishing."; exit 1; }

OUT="build/release"
rm -rf "$OUT" && mkdir -p "$OUT/dmg"

# Builds signed with the Developer ID certificate are notarized by Apple, and the tickets are
# stapled to the app and the .dmg, so they open without a warning even offline. Credentials come
# from the keychain profile made once with `xcrun notarytool store-credentials cooldown-notary`.
DEV_ID=$(codesign -dvv build/Cooldown.app 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)
PROFILE="${COOLDOWN_NOTARY_PROFILE:-cooldown-notary}"
notarize() {
  echo "Notarizing $(basename "$1")…"
  RESULT=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)
  echo "$RESULT" | grep -q '"status" *: *"Accepted"' || { echo "Notarization failed: $RESULT"; exit 1; }
}
[ -n "$DEV_ID" ] || { echo "No Developer ID signature (set COOLDOWN_ALLOW_UNNOTARIZED=1 only for a private test build)."; [ "${COOLDOWN_ALLOW_UNNOTARIZED:-0}" = "1" ] || exit 1; }
if [ -n "$DEV_ID" ]; then
  ditto -c -k --keepParent build/Cooldown.app "$OUT/notarize.zip"
  notarize "$OUT/notarize.zip"
  rm "$OUT/notarize.zip"
  xcrun stapler staple -q build/Cooldown.app
fi

cp -R build/Cooldown.app "$OUT/dmg/"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "Cooldown $VERSION" -srcfolder "$OUT/dmg" -fs HFS+ -format UDZO "$OUT/Cooldown-$VERSION.dmg"
if [ -n "$DEV_ID" ]; then
  codesign --sign "$DEV_ID" --timestamp "$OUT/Cooldown-$VERSION.dmg"
  notarize "$OUT/Cooldown-$VERSION.dmg"
  xcrun stapler staple -q "$OUT/Cooldown-$VERSION.dmg"
  xcrun stapler validate -q "$OUT/Cooldown-$VERSION.dmg" || { echo "Notarization ticket not stapled."; exit 1; }
fi
ditto -c -k --keepParent build/Cooldown.app "$OUT/Cooldown-$VERSION.zip"
( cd "$OUT" && shasum -a 256 "Cooldown-$VERSION.dmg" "Cooldown-$VERSION.zip" > SHA256SUMS.txt )

git tag -a "$TAG" -m "Cooldown $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$OUT/Cooldown-$VERSION.dmg" "$OUT/Cooldown-$VERSION.zip" "$OUT/SHA256SUMS.txt" \
  --title "Cooldown $VERSION" --notes-file "$NOTES" ${BETA:+--prerelease}
echo "Released $TAG"

# The Homebrew cask (github.com/vitalyor/homebrew-tap) follows the release, when its clone is next to this one.
TAP="${COOLDOWN_TAP:-../homebrew-tap}"
if [ -z "$BETA" ] && [ -f "$TAP/Casks/cooldown.rb" ]; then
  SHA=$(shasum -a 256 "$OUT/Cooldown-$VERSION.dmg" | cut -d' ' -f1)
  sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/cooldown.rb"
  ( cd "$TAP" && git commit -qam "Cooldown $VERSION" && git push -q ) && echo "Homebrew tap updated"
fi
