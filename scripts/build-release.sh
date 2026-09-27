#!/bin/bash
# Builds a Release copy of Zephydian and zips it for a GitHub Release.
# Used by .github/workflows/release.yml, and you can run it locally too:
#
#     scripts/build-release.sh
#
# Output: dist/Zephydian-<version>.zip plus its SHA-256 (needed for the Homebrew cask).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(awk '/MARKETING_VERSION:/ { print $2; exit }' app/project.yml)
BUILD_DIR=app/build/release
APP="$BUILD_DIR/Build/Products/Release/Zephydian.app"
ZIP="dist/Zephydian-$VERSION.zip"

echo "Building Zephydian $VERSION"
(cd app && xcodegen --quiet)
mkdir -p app/build && touch app/build/.metadata_never_index   # keep test copies out of Spotlight
xcodebuild -project app/Zephydian.xcodeproj -scheme Zephydian -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$BUILD_DIR" -quiet clean build

# ditto keeps macOS metadata (code signature, symlinks) intact, unlike plain `zip`.
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | awk '{ print $1 }' > "$ZIP.sha256"

echo "Created $ZIP"
echo "SHA-256: $(cat "$ZIP.sha256")"
