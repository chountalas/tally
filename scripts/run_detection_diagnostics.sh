#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

flag_file="${TMPDIR:-/tmp}/subscription-diagnostics.flag"
trap 'rm -f "$flag_file"' EXIT
touch "$flag_file"

xcodebuild test \
  -scheme Tally \
  -destination 'platform=macOS' \
  -only-testing:TallyTests/SubscriptionDetectionDiagnosticsTests/testPrintDetectionDiagnosticsFixtures
