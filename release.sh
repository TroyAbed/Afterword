#!/usr/bin/env bash
# Build a Release .app, package it as a .dmg, and publish a GitHub release.
#
#   ./release.sh 0.2                 # tag v0.2, build, dmg, gh release create
#   ./release.sh 0.2 --dmg-only      # just build the dmg into dist/, no release
#
# Needs: xcodegen, and (for the release step) `gh auth login` done once.
# The app is ad-hoc signed — not notarized. Until there is a paid Apple
# Developer account, a fresh download needs one command on the target Mac:
#   xattr -dr com.apple.quarantine /Applications/Afterword.app
set -euo pipefail

VER="${1:?usage: ./release.sh <version> [--dmg-only]}"
DMG_ONLY="${2:-}"
TAG="v$VER"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$ROOT/mac-app"
DERIVED="/tmp/afterword-release"
DIST="$ROOT/dist"
STAGE="/tmp/afterword-dmg"

echo "── build Release ($VER) ──"
cd "$APPDIR"
xcodegen generate >/dev/null
# keep Info.plist versions in step with the tag
xcodebuild -project Afterword.xcodeproj -scheme Afterword -configuration Release \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VER" CURRENT_PROJECT_VERSION="$(date +%Y%m%d)" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  build >/dev/null
APP="$DERIVED/Build/Products/Release/Afterword.app"
[ -d "$APP" ] || { echo "build produced no .app"; exit 1; }

echo "── package .dmg ──"
mkdir -p "$DIST"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Afterword-$VER.dmg"
rm -f "$DMG"
hdiutil create -volname "Afterword $VER" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "   $DMG  ($(du -h "$DMG" | cut -f1))"

if [ "$DMG_ONLY" = "--dmg-only" ]; then
  echo "── done (dmg only) ──"
  exit 0
fi

command -v gh >/dev/null || { echo "gh not installed — 'brew install gh', then 'gh auth login'"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "not logged in — run 'gh auth login'"; exit 1; }

echo "── publish GitHub release $TAG ──"
git tag -f "$TAG"
git push origin "$TAG"
INSTALL="macOS 14+, Apple Silicon or Intel. Ad-hoc signed — after downloading:
\`\`\`
xattr -dr com.apple.quarantine /Applications/Afterword.app
\`\`\`
Then open normally. First launch asks for Microphone (+ Screen Recording for
system audio / video; restart after granting). Set the server URL in
Einstellungen \u2192 Server."

# release notes: the CHANGELOG section for this version, else just the install note
NOTES_FILE="$(mktemp)"
if [ -f "$ROOT/CHANGELOG.md" ] && awk -v v="## $VER" '$0==v{f=1;next} /^## /{f=0} f' "$ROOT/CHANGELOG.md" | grep -q .; then
  awk -v v="## $VER" '$0==v{f=1;next} /^## /{f=0} f' "$ROOT/CHANGELOG.md" > "$NOTES_FILE"
  printf '\n---\n\n%b\n' "$INSTALL" >> "$NOTES_FILE"
else
  printf '%b\n' "$INSTALL" > "$NOTES_FILE"
fi

gh release create "$TAG" "$DMG" --title "Afterword $VER" --notes-file "$NOTES_FILE"
rm -f "$NOTES_FILE"gh release create "$TAG" "$DMG" --title "Afterword $VER" --notes "$NOTES"
echo "── done ──"
