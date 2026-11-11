# Production settings: the decided configuration for launch day

What `forum.societyprotocol.io` gets when the plugin release with smart accounts,
group sync, gating and the badge mirror ships. Everything here is a decision that is
already made; this page is the list to apply, in order. Nothing in it is applied to
production yet. Staging (`staging-forum.societyprotocol.io`) runs the same decisions
with the Sepolia badge ids (section 10).

Related: `docs/RELEASE_SEQUENCING.md` (why the user transfer comes before the plugin
release), `docs/UPGRADE.md` (deploy, backup, rollback, settings ownership), and the
plugin README (`discourse-siwe-auth`: "Transferring users to smart accounts", "Groups
follow badges", "Token-gated categories", "On-chain badges").

Commands run on the box, in the prod container, as the `discourse` user:

```bash
docker exec -u discourse -w /var/www/discourse society-prod-forum-1 bundle exec rake '<task>'
```

A rake or `rails runner` process needs about 1 GB on top of the running app. If the
container has a memory limit, raise it first and restore it afterwards (`docs/UPGRADE.md`
section 10). Site settings below are set in the admin UI (Admin > Settings, search
`siwe`) so they stay editable; none of them belongs in the env file.

## 1. Order of the day

1. Env vars in place (section 9), wallet sign-ins off, full database backup.
2. Deploy the plugin release and transfer the users to their Light Accounts (plugin
   README, "Production procedure"). Sign-ins back on.
3. Group sync: mapping, bootstrap, `log`, read the report, `enforce` (sections 2 and 3).
4. Gating: one category for `core-team` (section 4).
5. Badge mirror: `log`, read the report, `enforce` (section 5).
6. Presentation: `prioritize_username_in_ux` off (section 7).

**The user transfer (step 2) or group sync in `log` mode must come before the Safe
batch that moves badges from owner wallets to Light Accounts.** A forum user who is
still on the old wallet `E` is only judged on `E` (plus the Light Account, if the pair
is in the plugin's `script/forum-address-map.json`). If the batch moves that member's
badge to `S` while group sync is already in `enforce`, the member is seen without the
badge and leaves the group after two runs (about an hour). After the transfer every
member is judged on `S` and `E` together, so the batch changes nothing for them.

## 2. Badge to group mapping (mainnet)

`siwe_group_badge_mapping`, exactly:

```
13:governors|25:core-team|24:advisors|26:contributors|27:ico-participants|28:moderator-badge|14:vip-bronze|15:vip-silver|16:vip-gold
```

| Badge id | Badge | Group |
| --- | --- | --- |
| 13 | Governor | `governors` |
| 25 | Core Team | `core-team` |
| 24 | Advisor | `advisors` |
| 26 | Contributor / Builder | `contributors` |
| 27 | ICO Participant | `ico-participants` |
| 28 | Moderator | `moderator-badge` |
| 14 / 15 / 16 | Bronze / Silver / Gold VIP | `vip-bronze` / `vip-silver` / `vip-gold` |

Ids are from the badge registry (`docs/docs/technical/badge-ids.md` in the docs repo).
Confirm each id on chain before launch; the forum reads `balanceOfBatch` on the badges
contract and never asks for a name.

Deliberately not mapped:

- **11 (SP DAO) and 12 (Security Council).** They are entity badges, held by the DAO
  account and the Security Council Safe, not by people. A group fed by them would hold
  at most a contract wallet that cannot sign in through the Light Account page.
- **50 (contest winner).** A one-off award, not a role: nothing on the forum is meant
  to be restricted to it. If it is an official badge it is still mirrored as a forum
  badge (section 5).
- **Moderator badge 28 does not feed `moderators`.** `moderators`, `admins`, `staff`
  and `trust_level_*` are automatic Discourse groups that mirror staff flags and trust
  levels; the plugin refuses them as targets (the entry is ignored and logged), because
  a badge would otherwise grant forum privileges. Badge 28 feeds the ordinary group
  `moderator-badge`; who is a forum moderator stays a manual decision.

VIP tiers are exclusive on chain (a Silver holder does not hold Bronze), so they are
three separate groups. A category for "Silver and higher" lists `vip-silver` and
`vip-gold` in its access (section 4).

Rules the value was checked against (plugin `badge_group_mapping.rb`, with the
plugin's own parser): entries are `badge_id:group` separated by `|`; a group name is
1 to 60 characters of letters, digits, `_`, `.` or `-`; the gating config is stricter
(3 to 60 characters, lowercase letters, digits, `-` and `_` only), so use lowercase
everywhere. Discourse itself limits a group name to `max_username_length` (20 by
default); the longest here is `ico-participants` (16).

### The existing group "Governors"

Production already has a group named `Governors` (full name "Governors SP", 2
members, group and member list both public). The plugin looks groups up without
regard to case, so:

- `siwe:groups:bootstrap` prints `governors: exists, left as is`. It does not create a
  second group and does not change the existing one's settings.
- The sync uses that group as it is: it keeps its id, name, members, owners and
  category permissions. Do not rename or recreate it.
- Its two current members are judged like everyone else. Read them in the `log`
  report before enforcing: a member who does not hold badge 13 is removed after two
  runs unless they are staff, a group owner, or listed in
  `siwe_group_sync_exempt_usernames`.
- Its visibility is not touched by bootstrap. Set it by hand to the decision in
  section 8 (Admin > Groups > Governors > Manage > Interaction), or list `governors`
  under `groups:` in the gating config, which sets it on `provision[apply]`.

## 3. Group sync rollout

1. Set `siwe_group_badge_mapping` (section 2). Leave `siwe_group_sync_mode` at `off`.
2. `rake siwe:groups:bootstrap` (dry run), then `rake 'siwe:groups:bootstrap[false]'`.
   New groups are created closed: visible to members, member list for staff only, no
   public join, exit or membership requests. A name that is already a username makes
   the create fail; the dry run does not check that, so read the error and pick
   another name in the mapping if it happens.
3. Set `siwe_group_sync_mode` to `log`. `rake 'siwe:groups:sync[log]'` prints the
   report at once; `rake siwe:groups:report` shows the last scheduled one.
4. **The report must be reviewed** before the next step: every `add` is a real holder,
   every `remove` is someone who really lost or never had the badge, `kept` lists
   staff, owners and exempt users. Compare at least one known holder and one known
   non-holder per group with `balanceOf` on chain.
5. Set `siwe_group_sync_mode` to `enforce`. The scheduled job (every 30 minutes) is the
   only place removals happen; a removal needs two runs in a row
   (`siwe_group_sync_removal_confirmations`), and more than
   `max(3, 20 % of the group)` removals in one run removes nobody. Leave those three
   settings at their defaults.

`siwe_group_sync_exempt_usernames` stays empty unless the report shows someone who
must be grandfathered.

## 4. Gating

Start with one low-risk category: a new one, for `core-team`, at full access. It is
created already restricted, so nothing that is public today changes. `siwe_gating_config`:

```yaml
groups:
  core-team:
    full_name: Core Team
    visibility: members
categories:
  core-team-lounge:
    name: Core Team Lounge
    access:
      core-team: full
```

This text parses without errors in the plugin's `GatingConfig` and plans three actions
on an empty forum (create the group if missing, create the category, set its
permissions to `core-team` full and `staff` full).

1. `rake siwe:gating:provision` (dry run), read the plan.
2. `rake siwe:gating:audit` must print `AUDIT CLEAN`. It fails while a gated group
   has a member without the badge, a non-staff member without a wallet, or no badge
   feeding it.
3. `rake 'siwe:gating:provision[apply]'`, then `rake siwe:gating:provision` again:
   `nothing to change`.

Later categories are added to the same YAML. Restricting a category that is public
today additionally needs `confirm_restrict: true` on that category, after its audit.

## 5. Badge mirror

- **Official badges only.** `siwe_badges_community_allowlist` stays empty. Community
  badge names, texts and images are chosen by their creators; add an id only after
  looking at that badge.
- **Artwork from the badge metadata.** Nothing is uploaded by hand: name, description
  and image come from each badge's metadata through the query gateway. Manual edits to
  a mirrored badge are overwritten.
- **First run silent.** The first pass over each badge grants without notifications
  (the plugin does this by itself); `siwe_badges_notify_on_grant` stays `true` so later
  mints notify.
- **Do not purge system grants.** `rake siwe:badges:purge_system_grants` is not run.
  The built-in Discourse badges may be disabled (`rake 'siwe:badges:disable_system[false]'`
  and `siwe_badges_disable_system` on), which hides them and deletes nothing; members
  keep what they were granted.
- `siwe_badges_app_url`: the Outpost base URL, for the link on each badge page.
- Leave `siwe_badges_revoke_floor` (5), `siwe_badges_revoke_percent` (20) and
  `siwe_badges_revoke_confirmations` (2) at their defaults.

Rollout: `siwe_badges_sync_mode` `log`, read `rake siwe:badges:report` (badges that
would be created, name collisions, who gets what), then `enforce`. A second
`rake 'siwe:badges:sync[enforce]'` right after the first must report no changes.

## 6. Members without a wallet

- **Staff without a wallet are left alone.** Admins and moderators are never removed
  from a group by the sync, and an account with no wallet on record is never evaluated,
  so it gets no mirrored badge and loses nothing.
- **A non-staff member of a gated group who has no wallet must link one or be
  removed.** The sync cannot judge such a member, so they would keep access forever;
  `siwe:gating:audit` lists them (`no wallet on record`) and fails until each one has
  connected a wallet to their account (Preferences > Account > Associated accounts;
  that path was not tested with this plugin, try it on staging first) or has been
  removed from the group by hand. Do not put them on the exempt list.

## 7. Presentation

`prioritize_username_in_ux` is **off** (Admin > Settings > Users). Posts, user cards
and the directory then show the display name (Society name, ENS name or short wallet)
first and the username second. The setting is global.

## 8. Group visibility

For every badge-fed group: the **group is visible to its members** (and staff), the
**member list is visible to staff only**. Membership reveals who holds a badge by
wallet. This is what bootstrap and the gating provision create (`visibility: members`
in the YAML). The existing `Governors` group is public today and has to be changed by
hand or through the gating config (section 2).

## 9. Environment variables the prod forum needs for the plugin

Names only; values live in `/opt/society/env/forum-prod.env` on the box and in the
password manager. Each one shadows the site setting of the same name and makes it
read-only in the admin UI.

| Variable | Needed for | State on prod when this was written |
| --- | --- | --- |
| `DISCOURSE_SIWE_PROJECT_ID` | wallet modal (Reown) | set |
| `DISCOURSE_SIWE_ETHEREUM_RPC_URL` | signature checks, the transfer's contract-wallet check, and badge reads when no badges RPC is set (mainnet) | set |
| `DISCOURSE_SIWE_SOCIETY_SUBGRAPH_URL` | Society names, badge catalog | set |
| `DISCOURSE_SIWE_SOCIETY_SUBGRAPH_TOKEN` | the query gateway's bearer token | set |
| `DISCOURSE_SIWE_SOCIETY_BADGES_CHAIN_ID` | `1`: group sync and the badge mirror refuse to run against another chain. Unset (0) skips that check | **missing, add it** |
| `DISCOURSE_SIWE_SOCIETY_BADGES_CONTRACT` | the badges proxy. The plugin default is the mainnet proxy, so this is optional; set it to pin the address | missing, optional |
| `DISCOURSE_SIWE_SOCIETY_BADGES_RPC_URL` | a separate RPC for badge reads. Optional on prod: empty falls back to `DISCOURSE_SIWE_ETHEREUM_RPC_URL`, which is mainnet already | missing, optional |

Changing the env file needs a container recreate (any deploy does one).

Not env vars, admin UI: `siwe_group_badge_mapping`, `siwe_group_sync_mode`,
`siwe_group_sync_exempt_usernames`, `siwe_gating_config`, `siwe_badges_sync_mode`,
`siwe_badges_community_allowlist`, `siwe_badges_app_url`, `siwe_badges_disable_system`,
`prioritize_username_in_ux`.

## 10. Staging equivalents

Staging reads the Sepolia badges contract. The stand-ins: Governor is badge 69, Core
Team is badge 70, so staging's mapping is `69:governors|70:core-team`; community
badges 74, 75 and 76 are on staging's allowlist for testing. Everything else follows
the sections above.

## 11. GitHub environments and the AWS role

In `SocietyProtocol/forum`:

- **`production`** exists, with required reviewer `zedd3v` and deployment limited to
  the branch `main`. The `deploy-prod` job waits for that approval.
- **`staging`** is limited to the branch `staging` and has no reviewers.

The approval only protects the box once the IAM role `society-github-deploy` stops
accepting every workflow of the repo (`docs/UPGRADE.md` section 12). Its trust policy
lists the forum repo in two subject forms, the plain one and the one with ids:

```
repo:SocietyProtocol/forum:*
repo:SocietyProtocol@*/forum@*:*
```

Narrow these two, and only these two, to the two environments:

```
repo:SocietyProtocol/forum:environment:production
repo:SocietyProtocol/forum:environment:staging
repo:SocietyProtocol@*/forum@*:environment:production
repo:SocietyProtocol@*/forum@*:environment:staging
```

Keep the `StringLike` operator (the id form needs the wildcards), keep the `aud`
condition, and keep the entries of the other repositories (`web3-app-client`,
`web3-app-subgraph`, `docs`, `specs`) exactly as they are: they deploy with the same
role. **Do this only after one successful deploy through each environment** (a staging
deploy, then an approved `main` deploy). Narrowing earlier makes the next deploy fail
with `Not authorized to perform sts:AssumeRoleWithWebIdentity`. Nothing in this repo
changes IAM; it is August's change in the AWS console or CLI.
