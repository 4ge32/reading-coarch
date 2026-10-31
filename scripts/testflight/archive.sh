#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
cd "$(dirname "$0")/../.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Signed iPhone archives require the macOS GitHub Actions job.' >&2
  exit 1
fi
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/readingcoach-signing.XXXXXX")
keychain="$work/signing.keychain-db"
profiles_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
original_keychains=()
if ! security list-keychains -d user > "$work/original-keychains.txt"; then
  rm -rf -- "$work"
  echo 'Unable to inspect the runner keychain configuration; signing was not changed.' >&2
  exit 1
fi
python3 -c 'import shlex,sys; print("\n".join(shlex.split(open(sys.argv[1]).read())))' "$work/original-keychains.txt" > "$work/keychain-paths.txt"
while IFS= read -r item; do
  if [[ -n "$item" ]]; then original_keychains+=("$item"); fi
done < "$work/keychain-paths.txt"
installed_profiles=()
cleanup() {
  local status=$?
  set +eu
  for uuid in "${installed_profiles[@]}"; do
    rm -f -- "$profiles_dir/$uuid.mobileprovision"
    if [[ -f "$work/backup-$uuid.mobileprovision" ]]; then
      cp "$work/backup-$uuid.mobileprovision" "$profiles_dir/$uuid.mobileprovision"
    fi
  done
  security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf -- "$work"
  return "$status"
}
trap cleanup EXIT
python3 scripts/testflight/config.py decode "$work"
security cms -D -i "$work/app.mobileprovision" > "$work/app.plist"
security cms -D -i "$work/share.mobileprovision" > "$work/share.plist"
openssl pkcs12 -in "$work/distribution.p12" -passin env:DISTRIBUTION_CERTIFICATE_PASSWORD -clcerts -nokeys -out "$work/certificate.pem" >/dev/null 2>&1
openssl x509 -in "$work/certificate.pem" -outform DER -out "$work/certificate.der"
openssl x509 -in "$work/certificate.pem" -checkend 0 -noout >/dev/null
openssl x509 -in "$work/certificate.pem" -pubkey -noout > "$work/certificate-public.pem"
openssl pkcs12 -in "$work/distribution.p12" -passin env:DISTRIBUTION_CERTIFICATE_PASSWORD -nocerts -nodes 2>/dev/null \
  | openssl pkey -pubout > "$work/key-public.pem" 2>/dev/null
if ! cmp -s "$work/certificate-public.pem" "$work/key-public.pem"; then
  echo 'The distribution P12 does not contain the matching private key.' >&2; exit 1
fi
python3 scripts/testflight/config.py profiles "$work"
app_profile=$(sed -n '1p' "$work/profile-ids.txt")
share_profile=$(sed -n '2p' "$work/profile-ids.txt")
keychain_password=$(openssl rand -hex 32)
security create-keychain -p "$keychain_password" "$keychain" >/dev/null
security set-keychain-settings -lut 21600 "$keychain" >/dev/null
security unlock-keychain -p "$keychain_password" "$keychain" >/dev/null
security import "$work/distribution.p12" -P "$DISTRIBUTION_CERTIFICATE_PASSWORD" -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "${original_keychains[@]}" >/dev/null
mkdir -p "$profiles_dir"
for uuid in "$app_profile" "$share_profile"; do
  if [[ -f "$profiles_dir/$uuid.mobileprovision" ]]; then cp "$profiles_dir/$uuid.mobileprovision" "$work/backup-$uuid.mobileprovision"; fi
  installed_profiles+=("$uuid")
done
cp "$work/app.mobileprovision" "$profiles_dir/$app_profile.mobileprovision"
cp "$work/share.mobileprovision" "$profiles_dir/$share_profile.mobileprovision"
output="$PWD/build/testflight"
mkdir -p "$output"
if ! xcodebuild archive -project ios/ReadingCoach.xcodeproj -scheme ReadingCoach \
  -configuration Release -destination 'generic/platform=iOS' -archivePath "$work/ReadingCoach.xcarchive" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Apple Distribution' \
  READINGCOACH_BUNDLE_ID="$APP_BUNDLE_ID" READINGCOACH_APP_GROUP="$APP_GROUP_ID" \
  READINGCOACH_APP_PROFILE="$app_profile" READINGCOACH_SHARE_PROFILE="$share_profile" \
  MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="$APP_BUILD_NUMBER" \
  > "$work/archive.log" 2>&1; then
  TESTFLIGHT_EPHEMERAL_PASSWORD="$keychain_password" python3 scripts/testflight/diagnostics.py "$work/archive.log"
  echo 'Signed archive failed. Confirm the unsigned Simulator check passes, and check the registered IDs, distribution certificate and profiles.' >&2
  exit 1
fi
codesign --verify --deep --strict "$work/ReadingCoach.xcarchive/Products/Applications/ReadingCoach.app" >/dev/null 2>&1
if ! xcodebuild -exportArchive -archivePath "$work/ReadingCoach.xcarchive" \
  -exportOptionsPlist "$work/ExportOptions.plist" -exportPath "$work/export" > "$work/export.log" 2>&1; then
  TESTFLIGHT_EPHEMERAL_PASSWORD="$keychain_password" python3 scripts/testflight/diagnostics.py "$work/export.log"
  echo 'IPA export failed. Check both App Store Connect provisioning profiles and the distribution certificate.' >&2
  exit 1
fi
ipa=$(find "$work/export" -maxdepth 1 -name '*.ipa' -type f -print)
if [[ -z "$ipa" || "$ipa" == *$'\n'* ]]; then echo 'Expected exactly one exported IPA.' >&2; exit 1; fi
python3 scripts/testflight/config.py ipa "$ipa"
unzip -q "$ipa" -d "$work/ipa"
app="$work/ipa/Payload/ReadingCoach.app"
share="$app/PlugIns/ReadingCoachShare.appex"
for target in app share; do
  if [[ "$target" == app ]]; then bundle_path="$app"; else bundle_path="$share"; fi
  codesign --verify --deep --strict "$bundle_path" >/dev/null 2>&1
  codesign -d --entitlements :- "$bundle_path" > "$work/exported-$target.entitlements.plist" 2>/dev/null
  security cms -D -i "$bundle_path/embedded.mobileprovision" > "$work/exported-$target.profile.plist"
done
python3 scripts/testflight/config.py signed "$work"
cp "$ipa" "$output/ReadingCoach.ipa"
echo 'Signed IPA exported and package identifiers/versions validated. No upload was performed by this script.'
