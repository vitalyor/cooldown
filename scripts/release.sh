#!/bin/sh
# Publishes a release on GitHub: builds Cooldown, packs it as a .dmg (drag to Applications) and a
# .zip, tags the commit and creates the release with the notes from docs/releases/<version>.md.
# GitHub adds the source code archives to every release by itself.
#   scripts/release.sh 1.0.0
set -eu
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v$VERSION"
NOTES="docs/releases/$VERSION.md"
[ -f "$NOTES" ] || { echo "Write $NOTES first."; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit or stash changes first."; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "$TAG already exists."; exit 1; }

# The version goes into the source too, so builds made from here know which release they are
# (and the updater does not take a local build for an old one).
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
if [ -n "$(git status --porcelain)" ]; then
  git commit -q -am "Version $VERSION"
  git push -q
fi

COOLDOWN_VERSION="$VERSION" COOLDOWN_RELEASE=1 ./build.sh

OUT="build/release"
rm -rf "$OUT" && mkdir -p "$OUT/dmg"
cp -R build/Cooldown.app "$OUT/dmg/"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "Cooldown $VERSION" -srcfolder "$OUT/dmg" -fs HFS+ -format UDZO "$OUT/Cooldown-$VERSION.dmg"
ditto -c -k --keepParent build/Cooldown.app "$OUT/Cooldown-$VERSION.zip"
( cd "$OUT" && shasum -a 256 "Cooldown-$VERSION.dmg" "Cooldown-$VERSION.zip" > SHA256SUMS.txt )

git tag -a "$TAG" -m "Cooldown $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$OUT/Cooldown-$VERSION.dmg" "$OUT/Cooldown-$VERSION.zip" "$OUT/SHA256SUMS.txt" \
  --title "Cooldown $VERSION" --notes-file "$NOTES"
echo "Released $TAG"
