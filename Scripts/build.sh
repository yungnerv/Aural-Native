#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP_VERSION=$(tr -d '\r\n' < VERSION)
BUILD_NUMBER=${GITHUB_RUN_NUMBER:-1}
COMMIT=$(git rev-parse HEAD)
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]
source Scripts/toolchain.sh
xcodegen generate
xcodebuild -project Aural.xcodeproj -scheme Aural -configuration Release \
  -sdk iphoneos -destination generic/platform=iOS \
  -derivedDataPath "$PWD/DerivedData" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build
python3 Scripts/package.py \
  --app DerivedData/Build/Products/Release-iphoneos/Aural.app \
  --output output --version "$APP_VERSION" --build "$BUILD_NUMBER" --commit "$COMMIT"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat output/BUILD.txt >> "$GITHUB_STEP_SUMMARY"
fi
