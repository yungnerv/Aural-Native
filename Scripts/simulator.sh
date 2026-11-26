#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP_VERSION=$(tr -d '\r\n' < VERSION)
source Scripts/toolchain.sh
SIMULATOR_ID=$(python3 Scripts/select_simulator.py)
xcodegen generate
xcrun simctl boot "$SIMULATOR_ID" || xcrun simctl list devices booted | grep -F "$SIMULATOR_ID"
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcodebuild -project Aural.xcodeproj -scheme Aural \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$PWD/DerivedData-simulator" \
  -parallel-testing-enabled NO -resultBundlePath "$PWD/AuralTests.xcresult" \
  MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" test
