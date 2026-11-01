import { afterEach, describe, expect, it, vi } from 'vitest';
import { buildApp } from '../src/app.js';
import type { TutorProvider } from '../src/services/provider.js';
import { accessToken, config, reply, request } from './fixtures.js';

const apps: Awaited<ReturnType<typeof buildApp>>[] = [];
const headers = {authorization: `Bearer ${accessToken}`};
function provider(): TutorProvider {
  return {token: vi.fn(async () => ({value: 'ephemeral-test', expiresAt: Math.floor(Date.now()/1000) + 60, model: 'test-realtime', sessionDurationSeconds: 900})),
    tutor: vi.fn(async () => reply()), practice: vi.fn(async r => ({requestID:r.requestID,runID:r.runID,stateRevision:r.stateRevision,
      generatedPractice:{id:'practice-1',text:'A new generated example.',language:'en',label:'generated_practice'},feedbackJa:'練習文です。'}))};
}
async function app(p = provider(), options = {}) {const a = await buildApp(config, {provider:p, ...options}); apps.push(a); return a;}
afterEach(async () => {await Promise.all(apps.splice(0).map(a => a.close()));});

describe('authenticated private backend', () => {
  it('health reveals no credentials or model names; all paid routes require auth', async () => {
    const a = await app();
    expect((await a.inject('/health')).json()).toEqual({status:'ok',mode:'live'});
    for (const url of ['/v1/realtime/token','/v1/tutor/turn','/v1/practice']) {
      const r = await a.inject({method:'POST',url,payload:request}); expect(r.statusCode).toBe(401);
    }
  });
  it('rejects unauthorized and excessive token requests before provider work', async () => {
    const p = provider(); const a = await app(p,{tokenRateLimitMax:1});
    const payload = {requestID:request.requestID,runID:request.runID,stateRevision:request.stateRevision,context:request.context,turnMode:'manual'};
    expect((await a.inject({method:'POST',url:'/v1/realtime/token',headers,payload})).statusCode).toBe(200);
    expect((await a.inject({method:'POST',url:'/v1/realtime/token',headers,payload})).statusCode).toBe(429);
    expect(p.token).toHaveBeenCalledTimes(1);
  });
  it('validates context before invoking provider', async () => {
    const p = provider(); const a = await app(p);
    const malformed = structuredClone(request); malformed.context.passages[0]!.text = 'not source';
    const r = await a.inject({method:'POST',url:'/v1/tutor/turn',headers,payload:malformed});
    expect(r.statusCode).toBe(400); expect(p.tutor).not.toHaveBeenCalled();
  });
  it('deduplicates concurrent retries and refuses reusing IDs for another answer', async () => {
    const p = provider(); const a = await app(p);
    const results = await Promise.all([1,2].map(() => a.inject({method:'POST',url:'/v1/tutor/turn',headers,payload:request})));
    expect(results.map(r => r.statusCode)).toEqual([200,200]); expect(p.tutor).toHaveBeenCalledTimes(1);
    const conflict = await a.inject({method:'POST',url:'/v1/tutor/turn',headers,payload:{...request,learnerTurn:'another answer'}});
    expect(conflict.statusCode).toBe(409);
  });
  it('rejects delayed replies for the wrong revision and does not leak content', async () => {
    const p = provider(); p.tutor = vi.fn(async () => ({...reply(),stateRevision:3}));
    const a = await app(p); const r = await a.inject({method:'POST',url:'/v1/tutor/turn',headers,payload:request});
    expect(r.statusCode).toBe(502); expect(r.body).not.toContain(request.learnerTurn); expect(r.body).not.toContain(config.OPENAI_API_KEY);
  });
  it('bounds body size and suppresses raw unexpected error details', async () => {
    const p = provider(); p.tutor = vi.fn(async () => {throw new Error('private-article-content-and-secret');});
    const a = await app(p);
    const huge = await a.inject({method:'POST',url:'/v1/tutor/turn',headers,payload:{value:'x'.repeat(100000)}});
    expect(huge.statusCode).toBe(413);
    const error = await a.inject({method:'POST',url:'/v1/tutor/turn',headers,payload:request});
    expect(error.statusCode).toBe(500); expect(error.body).not.toContain('private-article');
  });
  it('aborts upstream on timeout, emits a useful error and allows retry', async () => {
    const p = provider(); let aborted = false;
    p.tutor = vi.fn((_r,signal) => new Promise((_resolve,reject) => signal.addEventListener('abort',() => {aborted=true;reject(new Error('cancelled'));})));
    const a = await buildApp({...config,UPSTREAM_TIMEOUT_MS:50},{provider:p}); apps.push(a);
    const r = await a.inject({method:'POST',url:'/v1/tutor/turn',headers,payload:request});
    expect(r.statusCode).toBe(504); expect(aborted).toBe(true);
    p.tutor = vi.fn(async () => reply());
    expect((await a.inject({method:'POST',url:'/v1/tutor/turn',headers,payload:request})).statusCode).toBe(200);
  });
  it('enforces concurrent request capacity', async () => {
    let finish: ((r: ReturnType<typeof reply>) => void) | undefined;
    const p = provider(); p.tutor = vi.fn(() => new Promise(resolve => {finish=resolve;}));
    const a = await app(p,{maxConcurrent:1});
    const first = a.inject({method:'POST',url:'/v1/tutor/turn',headers,payload:request});
    const waiting = Promise.resolve(first);
    await vi.waitFor(() => expect(p.tutor).toHaveBeenCalledTimes(1));
    const second = await a.inject({method:'POST',url:'/v1/tutor/turn',headers,payload:{...request,requestID:'request-2'}});
    expect(second.statusCode).toBe(429); finish!(reply()); expect((await waiting).statusCode).toBe(200);
  });
  it('Demo mode is explicit and cannot issue live credentials', async () => {
    const a = await buildApp({...config,PROVIDER_MODE:'demo'}); apps.push(a);
    const r = await a.inject({method:'POST',url:'/v1/tutor/turn',headers,payload:request});
    expect(r.json().feedbackJa).toContain('Demo'); expect(r.json().assessment).toBeNull();
    const token = await a.inject({method:'POST',url:'/v1/realtime/token',headers,payload:{requestID:'token',runID:request.runID,stateRevision:4,context:request.context,turnMode:'manual'}});
    expect(token.statusCode).toBe(409);
  });
});
