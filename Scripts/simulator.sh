#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP_VERSION=$(tr -d '\r\n' < VERSION)
source Scripts/toolchain.sh
FAMILY=${1:-iPhone}
SIMULATOR_ID=$(python3 Scripts/select_simulator.py "$FAMILY")
xcodegen generate
xcrun simctl boot "$SIMULATOR_ID" || xcrun simctl list devices booted | grep -F "$SIMULATOR_ID"
xcrun simctl bootstatus "$SIMULATOR_ID" -b
set --
if [[ "$FAMILY" == iPad ]]; then
  set -- -only-testing:AuralUITests
fi
# Preserve the actual test exit code, even while collecting failure evidence.
TEST_STATUS=0
xcodebuild -project Aural.xcodeproj -scheme Aural \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID,arch=$(uname -m)" \
  -derivedDataPath "$PWD/DerivedData-simulator" \
  -parallel-testing-enabled NO -resultBundlePath "$PWD/AuralTests-$FAMILY.xcresult" \
  MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" "$@" test || TEST_STATUS=$?
if [[ "$TEST_STATUS" -eq 0 ]]; then
  xcrun xcresulttool export attachments --path "AuralTests-$FAMILY.xcresult" \
    --output-path "screenshots/$FAMILY"
  shopt -s nullglob
  captures=("screenshots/$FAMILY/"*.png)
  if (( ${#captures[@]} < 10 )); then
    echo "Expected library, search, settings, landscape and player PNG attachments for $FAMILY" >&2
    TEST_STATUS=1
  fi
else
  echo "Aural playback diagnostics ($FAMILY):"
  xcrun simctl spawn "$SIMULATOR_ID" log show --last 15m --style compact \
    --info --debug --predicate 'subsystem == "local.aural.player" AND category == "Playback"' ||
    echo "Playback log collection failed; original test failure retained." >&2
fi
xcrun simctl shutdown "$SIMULATOR_ID"
exit "$TEST_STATUS"
