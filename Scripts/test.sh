#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
swiftc -swift-version 5 Aural/Models/Track.swift Aural/Library/LibraryRepository.swift Aural/Library/LibraryIndex.swift Aural/Library/FileDigest.swift Aural/Playback/PlaybackQueue.swift Tests/main.swift -o "$tmp/aural-tests"
"$tmp/aural-tests"
