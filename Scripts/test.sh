#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
source Scripts/toolchain.sh
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors Aural/Models/Track.swift Aural/Models/TrackMetadata.swift Aural/Library/LibraryRepository.swift Aural/Library/LibraryIndex.swift Aural/Library/FileDigest.swift Aural/Playback/PlaybackQueue.swift Aural/System/RemoteCommandGate.swift Tests/main.swift -o "$tmp/aural-tests"
"$tmp/aural-tests"
