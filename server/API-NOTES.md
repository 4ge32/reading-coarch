# Backend API evidence and operating constraints

Verified 2026-10-31 against OpenAI's official `openai/openai-node` repository,
HEAD `c717857c3151bde92e07e4d396301a9c67163e68`:

- `src/resources/realtime/client-secrets.ts`: `POST /v1/realtime/client_secrets`,
  session `type: realtime`, response `value` / `expires_at` / `session`.
- `src/resources/realtime/realtime.ts`: GA nested `audio.input` and `audio.output`,
  semantic VAD with `eagerness: low`, `create_response: false`,
  `interrupt_response: false`; no beta header. Both manual and automatic modes
  use VAD only to commit/transcribe chunks for voice controls and interruption.
  The native app accumulates manual chunks until explicit Send; silence never
  authorizes a tutor response or assessment.
- `src/resources/responses/responses.ts`: `POST /v1/responses`, structured output
  configured by `text.format` with `type: json_schema`, `strict: true`, `schema`.

The official documentation site `developers.openai.com` returned HTTP 403 from the
managed network. Official SDK source was the available first-party specification.
Model availability, provider account authorization, quotas, and Live behavior have
not been validated merely by reading those types.

Use Node 24 LTS, `npm ci`, `npm test`, `npm run build`, `npm start`. Supply
`APP_ACCESS_TOKEN` with at least 32 high-entropy characters. This is private-MVP
device authorization, not multi-user identity. `PROVIDER_MODE=live` is the default;
missing provider configuration causes an explicit 503, never Demo fallback.
`PROVIDER_MODE=demo` is deliberately selected and cannot issue voice credentials.

HTTP listens on loopback by default. Real devices require a reachable HTTPS URL,
using either the optional TLS certificate/key settings or a private TLS reverse
proxy. `LISTEN_PUBLIC=true` is an explicit acknowledgement for a proxy deployment,
not an instruction to deploy this server publicly. Trust proxy is disabled.

The backend is stateless regarding learning. It validates the submitted context,
UTF-16 boundaries, reply sources and echoed request/revision; the app must also
validate against its immutable local snapshot and current revision. It cannot
authenticate the provenance of arbitrary text supplied by the authorized device.
Transient in-memory idempotency entries last up to two minutes (45 seconds for
client secrets), are bounded to 512 entries, and disappear on restart. No article,
answer, header, credential, audio, or raw upstream error is logged or persisted.
The provider receives only the selected passages and bounded recent turns.

Session duration is a client-visible reminder/interruption policy, not a provider
billing cap. Credential expiry is checked from the provider response and never
hard-coded as its validity. Ephemeral secrets must remain only in device memory.
The app owns response gating, native source TTS, tool validation, and explicit
finish intent. Provider errors never update learning state.
