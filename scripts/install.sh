#!/bin/bash
set -euo pipefail

APP_NAME="Tally"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/release"
INSTALL_DIR="/Applications"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
QUIET=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--quiet]

Options:
  --quiet   Suppress xcodebuild output during the Release build
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --quiet)
      QUIET=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

BUILD_START_TIME=$(date +%s)

echo "Building $APP_NAME for macOS (Release)..."

XCODEBUILD_ARGS=(
  -project "$PROJECT_DIR/$APP_NAME.xcodeproj"
  -scheme "$APP_NAME"
  -configuration Release
  -destination "generic/platform=macOS"
  -derivedDataPath "$BUILD_DIR"
)

if [ "$QUIET" -eq 1 ]; then
  xcodebuild "${XCODEBUILD_ARGS[@]}" -quiet
else
  xcodebuild "${XCODEBUILD_ARGS[@]}" -showBuildTimingSummary
fi

BUILD_END_TIME=$(date +%s)
BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))
printf 'Build completed in %02dm:%02ds.\n' "$((BUILD_DURATION / 60))" "$((BUILD_DURATION % 60))"

APP_PATH=$(find "$BUILD_DIR" -name "$APP_NAME.app" -type d | head -1)

if [ -z "$APP_PATH" ]; then
  echo "Error: Build succeeded but $APP_NAME.app not found."
  exit 1
fi

echo "Installing to $INSTALL_DIR..."

INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

if [ -d "$INSTALLED_APP" ]; then
  rm -rf "$INSTALLED_APP"
fi

cp -R "$APP_PATH" "$INSTALL_DIR/"

if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$INSTALLED_APP"
fi

mdimport "$INSTALLED_APP" >/dev/null 2>&1 || true

echo "Done! $APP_NAME installed to $INSTALLED_APP"
echo "Open it from Spotlight or your Applications folder."
