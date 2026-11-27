# Changelog

## 0.3.11 — Native music navigation
- Open Albums, Artists, Songs, Favorites and Settings directly from the system tab bar. Each music browser keeps its own navigation and search state.

## 0.3.10 — Large-library saves
- Validate track IDs and normalized media names in one pass. Reuse validated filenames for backup protection and skip ownership checks for protected media during cleanup.

## 0.3.9 — Playback failure recovery
- Detach terminally failed items, invalidate pending callbacks, and rebuild the selected track on explicit Play. Disable seeking in the player and remote controls until an item is available.

## 0.3.8 — Library, playback startup and validation
- Defer player and remote-command setup until playback. Preserve resume intent on duplicate interruption notifications.
- Resolve track IDs through the position index and reuse it for queue pruning. Avoid comparing the entire library to detect pending import changes.
- Verify managed filenames and SHA-256 before import rollback, reuse backup protection for the batch, and deduplicate against uppercase legacy digests.
- Keep the full player stacked at accessibility text sizes and announce the scrubber position as elapsed time.
- Scan search text in track order, eliminating a UUID lookup per candidate. Cancel superseded pull-request workflows and use the standard Intel macOS 26 runner with the pinned Xcode build.
- Export real library and player screenshots for both simulator families, creating the iPhone 15 Pro Max and fifth-generation 12.9-inch iPad Pro simulators when supported. Collect launch metrics in the test results and verify the accessible scrubber value.

## 0.3.7 — Correct retirement fixture isolation
- Fix a regression fixture that accidentally reintroduced the same track UUID and both retired filenames, making its four-warning assertion incorrect. Use an independent replacement track and verify exact diagnostics, not only their count.
- Add a separate regression test confirming that reintroduced current audio and artwork are protected from retirement. Production recovery, cleanup guards, and interface are unchanged.

## 0.3.6 — Verified recovery and conservative media reclamation
- Recovery inspection checks recorded audio and artwork SHA-256 digests, reports missing/damaged/unverified media separately, and blocks known-damaged restores. Restore verifies the exact candidate before replacement.
- New imports record the derived artwork checksum. Optional field remains compatible with existing schema 1/2 indexes. Reject malformed digests and artwork digests without artwork.
- Reclaim retired media only when the filename matches the app-generated track identity and the bytes match the recorded digest. Preserve unverified legacy or changed media with explicit diagnostics. No changes to playback or native glass presentation.
- Add host regression coverage for changed audio/artwork, unverified legacy recovery, unrelated filenames and modified files during reclamation.

## 0.3.5 — Stable native glass mini-player host
- Use one selected-tab safe-area mini-player host on iPhone and iPad, retaining native glass and system navigation without the tab accessory's unreliable touch activation. Automatic tab minimization and inline accessory mode are removed for now.
- Verify a single accessible player, 44-point minimum hit targets, actual open/close and mini-player pause/resume, shared state and reopening. Run iPad validation even if iPhone tests fail; IPA publication still requires both suites to succeed.

## 0.3.4 — Full-row playback interaction and diagnostics
- Make the entire track button label hit-testable, including trailing empty space on iPad. Preserve selection semantics, swipe/context actions and native glass hosts.
- Require trailing-row taps to select the track in both UI suites; capture accessibility hierarchy and alerts on failure. Log playback preparation outcomes without personal metadata and collect diagnostics on failed simulator runs without losing the original test exit code.

## 0.3.3 — iPad mini-player presentation
- Use a safe-area-aware native Liquid Glass mini-player on iPad independently of the top tab bar; retain the native adaptive accessory on iPhone.
- Strengthen cross-device UI regression tests: verify current-track selection, hit testing, accessible metadata and transport, and shared pause state. Do not remove or relax the failing test.

## 0.3.2 — Native Liquid Glass presentation
- Adopt typed system tabs, native tab-bar minimization and adaptive mini-player placement. Keep the accessory's system glass surface instead of duplicating it.
- Present Now Playing in a native sheet/navigation stack with Liquid Glass playback, favorite and mode controls, system slider, adaptive wide layout and accessible labels/states.
- Keep album artwork and content surfaces free of unnecessary glass effects. Add isolated Debug-only synthetic-library UI tests and real simulator screenshot attachments.

## 0.3.1 — Metadata and extensibility foundation
- Add a native tagged M4A import fixture and validate the actual device executable architecture and Mach-O platform before packaging.
- Add optional typed embedded album artist, composer, genre, release/recording dates, disc and track positions, and original filename.
- Read supported native ID3/iTunes tags, reject malformed positions, group albums by album artist and sort tracks by disc/track with stable fallback.
- Write schema 2 on mutation, read legacy and schema 1 without rewriting, preserve backup bytes, and refuse unknown newer backup schemas.
- Document long-term extensibility and native Liquid Glass requirements.

## 0.3.0 — Foundation hardening
- Add throttled import progress, cancellation with committed-batch retention, and a full diagnostic report behind concise alerts.
- Use the pinned Xcode toolchain for host tests, explicit simulator architecture and separate iPad launch validation.
- Add a 16-file non-silent PCM byte-preservation simulator benchmark and host snapshot-search measurement.
- Search immutable snapshots off the main actor with cancellation and revision checks; use typed categories and precomputed favorites.
- Reduce full-index updates with bounded adaptive import batches; remove duplicate track-array state and publish navigation availability only on change.
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
