# Mozilla Readability

Vendored `Readability.js` is unmodified from `@mozilla/readability` **0.6.0**.
Upstream: https://github.com/mozilla/readability ; `Readability.js` is Apache-2.0.
The original notice and complete Apache license are included here. The separate
`fixtures/share/JSDOMParser.js` test parser is MPL-2.0 and retains its own notice.

Registry tarball: https://registry.npmjs.org/@mozilla/readability/-/readability-0.6.0.tgz

The npm tarball integrity was verified before extraction:
`sha512-juG5VWh4qAivzTAeMzvY9xs9HY5rAcr2E4I7tiSSCokRFi7XIZCAu92ZkSTsIj1OPceCifL3cpfteP3pDT9/QQ==`

`scripts/build-share.mjs` deterministically concatenates this source and
`Extraction.js` into the bundled `Preprocessing.js` Safari entry point.
Do not edit the generated file directly. Readability is an extractor; the
application receives only allowlisted block types with plain text, never HTML.
