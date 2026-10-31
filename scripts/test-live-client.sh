#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo_root=$PWD
overlay=$(mktemp -d "${TMPDIR:-/tmp}/readingcoach-live-client.XXXXXX")
trap 'rm -rf -- "$overlay"' EXIT

if command -v swift >/dev/null 2>&1; then
  core_package="$repo_root/packages/ReadingCore"
else
  core_package=/workspace/packages/ReadingCore
fi

# Build copies only. The checked-in iOS adapter and tests remain unchanged.
# FoundationNetworking is needed on Linux; the same Foundation API lives in Foundation on Apple OSes.
python3 - "$repo_root" "$overlay" "$core_package" <<'PY'
from pathlib import Path
import sys
repo, overlay, core_package = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
(overlay / 'Sources/LiveClient').mkdir(parents=True)
(overlay / 'Tests/LiveClientTests').mkdir(parents=True)
swift_path = core_package.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
(overlay / 'Package.swift').write_text(f'''// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "LiveClient",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LiveClient", targets: ["LiveClient"])],
    dependencies: [.package(path: "{swift_path}")],
    targets: [
        .target(name: "LiveClient", dependencies: [.product(name: "ReadingCore", package: "ReadingCore")]),
        .testTarget(name: "LiveClientTests", dependencies: ["LiveClient", .product(name: "ReadingCore", package: "ReadingCore")])
    ])
''')
networking = '#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n'
client = (repo / 'ios/ReadingCoach/Services/LiveTutorClient.swift').read_text()
tests = (repo / 'ios/ReadingCoachTests/LiveTutorClientTests.swift').read_text()
(overlay / 'Sources/LiveClient/LiveTutorClient.swift').write_text(networking + client)
(overlay / 'Tests/LiveClientTests/LiveTutorClientTests.swift').write_text(
    networking + tests.replace('@testable import ReadingCoach', '@testable import LiveClient'))
PY

if command -v swift >/dev/null 2>&1; then
  swift test --package-path "$overlay" --jobs 4
else
  env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    docker --host=unix:///var/run/docker.sock run --rm --user "$(id -u):$(id -g)" \
    -e XDG_CACHE_HOME=/tmp/readingcoach-cache \
    -e SWIFTPM_MODULECACHE_OVERRIDE=/tmp/readingcoach-modules \
    -e CLANG_MODULE_CACHE_PATH=/tmp/readingcoach-clang \
    -v "$repo_root:/workspace:ro" -v "$overlay:/live-tests" -w /live-tests \
    swift:6.1.2-jammy@sha256:5910655d205a5a54b0b9efdf72c4066a8de1932513fdc81793e2544b5d5a0709 \
    swift test --cache-path /tmp/readingcoach-swiftpm-cache \
      --config-path /tmp/readingcoach-swiftpm-config --security-path /tmp/readingcoach-swiftpm-security --jobs 4
fi
