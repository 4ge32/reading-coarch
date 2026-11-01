import { readConfig } from '../src/config.js';
import { tutorRequestSchema, type TutorReply } from '../src/schemas.js';
export const accessToken = 'test-token-only-not-a-real-secret-01234567890123456789';
export const config = readConfig({APP_ACCESS_TOKEN: accessToken, PROVIDER_MODE: 'live',
  OPENAI_API_KEY: 'test-api-key-not-real', OPENAI_REALTIME_MODEL: 'test-realtime', OPENAI_TEXT_MODEL: 'test-text'});
export const source = {articleID: 'article-1', snapshotID: 'snapshot-1', blockID: 'block-1', sentenceID: 'sentence-1',
  rangeUTF16: {location: 0, length: 27}};
export const request = tutorRequestSchema.parse({requestID: 'request-1', runID: 'run-1', stateRevision: 4,
  learnerTurn: '内容を説明して。', task: 'explain', context: {
    title: 'Original sample', focus: source, passages: [{sourceRef: source, blockText: 'A test may pass. 🚀 Really.', text: 'A test may pass. 🚀 Really.'}],
    explanationSeen: false, hintSeen: false, inputModality: 'text', presentation: 'reading',
  }});
export function reply(): TutorReply {
  return {requestID: request.requestID, runID: request.runID, stateRevision: request.stateRevision,
    intent: 'explain', feedbackJa: 'テストが通る可能性があると述べています。', sourceRefs: [structuredClone(source)],
    assessment: null, nextPromptJa: null, generatedPractice: null};
}
