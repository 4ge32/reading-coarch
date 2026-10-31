# API contract

Status: implementation in progress; concrete verification results are recorded in
`verification.md`. This file distinguishes inspected API definitions from Live
provider execution.

## Private backend

All `/v1/*` routes require `Authorization: Bearer <APP_ACCESS_TOKEN>` over HTTPS
for a remote device. `GET /health` exposes liveness only. Limits, upstream timeout,
and session duration are configured server-side; clients cannot select arbitrary
models or invoke arbitrary network URLs.

`POST /v1/tutor/turn` accepts request/run IDs, state revision, learner turn, task,
and bounded context: title, focus `SourceRef`, supplied passages (block text and
resolved text), exposure, input modality, and presentation. JSON schemas live in
`contracts/`. Returned IDs/revision and all citations are checked before state
changes. A schema-valid assessment still does not prove semantic accuracy.

`POST /v1/practice` labels generated practice explicitly. It never replaces or
becomes stored article text. `POST /v1/realtime/token` issues a short-lived
credential to an authenticated device; the regular provider key remains on the
server. Credentials are not logged or persisted by the app.

## OpenAI GA surface

The implementation uses Realtime GA, not beta headers, and Responses structured
outputs for text. Models are configurable via `OPENAI_REALTIME_MODEL`,
`OPENAI_TEXT_MODEL`, and `OPENAI_TRANSCRIPTION_MODEL`. Defaults are examples until
verified against an account. Source context is untrusted quoted data, never
permission to operate tools or export articles.

Inspected official `openai/openai-node` resource definitions on 2026-10-31:
`src/resources/realtime/client-secrets.ts`, `realtime.ts`, and
`src/resources/responses/responses.ts`. The official documentation website was
denied by the current network policy; no claim of a completed docs-site or Live
check is made.
Inspected upstream revision: `c717857c3151bde92e07e4d396301a9c67163e68`.
The backend evidence and operating limits are also recorded in
[`server/API-NOTES.md`](../server/API-NOTES.md).

The server calls `/v1/realtime/client_secrets`. The client exchanges SDP at
`/v1/realtime/calls` with the short-lived credential. A native peer connection
has an audio track and an `oai-events` data channel. Client-secret expiration
uses the returned timestamp, not a guessed lifetime.

Both modes use low-eagerness Semantic VAD to provide transcription and detect
interruptions. Automatic provider response creation is disabled; the app gates
response creation after final transcript/control handling. Manual submit is the
default and accumulates chunks until the explicit Send action.
`ThinkingHold` remains active through silence/VAD stop. Audio coordination treats
source TTS, tutor output, and microphone transmission as separate resources.

GA events include `response.output_audio_transcript.delta/done`,
`conversation.item.input_audio_transcription.completed`,
`response.function_call_arguments.done`, and WebRTC output audio buffer
started/stopped/clear. Stop/cancel handling must also keep unheard conversation
audio consistent. See device gates for unverified platform behavior.

## Third-party native WebRTC

`stasel/WebRTC` **156.0.0**, revision
`3cc466ea040e5dcd1344697bf211dc4c079d1a0c`.
The downloaded XCFramework SHA-256 matched its Package.swift declaration:
`43c2a6f7a650185bbc911d7605a979589671886e8fc0ac283f54fdf3f511dc46`.
The archive declares iOS arm64 device and arm64/x86_64 Simulator support.
It is a community distribution, not an official OpenAI SDK. Binary integrity
does not establish successful Xcode linkage, signing, microphone capture, or a
working Live session.
