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
APP_BINARY=DerivedData/Build/Products/Release-iphoneos/Aural.app/Aural
ARCHITECTURES=$(xcrun lipo -archs "$APP_BINARY")
[[ "$ARCHITECTURES" == arm64 ]] || { echo "Unexpected iOS executable architecture: $ARCHITECTURES" >&2; exit 1; }
BUILD_INFO=$(xcrun vtool -show-build "$APP_BINARY")
printf '%s\n' "$BUILD_INFO"
# LC_BUILD_VERSION identifies the target platform, not the host machine.
# Simulator binaries also use arm64; checking architecture alone is insufficient.
[[ "$(printf '%s\n' "$BUILD_INFO" | awk '$1 == "platform" { print $2 }')" == IOS ]] ||
  { echo "Expected physical iOS Mach-O platform" >&2; exit 1; }
python3 Scripts/package.py \
  --app DerivedData/Build/Products/Release-iphoneos/Aural.app \
  --output output --version "$APP_VERSION" --build "$BUILD_NUMBER" --commit "$COMMIT"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat output/BUILD.txt >> "$GITHUB_STEP_SUMMARY"
fi
