import { randomUUID } from 'node:crypto';
import { EnvHttpProxyAgent, fetch as undiciFetch } from 'undici';
import { z } from 'zod';
import type { Config } from '../config.js';
import { ServiceError } from '../errors.js';
import { voicePolicy, tutorPolicy } from '../prompts/tutor.js';
import {
  clientSecretSchema, practiceContentSchema, tutorReplySchema, validateTutorReply,
  type PracticeReply, type PracticeRequest, type TokenReply, type TokenRequest,
  type TutorReply, type TutorRequest,
} from '../schemas.js';
import type { TutorProvider } from './provider.js';

export type Fetcher = (url: string, options: {
  method: 'POST'; headers: Record<string, string>; body: string; signal: AbortSignal;
}) => Promise<{ok: boolean; status: number; text(): Promise<string>}>;

const toolRef = {
  type: 'object', additionalProperties: false,
  properties: {articleID: {type: 'string'}, snapshotID: {type: 'string'}, blockID: {type: 'string'},
    sentenceID: {type: ['string', 'null']}, rangeUTF16: {anyOf: [{type: 'null'}, {
      type: 'object', additionalProperties: false, properties: {location: {type: 'integer', minimum: 0}, length: {type: 'integer', minimum: 1}}, required: ['location', 'length'],
    }]}},
  required: ['articleID', 'snapshotID', 'blockID', 'sentenceID', 'rangeUTF16'],
};
function tool(name: string, description: string, properties: Record<string, unknown>) {
  return {type: 'function', name, description,
    parameters: {type: 'object', additionalProperties: false,
      properties: {runID: {type: 'string'}, stateRevision: {type: 'integer', minimum: 0}, ...properties},
      required: ['runID', 'stateRevision', ...Object.keys(properties)]}};
}
export const realtimeTools = [
  tool('get_source_context', 'Get saved original context; no URL access.', {sourceRef: toolRef}),
  tool('play_source', 'Read saved original using native TTS.', {sourceRef: toolRef}),
  tool('navigate', 'Move within the app-owned run; never mark understood.', {direction: {type: 'string', enum: ['next', 'previous', 'return_to_reader']}}),
  tool('mark_unclear', 'Locally mark a valid original sentence.', {sourceRef: toolRef}),
  tool('set_wait_mode', 'Set or explicitly release ThinkingHold.', {enabled: {type: 'boolean'}}),
  tool('request_assessment', 'Request shared text assessment for a confirmed meaning answer.', {sourceRef: toolRef, answer: {type: 'string'}}),
  tool('create_practice', 'Request a distinctly labelled generated example.', {sourceRef: toolRef, bottleneck: {type: 'string', enum: ['vocabulary', 'syntax', 'reference', 'logicalRelation', 'context', 'unknown']}}),
  tool('finish_session', 'Finish only with explicit learner intent; not proof of understanding.', {explicitUserIntent: {type: 'boolean', const: true}}),
];

export class OpenAIProvider implements TutorProvider {
  private readonly proxy: EnvHttpProxyAgent | undefined;
  private readonly fetcher: Fetcher;
  constructor(private readonly config: Config, fetcher?: Fetcher) {
    if (fetcher) this.fetcher = fetcher;
    else {
      this.proxy = new EnvHttpProxyAgent();
      this.fetcher = (url, options) => undiciFetch(url, {...options, dispatcher: this.proxy!});
    }
  }
  async close() { await this.proxy?.close(); }

  private async post(path: string, body: unknown, signal: AbortSignal): Promise<unknown> {
    if (!this.config.OPENAI_API_KEY) throw new ServiceError(503, 'not_configured', 'Live API credentials are not configured.');
    try {
      const response = await this.fetcher(`https://api.openai.com/v1/${path}`, {
        method: 'POST', headers: {'Authorization': `Bearer ${this.config.OPENAI_API_KEY}`, 'Content-Type': 'application/json'},
        body: JSON.stringify(body), signal,
      });
      if (!response.ok) {
        let upstreamCode = '';
        let upstreamType = '';
        try {
          const errorBody = await response.text();
          if (errorBody.length <= 16384) {
            const parsed = z.object({error:z.object({code:z.string().nullable().optional(),type:z.string().nullable().optional()})}).safeParse(JSON.parse(errorBody));
            if (parsed.success) {upstreamCode = parsed.data.error.code ?? ''; upstreamType = parsed.data.error.type ?? '';}
          }
        } catch { /* Error bodies are untrusted and never surfaced. */ }
        if ([401, 403].includes(response.status)) throw new ServiceError(502, 'upstream_authentication_failed', 'The upstream credential is invalid, expired, or unsupported.');
        if ([upstreamCode,upstreamType].some(value => ['insufficient_quota','billing_hard_limit_reached'].includes(value))) {
          throw new ServiceError(402, 'upstream_quota_exceeded', 'Upstream account quota is exhausted.');
        }
        if (response.status === 429) throw new ServiceError(429, 'upstream_rate_limited', 'Upstream rate or quota limit reached.');
        if (response.status === 404 || upstreamCode === 'model_not_found') throw new ServiceError(503, 'model_unavailable', 'Configured model or API endpoint is unavailable.');
        throw new ServiceError(502, 'upstream_error', 'The upstream API rejected the request.');
      }
      const text = await response.text();
      if (text.length > 262144) throw new ServiceError(502, 'invalid_upstream_response', 'The upstream response exceeded the limit.');
      return JSON.parse(text) as unknown;
    } catch (error) {
      if (error instanceof ServiceError) throw error;
      if (signal.aborted) throw new ServiceError(504, 'upstream_timeout', 'The upstream request was cancelled or timed out.');
      throw new ServiceError(502, 'upstream_unavailable', 'The upstream connection or response failed.');
    }
  }

