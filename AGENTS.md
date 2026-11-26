# Aural development rules

- Preserve original audio bytes and native safe areas. No unrequested audio processing or hardcoded device viewport workarounds.
- The library repository is the sole index writer. Fail closed on unreadable data. Commit before deleting media; never automatically delete unknown files.
- Keep disk IO, metadata processing and artwork decoding away from the main actor. Keep UI state on the main actor.
- Separate real responsibilities; avoid duplicate implementations, dead patches, unnecessary abstractions and paid dependencies.
- Add regression tests for critical behavior. Run the macOS tests and CI build before merging. Never bypass failing validation.
- Update VERSION and CHANGELOG. Preserve bundle ID, storage migrations and original files.
- Do not commit personal music, secrets, signing keys or profiles. Releases are unsigned prereleases.
- Physical-device testing is mandatory before calling an audio or UI feature production-ready.

- Keep Xcode and XcodeGen versions explicit; CI actions use reviewed immutable commit SHAs. Upgrade deliberately, not accidentally.
- Require Swift 6 language mode and warnings-as-errors. Resolve compiler diagnostics at their root; never suppress diagnostics, weaken tests or add unchecked isolation to hide defects. Run the simulator integration/launch suite.
- Recovery must validate the backup, preserve the damaged index, refuse unsupported newer schemas and require user confirmation.
- Download XcodeGen only from the reviewed versioned release with a pinned SHA-256 checksum; do not rely on mutable Homebrew formula versions.

## Engineering acceptance principles
Cleanliness, organization, lightweight resource use, simplicity, stability, measured performance, smoothness, fluidity, snappiness, seamless transitions, consistency, original audio fidelity, data integrity, root-cause resolution, maintainability and verification apply to every change. Preserve clean responsibility boundaries, avoid unnecessary code and dependencies, and measure responsiveness, frame pacing and resource use before making performance claims. Never mask defects for a green build.
