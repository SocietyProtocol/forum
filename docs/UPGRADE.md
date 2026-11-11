# Forum upgrade and ownership runbook

Applies to the Discourse forum built from this repo (`society-forum:staging`
and `society-forum:prod`, deployed by `.github/workflows/deploy-aws.yml`).
Names below come from the repo and from earlier inspection of the AWS box. Items
marked **verify** were not confirmed against the live box when this was written.

The decided production configuration for the plugin release (badge to group mapping,
group sync, gating, badge mirror, env vars, GitHub environments) is in
[`docs/PRODUCTION_SETTINGS.md`](PRODUCTION_SETTINGS.md).

## 1. Who owns what

| Area | Owner |
| --- | --- |
| Docker image, Discourse version, plugin pin, deploy pipeline, backups, rollback | August |
| Site settings (admin UI), moderation, content, verifying behaviour on staging | Fritz |
| Production deploys | August (the `production` GitHub environment should require his approval, and only counts once the AWS role trust policy is narrowed, section 12) |

Both subscribe to Discourse security announcements: watch the Announcements
and Security categories on meta.discourse.org and the security advisories of
`discourse/discourse` on GitHub.

## 2. Cadence

- Monthly: bump to the latest stable Discourse tag.
- Security releases: ship to staging the same day and to prod within 72 hours.
- A plugin change ships when a deploy is triggered (section 5), not on the monthly clock.

## 3. The upgrade flow

1. **Staging branch.** On `staging`, change the `FROM` line in `Dockerfile` to the new tag, pinned by digest:
   `FROM discourse/discourse:<tag>@sha256:<digest>`. Get the digest with
   `docker buildx imagetools inspect discourse/discourse:<tag>` (or `docker pull`
   then `docker image inspect --format '{{index .RepoDigests 0}}'`).
   Update the two `<tag>` labels at the bottom of the `Dockerfile` to the same tag
   (`scripts/test_placeholders.py` fails if they differ), and the `rubyzip`/events
   workarounds if the release notes say they changed.
2. **Push to `staging`.** The workflow runs the `test` job, then `deploy-staging`:
   builds on the box, recreates `staging-forum`, and fails the job if the health
   check or the plugin assertion fails (section 6).
3. **Smoke.** Run the checklist in section 8 against staging, then the Sepolia
   e2e (`web3-app-client/scripts/e2e`, step `A14b` once it exists).
4. **Fritz checks settings.** Compare staging's overridden settings with the
   baseline (section 10) and click through login, a gated category and admin > Plugins.
5. **Merge `staging` into `main`** (PR). The `deploy-prod` job waits for the
   `production` environment approval (one-time GitHub setup, section 12).
6. **Before approving prod: back up the database (section 4).** The pipeline
   does not take the backup for you.
7. **Approve.** The job builds, recreates `prod-forum`, waits up to 10 minutes for
   `/srv/status` and checks the plugin SHA. Only when all of that passes does it tag the
   new image `society-forum:prod-good` (the old `-good` becomes `-prev`, section 7).
8. **Smoke prod** (section 8, read-only checks only).

Deploys queue, they never overlap. Staging and prod run on the same box, so
both deploy jobs share one GitHub concurrency group (`aws-outpost-forum`): a
staging push that arrives while a prod deploy runs waits for it, and the other
way round. GitHub keeps only one waiting run per group, so a newer waiting run
replaces an older waiting one (the older shows as "Canceled"; re-run it, which
matters most for a waiting prod rollback). A second guard runs on the box: the
remote script takes an exclusive `flock` on `/tmp/society-build.lock` for the whole
build, recreate and health wait (waits up to 30 minutes, then fails without touching
docker) and works in its own `mktemp -d` directory, so even a manual overlap cannot
delete another run's build context. The web client and subgraph deploy scripts
are copies of this one and must use the same lock file to be covered.

Downtime: `--force-recreate` stops the single container; expect a few minutes
of unavailability while Discourse boots. The build also runs on the live
instance (`docker build --network=host` over SSM) and competes with the running
forum for CPU and memory, so deploy prod at a quiet time.

Migrations: it is **unverified** whether `/sbin/boot` in the base image runs
`db:migrate`. Check once on staging:
`docker exec society-staging-forum-1 grep -rn "db:migrate\|MIGRATE_ON_BOOT" /sbin/boot /etc/service /etc/runit 2>/dev/null`.
If nothing migrates at boot, uncomment the `POST_DEPLOY_CMD` line in the deploy
job (it runs through `docker exec` in the new container, before the health wait):
`cd /var/www/discourse && su discourse -c 'bundle exec rake db:migrate'`.
Applying migrations twice is harmless. Check pending migrations after any bump with
`docker exec -u discourse -w /var/www/discourse society-staging-forum-1 bundle exec rake db:migrate:status | grep -c '^ *down'` (must print 0).

