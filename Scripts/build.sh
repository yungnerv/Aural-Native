#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP_VERSION=$(tr -d '\r\n' < VERSION)
GITHUB_RUN_NUMBER="${GITHUB_RUN_NUMBER:-1}"
GITHUB_SHA="${GITHUB_SHA:-$(git rev-parse HEAD)}"
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$GITHUB_RUN_NUMBER" =~ ^[0-9]+$ ]]
command -v xcodegen >/dev/null || brew install xcodegen
xcodebuild -version
xcodegen generate
xcodebuild -project Aural.xcodeproj -scheme Aural -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$PWD/DerivedData" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER" build
APP="$PWD/DerivedData/Build/Products/Release-iphoneos/Aural.app"
test -f "$APP/Aural" || { echo 'App executable missing' >&2; exit 1; }
verify() {
  local key="$1" expected="$2" actual
  actual=$(/usr/libexec/PlistBuddy -c "Print $key" "$APP/Info.plist")
  printf '%s: %s (expected %s)\n' "$key" "$actual" "$expected"
  [[ "$actual" == "$expected" ]] || { echo "Bundle verification failed: $key" >&2; exit 1; }
}
verify CFBundleIdentifier local.aural.player
verify CFBundleShortVersionString "$APP_VERSION"
verify CFBundleVersion "$GITHUB_RUN_NUMBER"
rm -rf output/Payload
mkdir -p output/Payload
ditto "$APP" output/Payload/Aural.app"
cd output
IPA="Aural-${APP_VERSION}-build-${GITHUB_RUN_NUMBER}-unsigned.ipa"
rm -f "$IPA"
zip -qry "$IPA" Payload
unzip -tq "$IPA"
shasum -a 256 "$IPA" > SHA256SUMS.txt
printf 'Version: %s\nBuild: %s\nCommit: %s\nUnsigned: yes\n' "$APP_VERSION" "$GITHUB_RUN_NUMBER" "$GITHUB_SHA" > BUILD.txt
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat BUILD.txt >> "$GITHUB_STEP_SUMMARY"; fi
