# Staging twin: environment and self-diagnosis

`staging-forum.societyprotocol.io` is the single sanctioned test forum: the AWS
service `staging-forum`, built from this repo's `staging` branch with the same
`Dockerfile` as prod. Test gating and group sync there. A hand-built forum is
not a substitute (section 3 lists why those fail).

`.env.staging.example` is the env template. It contains placeholders only. Fill
it in outside git; never copy a value from the production env file.

## 1. What makes the twin faithful

| Setting | Staging value | Why it matters |
| --- | --- | --- |
| `DISCOURSE_HOSTNAME` | `staging-forum.societyprotocol.io` | The SIWE message domain must equal `Discourse.base_url`, or login fails with "Invalid domain". |
| `DISCOURSE_FORCE_HTTPS` | `true` | Behind Cloudflare and Caddy. The proxy must send `X-Forwarded-Proto: https`, otherwise the session cookie is not `secure` and the nonce is lost. |
| Database and Redis | `staging-forum-postgres`, `staging-redis` | Own data. Never point staging at prod's database or Redis. |
| `DISCOURSE_SECRET_KEY_BASE` | newly generated (`openssl rand -hex 64`) | Never copied from prod: sessions and tokens must not be valid across environments. |
| Mail | Mailpit sink, or a real relay | Without working mail, new SIWE users are inactive (section 4). |
| `DISCOURSE_SIWE_PROJECT_ID` | Reown project with the staging hostname in its domain allowlist | Wallet modal fails to connect from a hostname that is not allowlisted. |
| `DISCOURSE_SIWE_ETHEREUM_RPC_URL` | mainnet HTTPS RPC (placeholder) | Signature verification (including smart-account signatures) calls it. Empty means verification fails. |
| Badge settings | contract `0x12406bB6d11Cb641e100F1d8595c0C5e63F0bD47`, chain id `11155111`, RPC `https://ethereum-sepolia-rpc.publicnode.com` | The Sepolia badges for group sync (F2) and gating. |
| `DISCOURSE_SIWE_SOCIETY_SUBGRAPH_URL` / `_TOKEN` | staging gateway (`staging-gateway`), its own token | The staging gateway reads the Sepolia subgraph. |

Which settings come from env and which stay in the admin UI is explained in
`docs/UPGRADE.md`, "Settings ownership". Group mapping and sync mode are left to
the admin UI so Fritz can change them.

Do not restore anonymised production data into staging for gating tests. Prod
users have mainnet addresses that hold none of the Sepolia badges, the badge ids
and contract differ, and `user_associated_accounts.provider_uid` holds real member
wallets. Seed staging with named test users and Sepolia badges instead.

Staging container sizing: the forum container has a memory limit (about 1 GB). A
`rails runner` in it needs temporary headroom
(`docker update --memory 2g --memory-swap 4g <container>`, then set it back).

## 2. A private sandbox for Fritz

Hand over this repo, not a hand-built install: `docker build` the same `Dockerfile`
(`--build-arg SIWE_BRANCH=staging`; add `--build-arg SIWE_REF=<40-char sha>` to pin),
plus Postgres (pgvector image), Redis and an HTTPS hostname with a Reown allowlist entry.
A sandbox on plain `http://localhost` cannot work: the SIWE domain, `FORCE_HTTPS`, the
secure cookie and the Reown allowlist all need a real HTTPS hostname.

## 3. Why a hand-built test forum fails (check in this order)

1. **Hostname or HTTPS mismatch.** `callback_phase` (`lib/omniauth/strategies/siwe.rb`) rejects
   the login with "Invalid domain" unless the message domain equals `Discourse.base_url`
   (`auth_controller.rb`). A proxy that does not send `X-Forwarded-Proto: https`, or
   `FORCE_HTTPS=true` with no TLS terminator, breaks the secure cookie and the nonce.
   Check: run the smoke checklist in `docs/UPGRADE.md` section 8 (secure `_forum_session`,
   message domain equals the host).
2. **Built from stock discourse_docker, not this `Dockerfile`.** Symptoms: boot crash from
   `discourse-events` plus `discourse-calendar` (MultiplePrependBlocks), a failed native build for
   a missing `rubyzip` gem, or the SIWE JavaScript never compiled because boot-time precompile is
   skipped (the login page has no wallet button). Check: `docker image inspect` shows the labels
   `io.societyprotocol.*`; the plugin directory contains no `discourse-events` sibling.
3. **Image drift** against the pinned Discourse tag. Check: label
   `io.societyprotocol.discourse.tag` on the image equals the `FROM` tag in this repo.
4. **Reown project id and RPC.** Hostname missing from the Reown allowlist, or empty
   `siwe_project_id` / `siwe_ethereum_rpc_url` (smart-account signature verification needs the RPC).
   Check: admin > Settings, search `siwe`; the browser console shows the Reown origin error.
5. **Inactive SIWE users with no SMTP** (section 4).
6. **Production env copied to the test box**: same database or Redis, or the same
   `SECRET_KEY_BASE`. Check: `DISCOURSE_DB_HOST`, `DISCOURSE_REDIS_HOST` and the hostname differ from
   the prod values. If a test forum ever pointed at the prod database, treat it as an incident.

## 4. Inactive SIWE users (no SMTP)

SIWE users are created without a verified email (`primary_email_verified?` is false), so they are
inactive until the activation mail is confirmed. With Mailpit or a relay configured, open the
mail. Without mail, activate the user by hand (rails runner, container as in `docs/UPGRADE.md`):

```bash
docker exec -u discourse -w /var/www/discourse society-staging-forum-1 \
  bundle exec rails runner 'u = User.find_by_username("REPLACE_USERNAME"); u.activate; puts [u.username, u.active?].inspect'
```

`User#activate` is the method behind the admin "Activate" button; its exact behaviour was not
re-read against the 2026.8.0 source. If it raises, `u.update!(active: true)` does the same thing.
If the site requires approval, also run `u.update!(approved: true)`.
