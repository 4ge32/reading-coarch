# Verification

## Executed — 2026-10-31

Host: Debian 13, x86_64 Linux; Node 24.19.0. Swift checks use the official
Swift 6.1.2 Jammy image, pinned by digest in `scripts/check.sh`.

| Command / check | Result |
| --- | --- |
| `bash scripts/check.sh` | Passed: backend build, 32 backend tests, 31 ReadingCore tests, 7 extraction tests, 6 eval-harness tests, reproducible Safari bundle; the 9 HTTP adapter tests also pass via the appended overlay step |
| `cd server && npm run build && npm test && npm run smoke` | Passed: 32 tests; actual loopback HTTP health 200, unauthenticated token 401, authenticated Demo tutor 200; disconnect cancels upstream work |
| `node scripts/evals/run.mjs` | Produced review reports for all 18 supplied cases; **no Live model calls and no semantic quality passes** |
| Swift frontend parse of all `ios/**/*.swift` | Passed syntax parsing only; no Apple SDK type checking or linking |
| Project/workflow YAML, Package.resolved JSON, plist/entitlement parsing, shell syntax, `git diff --check` | Passed |
| Pinned Readability npm integrity / vendored hashes | Passed; unchanged upstream source and license retained |
| WebRTC 156.0.0 binary checksum and archive platforms | Passed checksum; archive declares iOS arm64 and arm64/x86_64 Simulator |
| XcodeGen 2.44.1 release download/hash | Verified pinned SHA-256; macOS generation remains unrun here |
| Frozen server reinstall and production dependency audit | Passed; 0 production vulnerabilities reported at verification time |

The 31 core tests execute source/UTF-16 validation, repeated sentence identity,
immutable snapshot decoding, mark history, revision/request/tool fencing,
superseded transcripts, separate exposure/evidence types, practice provenance,
explicit hold through repeated VAD stops, interleaved utterance gating, audio
arbitration, and separated timing. Backend tests exercise actual route validation
with controlled upstream responses; they do not call a paid provider.

The same Live HTTP adapter and its 9 XCTest cases additionally compile and pass
in a temporary Linux Swift package with only a FoundationNetworking import and
test-module rename. This checks the HTTP adapter, not native WebRTC, Keychain,
AVFoundation, or the iOS target. Reproduce with `scripts/test-live-client.sh`.
Those tests cover HTTPS configuration, authentication/quota/rate/timeout errors,
expired credentials, stale replies, invalid citations/UTF-16 ranges, and labeled
generated practice. Native XCTest and UI tests still require Xcode.

## Gates unavailable in the initial implementation — 2026-10-31

- Xcode build and Simulator: Linux host, no Xcode/Apple SDKs. CI is provided but
  has not been observed running.
- Physical iPhone, Safari share-sheet integration, native TTS/audio routing,
  signing/App Group provisioning, and marking latency: no device attached.
- Live OpenAI text/voice calls and tutor semantic quality: no provider account
  credentials configured for these checks. No Live quality pass is claimed.
- Public deployment, App Store submission, billing changes: outside task scope.

The checklist in `manual-test.md` defines the remaining device checks. Runnable
Demo fixtures and portable tests do not satisfy the Live or device gates.

## Initial implementation limits and next checks — 2026-10-31

- Draft code includes real HTTP/SDP/peer connection/data-channel and microphone
  paths. Their presence and syntax parsing do **not** prove working end-to-end
  Live voice. No silent Demo fallback is used.
- Provision your app/extension bundle IDs, signing team, and matching App Group;
  generate the project on macOS and run its `ReadingCoach` scheme and XCTest/UI
  targets. CI is configured but has not been observed executing.
- Configure a trusted device-reachable HTTPS backend, private high-entropy app
  access token, server-side provider key, and model IDs available to your account.
  Defaults are examples, not an assertion of model availability.
- Run both conversation modes, source-TTS/microphone exclusion, interruption,
  transcript correction, import retry, deletion, backgrounding, and performance
  checks on device. Review all Live tutor outputs against the supplied rubrics.
