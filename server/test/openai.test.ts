import { describe, expect, it, vi } from 'vitest';
import { OpenAIProvider, type Fetcher } from '../src/services/openai.js';
import { config, reply, request } from './fixtures.js';
import { tutorRequestSchema } from '../src/schemas.js';

function response(body: unknown, status = 200) {return {ok:status >= 200 && status < 300,status,text:async () => JSON.stringify(body)};}
function modelResponse(value: unknown) {return response({status:'completed',output:[{type:'message',content:[{type:'output_text',text:JSON.stringify(value)}]}]});}
const tokenRequest = {requestID:'token-1',runID:request.runID,stateRevision:request.stateRevision,context:request.context,turnMode:'manual' as const};

describe('OpenAI GA adapter with deterministic upstream transport', () => {
  it('issues short-lived client secrets with manual response gating and no beta header', async () => {
    const fetcher = vi.fn<Fetcher>(async () => response({value:'ephemeral-only',expires_at:Math.floor(Date.now()/1000)+60,session:{type:'realtime'}}));
    const p = new OpenAIProvider(config,fetcher);
    const token = await p.token(tokenRequest,new AbortController().signal);
    expect(token.value).toBe('ephemeral-only');
    const [url, options] = fetcher.mock.calls[0]!;
    expect(url).toBe('https://api.openai.com/v1/realtime/client_secrets');
    expect(options.headers).not.toHaveProperty('OpenAI-Beta');
    const body = JSON.parse(options.body);
    expect(body.session.type).toBe('realtime');
    expect(body.session.audio.input.turn_detection).toEqual({type:'semantic_vad',eagerness:'low',create_response:false,interrupt_response:false});
    expect(body.session.tools.map((t: {name:string}) => t.name)).toContain('play_source');
    expect(body.session.tools.every((t:{parameters:{required:string[]}}) => t.parameters.required.includes('stateRevision'))).toBe(true);
  });
  it('automatic mode VAD never autonomously creates a response or bypasses the transcript gate', async () => {
    const fetcher = vi.fn<Fetcher>(async () => response({value:'ephemeral',expires_at:Math.floor(Date.now()/1000)+60}));
    await new OpenAIProvider(config,fetcher).token({...tokenRequest,turnMode:'automatic'},new AbortController().signal);
    expect(JSON.parse(fetcher.mock.calls[0]![1].body).session.audio.input.turn_detection)
      .toEqual({type:'semantic_vad',eagerness:'low',create_response:false,interrupt_response:false});
  });
  it('rejects expired or unsupported credential responses', async () => {
    for (const body of [{value:'expired',expires_at:1},{client_secret:{value:'legacy',expires_at:9999999999}}]) {
      const p = new OpenAIProvider(config,async () => response(body));
      await expect(p.token(tokenRequest,new AbortController().signal)).rejects.toMatchObject({code:'invalid_upstream_response'});
    }
  });
  it('uses Responses structured output and validates the envelope and sources', async () => {
    const fetcher = vi.fn<Fetcher>(async () => modelResponse(reply()));
    const p = new OpenAIProvider(config,fetcher); expect(await p.tutor(request,new AbortController().signal)).toEqual(reply());
    const [url,options] = fetcher.mock.calls[0]!; const body = JSON.parse(options.body);
    expect(url).toBe('https://api.openai.com/v1/responses'); expect(body.store).toBe(false);
    expect(body.text.format.type).toBe('json_schema'); expect(body.text.format.strict).toBe(true);
    expect(body).not.toHaveProperty('tools');
    expect(body.instructions).toContain('UNTRUSTED');
  });
  it('treats model refusal, truncation, wrong revision and forged refs as errors without a fallback', async () => {
    const forged = reply(); forged.sourceRefs[0]!.articleID = 'unrelated';
    for (const model of [
      response({status:'completed',output:[{type:'message',content:[{type:'refusal',refusal:'Cannot answer'}]}]}),
      response({status:'incomplete',output:[]}),
      modelResponse({...reply(),stateRevision:99}),
      modelResponse(forged),
    ]) {
      const p = new OpenAIProvider(config,async () => model);
      await expect(p.tutor(request,new AbortController().signal)).rejects.toHaveProperty('status');
    }
  });
  it.each([[401,'upstream_authentication_failed'],[403,'upstream_authentication_failed'],[404,'model_unavailable'],[429,'upstream_rate_limited'],[500,'upstream_error']])('maps upstream status %i without exposing body', async (status,code) => {
    const p = new OpenAIProvider(config,async () => response({private_key:'secret',article:'private source'},status as number));
    await expect(p.tutor(request,new AbortController().signal)).rejects.toMatchObject({code});
  });
  it('distinguishes missing credentials/models and network failures', async () => {
    const missing = new OpenAIProvider({...config,OPENAI_API_KEY:''},async () => modelResponse(reply()));
    await expect(missing.tutor(request,new AbortController().signal)).rejects.toMatchObject({code:'not_configured'});
    const failing = new OpenAIProvider(config,async () => {throw new Error('secret network details');});
    await expect(failing.tutor(request,new AbortController().signal)).rejects.toMatchObject({code:'upstream_unavailable'});
  });
  it('distinguishes account quota exhaustion from ordinary rate limiting', async () => {
    for (const error of [{code:'insufficient_quota'},{code:'billing_hard_limit_reached'},{type:'insufficient_quota',code:null}]) {
      const p = new OpenAIProvider(config,async () => response({error:{...error,message:'Private account details'}},429));
      await expect(p.tutor(request,new AbortController().signal)).rejects.toMatchObject({status:402,code:'upstream_quota_exceeded'});
    }
  });
  it('labels new practice, isolates its ID namespace, and rejects source reuse', async () => {
    const content = {generatedPractice:{text:'A review may help without guaranteeing success.',language:'en',label:'generated_practice'},feedbackJa:'練習文です。'};
    const fetcher = vi.fn<Fetcher>(async () => modelResponse(content));
    const p = new OpenAIProvider(config,fetcher);
    const practiceRequest = {requestID:request.requestID,runID:request.runID,stateRevision:request.stateRevision,context:request.context,bottleneck:'logicalRelation' as const};
    const generated = await p.practice(practiceRequest,new AbortController().signal);
    expect(generated.generatedPractice.id).toMatch(/^practice:/);
    content.generatedPractice.text = request.context.passages[0]!.text;
    await expect(p.practice(practiceRequest,new AbortController().signal)).rejects.toMatchObject({code:'invalid_upstream_response'});
  });
  it('targets generated practice explicitly while preserving original source references', async () => {
    const r = tutorRequestSchema.parse({...request,task:'assess',practice:{id:'practice:example',text:'A decision can be useful without being final.',label:'generated_practice'}});
    const assessed = {...reply(),intent:'assess',assessment:{outcome:'meaningMatched',matchedPoints:['Meaning matched'],missedPoints:[],bottleneck:'unknown'}};
    const fetcher = vi.fn<Fetcher>(async () => modelResponse(assessed));
    const result = await new OpenAIProvider(config,fetcher).tutor(r,new AbortController().signal);
    expect(result.assessment?.outcome).toBe('meaningMatched');
    const body = JSON.parse(fetcher.mock.calls[0]![1].body);
    const sent = JSON.parse(body.input[0].content[0].text);
    expect(sent.practice.label).toBe('generated_practice');
    expect(body.instructions).toContain('against practice.text');
    expect(result.sourceRefs[0]?.articleID).toBe(request.context.focus.articleID);
  });
});
