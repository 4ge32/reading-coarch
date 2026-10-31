import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { requestFor, checkReply, reportMarkdown } from './run.mjs';

const fixture = JSON.parse(await readFile(new URL('../../evals/tutor_cases.json', import.meta.url)));
const replyFor = (request) => ({ requestID: request.requestID, runID: request.runID,
  stateRevision: request.stateRevision, intent: 'explain', feedbackJa: 'サンプル説明です。',
  sourceRefs: [request.context.focus], assessment: null, nextPromptJa: null, generatedPractice: null });

test('all 18 fixture cases adapt without fabricating missing source', () => {
  assert.equal(fixture.cases.length, 18);
  for (const c of fixture.cases) {
    const request = requestFor(c, 'test-run');
    assert.deepEqual(checkReply(request, replyFor(request)), []);
    assert.equal(request.context.passages.at(-1).text, c.source.text);
  }
  const lastSentence = requestFor(fixture.cases.find((c) => c.id === 'T08'));
  assert.equal(lastSentence.context.passages.length, 1);
});
test('target correction retains only explicitly supplied previous source', () => {
  const request = requestFor(fixture.cases.find((c) => c.id === 'T10'));
  assert.equal(request.context.passages.length, 2);
  assert.equal(request.context.passages[0].sourceRef.blockID, 'T01-block');
});
test('prior question and read-aloud task preserve evaluation intent', () => {
  const shortAnswer = fixture.cases.find((c) => c.id === 'T17');
  assert.deepEqual(requestFor(shortAnswer).context.recentTurns,
    [{ role: 'assistant', text: shortAnswer.context.question }]);
  assert.equal(requestFor(fixture.cases.find((c) => c.id === 'T13')).task, 'read_aloud');
});
test('rejects stale revisions, cross-snapshot refs and unlabeled generated text', () => {
  const request = requestFor(fixture.cases[0]);
  const reply = replyFor(request);
  reply.stateRevision = 99;
  reply.sourceRefs = [{ ...request.context.focus, snapshotID: 'forged' }];
  reply.generatedPractice = { text: 'Invented source.', label: 'source', language: 'en' };
  assert.deepEqual(checkReply(request, reply), ['stateRevision mismatch',
    'source reference outside supplied context', 'generated practice is not explicitly labeled']);
});
test('UTF16 offsets are part of source identity', () => {
  const request = requestFor(fixture.cases[0]);
  request.context.focus.rangeUTF16 = { location: 0, length: 10 };
  const reply = replyFor(request);
  reply.sourceRefs = [{ ...request.context.focus, rangeUTF16: { location: 1, length: 10 } }];
  assert.ok(checkReply(request, reply).includes('source reference outside supplied context'));
});
test('unrun cases and human semantics never become passing quality claims', () => {
  const report = reportMarkdown([{ caseID: 'T01', title: 'test', rubric: fixture.cases[0].expected,
    status: 'not_run', failures: [] }], { mode: 'rubric-only' });
  assert.match(report, /Envelope: not run/);
  assert.match(report, /PENDING/);
});