## 4. Pre-deploy backup (prod)

The forum database lives in its own Postgres container (compose project
`society-db`, **verify** with `docker ps --format '{{.Names}}' | grep forum-postgres`):
`society-db-prod-forum-postgres-1` (prod) and `society-db-staging-forum-postgres-1`
(staging). Database `discourse`, user `discourse`. Run on the box (SSM):

```bash
sudo mkdir -p /data/prod/backups && df -h /data | tail -1
docker exec society-db-prod-forum-postgres-1 pg_dump -U discourse -d discourse -Fc \
  > /data/prod/backups/forum-$(date -u +%Y%m%dT%H%M%SZ).dump
ls -lh /data/prod/backups | tail -3
docker exec -i society-db-prod-forum-postgres-1 pg_restore --list < "$(ls -t /data/prod/backups/forum-*.dump | head -1)" | head -5
```

It runs inside the Postgres container, so the client version always matches the
server and no password is needed (local socket). Uploads are not in the dump;
they live on the forum volume (`persist-uploads.sh`). An EBS snapshot of the
instance is the alternative if the dump is too slow.

## 5. How a plugin change ships

The image pins the plugin by commit: the deploy script resolves the tip of the
plugin branch (`main` for prod, `staging` for staging) with `git ls-remote` and
builds with `--build-arg SIWE_REF=<sha>`. A new SHA busts the cache, so a plugin
push now really ships once a deploy runs. A plugin push alone does not start a deploy. Either:

- run **Actions > Deploy to AWS > Run workflow**, choose `staging` or `main`,
  optionally paste a 40-char plugin commit (`plugin_sha`); or
- have the plugin repo send a `repository_dispatch`:
  `POST /repos/SocietyProtocol/forum/dispatches` with
  `{"event_type":"plugin-updated","client_payload":{"env":"staging","sha":"<optional>"}}`.
  The plugin repo needs a fine-grained token with Contents + Actions write on the forum
  repo stored as its own secret (August to create; nothing is stored in this repo).
  Wire `env: staging` from the plugin's `staging` branch first. Do not wire `env: prod`
  until the release path in `docs/RELEASE_SEQUENCING.md` is decided.

**Pins.** What a build uses for the plugin, first match wins: the `plugin_sha` workflow input or
dispatch `sha` (that run only), the SHA in `.plugin-pin` at the root of the deployed branch (see
below), the tip of the plugin branch. `plugin_sha` alone is **one-shot**: the next push to
the branch re-resolves the tip. To hold a plugin commit across pushes, commit it to `.plugin-pin`
(one full lowercase SHA, nothing else; empty or absent means follow the tip). The test job
checks the file's format, and the post-deploy check asserts the container runs that commit. The file is per
branch and rides along when `staging` is merged into `main`. `docs/RELEASE_SEQUENCING.md`
explains why this matters for Option B.

Dispatch inputs are untrusted text. `.github/scripts/prepare-target.sh` accepts only
`ref` exactly `main` or `staging`, `env` exactly `staging` or `prod`, and a plugin SHA of
exactly 40 lowercase hex characters (length and charset, so a value with a newline cannot
pass), and writes only validated values to `$GITHUB_OUTPUT`. `deploy-outpost.sh` and the
`Dockerfile` repeat the SHA check. `scripts/test_deploy_pipeline.py` covers multi-line,
short, long, uppercase and injected values.

`workflow_dispatch` and `repository_dispatch` only work once this workflow file is on the
default branch.

## 6. Health check, and what a failed deploy looks like

After the container is recreated the script polls inside the container
(`docker exec <container> curl http://localhost/srv/status`, with
`X-Forwarded-Proto: https` so `FORCE_HTTPS` does not redirect) until the body is
exactly `ok`, for up to `HEALTH_TIMEOUT_SECONDS` (600). It then asserts that the
plugin checkout in the container (`git rev-parse HEAD`) and the image label
`io.societyprotocol.siwe-auth.ref` both equal the SHA that was built, and prints the
`# version:` line of `plugin.rb`. On any failure the job exits non-zero and prints the last 50 log lines
(credentials masked) plus the exact rollback command, which restores `society-forum:<env>-good`. Other services opt in by setting
`HEALTH_URL_PATH`; without it the script behaves as before.

## 7. Rollback

Every build is tagged `society-forum:<env>-<forum sha12>[-p<plugin sha7>]` (the newest 5 are kept).
Two more tags are the rollback targets, and they move **only after a deploy has passed its checks**:

