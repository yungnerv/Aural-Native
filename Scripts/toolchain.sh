#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
[[ -d "$DEVELOPER_DIR" ]] || { echo "Required Xcode 26.6 unavailable" >&2; exit 1; }
xcodebuild -version
[[ "$(xcodebuild -version | head -1)" == "Xcode 26.6" ]] || exit 1
command -v xcodegen >/dev/null || brew install xcodegen
GEN_VERSION=$(xcodegen --version)
echo "$GEN_VERSION"
[[ "$GEN_VERSION" == *"2.48.0"* ]] || { echo "Expected XcodeGen 2.48.0; review the toolchain update before building" >&2; exit 1; }