- Practice targets are labeled and answerable with separate transfer evidence.
  Demo provides sample feedback without claiming actual semantic assessment.
- Model-requested session finish requires visible user confirmation. Session
  timers and credential expiration are not hard provider billing caps.
- The backend keeps bounded transient idempotency entries in memory; restart
  clears them. Durable learning/source state belongs to the device.

No public deployment, billing change, or App Store submission was performed.

## CI investigation — 2026-11-01

The PR's `Check` run 41198399400 compiled the iOS targets, but failed during
Simulator testing. Four `AppStoreTests` ended in unexpected process exits;
the test retaining its `ModelContainer`, the other 20 unit tests, and the UI
test passed. The portable job passed. The failure does not establish a root
cause on its own. `ReadingStore` now retains its context's `ModelContainer`,
and a lifetime regression test exercises use after the factory returns. On
commit `bfeb76b5a2535094ee94e5279ee31611295860c6`, the push-triggered Check
run 41312804965 passed: all 26 iOS unit tests, including the formerly failing
tests and the new regression, and the UI test passed. The portable job also
passed. Later commits still require their own CI results. Device, signed
archive, and TestFlight remain separate gates.

## Initial cloud build / TestFlight preparation — 2026-10-31

Added a manual cloud workflow with pinned macOS/Xcode, unsigned validation by
default, optional signed archive, and explicit internal TestFlight upload. The
app now has a 1024×1024 RGB AppIcon, shared app/extension version settings,
configurable bundle/profile identifiers, and a UserDefaults required-reason
privacy manifest. YAML, plist/privacy/asset JSON, PNG dimensions/color type, and
shell syntax were checked on Linux. See `docs/testflight.md` for enrollment,
browser-based certificate preparation, secure GitHub settings, and installation.

`python3 -m unittest discover -s scripts/testflight -p 'test_*.py'` passed all 15
release-preparation tests. These exercise profile/team/bundle/group/certificate
and expiry checks, signed-entitlement and IPA-package validation, real OpenSSL
CSR/P12 round trips, overwrite refusal, wrong-certificate rejection, and redacted
failure diagnostics. Test certificates are local self-signed fixtures; they do
not establish successful Apple signing or macOS Keychain import.

At that time enrollment and Apple signing/upload credentials were unavailable,
and GitHub API access was denied. The user has since confirmed enrollment;
subsequent CI observations are recorded above. A signed archive and TestFlight
upload were unverified at that time. No signing secrets were requested in chat or
added to that execution environment.

## Signed iPhone archive — 2026-11-03

[Workflow run 41646181459](https://github.com/4ge32/reading-coarch/actions/runs/41646181459)
on `main` commit `5ee03016bc825adacd5b97aa50cf4db9c2a17756` passed the unsigned
iPhone Simulator tests, then archived and exported a signed IPA. The workflow
validated the main app and share extension identifiers, App Group, embedded
profiles, signing certificate, signed entitlements and package contents. The
signed IPA was retained as a GitHub Actions artifact with a three-day expiry.

The upload step was deliberately skipped. App Store Connect processing, internal
TestFlight installation, physical-device behavior, and Live API calls remain
unverified. This result is not an App Store submission or public release.

## First TestFlight upload attempt — 2026-11-03

[Workflow run 41652754280](https://github.com/4ge32/reading-coarch/actions/runs/41652754280)
passed Simulator tests, archived and validated a signed IPA, and attempted an
internal TestFlight upload. Apple rejected it with error 90474 because the exported
app advertised iPad support without all required iPad orientations. Inspection of
the archived IPA found `UIDeviceFamily` `[1, 2]` in both app and share extension,
despite the project-level iPhone-only setting.

The project now explicitly sets the device family on both targets, overriding the
XcodeGen target preset. IPA validation rejects an app or share extension that is
not iPhone-only. A successful upload, processing, and iPhone installation have not
yet been observed.
