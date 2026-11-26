# Development

Models contain portable track data. Library owns versioned persistence, indexing, streaming content hashes and importing. Playback separates AVPlayer/session ownership, queue ordering, progress and main-actor coordination. System owns Now Playing and remote command registration. Artwork owns bounded asynchronous decoding. Views own presentation; playback progress is observed only by a small subtree. Scripts contain CI tests and IPA packaging.

## Storage contract

The AuralLibrary directory and existing media filenames remain unchanged. Legacy arrays are accepted; the next successful mutation writes a schema 1 envelope. The previous valid index is preserved as library.previous.json. Unreadable or unsupported indexes, including missing indexes alongside existing media, block mutations. The repository refuses to delete any file still referenced by the committed index. Recovery is deliberate; the backup is metadata only, not a copy of music. Deleted media may no longer exist. Unknown files are never automatically removed; an interrupted import may leave orphan files. Do not downgrade after migration to a version that understands only legacy arrays. Keep original audio separately.

Imports are serialized with other mutations, lazily hash legacy tracks, stream new hashes in bounded chunks and commit in batches of up to 16. Index commit precedes deletion. Cleanup targets only uncommitted imports or tracks removed successfully from the index. Atomic JSON is retained until large-library measurements justify a tested SQLite migration.

## Build and release

iOS/iPadOS 26.1+. The CI workflow runs Scripts/test.sh then Scripts/build.sh. VERSION is the sole release version. project.yml contains only a placeholder; Scripts/build.sh supplies the real version and build number for both CI and local builds. The bundle keys expand from build settings and exact values are logged and checked. Automatic CI runs for pull requests and relevant main changes. Optional manual prereleases publish unsigned IPA and checksum. Keep main buildable. Do not merge until CI succeeds; do not call device behavior validated until tested.

## Remaining validation

Physical-device signing, interruptions and background playback, storage recovery tooling, profiling at large-library scale, extended decoders, gapless playback and full PWA parity remain outstanding. Playback engine and system controller have independent ownership and observation lifetimes. Physical-device lifecycle testing remains required.

Packaging is implemented in Scripts/package.py. CI parses both shell scripts and exercises packaging against synthetic bundles before invoking Xcode. The packager validates bundle identity, version, executable and archive integrity, preserves executable permissions, rejects escaping symlinks, and publishes checksum and build metadata only after archive validation. Synthetic fixtures do not establish actual iOS installation compatibility.

A genuinely new, empty library receives a schema-1 index before importing. Interrupted first imports therefore cannot make the library appear to have lost its index. Before any commit or media deletion, the repository compares the on-disk index with its last known bytes and fails closed if they differ. This is a single-process, single-writer architecture with accidental stale-writer detection, not a multiprocess locking guarantee.

## Recovery and audit corrections (0.2.1)
The empty index is written atomically before import. A corrupt or missing index can be inspected and explicitly restored from the previous snapshot only when all referenced audio and artwork files are regular files and present. A healthy index or unsupported newer schema is not eligible. Preserve damaged bytes in a uniquely named archive; do not delete media or unreferenced files during recovery. Missing media blocks restore. The UI exposes an explicit retry and confirmation; stale writes and direct stale deletions both invalidate the repository. Recovery is not a replacement for external music backups. A 10,000-track synthetic metadata fixture checks host serialization and index behavior, not device performance or actual 10,000-file import.

## Simulator and toolchain gates
CI now validates an exact Xcode version (26.6), the reviewed XcodeGen version (2.48.0) and immutable GitHub Action commits. Homebrew is used to obtain XcodeGen if missing; unexpected versions fail closed and require a deliberate review. This is tool-version control, not a bit-for-bit reproducibility guarantee. Simulator tests exercise import bytes, duplicate rejection, failed import cleanup, playback intent/lifecycle and fresh launch. Strict concurrency checking is enabled in Swift 5 language mode to expose migration warnings; Swift 6 mode is not yet enforced. Remote commands reject unavailable requests and stale queued track IDs; an accepted command is not a guarantee of successful audio rendering. Native integration and UI tests must pass before publication.
