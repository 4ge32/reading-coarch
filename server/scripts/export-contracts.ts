import { writeFileSync } from 'node:fs';
import { z } from 'zod';
import { tokenRequestSchema, tutorRequestSchema, tutorReplySchema, practiceRequestSchema } from '../src/schemas.js';
import { realtimeTools } from '../src/services/openai.js';

for (const [name,schema] of Object.entries({
  'tutor-turn.request':tutorRequestSchema,
  'tutor-reply':tutorReplySchema,
  'realtime-token.request':tokenRequestSchema,
  'practice.request':practiceRequestSchema,
})) {
  const jsonSchema = z.toJSONSchema(schema,{io:'input'});
  writeFileSync(new URL(`../../contracts/${name}.schema.json`,import.meta.url),JSON.stringify({
    ...jsonSchema,
    $comment: 'Generated from server/src/schemas.ts. Runtime also validates UTF-16 boundaries, source text equality, snapshot identity, reply source allowlist and request/revision equality.',
  },null,2)+'\n');
}
writeFileSync(new URL('../../contracts/realtime-tools.json',import.meta.url),JSON.stringify(realtimeTools,null,2)+'\n');
