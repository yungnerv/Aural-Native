# Development

Models contain portable track data. Library owns versioned persistence, indexing, streaming content hashes and importing. Playback owns AVPlayer orchestration and queue ordering. Artwork owns bounded asynchronous decoding. Views own presentation; playback progress is observed only by a small subtree. Scripts contain CI tests and IPA packaging.

## Storage contract

The AuralLibrary directory and existing media filenames remain unchanged. Legacy arrays are accepted; the next successful mutation writes a schema 1 envelope. The previous valid index is preserved as library.previous.json. Unreadable or unsupported indexes block mutations. Recovery is deliberate; the backup is metadata only, not a copy of music. Deleted media may no longer exist. Unknown files are never automatically removed; an interrupted import may leave orphan files. Do not downgrade after migration to a version that understands only legacy arrays. Keep original audio separately.

Imports are serialized with other mutations, lazily hash legacy tracks, stream new hashes in bounded chunks and commit in batches of up to 16. Index commit precedes deletion. Cleanup targets only uncommitted imports or tracks removed successfully from the index. Atomic JSON is retained until large-library measurements justify a tested SQLite migration.

## Build and release

iOS/iPadOS 26.1+. The CI workflow runs Scripts/test.sh then Scripts/build.sh. VERSION controls CI version; project.yml is the XcodeGen project and its version is the local fallback. The bundle keys expand from build settings and exact values are logged and checked. Automatic CI runs for pull requests and relevant main changes. Optional manual prereleases publish unsigned IPA and checksum. Keep main buildable. Do not merge until CI succeeds; do not call device behavior validated until tested.

## Remaining validation

Physical-device signing, interruptions and background playback, storage recovery tooling, profiling at large-library scale, extended decoders, gapless playback and full PWA parity remain outstanding. Playback coordinator still owns AVPlayer and system controls; a further measured split is appropriate once the storage changes compile.
