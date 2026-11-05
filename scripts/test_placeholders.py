#!/usr/bin/env python3
"""Check forum env placeholders and Dockerfile ship the upload path."""

import re
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
        raise SystemExit("Dockerfile does not listen on port 8080")
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
    # The Railway-era "stays on the current host" comment check is gone: it
    # asserted wording, not behaviour, and the Dockerfile no longer carries it.
    from_tag = re.search(r"^FROM discourse/discourse:([^@\s]+)(@sha256:[0-9a-f]{64})?\s*$", dockerfile, re.M)
    if not from_tag:
        raise SystemExit("Dockerfile FROM line is not a pinned discourse/discourse tag")
    if f'io.societyprotocol.discourse.tag="{from_tag.group(1)}"' not in dockerfile:
        raise SystemExit("Dockerfile Discourse tag label does not match the FROM tag")
    if f'org.opencontainers.image.base.name="discourse/discourse:{from_tag.group(1)}"' not in dockerfile:
        raise SystemExit("Dockerfile base.name label does not match the FROM tag")
    if "ARG SIWE_REF" not in dockerfile or "ARG SIWE_BRANCH" not in dockerfile:
        raise SystemExit("Dockerfile must declare both SIWE_REF and SIWE_BRANCH")
    if "io.societyprotocol.siwe-auth.ref" not in dockerfile:
        raise SystemExit("Dockerfile does not label the plugin ref")
    for name in (".env.example",):
        text = (ROOT / name).read_text(encoding="utf-8")
        for line in text.splitlines():
            if "://" in line and "@" in line.split("://", 1)[1].split("/", 1)[0]:
                raise SystemExit(f"{name} has a URL with embedded credentials")
        if re.search(r"(?i)railway", text):
            raise SystemExit(f"{name} still mentions Railway")
    print("ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
