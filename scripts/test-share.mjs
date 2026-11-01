import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { test } from 'node:test';

const read = path => readFileSync(new URL('../' + path, import.meta.url), 'utf8');
const parserContext = {};
runInNewContext(read('fixtures/share/JSDOMParser.js'), parserContext);
// Mozilla's dependency-free test DOM accepts well-formed XHTML. Safari uses its native HTML DOMParser.
const parse = html => {
  const normalized = html.replace(/<!doctype[^>]*>/gi, '').trim();
  const document = new parserContext.JSDOMParser().parse(normalized, 'https://example.com/reading');
  // This lightweight upstream test DOM does not implement Document.cloneNode.
  document.cloneNode = () => parse(normalized);
  return document;
};
const context = { URL, console };
runInNewContext(read('ios/ReadingCoachShare/Resources/Preprocessing.js'), context);
const extraction = context.ReadingCoachExtraction;
const plain = value => JSON.parse(JSON.stringify(value));

test('vendored Readability and test parser match pinned upstream SHA256 values', () => {
  assert.equal(createHash('sha256').update(read('ios/ReadingCoachShare/Resources/ThirdParty/Readability.js')).digest('hex'), '34dcab3d0832d0019f02990eed6b6124e029e8c32b9f0c6f2550544ff8dff174');
  assert.equal(createHash('sha256').update(read('fixtures/share/JSDOMParser.js')).digest('hex'), '6b8eae46939f187ef4565c67f452a9098211daea80e50c9aea74d72015b73680');
});

test('allowlisted blocks preserve text and structure without executable content', () => {
  const blocks = plain(extraction.blocksFromDocument(parse(read('fixtures/share/unsafe.html'))));
  assert.deepEqual(blocks.map(block => block.kind), ['heading', 'paragraph', 'blockquote', 'code']);
  const text = blocks.map(block => block.text).join('\n');
  assert.match(text, /ignore previous instructions/);
  assert.match(text, /🧠/);
  assert.doesNotMatch(text, /sendSecrets|iframe text|private text|invisible text|javascript:|onerror/);
  assert.ok(blocks.every(block => Object.keys(block).sort().join(',') === 'kind,text'));
});

test('Readability extracts a cloned page, retaining heading, list, quote and code', () => {
  const document = parse(read('fixtures/share/article.html'));
  const before = document.documentElement.innerHTML;
  const result = plain(extraction.extract(document, 'https://example.com/reading', parse));
  assert.equal(result.status, 'extracted');
  assert.equal(result.extractionVersion, 'readability-0.6.0/readingcoach-blocks-1');
  assert.equal(result.sourceURL, 'https://example.com/reading');
  for (const kind of ['heading', 'paragraph', 'listItem', 'blockquote', 'code']) assert.ok(result.blocks.some(block => block.kind === kind), `missing ${kind}`);
  assert.equal(document.documentElement.innerHTML, before, 'original page must be unchanged');
});

test('URL-only or failed extraction never invents article content', () => {
  const result = plain(extraction.extract(parse('<html><head><title>No body</title></head><body></body></html>'), 'https://example.com/empty', parse));
  assert.equal(result.status, 'urlOnly');
  assert.deepEqual(result.blocks, []);
  assert.equal(result.sourceURL, 'https://example.com/empty');
});

test('URL allowlist rejects executable schemes and embedded credentials', () => {
  for (const url of ['javascript:alert(1)', 'data:text/html,hello', 'file:///etc/passwd', 'https://user:secret@example.com/x', 'not a url']) assert.equal(extraction.safeURL(url), null);
  assert.equal(extraction.safeURL('https://example.com/read?a=1'), 'https://example.com/read?a=1');
});

test('nested block boundaries stay readable and code indentation is preserved', () => {
  const blocks = plain(extraction.blocksFromDocument(parse('<html><body><blockquote><p>First sentence.</p><p>Second sentence.</p></blockquote><pre>  indented\n    nested</pre></body></html>')));
  assert.equal(blocks[0].text, 'First sentence. Second sentence.');
  assert.equal(blocks[1].text, '  indented\n    nested');
});

test('oversized extraction fails before a share job can be accepted', () => {
  assert.throws(() => extraction.blocksFromDocument(parse('<html><body><p>' + 'a'.repeat(2_000_001) + '</p></body></html>')), /too large/);
});
