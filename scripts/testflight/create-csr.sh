#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
output=${1:-.signing}
if [[ -z "${DISTRIBUTION_CERTIFICATE_PASSWORD:-}" ]]; then
  echo 'Supply DISTRIBUTION_CERTIFICATE_PASSWORD securely in the process environment.' >&2; exit 1
fi
mkdir -p "$output"
if [[ -e "$output/distribution-key.pem" || -e "$output/distribution.csr" ]]; then
  echo 'Signing key/CSR already exists; preserve it and choose another output directory.' >&2; exit 1
fi
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -aes-256-cbc \
  -pass env:DISTRIBUTION_CERTIFICATE_PASSWORD -out "$output/distribution-key.pem" >/dev/null 2>&1
openssl req -new -key "$output/distribution-key.pem" -passin env:DISTRIBUTION_CERTIFICATE_PASSWORD \
  -subj '/CN=ReadingCoach Distribution/O=ReadingCoach' -out "$output/distribution.csr"
echo 'Created encrypted distribution-key.pem and public distribution.csr. Upload only the CSR to Apple; keep the key private.'
