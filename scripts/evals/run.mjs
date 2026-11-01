import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const refFor = (source) => Object.fromEntries(
  ['articleID', 'snapshotID', 'blockID', 'sentenceID', 'rangeUTF16']
    .filter((key) => source[key] !== undefined).map((key) => [key, source[key]])
);
const sameRef = (a, b) => ['articleID', 'snapshotID', 'blockID', 'sentenceID']
  .every((key) => a?.[key] === b?.[key])
  && a?.rangeUTF16?.location === b?.rangeUTF16?.location
  && a?.rangeUTF16?.length === b?.rangeUTF16?.length;

export function requestFor(testCase, runID = randomUUID()) {
  const sourceRef = refFor(testCase.source);
  const passages = [{ sourceRef, blockText: testCase.source.text, text: testCase.source.text }];
  if (testCase.context?.previousSourceRef && testCase.context?.previousSourceText) {
    passages.unshift({ sourceRef: testCase.context.previousSourceRef,
      blockText: testCase.context.previousSourceText, text: testCase.context.previousSourceText });
  }
  // The endpoint receives only provided source passages. A missing next sentence
  // or an unavailable antecedent must never be fabricated by the harness.
  return {
    requestID: `eval-${testCase.id}-${runID}`, runID, stateRevision: 0,
    learnerTurn: testCase.learnerTurn,
    task: testCase.context?.task === 'read_aloud' ? 'read_aloud' : testCase.expected.assessment ? 'assess' : 'tutor',
    context: {
      title: `自作評価教材 ${testCase.id}`, focus: sourceRef, passages,
      explanationSeen: Boolean(testCase.context?.earlierExplanationSeen || testCase.context?.explanationSeen),
      hintSeen: false, inputModality: testCase.mode === 'voice' ? 'voice' : 'text',
      presentation: testCase.context?.task === 'read_aloud' ? 'listening' : 'reading',
      recentTurns: testCase.context?.question ? [{ role: 'assistant', text: testCase.context.question }] : [],
    },
  };
}

export function checkReply(request, reply) {
  const failures = [];
  if (!reply || typeof reply !== 'object') return ['reply is not an object'];
  for (const key of ['requestID', 'runID', 'stateRevision']) {
    if (reply[key] !== request[key]) failures.push(`${key} mismatch`);
  }
  if (!['clarify', 'explain', 'assess', 'practice', 'navigate', 'pause'].includes(reply.intent)) {
    failures.push('invalid intent');
  }
  if (typeof reply.feedbackJa !== 'string' || !reply.feedbackJa.trim()) failures.push('missing feedbackJa');
  if (!Array.isArray(reply.sourceRefs)) failures.push('missing sourceRefs');
  else if (!reply.sourceRefs.every((ref) => request.context.passages.some((p) => sameRef(p.sourceRef, ref)))) {
    failures.push('source reference outside supplied context');
  }
  if (reply.generatedPractice != null && (reply.generatedPractice.label !== 'generated_practice'
    || typeof reply.generatedPractice.text !== 'string' || reply.generatedPractice.language !== 'en')) {
    failures.push('generated practice is not explicitly labeled');
  }
  if (reply.assessment != null && !['meaningMatched', 'partiallyMatched', 'meaningMismatch', 'uncertain']
    .includes(reply.assessment.outcome)) failures.push('invalid assessment outcome');
  return failures;
}

