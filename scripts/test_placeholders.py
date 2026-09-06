#!/usr/bin/env python3
"""Check forum env placeholders and Dockerfile ship the Railway path."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = [
    "DISCOURSE_HOSTNAME",
    "DISCOURSE_SMTP_ADDRESS",
    "DISCOURSE_SMTP_PASSWORD",
    "DISCOURSE_SECRET_KEY_BASE",
    "ADMIN_PASSWORD",
    "DISCOURSE_SIWE_PROJECT_ID",
    "DISCOURSE_SIWE_ETHEREUM_RPC_URL",
]


def main() -> int:
    example = (ROOT / ".env.example").read_text(encoding="utf-8")
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
    missing = [key for key in REQUIRED if key not in example]
    if missing:
        raise SystemExit(f"missing placeholders: {missing}")
    if "REPLACE_WITH_SMTP_HOST" not in example:
        raise SystemExit("SMTP host is not a placeholder")
    if "bitnami/discourse:" not in dockerfile:
        raise SystemExit("Dockerfile does not use the Discourse image")
    if "forum.societyprotocol.io stays" not in dockerfile and "stays on the current host" not in dockerfile:
        raise SystemExit("Dockerfile is missing the production-safe comment")
    print("ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
