# Aural development rules

- Preserve original audio bytes and native safe areas. No unrequested audio processing or hardcoded device viewport workarounds.
- The library repository is the sole index writer. Fail closed on unreadable data. Commit before deleting media; never automatically delete unknown files.
- Keep disk IO, metadata processing and artwork decoding away from the main actor. Keep UI state on the main actor.
- Separate real responsibilities; avoid duplicate implementations, dead patches, unnecessary abstractions and paid dependencies.
- Add regression tests for critical behavior. Run the macOS tests and CI build before merging. Never bypass failing validation.
- Update VERSION and CHANGELOG. Preserve bundle ID, storage migrations and original files.
- Do not commit personal music, secrets, signing keys or profiles. Releases are unsigned prereleases.
- Physical-device testing is mandatory before calling an audio or UI feature production-ready.