- `society-forum:<env>-good`: the last release whose container passed the health check and the
  plugin assertion (or, for a service without a health check, whose `docker compose up` succeeded).
- `society-forum:<env>-prev`: the `-good` before that one.

On success the job first tags the old `-good` as `-prev`, then tags the new image as `-good`.
A failed build, a failed `compose up` or a failed health check never touches either tag, so
`-good` is the release to return to even after several failed attempts in a row. A re-run of the
build that is already `-good` leaves `-prev` alone. Pruning of the old SHA tags skips anything that
is `-good`, `-prev`, the current `society-forum:<env>` or used by a running container.
`society-forum:<env>-good` was created by hand on the box from the image running when this
pipeline was introduced, so the first deploy finds it (if `-good` is missing the failure
output says so and the first healthy deploy creates it).

```bash
# on the box, prod shown; for staging use staging-forum / society-forum:staging
docker image ls society-forum
docker tag society-forum:prod-good society-forum:prod
cd /opt/society && docker compose -f apps.yml up -d --no-deps --force-recreate prod-forum
```

**Rolling back a plugin pin:** if the bad release was a plugin commit chosen with `plugin_sha`,
rolling back by re-running with the old SHA only lasts until the next push; commit the old SHA
to `.plugin-pin` too (section 5), or use the `-good` image above, which the next push to the branch
will also replace by a fresh build of whatever the branch and pin resolve to.

This is the command a failed deploy prints. Nothing rolls back automatically: a failed prod
health check leaves the broken container running until someone runs it. After the rollback
the live tag is `-good` again; the next healthy deploy advances `-good`/`-prev` as above.

To go further back, use `society-forum:prod-prev` or `docker tag society-forum:prod-<sha> society-forum:prod`.
If the failed release applied Discourse migrations, the old image may not run on the
migrated schema: stop the forum and restore the pre-deploy dump
(`pg_restore --clean --if-exists -U discourse -d discourse` inside the Postgres container).
That loses everything written since the dump.

## 9. Never use the admin "Upgrade" button in production

If `docker_manager` is installed, its Upgrade page (`/admin/upgrade`) pulls code and
restarts inside the running container. The change is lost the next time the
container is recreated and it bypasses the pinned image, plugin SHA and backups.
Upgrade only through the flow above. Check whether it is present:
`docker exec society-staging-forum-1 ls /var/www/discourse/plugins | grep -i docker_manager`
(**verify**; if present, consider removing it in the `Dockerfile`).

## 8. Staging smoke checklist

Replace `HOST` (`staging-forum.societyprotocol.io`). Run after every staging deploy.

```bash
HOST=staging-forum.societyprotocol.io
curl -fsS https://$HOST/srv/status; echo                                   # 1. prints: ok
curl -sS -D - -o /dev/null -A 'Mozilla/5.0' -H 'Accept: application/json' \
  https://$HOST/session/csrf | grep -iE '^(HTTP/|set-cookie: _forum_session|x-discourse-route)'
                              # 2. HTTP 200, _forum_session cookie with "secure", 3. x-discourse-route present
curl -fsS "https://$HOST/discourse-siwe/message?eth_account=0x0000000000000000000000000000000000000001&chain_id=11155111" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["message"].splitlines()[0])'
                              # 4. first line starts with: staging-forum.societyprotocol.io wants you to sign in
docker inspect -f '{{index .Config.Labels "io.societyprotocol.siwe-auth.ref"}}' society-staging-forum-1
docker exec society-staging-forum-1 grep -m1 '# version:' /var/www/discourse/plugins/discourse-siwe-auth/plugin.rb
                              # 5. label equals the plugin SHA the job printed; version is the expected one
```

A missing `secure` flag or a domain other than the staging host means the proxy is not
sending `X-Forwarded-Proto: https` or `DISCOURSE_HOSTNAME` is wrong (see `docs/STAGING_ENV.md`).

## 10. Settings ownership

- A plugin setting is shadowed by an env var named `DISCOURSE_` + the upper-cased setting name
  (`siwe_project_id` by `DISCOURSE_SIWE_PROJECT_ID`). A shadowed setting is read-only in the
  admin UI and the env value wins. The env file lives on the box (`/opt/society/env/forum-*.env`),
  so changing one is August's job and needs a container recreate.
- Settings marked `secret: true` in the plugin (`siwe_society_subgraph_token`,
  `siwe_society_badges_rpc_url`) are hidden in the UI, but if set through the UI they are
  stored in the `site_settings` table. Keep them env-only.
