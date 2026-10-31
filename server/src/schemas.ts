import { z } from 'zod';

const id = z.string().min(1).max(128);
const range = z.strictObject({ location: z.number().int().min(0), length: z.number().int().min(1) });
export const sourceRefSchema = z.strictObject({
  articleID: id, snapshotID: id, blockID: id,
  sentenceID: id.nullish(), rangeUTF16: range.nullish(),
});
export type SourceRef = z.infer<typeof sourceRefSchema>;

export function refKey(ref: SourceRef): string {
  return JSON.stringify([ref.articleID, ref.snapshotID, ref.blockID, ref.sentenceID ?? null,
    ref.rangeUTF16?.location ?? null, ref.rangeUTF16?.length ?? null]);
}
function safeSlice(text: string, r: { location: number; length: number }): string | undefined {
  const end = r.location + r.length;
  if (!Number.isSafeInteger(end) || end > text.length) return undefined;
  const splitsPair = (index: number) => index > 0 && index < text.length &&
    text.charCodeAt(index - 1) >= 0xd800 && text.charCodeAt(index - 1) <= 0xdbff &&
    text.charCodeAt(index) >= 0xdc00 && text.charCodeAt(index) <= 0xdfff;
  if (splitsPair(r.location) || splitsPair(end)) return undefined;
  return text.slice(r.location, end);
}
export const contextSchema = z.strictObject({
  title: z.string().max(500),
  focus: sourceRefSchema,
  passages: z.array(z.strictObject({
    sourceRef: sourceRefSchema,
    blockText: z.string().min(1).max(24000),
    text: z.string().min(1).max(12000),
  })).min(1).max(12),
  explanationSeen: z.boolean(), hintSeen: z.boolean(),
  inputModality: z.enum(['text', 'voice']),
  presentation: z.enum(['reading', 'listening', 'both']),
  recentTurns: z.array(z.strictObject({role: z.enum(['user', 'assistant']), text: z.string().max(2000)})).max(8).default([]),
}).superRefine((context, ctx) => {
  const keys = new Set<string>();
  if (context.passages.reduce((sum, p) => sum + p.blockText.length, 0) > 48000) {
    ctx.addIssue({code: 'custom', message: 'Context too large'});
  }
  for (const [index, p] of context.passages.entries()) {
    if (p.sourceRef.articleID !== context.focus.articleID || p.sourceRef.snapshotID !== context.focus.snapshotID) {
      ctx.addIssue({code: 'custom', path: ['passages', index], message: 'Mixed source snapshots'});
    }
    const text = p.sourceRef.rangeUTF16 ? safeSlice(p.blockText, p.sourceRef.rangeUTF16) : p.blockText;
    if (text !== p.text) ctx.addIssue({code: 'custom', path: ['passages', index], message: 'Source range mismatch'});
    const key = refKey(p.sourceRef);
    if (keys.has(key)) ctx.addIssue({code: 'custom', path: ['passages', index], message: 'Duplicate source reference'});
    keys.add(key);
  }
  if (!keys.has(refKey(context.focus))) ctx.addIssue({code: 'custom', message: 'Focus not in source context'});
});
const envelope = {requestID: id, runID: id, stateRevision: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER)};
export const practiceAnswerTargetSchema = z.strictObject({
  id: z.string().min(10).max(160).startsWith('practice:'),
  text: z.string().min(1).max(2000),
  label: z.literal('generated_practice'),
  language: z.literal('en').default('en'),
});
export const tutorRequestSchema = z.strictObject({
  ...envelope, context: contextSchema, learnerTurn: z.string().min(1).max(8000),
  task: z.enum(['tutor', 'explain', 'assess', 'read_aloud']),
  practice: practiceAnswerTargetSchema.optional(),
}).superRefine((request, ctx) => {
  if (!request.practice) return;
  if (request.task !== 'assess') ctx.addIssue({code:'custom',path:['practice'],message:'Practice target requires assessment task'});
  if (request.context.passages.some(p => p.text === request.practice?.text)) {
    ctx.addIssue({code:'custom',path:['practice'],message:'Practice text must be separate from source'});
  }
});
export const tokenRequestSchema = z.strictObject({
  ...envelope, context: contextSchema, turnMode: z.enum(['manual', 'automatic']),
});
export const practiceRequestSchema = z.strictObject({
  ...envelope, context: contextSchema,
  bottleneck: z.enum(['vocabulary', 'syntax', 'reference', 'logicalRelation', 'context', 'unknown']),
});
const wireSourceRef = z.strictObject({
  articleID: id, snapshotID: id, blockID: id,
  sentenceID: id.nullable(), rangeUTF16: range.nullable(),
});
export const generatedPracticeSchema = z.strictObject({
  text: z.string().min(1).max(2000), language: z.literal('en'), label: z.literal('generated_practice'),
});
export const tutorReplySchema = z.strictObject({
  ...envelope,
  intent: z.enum(['clarify', 'explain', 'assess', 'practice', 'navigate', 'pause']),
  feedbackJa: z.string().min(1).max(8000),
  sourceRefs: z.array(wireSourceRef).max(12),
  assessment: z.strictObject({
    outcome: z.enum(['meaningMatched', 'partiallyMatched', 'meaningMismatch', 'uncertain']),
    matchedPoints: z.array(z.string().max(1000)).max(12),
    missedPoints: z.array(z.string().max(1000)).max(12),
    bottleneck: z.enum(['vocabulary', 'syntax', 'reference', 'logicalRelation', 'context', 'unknown']),
  }).nullable(),
  nextPromptJa: z.string().max(2000).nullable(),
  generatedPractice: generatedPracticeSchema.nullable(),
});
export const practiceContentSchema = z.strictObject({
  generatedPractice: generatedPracticeSchema,
  feedbackJa: z.string().min(1).max(2000),
});
export const clientSecretSchema = z.object({value: z.string().min(1), expires_at: z.number().int().positive()});
export type TutorRequest = z.infer<typeof tutorRequestSchema>;
export type TokenRequest = z.infer<typeof tokenRequestSchema>;
export type PracticeRequest = z.infer<typeof practiceRequestSchema>;
export type TutorReply = z.infer<typeof tutorReplySchema>;
export type PracticeReply = z.infer<typeof practiceContentSchema> & {
  requestID: string; runID: string; stateRevision: number;
  generatedPractice: z.infer<typeof generatedPracticeSchema> & {id: string};
};
export type TokenReply = {value: string; expiresAt: number; model: string; sessionDurationSeconds: number};

export function validateTutorReply(reply: unknown, request: TutorRequest): TutorReply {
  const parsed = tutorReplySchema.parse(reply);
  if (parsed.requestID !== request.requestID || parsed.runID !== request.runID || parsed.stateRevision !== request.stateRevision) {
    throw new Error('Reply envelope mismatch');
  }
  const allowed = new Set(request.context.passages.map(p => refKey(p.sourceRef)));
  if (parsed.sourceRefs.some(ref => !allowed.has(refKey(ref)))) throw new Error('Reply cites unknown source');
  if (parsed.generatedPractice && request.context.passages.some(p => p.text === parsed.generatedPractice?.text)) {
    throw new Error('Generated practice duplicates source');
  }
  // Explanations, oral repetition, and navigation are never assessments.
  if (parsed.assessment && (['explain', 'read_aloud'].includes(request.task) || parsed.intent !== 'assess')) {
    throw new Error('Assessment without assessment intent');
  }
  return parsed;
}
