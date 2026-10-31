#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
cd "$(dirname "$0")/../.."
if [[ "$(uname -s)" != Darwin ]]; then echo 'TestFlight upload requires the macOS workflow.' >&2; exit 1; fi
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/readingcoach-upload.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
python3 - "$work" <<'PY'
import os,re,sys
from pathlib import Path
if not re.fullmatch(r'[A-Z0-9]{10}',os.environ.get('ASC_KEY_ID','')):
    raise SystemExit('Set a valid ASC_KEY_ID in the testflight environment secrets.')
if not re.fullmatch(r'[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}',os.environ.get('ASC_ISSUER_ID','')):
    raise SystemExit('Set the team API key ASC_ISSUER_ID in the testflight environment secrets.')
key=os.environ.get('ASC_PRIVATE_KEY_P8','')
if not key.startswith('-----BEGIN PRIVATE KEY-----') or '-----END PRIVATE KEY-----' not in key:
    raise SystemExit('Set ASC_PRIVATE_KEY_P8 to the complete team API private key, not base64.')
directory=Path(sys.argv[1])/'private_keys'
directory.mkdir(mode=0o700)
path=directory/('AuthKey_'+os.environ['ASC_KEY_ID']+'.p8')
path.write_text(key.rstrip()+'\n')
path.chmod(0o600)
PY
openssl pkey -in "$work/private_keys/AuthKey_$ASC_KEY_ID.p8" -noout >/dev/null 2>&1
ipa="$PWD/build/testflight/ReadingCoach.ipa"
python3 scripts/testflight/config.py ipa "$ipa"
if ! API_PRIVATE_KEYS_DIR="$work/private_keys" xcrun altool --upload-app --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID" -t ios -f "$ipa" > "$work/upload.log" 2>&1; then
  python3 scripts/testflight/diagnostics.py "$work/upload.log"
  echo 'TestFlight upload failed. Check API-key resource access, app registration, Apple agreements and whether this build number was used before.' >&2
  exit 1
fi
echo 'Apple accepted the upload request. Wait for App Store Connect processing, then add the build to an internal TestFlight group.'
echo 'This workflow does not submit an App Store release or automatically invite external testers.'
