#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
output=${1:-.signing}
if [[ -z "${DISTRIBUTION_CERTIFICATE_PASSWORD:-}" ]]; then
  echo 'Supply DISTRIBUTION_CERTIFICATE_PASSWORD securely in the process environment.' >&2; exit 1
fi
if [[ -e "$output/distribution.p12" ]]; then echo 'distribution.p12 already exists; do not overwrite an existing signing identity.' >&2; exit 1; fi
work=$(mktemp -d "${TMPDIR:-/tmp}/readingcoach-certificate.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
openssl x509 -inform DER -in "$output/distribution.cer" -out "$work/distribution.pem"
openssl x509 -in "$work/distribution.pem" -checkend 0 -noout >/dev/null
openssl x509 -in "$work/distribution.pem" -pubkey -noout > "$work/certificate-public.pem"
openssl pkey -in "$output/distribution-key.pem" -passin env:DISTRIBUTION_CERTIFICATE_PASSWORD -pubout > "$work/key-public.pem"
if ! cmp -s "$work/certificate-public.pem" "$work/key-public.pem"; then
  echo 'Downloaded certificate does not match this private key/CSR. Nothing was packaged.' >&2; exit 1
fi
openssl pkcs12 -export -inkey "$output/distribution-key.pem" -passin env:DISTRIBUTION_CERTIFICATE_PASSWORD \
  -in "$work/distribution.pem" -name 'Apple Distribution' -out "$output/distribution.p12" \
  -passout env:DISTRIBUTION_CERTIFICATE_PASSWORD \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -iter 100000
echo 'Created the encrypted distribution.p12. Store it and its password in GitHub environment secrets; never commit either.'
