#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
[[ -d "$DEVELOPER_DIR" ]] || { echo "Required Xcode 26.6 unavailable" >&2; exit 1; }
XCODE_INFO=$(xcodebuild -version)
printf "%s\n" "$XCODE_INFO"
[[ "$XCODE_INFO" == $'Xcode 26.6\nBuild version 17F113' ]] || { echo "Unexpected Xcode build" >&2; exit 1; }
XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
# Official fixed release; SHA-256 cross-checked against Hermit and SourceForge mirror.
# https://github.com/cashapp/hermit-packages/blob/master/xcodegen.hcl
TOOL_HOME="${RUNNER_TEMP:-$PWD/.tools}/aural-xcodegen-$XCODEGEN_VERSION"
mkdir -p "$TOOL_HOME"
ARCHIVE="$TOOL_HOME/xcodegen.zip"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 --proto "=https" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" \
    --output "$ARCHIVE.download"
  printf "%s  %s\n" "$XCODEGEN_SHA256" "$ARCHIVE.download" | shasum -a 256 -c -
  mv "$ARCHIVE.download" "$ARCHIVE"
fi
printf "%s  %s\n" "$XCODEGEN_SHA256" "$ARCHIVE" | shasum -a 256 -c -
unzip -oq "$ARCHIVE" -d "$TOOL_HOME"
export PATH="$TOOL_HOME/xcodegen/bin:$PATH"
[[ "$(command -v xcodegen)" == "$TOOL_HOME/xcodegen/bin/xcodegen" ]] || exit 1
GEN_VERSION=$(xcodegen --version)
echo "$GEN_VERSION"
[[ "$GEN_VERSION" == "Version: $XCODEGEN_VERSION" ]] || { echo "Unexpected XcodeGen version" >&2; exit 1; }