  async token(request: TokenRequest, signal: AbortSignal): Promise<TokenReply> {
    const model = this.config.OPENAI_REALTIME_MODEL;
    if (!model) throw new ServiceError(503, 'not_configured', 'Realtime model is not configured.');
    const session = {
      type: 'realtime', model, output_modalities: ['audio'],
      instructions: `${voicePolicy}\nActive app envelope and untrusted context JSON:\n${JSON.stringify(request)}`,
      audio: {
        input: {transcription: {model: this.config.OPENAI_TRANSCRIPTION_MODEL},
          // Both modes transcribe chunks for voice controls and barge-in. The
          // native app gates generation; manual mode waits for explicit Send.
          turn_detection: {
            type: 'semantic_vad', eagerness: 'low', create_response: false, interrupt_response: false,
          }},
        output: {voice: 'marin'},
      },
      tools: realtimeTools, tool_choice: 'auto',
    };
    const value = await this.post('realtime/client_secrets', {expires_after: {anchor: 'created_at', seconds: 60}, session}, signal);
    const result = clientSecretSchema.safeParse(value);
    if (!result.success || result.data.expires_at * 1000 <= Date.now()) {
      throw new ServiceError(502, 'invalid_upstream_response', 'The upstream credential response is invalid or expired.');
    }
    return {value: result.data.value, expiresAt: result.data.expires_at, model,
      sessionDurationSeconds: this.config.SESSION_DURATION_SECONDS};
  }

  private async structured<T>(name: string, schema: z.ZodType<T>, data: unknown, signal: AbortSignal): Promise<T> {
    const model = this.config.OPENAI_TEXT_MODEL;
    if (!model) throw new ServiceError(503, 'not_configured', 'Text model is not configured.');
    const response = await this.post('responses', {
      model, store: false,
      instructions: tutorPolicy,
      input: [{role: 'user', content: [{type: 'input_text', text: JSON.stringify(data)}]}],
      text: {format: {type: 'json_schema', name, strict: true, schema: z.toJSONSchema(schema)}},
      max_output_tokens: 1800,
    }, signal);
    const envelope = z.object({status: z.literal('completed'),
      output: z.array(z.object({type: z.string(), content: z.array(z.object({
        type: z.string(), text: z.string().optional(),
      }).passthrough()).optional()}).passthrough())}).safeParse(response);
    if (!envelope.success) throw new ServiceError(502, 'invalid_upstream_response', 'Incomplete or invalid model response.');
    const content = envelope.data.output.flatMap(item => item.content ?? []);
    if (content.some(c => c.type === 'refusal')) throw new ServiceError(422, 'model_refusal', 'The model declined this request.');
    const output = content.filter(c => c.type === 'output_text').map(c => c.text ?? '').join('');
    try { return schema.parse(JSON.parse(output)); }
    catch { throw new ServiceError(502, 'invalid_upstream_response', 'Model output failed schema validation.'); }
  }

  async tutor(request: TutorRequest, signal: AbortSignal): Promise<TutorReply> {
    const reply = await this.structured('tutor_reply', tutorReplySchema, request, signal);
    try { return validateTutorReply(reply, request); }
    catch { throw new ServiceError(502, 'invalid_source_or_revision', 'Model output cited an invalid source or state revision.'); }
  }

  async practice(request: PracticeRequest, signal: AbortSignal): Promise<PracticeReply> {
    const content = await this.structured('practice_reply', practiceContentSchema, {
      ...request, instruction: 'Generate one new short English practice sentence for the given bottleneck, clearly distinct from every source passage. Explain briefly in Japanese. Do not assess the learner.',
    }, signal);
    if (request.context.passages.some(p => p.text === content.generatedPractice.text)) {
      throw new ServiceError(502, 'invalid_upstream_response', 'Generated practice duplicated source text.');
    }
    return {...content, requestID: request.requestID, runID: request.runID, stateRevision: request.stateRevision,
      generatedPractice: {...content.generatedPractice, id: `practice:${randomUUID()}`}};
  }
}
