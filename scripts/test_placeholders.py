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
    if "discourse/discourse:2026.8.0-latest.1" not in dockerfile:
        raise SystemExit("Dockerfile does not use the matching production Discourse image")
    if "discourse-siwe-auth" not in dockerfile:
        raise SystemExit("Dockerfile does not install the SIWE plugin")
    if "disable-events.sh" not in dockerfile:
        raise SystemExit("Dockerfile does not disable the conflicting events plugin")
    if "fix-nginx.sh" not in dockerfile:
        raise SystemExit("Dockerfile does not listen on Railway port 8080")
    if "assets:precompile" not in dockerfile:
        raise SystemExit("Dockerfile does not compile SIWE client assets")
    if "PRECOMPILE_ON_BOOT=0" not in dockerfile:
        raise SystemExit("Dockerfile still lets boot skip Ember compile")
    if "persist-uploads.sh" not in dockerfile:
        raise SystemExit("Dockerfile does not keep uploads on the volume")
    if "seed-uploads" not in dockerfile:
        raise SystemExit("Dockerfile does not seed restored uploads")
    logo = ROOT / "seed-uploads/default/original/1X/8125148fe00ab5c849944c6b650d62754c2a3c33.png"
    if not logo.is_file():
        raise SystemExit("seed uploads are missing the site logo")
    if "forum.societyprotocol.io stays" not in dockerfile and "stays on the current host" not in dockerfile:
        raise SystemExit("Dockerfile is missing the production-safe comment")
    print("ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