export function reportMarkdown(records, metadata) {
  return ['# Tutor evaluation review', '',
    `Run: ${metadata.startedAt}. Mode: ${metadata.mode}. Model (operator supplied): ${metadata.model}.`,
    `Prompt: ${metadata.promptVersion}. Fixture schema: ${metadata.fixtureSchemaVersion}.`, '',
    'Deterministic envelope checks do not grade teaching quality or prove app-state transitions.',
    'Each executed response still requires a human semantic review against its rubric.',
    'Voice-control event cases require the core/device tests and are not sent to the text endpoint.', '',
    ...records.flatMap((r) => [`## ${r.caseID}: ${r.title}`, '',
      `Execution: ${r.status}. Envelope: ${r.failures?.length ? 'FAIL' : r.reply ? 'PASS' : 'not run'}.`,
      ...(r.failures ?? []).map((failure) => `- ${failure}`), '',
      'Required meaning:', ...(r.rubric.must ?? []).map((item) => `- ${item}`), '',
      'Prohibited behavior:', ...(r.rubric.mustNot ?? []).map((item) => `- ${item}`), '',
      `Expected state/evidence (separate app test): ${r.rubric.state ?? 'see case context'}.`,
      `Expected assessment: ${r.rubric.assessment ?? 'not specified'}.`, '',
      'Human semantic review: **PENDING**', '',
      ...(r.reply ? ['Response:', '', '```json', JSON.stringify(r.reply, null, 2), '```', ''] : []),
    ]),
  ].join('\n');
}

async function main() {
  const args = process.argv.slice(2);
  const live = args.includes('--live');
  if (args.some((arg) => arg !== '--live')) throw new Error('Usage: node scripts/evals/run.mjs [--live]');
  const fixture = JSON.parse(await readFile(resolve(root, 'evals/tutor_cases.json'), 'utf8'));
  const metadata = { startedAt: new Date().toISOString(), mode: live ? 'live' : 'rubric-only',
    model: process.env.EVAL_MODEL ?? 'not recorded', promptVersion: process.env.EVAL_PROMPT_VERSION ?? 'not recorded',
    fixtureSchemaVersion: fixture.schemaVersion };
  let endpoint;
  if (live) {
    if (!process.env.APP_ACCESS_TOKEN || !process.env.EVAL_SERVER_URL) {
      throw new Error('Live eval requires APP_ACCESS_TOKEN and EVAL_SERVER_URL; enter credentials outside chat.');
    }
    endpoint = new URL('/v1/tutor/turn', process.env.EVAL_SERVER_URL);
    if (endpoint.protocol !== 'https:' && !(endpoint.protocol === 'http:'
      && ['localhost', '127.0.0.1', '[::1]'].includes(endpoint.hostname))) {
      throw new Error('Use HTTPS for remote evaluation servers.');
    }
    if (endpoint.username || endpoint.password) throw new Error('Credentials must not be in the URL.');
  }
  const records = [];
  for (const testCase of fixture.cases) {
    const record = { caseID: testCase.id, title: testCase.title, rubric: testCase.expected,
      context: testCase.context ?? null, status: 'not_run', failures: [] };
    if (live && testCase.mode !== 'voice_control') {
      const request = requestFor(testCase);
      record.request = request;
      try {
        const response = await fetch(endpoint, { method: 'POST',
          headers: { authorization: `Bearer ${process.env.APP_ACCESS_TOKEN}`, 'content-type': 'application/json' },
          body: JSON.stringify(request), signal: AbortSignal.timeout(45000) });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        record.reply = await response.json();
        record.failures = checkReply(request, record.reply);
        record.status = record.failures.length ? 'envelope_failed' : 'executed_needs_human_review';
      } catch (error) {
        record.status = 'execution_failed';
        // Never retain upstream error bodies or authorization headers.
        record.failures = [error instanceof Error && /^HTTP \d+$/.test(error.message)
          ? error.message : 'request failed or timed out'];
      }
    } else if (testCase.mode === 'voice_control') record.status = 'requires_state_event_test';
    records.push(record);
  }
  const output = resolve(root, 'evals/results', metadata.startedAt.replaceAll(':', '-'));
  await mkdir(output, { recursive: true });
  await writeFile(resolve(output, 'results.json'), JSON.stringify({ metadata, records }, null, 2) + '\n');
  await writeFile(resolve(output, 'review.md'), reportMarkdown(records, metadata));
  console.log(`Wrote ${records.length} evaluation rubrics to ${output}. Semantic reviews remain pending.`);
  if (records.some((r) => ['execution_failed', 'envelope_failed'].includes(r.status))) process.exitCode = 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { console.error(error.message); process.exitCode = 1; });
}
