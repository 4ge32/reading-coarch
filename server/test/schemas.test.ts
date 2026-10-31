import { describe, expect, it } from 'vitest';
import { tutorRequestSchema, validateTutorReply } from '../src/schemas.js';
import { reply, request } from './fixtures.js';

describe('immutable source and state validation', () => {
  it('accepts a Unicode source with block-local UTF-16 ranges', () => {
    expect(tutorRequestSchema.parse(request).context.passages[0]?.text).toBe('A test may pass. 🚀 Really.');
  });
  it.each([
    {location: 17, length: 1}, // half of the rocket surrogate pair
    {location: 18, length: 2}, // starts inside the surrogate pair
    {location: 0, length: 100},
    {location: -1, length: 2},
  ])('rejects invalid Unicode source range %o', rangeUTF16 => {
    const r = structuredClone(request);
    r.context.passages[0]!.sourceRef.rangeUTF16 = rangeUTF16;
    expect(tutorRequestSchema.safeParse(r).success).toBe(false);
  });
  it('rejects reconstructed source text, mixed snapshots and forged focus', () => {
    for (const edit of [
      (r: typeof request) => {r.context.passages[0]!.text = 'Model reconstruction';},
      (r: typeof request) => {r.context.passages[0]!.sourceRef.snapshotID = 'other';},
      (r: typeof request) => {r.context.focus.sentenceID = 'not-in-context';},
    ]) {
      const r = structuredClone(request); edit(r);
      expect(tutorRequestSchema.safeParse(r).success).toBe(false);
    }
  });
  it('rejects stale output, unknown source, generated source and false assessment', () => {
    for (const edit of [
      (r: ReturnType<typeof reply>) => {r.stateRevision += 1;},
      (r: ReturnType<typeof reply>) => {r.sourceRefs[0]!.snapshotID = 'forged';},
      (r: ReturnType<typeof reply>) => {r.generatedPractice = {text: request.context.passages[0]!.text, language: 'en', label: 'generated_practice'};},
      (r: ReturnType<typeof reply>) => {r.assessment = {outcome: 'meaningMatched', matchedPoints: [], missedPoints: [], bottleneck: 'unknown'};},
    ]) {const r = reply(); edit(r); expect(() => validateTutorReply(r, request)).toThrow();}
  });
  it('rejects unknown model and URL/tool arguments on the request', () => {
    expect(tutorRequestSchema.safeParse({...request, model: 'unapproved', url: 'https://attacker.invalid'}).success).toBe(false);
  });
  it('keeps practice answers in their own namespace and cannot masquerade as source', () => {
    const practice = {id:'practice:one',text:'A new decision may be useful.',label:'generated_practice'};
    expect(tutorRequestSchema.safeParse({...request,task:'assess',practice}).success).toBe(true);
    expect(tutorRequestSchema.safeParse({...request,task:'assess',practice:{...practice,id:'sentence-1'}}).success).toBe(false);
    expect(tutorRequestSchema.safeParse({...request,task:'assess',practice:{...practice,text:request.context.passages[0]!.text}}).success).toBe(false);
    expect(tutorRequestSchema.safeParse({...request,practice}).success).toBe(false);
  });
});
