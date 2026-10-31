# Implementation decisions

## Scope and environment — 2026-10-31

PR #1 continues `codex/reading-coach-v0-1` and the authoritative `CODEX_TASK.md`.
The local checkout originally contained only the initial README; the existing
draft branch contains the brief, repository instructions, and 18 tutor cases.
Implementation targets iOS 17, a persistence-independent Swift package, and a
private TypeScript backend on Node 24 LTS.

Work is divided into source/state core, local iPhone workflow, Safari import,
native Live transport, backend, and integration/verification. The milestones in
the brief remain acceptance gates; code presence alone does not pass device or
Live gates.

This task runs on Linux without Xcode or Apple SDKs. Portable Swift tests use an
official Swift 6.1.2 container. iOS build, Simulator, signing, device audio, and
Live-provider checks must be reported separately. No public deployment, billing
change, or App Store submission is part of this task.

## Source identity

The confirmed import is the source snapshot. Blocks and sentences receive IDs
once at import. Sentence ranges use block-relative UTF-16 offsets, with
validation before resolution. iOS uses NLTokenizer; the portable core accepts
the persisted segmentation instead of implementing a second tokenizer.
Reimport creates a new snapshot; marks are never guessed onto new text.

## Boundaries

SwiftData belongs to the app. The extension writes atomic inbox jobs into the
App Group and never updates the app database. Model output cannot mutate source
text or learning state directly. Local marks require no backend. Demo uses
explicit fixtures, and a failed Live call remains a visible error.

## External dependencies and documentation

Dependencies are pinned in manifests and lockfiles. OpenAI's documentation site
is denied by the environment policy; implementation checks current official
`openai/openai-node` resource definitions on GitHub instead. API details and
the inspected upstream revision are recorded in `api-contract.md`.
The community `stasel/WebRTC` binary is not an official OpenAI SDK; its release
artifact checksum and supported platforms are verified independently.

Both voice modes use VAD transcription with provider response generation disabled.
Manual mode accumulates chunks until Send; automatic mode waits for finalized
utterances and the app response gate. Silence does not release ThinkingHold.
Ending a session through a model tool requires visible user confirmation, since
the tool's assertion alone is not evidence of the learner's intent.

Generated practice has a separate `practice:` identity and answer path. It is
never fed to the source resolver as stored original text. Word counts and their
method version are saved when a reading run is explicitly completed; later
assisted or rereading activity cannot change that run's numerator or time.

## iPhone delivery without a Mac

The user chose paid Apple Developer enrollment and cloud builds/TestFlight.
Distribution is internal TestFlight only; it is not an App Store release.
The new manual workflow runs unsigned Simulator tests by default. Signed builds
and uploads are explicit inputs, with signing secrets confined to the GitHub
`testflight` environment and upload credentials confined to the upload step.

Manual Apple Distribution certificates/profiles are the documented baseline.
Browser-based Codespaces/OpenSSL scripts prepare the CSR and encrypted P12, so
certificate setup does not require a Mac. The app and Safari extension have
separate profiles but matching Team ID, App Group, version, and build number.
Identifiers and profile selectors are per-target build settings, avoiding a
global bundle-ID or profile override that would break the extension.

The runner is macOS 26 with explicit Xcode 26.6, checked against official
`actions/runner-images` revision `4da2307112a0fad2fd2ecaca8ba7d08683b8c581`.
Apple's current upload requirement page was blocked, so no claim of independently
verified submission eligibility is made. Actual native build/archive/upload
remain separate gates. An opaque AppIcon asset and the required-reason
UserDefaults privacy manifest are now included. Privacy declarations in
App Store Connect remain a separate step when configuring the app record.
