# Changelog

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
