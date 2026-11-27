# Changelog

## 0.3.0 — Foundation hardening
- Use playback revision tickets for remote commands and scrubbing, reject seeks without an item, and reprepare failed items on explicit resume.
- Release the audio session on pause/clear, gate queue navigation on library availability, and publish the replacement queue before playback starts.
- Correct subsecond slider ranges, non-drag accessibility adjustments, search and Favorites empty states, and playback button availability.
- Stage imports privately, validate sources before copying, and publish audio and artwork under separate names without replacing existing files.
- Surface failed import cleanup; retain media needed by the previous index and reclaim only media from a retired snapshot after a successful commit.
- Verify recorded audio checksums during explicit recovery; add regression coverage for recovery retention, checksum mismatch and nonregular imports.

## 0.2.2 — Swift 6 concurrency foundation
- Isolate observer destruction on the owning main actor.
- Scope item notifications to their registered item; transfer only immutable generation values to asynchronous callbacks.
- Invalidate obsolete item, player and seek callbacks on replacement/reset.
- Explicitly mark system callbacks Sendable and protect remote command state with a standard-library mutex.
- Enable Swift 6 and warnings-as-errors for application, tests and portable Swift suite.
- Add regression coverage for obsolete notifications and observer owner release.

## 0.2.1 — Foundation audit corrections
- Independent stale-index verification before deletion; atomic first index and fail-closed UI state.
- Explicit previous-index recovery with file validation and preservation of damaged bytes.
- Case-folded filename collision checks and directory/symlink deletion guards.
- Separate Favorites filtering; visible busy/recovery states.
- Independent stale-delete, recovery, path safety and 10,000-track metadata tests.
- Track-bound scrub gestures, live navigation group lookup, queue pruning and remote command availability checks.
- Media-services reset recovery, simulator integration and launch tests, tool-version validation and pinned CI action commits.

## 0.2.0 — Foundation hardening
- Explicit bundle version keys and diagnostics; modern CI actions and separate scripts.
- Asynchronous versioned storage, atomic writes, previous-index backup and corruption protection.
- Serialized mutations, bounded import batches and streaming duplicate detection.
- Separate importer, playback engine, queue, system controller, library index and artwork cache; isolate progress view updates.
- Protect referenced media at the repository boundary; treat a missing index alongside media as a recovery condition.
- Reject stale seeks and late artwork results; derive indexes off the main actor.
- Restore queue ordering, register artwork by track ID, handle audio interruptions and clean up observers.
- Expand portable regression tests and establish permanent development rules.
- Native device testing remains outstanding.

## 0.1.1 — Development foundation
- Split the previously compiled 0.1.0 Swift source into model, playback and view files.
- Preserve bundle identifier, audio engine, library storage format and icon.
- Add portable model tests, automatic CI, versioned unsigned IPA artifacts and optional GitHub prereleases.
- Display version and build from the actual app bundle.

## 0.1.0
- First successful GitHub cloud compilation of the native starter.
- Device installation, full PWA parity, extended decoding and gapless playback remain unverified or incomplete.
