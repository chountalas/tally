#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Tally"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_VERSION="$(awk '/MARKETING_VERSION:/ { print $2; exit }' "$ROOT_DIR/project.yml")"
VERSION="${VERSION:-$DEFAULT_VERSION}"
DERIVED_DATA="$ROOT_DIR/DerivedData"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/staging"
APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION-arm64.zip"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION-arm64.dmg"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
BUNDLE_IDENTIFIER="${TALLY_RELEASE_BUNDLE_IDENTIFIER:-dev.tally.Tally}"
DEVELOPMENT_TEAM="${TALLY_RELEASE_DEVELOPMENT_TEAM:-}"

if [[ -z "$VERSION" ]]; then
  echo "Could not determine MARKETING_VERSION from project.yml." >&2
  exit 1
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  TIMESTAMP_FLAG="--timestamp=none"
else
  TIMESTAMP_FLAG="--timestamp"
fi

cd "$ROOT_DIR"

xcodegen generate

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR" "$STAGING_DIR"

BUILD_SETTINGS=(
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
  TALLY_BUNDLE_IDENTIFIER="$BUNDLE_IDENTIFIER"
  MARKETING_VERSION="$VERSION"
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=YES
  ENABLE_HARDENED_RUNTIME=YES
)

if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  BUILD_SETTINGS+=(TALLY_DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

xcodebuild \
  -project "$ROOT_DIR/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS,arch=arm64' \
  "${BUILD_SETTINGS[@]}" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app not found: $APP_PATH" >&2
  exit 1
fi

codesign --force --deep --options runtime "$TIMESTAMP_FLAG" --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

shasum -a 256 "$ZIP_PATH" "$DMG_PATH" > "$DIST_DIR/checksums.txt"

echo "$ZIP_PATH"
echo "$DMG_PATH"
