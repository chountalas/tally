#!/usr/bin/env bash
# One-command signed + notarized release.
# Required environment variables:
#   CODE_SIGN_IDENTITY
#   NOTARY_PROFILE
#   TALLY_RELEASE_BUNDLE_IDENTIFIER
#   TALLY_RELEASE_DEVELOPMENT_TEAM
# Optional environment variable:
#   VERSION (defaults to MARKETING_VERSION in project.yml)
set -euo pipefail

APP_NAME="Tally"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_VERSION="$(awk '/MARKETING_VERSION:/ { print $2; exit }' "$ROOT_DIR/project.yml")"
VERSION="${VERSION:-$DEFAULT_VERSION}"
APP_PATH="$ROOT_DIR/DerivedData/Build/Products/Release/$APP_NAME.app"
DMG_PATH="$ROOT_DIR/dist/$APP_NAME-$VERSION-arm64.dmg"
ZIP_PATH="$ROOT_DIR/dist/$APP_NAME-$VERSION-arm64.zip"
STAGING_DIR="$ROOT_DIR/dist/staging"

require_env() {
  local variable_name="$1"
  if [[ -z "${!variable_name:-}" ]]; then
    echo "Required environment variable is not set: $variable_name" >&2
    exit 1
  fi
}

require_env CODE_SIGN_IDENTITY
require_env NOTARY_PROFILE
require_env TALLY_RELEASE_BUNDLE_IDENTIFIER
require_env TALLY_RELEASE_DEVELOPMENT_TEAM

SIGN_IDENTITY="$CODE_SIGN_IDENTITY"

if [[ -z "$VERSION" ]]; then
  echo "Could not determine MARKETING_VERSION from project.yml." >&2
  exit 1
fi

cd "$ROOT_DIR"

echo "==> Building and signing $APP_NAME $VERSION"
CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  TALLY_RELEASE_BUNDLE_IDENTIFIER="$TALLY_RELEASE_BUNDLE_IDENTIFIER" \
  TALLY_RELEASE_DEVELOPMENT_TEAM="$TALLY_RELEASE_DEVELOPMENT_TEAM" \
  VERSION="$VERSION" \
  ./scripts/package_release.sh >/dev/null

echo "==> Submitting the app zip to Apple for notarization"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling the app notarization ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Rebuilding release artifacts from the stapled app"
rm -f "$ZIP_PATH" "$DMG_PATH"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> Signing the disk image"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

echo "==> Submitting the disk image to Apple for notarization"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling the disk image notarization ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "==> Refreshing checksums"
shasum -a 256 "$ZIP_PATH" "$DMG_PATH" > "$ROOT_DIR/dist/checksums.txt"

echo "==> Verifying Gatekeeper acceptance"
spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"

echo ""
echo "Done. Notarized files in dist/:"
echo "  $DMG_PATH"
echo "  $ZIP_PATH"
echo "  $ROOT_DIR/dist/checksums.txt"
echo ""
echo "Upload them to a GitHub release with:"
echo "  gh release upload v$VERSION dist/$APP_NAME-$VERSION-arm64.dmg dist/$APP_NAME-$VERSION-arm64.zip dist/checksums.txt --clobber -R chountalas/tally"
