import { z } from 'zod';

const envSchema = z.object({
  APP_ACCESS_TOKEN: z.string().min(32),
  PROVIDER_MODE: z.enum(['live', 'demo']).default('live'),
  OPENAI_API_KEY: z.string().optional(),
  OPENAI_REALTIME_MODEL: z.string().min(1).optional(),
  OPENAI_TEXT_MODEL: z.string().min(1).optional(),
  OPENAI_TRANSCRIPTION_MODEL: z.string().default('gpt-4o-mini-transcribe'),
  HOST: z.string().default('127.0.0.1'),
  PORT: z.coerce.number().int().min(1).max(65535).default(8787),
  SESSION_DURATION_SECONDS: z.coerce.number().int().min(60).max(3600).default(900),
  UPSTREAM_TIMEOUT_MS: z.coerce.number().int().min(50).max(120000).default(30000),
  TLS_CERT_FILE: z.string().optional(),
  TLS_KEY_FILE: z.string().optional(),
  LISTEN_PUBLIC: z.enum(['true', 'false']).default('false'),
});

export function readConfig(env: NodeJS.ProcessEnv = process.env) {
  const parsed = envSchema.safeParse(env);
  if (!parsed.success) throw new Error('Invalid server configuration; check required variable names in .env.example.');
  const c = parsed.data;
  if (Boolean(c.TLS_CERT_FILE) !== Boolean(c.TLS_KEY_FILE)) throw new Error('Both TLS_CERT_FILE and TLS_KEY_FILE are required.');
  if (!['127.0.0.1', '::1', 'localhost'].includes(c.HOST) && !c.TLS_CERT_FILE && c.LISTEN_PUBLIC !== 'true') {
    throw new Error('Non-loopback plaintext requires explicit LISTEN_PUBLIC=true behind a private TLS reverse proxy.');
  }
  return c;
}
export type Config = ReturnType<typeof readConfig>;
