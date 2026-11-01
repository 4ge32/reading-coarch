#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Xcode project generation requires macOS. Portable tests do not require Xcode.' >&2
  exit 1
fi
version=2.44.1
checksum=a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73
tool_root="$PWD/.tools/xcodegen-$version"
if [[ ! -x "$tool_root/xcodegen/bin/xcodegen" ]]; then
  mkdir -p "$tool_root"
  archive="$(mktemp -t readingcoach-xcodegen).zip"
  trap 'rm -f "$archive"' EXIT
  curl --fail --location --silent --show-error \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip" -o "$archive"
  echo "$checksum  $archive" | shasum -a 256 -c -
  unzip -q "$archive" -d "$tool_root"
fi
"$tool_root/xcodegen/bin/xcodegen" generate --spec ios/project.yml
resolved_dir=ios/ReadingCoach.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$resolved_dir"
cp ios/Package.resolved "$resolved_dir/Package.resolved"
