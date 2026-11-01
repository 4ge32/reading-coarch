"""Bounded release diagnostics; raw signing and upload logs are never published."""
import os
import re
import sys
from pathlib import Path

SENSITIVE_NAMES = (
    "DISTRIBUTION_CERTIFICATE_P12_BASE64", "DISTRIBUTION_CERTIFICATE_PASSWORD",
    "APP_PROVISION_PROFILE_BASE64", "SHARE_PROVISION_PROFILE_BASE64",
    "ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_P8", "TESTFLIGHT_EPHEMERAL_PASSWORD",
)


def summarize(text, env):
    for name in SENSITIVE_NAMES:
        value = env.get(name, "")
        if value:
            text = text.replace(value, "[redacted]")
    text = re.sub(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)",
                  "[private key redacted]", text, flags=re.S)
    text = re.sub(r"(?i)(authorization[\"']?\s*[:=]\s*)(?:bearer\s+)?[^\r\n]+", r"\1[redacted]", text)
    text = re.sub(r"(?i)((?:password|private[_ -]?key|token)[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|\S+)", r"\1[redacted]", text)
    text = re.sub(r"[A-Za-z0-9_+/=-]{80,}", "[encoded data redacted]", text)
    text = re.sub(r"(?i)(provisioning profile\s+)[\"'][^\"']*[\"']", r"\1[profile]", text)
    text = re.sub(r"[^\s\"']+\.keychain(?:-db)?", "[keychain]", text)
    text = re.sub(r"[^\s\"']+\.p8", "[API key file]", text)
    lines = []
    for line in text.splitlines():
        if re.search(r"(?i)\berror\b|\bfatal\b|\bfailed\b|ITMS-\d+", line):
            line = line.strip()[:600]
            if line and line not in lines:
                lines.append(line)
    return lines[-12:]


if __name__ == "__main__":
    try:
        lines = summarize(Path(sys.argv[1]).read_text(errors="replace"), os.environ)
    except (OSError, IndexError):
        lines = []
    print("Sanitized release error summary (raw log retained only until job cleanup):", file=sys.stderr)
    for line in lines:
        print(line, file=sys.stderr)
    if not lines:
        print("No safe error detail was available. Check the selected Xcode, signing environment and App Store Connect configuration.", file=sys.stderr)