- Rule of thumb: env for endpoints, tokens and anything that differs per environment;
  admin UI for what Fritz tunes (group mapping, sync mode, statement, exempt list).
  The values decided for production, and the env var names the prod forum needs, are
  listed in [`docs/PRODUCTION_SETTINGS.md`](PRODUCTION_SETTINGS.md).
- Dump a redacted baseline (run it on staging first; a `rails runner` needs more memory than the
  forum's container limit, so raise it temporarily and restore it: `docker update --memory 2g --memory-swap 4g <container>`):

```bash
docker exec -i -u discourse -w /var/www/discourse society-staging-forum-1 bash -lc \
  'cat > /tmp/settings_baseline.rb && bundle exec rails runner /tmp/settings_baseline.rb' <<'RUBY'
require "json"
redact = /token|secret|key|password|rpc_url/i
secret_names = SiteSetting.secret_settings.map(&:to_s)
shadowed = SiteSetting.shadowed_settings.map(&:to_s).sort
overrides = DB.query("SELECT name, value, data_type FROM site_settings ORDER BY name").map do |r|
  hide = r.name =~ redact || secret_names.include?(r.name)
  { name: r.name, value: hide ? "[REDACTED]" : r.value, data_type: r.data_type }
end
puts JSON.pretty_generate(overrides: overrides, shadowed_by_env: shadowed)
RUBY
```

  Shadowed settings are listed by name only (their values come from env). Commit the output
  to `docs/settings-baseline-<env>.json` only after reading it once for anything sensitive.
  `SiteSetting.shadowed_settings` and `secret_settings` were taken from Discourse's
  `SiteSettingExtension`; they were **not** re-checked against the running 2026.8.0 source.

## 11. Railway leftovers (TODO, not removed)

`fix-nginx.sh` (adds `listen 8080`), `ENV PORT=8080` and `EXPOSE 8080` are Railway-era. They were
kept because earlier diagnostics on the box curl `127.0.0.1:8080` inside the forum container and the
Caddy upstream / `apps.yml` port mapping could not be read. To remove them, first run on the box:
`grep -n -B1 -A4 forum /opt/society/Caddyfile` and
`docker compose -f /opt/society/apps.yml config | grep -n -A12 'forum:'` (mask secrets) and confirm nothing
targets 8080, then delete the three items and the `test_placeholders.py` check for `fix-nginx.sh`.
Also still pointing at Railway hosts: the probes in `.grok/workflows/outpost-infra-health.rhai`
(forum-staging host header and cookie probe). Update them to `staging-forum.societyprotocol.io`.

## 12. One-time setup for August

- GitHub > Settings > Environments: create `production`, add required reviewers (August) and
  restrict its deployment branches to `main`. Until it exists with reviewers, `deploy-prod` runs
  without approval. `staging` is also a named environment now (GitHub creates it on first use);
  it needs no reviewers.
- Optional: a plugin-repo workflow that sends the `plugin-updated` dispatch (section 5).
- Decide whether to enable `POST_DEPLOY_CMD` after reading section 3 "Migrations".

### The environment gate does not protect the prod box until the AWS trust policy is narrowed

The reviewer approval on `production` only gates the `deploy-prod` job. What actually lets a
workflow reach the box is the IAM role `society-github-deploy`, which both deploy jobs assume
through GitHub OIDC and which can run SSM commands on the instance that hosts prod and staging.
A review read its trust policy as accepting any subject under `repo:SocietyProtocol/forum:*` (re-check it in IAM; nothing in this repo defines it). **While
that wildcard stands, anyone who can push a branch or workflow to the forum repo can assume the
role from a job that has no environment, skip the approval, and run commands on the prod box.**
The approval is a process control, not a technical barrier, until the policy is narrowed.

The workflow side is done: `contents: read` at workflow level, `id-token: write` only on
`deploy-staging` and `deploy-prod`, and each of those jobs declares an environment, so their OIDC
subjects are `repo:SocietyProtocol/forum:environment:staging` and
`repo:SocietyProtocol/forum:environment:production`. The AWS change (not made from this repo;
August to do it) is to replace the wildcard `sub` condition with a `StringEquals` on exactly those
two subjects (keep the `aud` of `sts.amazonaws.com`):

```json
"Condition": {
  "StringEquals": {
    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
    "token.actions.githubusercontent.com:sub": [
      "repo:SocietyProtocol/forum:environment:production",
      "repo:SocietyProtocol/forum:environment:staging"
    ]
  }
}
```

Do it only after this workflow has run once on each environment (a push to `staging`, then a
`main` deploy), or the next deploy fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`.
Other repos that assume the same role (web client, subgraph) need their own subjects added.
Staging and prod share one box, so a separate prod role would not stop a staging job from reaching
prod containers; the real separation is the environment's reviewers plus its branch restriction.
