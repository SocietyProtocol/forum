# Release sequencing: Light Account login and the user rewrite

**Decision needed from August and Ashton: Option A or Option B below.** Do not let a plain
merge decide it.

## The hazard

The prod image builds `discourse-siwe-auth` from its `main` branch
(`PIN_BRANCH: main` in `deploy-aws.yml`). As of this writing `main` does not contain the
Light Account login (`8a4f838`); the plugin's `staging` branch does, together with the rewrite
script `script/rewrite_smart_account_users.rb` (`b5f46c5`). Any prod deploy that picks up a plugin `main` containing
that login, before the rewrite has been applied, makes existing members sign in as their Light
Account `S` instead of their wallet `E`. Discourse matches the SIWE uid exactly, so each of them
gets a new, empty forum user. Merging this repo's `staging` into `main` does not change the plugin
by itself, but it triggers a prod build that resolves whatever plugin `main` is at that moment.

The deploy pipeline does not read this file. Until the choice is made, do not merge the plugin's
`staging` into its `main`, and do not wire a `repository_dispatch` with `env: prod` from the plugin repo.

## Option A: rewrite users first, then ship the plugin to prod

Needed if gating and group sync (which rely on `S` and `E`) ship together with Light Account login.
The plugin README (section "Moving forum users to Light Accounts") describes a `discourse_docker`
launcher flow (`/var/discourse`, `./launcher enter app`, `./launcher rebuild app`). That flow does
not exist on AWS. The equivalent, prod container `society-prod-forum-1`, Postgres container
`society-db-prod-forum-postgres-1` (names **unverified**, see `docs/UPGRADE.md`):

1. **Backup**, both:
   - a full dump as in `docs/UPGRADE.md` section 4, and
   - the plugin's rollback tables:
     ```bash
     docker exec -i society-db-prod-forum-postgres-1 psql -U discourse -d discourse <<'SQL'
     CREATE TABLE siwe_backup_accounts AS SELECT * FROM user_associated_accounts WHERE provider_name = 'siwe';
     CREATE TABLE siwe_backup_fields AS SELECT * FROM user_custom_fields WHERE name IN ('wallet_address', 'siwe_owner_address');
     CREATE TABLE siwe_backup_names AS SELECT id, name FROM users WHERE id IN (SELECT user_id FROM siwe_backup_accounts);
     SQL
     ```
2. **Put the script and its libraries in the container.** The prod image has plugin `main`, which has
   neither. Copy a checkout of the plugin's `staging` branch (the script loads `lib/discourse_siwe/*.rb`
   from its own checkout):
   ```bash
   git clone -b staging https://github.com/SocietyProtocol/discourse-siwe-auth.git /tmp/siwe-staging
   docker cp /tmp/siwe-staging society-prod-forum-1:/tmp/discourse-siwe-auth
   docker exec society-prod-forum-1 chown -R discourse:discourse /tmp/discourse-siwe-auth
   ```
3. **Dry run** and read the table (`rewrite`, `duplicate`, `adopt`, `review`, `contract`). Set
   `SUSPECT_AFTER` to the first deploy of any build with the Light Account login (README step 0), or
   `NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED=1` when applying, if none ever ran on prod. The prod container's
   memory limit may be too low for `rails runner`: raise it temporarily
   (`docker update --memory 2g --memory-swap 4g`) and restore it afterwards.
   ```bash
   docker exec -u discourse -w /var/www/discourse \
     -e RPC_URL=REPLACE_WITH_MAINNET_HTTPS_RPC_URL -e SUSPECT_AFTER=REPLACE_ISO_TIME \
     society-prod-forum-1 bundle exec rails runner /tmp/discourse-siwe-auth/script/rewrite_smart_account_users.rb
   ```
4. **Disable SIWE login** (admin > Settings > "Discourse siwe enabled" off, or
   `rails runner 'SiteSetting.discourse_siwe_enabled = false'`) so nobody signs in between the rewrite and the redeploy.
5. **Apply**: the same command with `-e APPLY=1` (plus `MERGE_DUPLICATES=1` only after a full backup,
   because merges cannot be undone from the backup tables). Re-run the dry run: every row should be
   `already` apart from `review` rows left on purpose.
6. **Redeploy**: merge the plugin `staging` into `main`, then deploy prod (Actions > Deploy to AWS > Run
   workflow > `main`, approve the `production` environment). Confirm the shipped SHA with the smoke
   checklist.
7. **Re-enable SIWE login** and sign in once with a migrated wallet: it must land on the existing user.

Rollback before step 6: disable SIWE login, restore from the backup tables or the dump, and redeploy
the previous plugin commit (workflow input `plugin_sha`).

## Option B: ship gating and sync to prod without Light Account login

Cherry-pick the gating and sync commits onto a branch cut from the plugin's `origin/main`, then deploy
that commit to prod with the workflow input `plugin_sha` (a commit that is not on `main` can be built;
the pipeline fetches it by SHA). Merge the Light Account work later, following Option A at that time.
Check how the cherry-picked sync code resolves `S` versus `E` before choosing this: the plan (F2/F3) says
the new features need Light Account addresses.

## What decides it

Since the new features need the `S`/`E` pair, Option A is probably forced. The plan asks August and
Ashton to confirm, and to confirm who runs the prod rewrite (the migration is August's task).
