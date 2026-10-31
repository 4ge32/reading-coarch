# ReadingCoach

An iPhone reading coach for deeper comprehension and faster reading, with tap-to-mark passages, voice tutoring, and read-aloud playback.

The v0.1 implementation is being developed in draft PR #1 on
`codex/reading-coach-v0-1`. The acceptance specification is [CODEX_TASK.md](CODEX_TASK.md).
Interface and tutor feedback are in Japanese; reading materials are English.

To install on an iPhone without a Mac, follow the
[cloud build and internal TestFlight guide](docs/testflight.md). It requires an
active paid Apple Developer membership and your own signing configuration.
The workflow defaults to unsigned Simulator validation; uploading requires an
explicit action. No build has been distributed yet.

## Demo on iPhone / Simulator

Requires macOS, Xcode 16.4 or later, and an iOS 17+ target. Project generation
downloads XcodeGen 2.44.1 and verifies its pinned SHA-256 before use.

```sh
bash scripts/generate-project.sh
open ios/ReadingCoach.xcodeproj
```

Select the `ReadingCoach` scheme and an iPhone Simulator. Demo needs no backend
or API key. It provides an original sample article, sentence marking, paste
import, local storage, source TTS, and fixture tutor responses. Demo is visibly
labeled; its responses do not demonstrate Live teaching or voice recognition.

For a device, configure your development team, unique app/extension bundle IDs,
and a shared App Group in `ios/project.yml`, regenerate, and enable the matching
capabilities for both targets. Both targets must use the same App Group.
The placeholder `group.com.example.ReadingCoach` is not a provisioned entitlement.
Run the app once, then enable ReadingCoach in Safari's share sheet. Confirm the
import preview in the app; a URL-only share is explicitly stored as missing body.
The extension does not bypass logins or paywalls, and the server does not fetch
arbitrary article URLs.

## Private Live backend

Requires Node **24.19.0** (pinned in `.node-version`). Run from `server/`:

```sh
npm ci
cp .env.example .env
# Edit .env locally; never commit credentials.
npm run build
npm start
```

Set a high-entropy `APP_ACCESS_TOKEN` (for example, generated with
`openssl rand -hex 32`), server-side `OPENAI_API_KEY`, and model IDs available to
your account. Default model names in `.env.example` are configurable examples;
availability and quota require an actual Live check. The app stores only the
private app access token in Keychain; the long-lived OpenAI key stays server-side.

`GET /health` is a minimal liveness check. Tutor, practice, and Realtime token
endpoints require the app access token. The backend defaults to loopback. A
physical iPhone cannot reach your computer's `localhost`: configure a trusted,
device-reachable **HTTPS** endpoint, using the server's TLS options or your
private TLS reverse proxy. Do not disable App Transport Security globally.
No public deployment is included.

In Settings, enter the HTTPS backend URL and app access token, acknowledge the
external-processing notice, then explicitly choose Live. Permit microphone access
when starting voice conversation. Articles, limited context, answers, and live
audio are sent to the configured services; the app/server do not save raw audio.
Provider retention terms still apply. Live failures are shown as errors and never
silently replaced with Demo responses. Foreground recording only: interruptions
and backgrounding stop audio; resuming requires user action.

## Validation

```sh
npm ci --prefix server
bash scripts/check.sh                 # Swift 6.1.2+ or the managed Docker daemon
# Or run just the portable Swift suite in the official container:
docker run --rm -v "$PWD:/workspace" -w /workspace \
  swift:6.1.2-jammy@sha256:5910655d205a5a54b0b9efdf72c4066a8de1932513fdc81793e2544b5d5a0709 \
  swift test --package-path packages/ReadingCore --jobs 4
```

The CI configuration also generates the Xcode project and runs Simulator tests.
Checked-in workflows are not evidence that CI has run. See
[verification](docs/verification.md) for executed checks and unavailable gates,
and [manual checks](docs/manual-test.md) for device acceptance.

The tutor evaluation harness consumes all 18 supplied cases:

```sh
node scripts/evals/run.mjs             # rubric report only; no model calls
# Live, against your private server (credentials supplied securely as env vars):
EVAL_SERVER_URL=https://your-private-server.example \
  EVAL_MODEL=your-configured-model EVAL_PROMPT_VERSION=readingcoach-tutor-v1 \
  node scripts/evals/run.mjs --live
```

Live evaluation also requires `APP_ACCESS_TOKEN` in the process environment.
Generated reports and raw replies stay in ignored `evals/results/`. Envelope and
source checks are deterministic; meaning-quality reviews remain explicitly
pending until a human reviews each rubric. Voice-control cases require state and
device tests instead of a text API call.

## Storage, measurement, and limits

The app uses SwiftData locally. Source snapshots are immutable, with stable
sentence IDs, content hashes, and block-relative UTF-16 references. Reimporting
creates a new snapshot without moving old marks. Native TTS resolves the stored
source, never a model reconstruction. Generated practice is labeled separately.

Settings provides deletion of local reading/learning data and of the Keychain
credential. Article deletion removes its snapshots and associated activity.
An import inbox job is acknowledged only after database persistence; corrupt jobs
are retained for explicit retry/removal.

Reading time is an estimate of foreground reader time, not eye tracking.
First-pass, rereading, tutoring, source listening, and pauses are tracked
separately. WPM is limited to explicitly completed reading runs. Word-count
method `unicode-letters-apostrophe-hyphen-v1` counts Unicode letter/number runs,
including internal straight or curly apostrophes and hyphens as one word; code
blocks are excluded. It does not
claim to measure all languages or actual comprehension.

No App Store distribution, background recording, cloud sync, notifications,
paywall bypass, PDF/EPUB import, or pronunciation scoring is provided.
See [decisions](docs/decisions.md), [API contract](docs/api-contract.md), and
[verification](docs/verification.md) for implementation boundaries and test gates.
