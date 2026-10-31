import { createHash, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import type { ServerResponse } from 'node:http';
import Fastify from 'fastify';
import rateLimit from '@fastify/rate-limit';
import { z } from 'zod';
import type { Config } from './config.js';
import { ServiceError } from './errors.js';
import { practiceRequestSchema, tokenRequestSchema, tutorRequestSchema, validateTutorReply } from './schemas.js';
import { DemoProvider } from './services/demo.js';
import { OpenAIProvider } from './services/openai.js';
import type { TutorProvider } from './services/provider.js';

export interface AppOptions { provider?: TutorProvider; rateLimitMax?: number; tokenRateLimitMax?: number; maxConcurrent?: number }

export async function buildApp(config: Config, options: AppOptions = {}) {
  const tls = config.TLS_CERT_FILE && config.TLS_KEY_FILE ? {
    cert: readFileSync(config.TLS_CERT_FILE), key: readFileSync(config.TLS_KEY_FILE),
  } : undefined;
  const app = Fastify({logger: false, trustProxy: false,
    bodyLimit: 98304, requestTimeout: 40000, ...(tls ? {https: tls} : {})});
  const provider: TutorProvider = options.provider ?? (config.PROVIDER_MODE === 'demo' ? new DemoProvider() : new OpenAIProvider(config));
  await app.register(rateLimit, {max: options.rateLimitMax ?? 120, timeWindow: 60000, hook: 'onRequest'});
  const expectedDigest = createHash('sha256').update(config.APP_ACCESS_TOKEN).digest();
  let active = 0;
  const maxConcurrent = options.maxConcurrent ?? 4;
  const cache = new Map<string, {fingerprint: string; expiresAt: number; pending: Promise<unknown>}>();

  app.addHook('onRequest', async (request, reply) => {
    reply.header('Cache-Control', 'no-store');
    reply.header('X-Content-Type-Options', 'nosniff');
    if (request.routeOptions.url === '/health') return;
    const authorization = request.headers.authorization;
    const token = typeof authorization === 'string' && authorization.startsWith('Bearer ') ? authorization.slice(7) : '';
    const digest = createHash('sha256').update(token).digest();
    if (!token || !timingSafeEqual(digest, expectedDigest)) {
      reply.header('WWW-Authenticate', 'Bearer');
      throw new ServiceError(401, 'unauthorized', 'A valid device access token is required.');
    }
  });
  app.setErrorHandler((error, _request, reply) => {
    if (error instanceof ServiceError) return reply.status(error.status).send({error: {code: error.code, message: error.message}});
    if (error instanceof z.ZodError) return reply.status(400).send({error: {code: 'invalid_request', message: 'Request failed schema or source validation.'}});
    const status = typeof error === 'object' && error !== null && 'statusCode' in error && typeof error.statusCode === 'number' ? error.statusCode : 500;
    if (status === 429) return reply.status(429).send({error: {code: 'rate_limited', message: 'Request rate limit reached.'}});
    if (status === 413) return reply.status(413).send({error: {code: 'body_too_large', message: 'Request body exceeds limit.'}});
    if (status >= 400 && status < 500) return reply.status(status).send({error: {code: 'invalid_request', message: 'Invalid request.'}});
    // Never serialize upstream errors, request bodies, headers, article text, or keys.
    return reply.status(500).send({error: {code: 'internal_error', message: 'The request could not be completed.'}});
  });
  app.setNotFoundHandler((_request, reply) => reply.status(404).send({error: {code: 'not_found', message: 'Route not found.'}}));

  async function execute<T>(route: string, body: {requestID: string}, response: ServerResponse, operation: (signal: AbortSignal) => Promise<T>): Promise<T> {
    const now = Date.now();
    for (const [key, value] of cache) if (value.expiresAt <= now) cache.delete(key);
    const key = `${route}:${body.requestID}`;
    const fingerprint = createHash('sha256').update(JSON.stringify(body)).digest('hex');
    const entry = cache.get(key);
    if (entry) {
      if (entry.fingerprint !== fingerprint) throw new ServiceError(409, 'request_conflict', 'The request ID was already used with different content.');
      return await entry.pending as T;
    }
    if (active >= maxConcurrent || cache.size >= 512) throw new ServiceError(429, 'server_busy', 'Server concurrency limit reached; retry later.');
    active += 1;
    const controller = new AbortController();
    const disconnected = () => {if (!response.writableEnded) controller.abort();};
    response.once('close', disconnected);
    const timeout = setTimeout(() => controller.abort(), config.UPSTREAM_TIMEOUT_MS);
    const pending = Promise.race([
      Promise.resolve().then(() => operation(controller.signal)),
      new Promise<never>((_resolve, reject) => controller.signal.addEventListener('abort', () =>
        reject(new ServiceError(504, 'upstream_timeout', 'The upstream request timed out.')), {once: true})),
    ]).finally(() => {clearTimeout(timeout); response.removeListener('close', disconnected); active -= 1;});
    cache.set(key, {fingerprint, expiresAt: now + (route === 'token' ? 45000 : 120000), pending});
    try {
      const result = await pending;
      if (route === 'token' && typeof result === 'object' && result !== null && 'expiresAt' in result && typeof result.expiresAt === 'number') {
        const cached = cache.get(key);
        if (cached) cached.expiresAt = Math.min(cached.expiresAt, result.expiresAt * 1000 - 1000);
      }
      return result;
    }
    catch (error) { cache.delete(key); throw error; }
  }

  app.get('/health', {config: {rateLimit: false}}, async () => ({status: 'ok', mode: config.PROVIDER_MODE}));
  app.post('/v1/realtime/token', {config: {rateLimit: {max: options.tokenRateLimitMax ?? 6, timeWindow: 60000}}}, async (request, reply) => {
    const body = tokenRequestSchema.parse(request.body);
    return execute('token', body, reply.raw, signal => provider.token(body, signal));
  });
  app.post('/v1/tutor/turn', async (request, response) => {
    const body = tutorRequestSchema.parse(request.body);
    return execute('tutor', body, response.raw, async signal => {
      const reply = await provider.tutor(body, signal);
      try { return validateTutorReply(reply, body); }
      catch { throw new ServiceError(502, 'invalid_source_or_revision', 'Tutor output failed source or revision validation.'); }
    });
  });
  app.post('/v1/practice', async (request, reply) => {
    const body = practiceRequestSchema.parse(request.body);
    return execute('practice', body, reply.raw, signal => provider.practice(body, signal));
  });
  app.addHook('onClose', async () => {cache.clear(); await provider.close?.();});
  return app;
}
