#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
git diff --check
npm --prefix server run build
npm --prefix server test
node scripts/evals/run.test.mjs
node scripts/test-share.mjs
node scripts/build-share.mjs --check
if command -v swift >/dev/null 2>&1; then
  swift test --package-path packages/ReadingCore --jobs 4
else
  env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    docker --host=unix:///var/run/docker.sock run --rm --user "$(id -u):$(id -g)" \
    -e XDG_CACHE_HOME=/tmp/readingcoach-cache \
    -e SWIFTPM_MODULECACHE_OVERRIDE=/tmp/readingcoach-modules \
    -e CLANG_MODULE_CACHE_PATH=/tmp/readingcoach-clang \
    -v "$PWD:/workspace" -w /workspace \
    swift:6.1.2-jammy@sha256:5910655d205a5a54b0b9efdf72c4066a8de1932513fdc81793e2544b5d5a0709 \
    swift test --package-path packages/ReadingCore --cache-path /tmp/readingcoach-swiftpm-cache \
      --config-path /tmp/readingcoach-swiftpm-config --security-path /tmp/readingcoach-swiftpm-security --jobs 4
fi
bash scripts/test-live-client.sh
