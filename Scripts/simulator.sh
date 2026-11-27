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
xcodebuild -project Aural.xcodeproj -scheme Aural \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID,arch=$(uname -m)" \
  -derivedDataPath "$PWD/DerivedData-simulator" \
  -parallel-testing-enabled NO -resultBundlePath "$PWD/AuralTests-$FAMILY.xcresult" \
  MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" "$@" test
xcrun simctl shutdown "$SIMULATOR_ID"
