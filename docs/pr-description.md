# Implement ReadingCoach v0.1 reader, tutor backend, and native voice workflow

Implements the iPhone workflow from imported source to local sentence marks,
tutoring, stored-source playback, and reading resumption. The source/state core
keeps immutable snapshots, stable UTF-16 references, revision checks, separate
learning evidence, and explicit wait/navigation semantics.

Includes SwiftUI/SwiftData screens, Safari App Group import with pinned
Readability, native TTS, a native WebRTC GA Realtime adapter, authenticated private
Fastify endpoints, explicit Demo/Live modes, typed generated practice, tests,
reproducible project generation, and CI.

Validation: all 85 portable core, backend, import, evaluation harness, and HTTP
adapter tests pass; local HTTP/cancellation smoke tests pass. iOS source syntax parses.
See `docs/verification.md` for commands, counts, and exact boundaries.

Also prepares cloud iPhone builds and internal TestFlight delivery for a user
without a Mac: manual upload gating, separate app/extension signing profiles,
browser-terminal CSR/P12 helpers, AppIcon/privacy packaging, and 15 passing
release-preparation tests. Enrollment and signing/upload credentials remain
required; no signed archive or TestFlight upload has been run.

Keep this PR as a draft: Xcode build/Simulator, signing/App Groups, physical-device
audio/Safari integration, and Live provider calls and semantic review have not
been run in this Linux task. These gates are documented in `docs/manual-test.md`.
