import { ServiceError } from '../errors.js';
import type { PracticeReply, PracticeRequest, TokenRequest, TutorReply, TutorRequest } from '../schemas.js';
import type { TutorProvider } from './provider.js';

/** Explicit deterministic transport fixture. This never claims live assessment. */
export class DemoProvider implements TutorProvider {
  async token(_request: TokenRequest, _signal: AbortSignal): Promise<never> {
    throw new ServiceError(409, 'demo_has_no_voice_connection', 'Demo cannot issue Live voice credentials.');
  }
  async tutor(r: TutorRequest, _signal: AbortSignal): Promise<TutorReply> {
    const ref = r.context.focus;
    return {requestID: r.requestID, runID: r.runID, stateRevision: r.stateRevision,
      intent: 'clarify', feedbackJa: 'Demo：応答はサンプルです。英文が述べていることと、そこから推測したことを分けて考えてみましょう。これは回答の採点ではありません。',
      sourceRefs: [{...ref, sentenceID: ref.sentenceID ?? null, rangeUTF16: ref.rangeUTF16 ?? null}],
      assessment: null, nextPromptJa: 'どの部分の意味が曖昧ですか？', generatedPractice: null};
  }
  async practice(r: PracticeRequest, _signal: AbortSignal): Promise<PracticeReply> {
    return {requestID: r.requestID, runID: r.runID, stateRevision: r.stateRevision,
      generatedPractice: {id: `practice:demo-${r.requestID}`, text: 'A careful review may reveal a risk without proving that a failure will occur.', language: 'en', label: 'generated_practice'},
      feedbackJa: 'Demo：生成練習文のサンプルです。原文ではありません。'};
  }
}
