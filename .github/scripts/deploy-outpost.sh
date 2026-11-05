#!/usr/bin/env bash
# Upload this repo (or CONTEXT) and rebuild one outpost image on AWS.
#
# This script is copied by several repos (forum, web client, subgraph). Every
# feature below is opt-in through environment variables, so a repo that sets
# only IMAGE / SERVICE keeps the original behaviour (plus the rollback tags
# <IMAGE>-good and <IMAGE>-prev, which only move after a deploy has passed its checks).
#
# Required:  IMAGE  SERVICE  GITHUB_SHA  GITHUB_REPOSITORY
# Optional:
#   CONTEXT, ENVFILE, BUILD_ARGS        as before
#   PIN_REPO_URL, PIN_BRANCH            resolve a branch tip of ANOTHER repo with git
#                                       ls-remote (PIN_BRANCH defaults to main) and
#   PIN_BUILD_ARG                       pass it as --build-arg <PIN_BUILD_ARG>=<sha>
#                                       (required with PIN_REPO_URL). A new SHA also
#                                       busts the Docker layer cache.
#   PIN_SHA                             skip ls-remote, use this full SHA
#   PIN_FILE                            default ${CONTEXT}/.plugin-pin. When PIN_SHA is
#                                       empty and this file exists with a non-empty
#                                       value (one full SHA, surrounding whitespace
#                                       ignored), that SHA is used instead of the branch
#                                       tip. This is what makes a pin survive later
#                                       pushes; PIN_SHA still wins over the file.
#   HEALTH_URL_PATH                     enable the post-deploy check, e.g. /srv/status
#   HEALTH_CONTAINER                    default society-${SERVICE}-1
#   HEALTH_PORT                         default 80 (port inside the container)
#   HEALTH_EXPECT_BODY                  exact response body expected, e.g. ok
#   HEALTH_TIMEOUT_SECONDS              default 600
#   HEALTH_PLUGIN_DIR                   path of a git checkout inside the container;
#                                       its HEAD must equal the pinned SHA and its
#                                       plugin.rb "# version:" line is printed
#   EXPECT_PLUGIN_VERSION               optional exact "# version:" value to assert
#   POST_DEPLOY_CMD                     shell command run with `docker exec` in the new
#                                       container before the health wait, for example
#                                       a database migration. Not set by default.
#   KEEP_IMAGES                         SHA-tagged images to keep per IMAGE (default 5);
#                                       images that are -good, -prev, IMAGE itself or in
#                                       use by a container are never removed
#   DEPLOY_SHA                          commit being deployed (default GITHUB_SHA); set it
#                                       when the workflow checks out a ref other than
#                                       the event commit (workflow/repository dispatch)
#   LOCK_FILE                           host-wide lock taken on the box for the whole
#                                       remote deploy (default /tmp/society-build.lock).
#                                       Every outpost deploy script on the box should
#                                       use the same file so builds never overlap.
#   LOCK_TIMEOUT_SECONDS                how long to wait for that lock (default 1800)
#   COMPOSE_DIR                         directory holding apps.yml (default /opt/society)
#   DRY_RUN=1                           resolve, print the remote script, stop (no AWS)
set -euo pipefail

INSTANCE_ID="${INSTANCE_ID:-i-02994d9540a69390d}"
BUCKET="${BUCKET:-society-migrate-019141478782}"
REGION="${AWS_REGION:-us-east-1}"
: "${IMAGE:?set IMAGE}"
: "${SERVICE:?set SERVICE}"
: "${GITHUB_SHA:?set GITHUB_SHA}"
: "${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY}"

CONTEXT="${CONTEXT:-.}"
ENVFILE="${ENVFILE:-}"
BUILD_ARGS="${BUILD_ARGS:-}"
PIN_REPO_URL="${PIN_REPO_URL:-}"
PIN_BRANCH="${PIN_BRANCH:-main}"
PIN_BUILD_ARG="${PIN_BUILD_ARG:-}"
PIN_SHA="${PIN_SHA:-}"
PIN_FILE="${PIN_FILE:-${CONTEXT}/.plugin-pin}"
HEALTH_URL_PATH="${HEALTH_URL_PATH:-}"
HEALTH_CONTAINER="${HEALTH_CONTAINER:-society-${SERVICE}-1}"
HEALTH_PORT="${HEALTH_PORT:-80}"
HEALTH_EXPECT_BODY="${HEALTH_EXPECT_BODY:-}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-600}"
HEALTH_PLUGIN_DIR="${HEALTH_PLUGIN_DIR:-}"
EXPECT_PLUGIN_VERSION="${EXPECT_PLUGIN_VERSION:-}"
POST_DEPLOY_CMD="${POST_DEPLOY_CMD:-}"
KEEP_IMAGES="${KEEP_IMAGES:-5}"
LOCK_FILE="${LOCK_FILE:-/tmp/society-build.lock}"
LOCK_TIMEOUT_SECONDS="${LOCK_TIMEOUT_SECONDS:-1800}"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/society}"
REMOTE_TMP="${REMOTE_TMP:-/tmp}"
DRY_RUN="${DRY_RUN:-}"
DEPLOY_SHA="${DEPLOY_SHA:-$GITHUB_SHA}"

case "$IMAGE" in *:*) ;; *) IMAGE="${IMAGE}:latest" ;; esac
case "$HEALTH_TIMEOUT_SECONDS$HEALTH_PORT$KEEP_IMAGES$LOCK_TIMEOUT_SECONDS" in
  *[!0-9]*) echo "HEALTH_TIMEOUT_SECONDS, HEALTH_PORT, KEEP_IMAGES and LOCK_TIMEOUT_SECONDS must be integers" >&2; exit 2 ;;
esac

# A full lowercase commit SHA, judged by length and charset. A line-anchored grep
# regex would accept "<40 hex>\nmore" because grep matches line by line.
is_sha40() {
  [ "${#1}" -eq 40 ] || return 1
  case "$1" in
    *[!0123456789abcdef]*) return 1 ;;
  esac
  return 0
}
is_sha40 "$DEPLOY_SHA" || { echo "DEPLOY_SHA / GITHUB_SHA must be a full 40-char lowercase SHA" >&2; exit 2; }

mask_url() { sed -E 's#//[^/@ ]*@#//***@#g'; }

# Pin another repo's commit so the Docker build fetches exactly that SHA.
PIN_TAG_SUFFIX=""
if [ -n "$PIN_REPO_URL" ]; then
  : "${PIN_BUILD_ARG:?set PIN_BUILD_ARG with PIN_REPO_URL}"
  case "$PIN_BUILD_ARG" in
    ""|[0-9]*|*[!A-Za-z0-9_]*) echo "PIN_BUILD_ARG must be a plain identifier" >&2; exit 2 ;;
  esac
  PIN_SOURCE="explicit PIN_SHA"
  if [ -z "$PIN_SHA" ] && [ -f "$PIN_FILE" ]; then
    pin_text="$(cat "$PIN_FILE")"
    # trim leading and trailing whitespace (including CR) but keep inner newlines,
    # so a multi-line file is rejected by the SHA check below instead of merged
    pin_text="${pin_text%"${pin_text##*[![:space:]]}"}"
    pin_text="${pin_text#"${pin_text%%[![:space:]]*}"}"
    if [ -n "$pin_text" ]; then
      is_sha40 "$pin_text" || { echo "${PIN_FILE} must contain exactly one 40-char lowercase commit SHA (or be empty to follow the branch tip)" >&2; exit 1; }
      PIN_SHA="$pin_text"
      PIN_SOURCE="${PIN_FILE}"
    fi
  fi
  if [ -z "$PIN_SHA" ]; then
    PIN_SOURCE="tip of ${PIN_BRANCH}"
    PIN_SHA="$(git ls-remote "$PIN_REPO_URL" "refs/heads/${PIN_BRANCH}" | awk 'NR==1 {print $1}')"
  fi
  if ! is_sha40 "$PIN_SHA"; then
    echo "could not resolve a valid 40-char lowercase SHA for ${PIN_BRANCH} of $(printf '%s' "$PIN_REPO_URL" | mask_url)" >&2
    exit 1
  fi
  echo "pinned ${PIN_BUILD_ARG}=${PIN_SHA} from ${PIN_SOURCE} (branch ${PIN_BRANCH} of $(printf '%s' "$PIN_REPO_URL" | mask_url))"
  BUILD_ARGS="${BUILD_ARGS} --build-arg ${PIN_BUILD_ARG}=${PIN_SHA}"
  PIN_TAG_SUFFIX="-p${PIN_SHA:0:7}"
fi
SHA_TAG="${IMAGE}-${DEPLOY_SHA:0:12}${PIN_TAG_SUFFIX}"

REPO="${GITHUB_REPOSITORY##*/}"
# The run id keeps two runs of the same commit and service (a manual re-run
# overlapping the original) from overwriting each other's S3 objects.
RUN_TAG="$(printf '%s' "${GITHUB_RUN_ID:-local$$}-${GITHUB_RUN_ATTEMPT:-1}" | tr -c 'A-Za-z0-9\n' '-')"
PREFIX="deploy/${REPO}/${DEPLOY_SHA}-${SERVICE}-${RUN_TAG}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# The remote script is a fixed body (quoted heredoc) preceded by a prelude that
# exports each value with printf %q, so no value is ever re-parsed as shell code.
{
  echo "#!/usr/bin/env bash"
  for var in BUCKET PREFIX ENVFILE BUILD_ARGS IMAGE SHA_TAG SERVICE PIN_SHA \
    HEALTH_URL_PATH HEALTH_CONTAINER HEALTH_PORT HEALTH_EXPECT_BODY \
    HEALTH_TIMEOUT_SECONDS HEALTH_PLUGIN_DIR EXPECT_PLUGIN_VERSION \
    POST_DEPLOY_CMD KEEP_IMAGES LOCK_FILE LOCK_TIMEOUT_SECONDS COMPOSE_DIR REMOTE_TMP; do
    printf 'export %s=%q\n' "$var" "${!var}"
  done
  cat <<'REMOTE'
set -eu

# Host-wide lock for the whole deploy. Staging and prod (and the other outpost
# services) share one box, one docker daemon and its CPU/RAM, so two deploys must
# never build or recreate at the same time. The lock is released when this
# script exits (fd 9 closes).
command -v flock >/dev/null 2>&1 || { echo "flock is required on the box (util-linux)" >&2; exit 1; }
exec 9>"${LOCK_FILE}"
echo "waiting up to ${LOCK_TIMEOUT_SECONDS}s for the deploy lock ${LOCK_FILE}"
flock -w "${LOCK_TIMEOUT_SECONDS}" 9 || { echo "DEPLOY_FAILED ${SERVICE}: another deploy held ${LOCK_FILE} for ${LOCK_TIMEOUT_SECONDS}s" >&2; exit 1; }
echo "deploy lock acquired"

# Private working directory per run. Leftovers of killed runs are removed under the lock.
find "${REMOTE_TMP}" -maxdepth 1 -name 'society-build.*' -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
RUN_DIR="$(mktemp -d "${REMOTE_TMP}/society-build.XXXXXX")"
trap 'rm -rf "$RUN_DIR"' EXIT
SRC_DIR="${RUN_DIR}/src"

log_tail() { # last 50 container log lines with obvious credentials masked
  docker logs --tail 50 "$1" 2>&1 | tail -n 50 \
    | sed -E 's#(://[^/@ :]+:)[^@ ]+@#\1***@#g; s#((token|secret|password|passwd|key)[A-Za-z_]*[=:] *)[^ ]+#\1***#Ig' || true
}
fail_with_logs() {
  echo "DEPLOY_FAILED ${SERVICE}: $1" >&2
  echo "--- last 50 log lines of ${HEALTH_CONTAINER} ---" >&2
  log_tail "$HEALTH_CONTAINER" >&2
  if docker image inspect "${IMAGE}-good" >/dev/null 2>&1; then
    echo "${IMAGE}-good and ${IMAGE}-prev were not touched by this deploy." >&2
    echo "Rollback: docker tag ${IMAGE}-good ${IMAGE} && cd ${COMPOSE_DIR} && docker compose -f apps.yml up -d --no-deps --force-recreate ${SERVICE}" >&2
  else
    echo "No ${IMAGE}-good image exists. Pick one with: docker image ls ${IMAGE%:*}" >&2
  fi
  exit 1
}

mkdir -p "${SRC_DIR}"
aws s3 cp "s3://${BUCKET}/${PREFIX}.tgz" "${RUN_DIR}/src.tgz"
tar -xzf "${RUN_DIR}/src.tgz" -C "${SRC_DIR}"
if [ -n "${ENVFILE}" ]; then
  cp "${ENVFILE}" "${SRC_DIR}/.env.production"
fi

# Rollback images are only ever moved AFTER this deploy has proven itself (see
# promote_good below). The build, the recreate and a failed health check never
# touch ${IMAGE}-good or ${IMAGE}-prev, so they always hold the last release that
# passed its checks and the one before it.
if docker image inspect "${IMAGE}-good" >/dev/null 2>&1; then
  echo "rollback image: ${IMAGE}-good -> $(docker image inspect -f '{{.Id}}' "${IMAGE}-good")"
else
  echo "warning: no ${IMAGE}-good image yet; the first healthy deploy creates it"
fi

# shellcheck disable=SC2086
docker build --network=host ${BUILD_ARGS} -t "${IMAGE}" -t "${SHA_TAG}" "${SRC_DIR}" || {
  echo "DEPLOY_FAILED ${SERVICE}: docker build failed. The running container, ${IMAGE}, ${IMAGE}-good and ${IMAGE}-prev were not changed." >&2
  exit 1
}
rm -rf "${RUN_DIR}/src" "${RUN_DIR}/src.tgz"

cd "${COMPOSE_DIR}"
docker compose -f apps.yml up -d --no-deps --force-recreate "${SERVICE}" \
  || fail_with_logs "docker compose up failed"

if [ -n "${POST_DEPLOY_CMD}" ]; then
  echo "waiting for ${HEALTH_CONTAINER} to be running before POST_DEPLOY_CMD"
  for _ in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Running}}' "${HEALTH_CONTAINER}" 2>/dev/null || true)" = "true" ] && break
    sleep 2
  done
  echo "running POST_DEPLOY_CMD in ${HEALTH_CONTAINER}"
  docker exec "${HEALTH_CONTAINER}" bash -lc "${POST_DEPLOY_CMD}" \
    || fail_with_logs "POST_DEPLOY_CMD exited non-zero"
fi

if [ -n "${HEALTH_URL_PATH}" ]; then
  url="http://localhost:${HEALTH_PORT}${HEALTH_URL_PATH}"
  echo "waiting up to ${HEALTH_TIMEOUT_SECONDS}s for ${url} inside ${HEALTH_CONTAINER}"
  waited=0
  healthy=""
  while [ "$waited" -lt "${HEALTH_TIMEOUT_SECONDS}" ]; do
    body="$(docker exec "${HEALTH_CONTAINER}" curl -fsS --max-time 5 \
      -H 'X-Forwarded-Proto: https' "${url}" 2>/dev/null || true)"
    if [ -n "$body" ] && { [ -z "${HEALTH_EXPECT_BODY}" ] || [ "$body" = "${HEALTH_EXPECT_BODY}" ]; }; then
      healthy=1
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done
  [ -n "$healthy" ] || fail_with_logs "no healthy response from ${url} after ${HEALTH_TIMEOUT_SECONDS}s"
  echo "healthy after ~${waited}s: ${url}"

  if [ -n "${HEALTH_PLUGIN_DIR}" ]; then
    version_line="$(docker exec "${HEALTH_CONTAINER}" grep -m1 '# version:' "${HEALTH_PLUGIN_DIR}/plugin.rb" || true)"
    echo "plugin ${version_line:-version line not found}"
    if [ -n "${EXPECT_PLUGIN_VERSION}" ]; then
      [ "${version_line##*: }" = "${EXPECT_PLUGIN_VERSION}" ] \
        || fail_with_logs "plugin version '${version_line##*: }' != expected '${EXPECT_PLUGIN_VERSION}'"
    fi
    if [ -n "${PIN_SHA}" ]; then
      running_sha="$(docker exec -u discourse "${HEALTH_CONTAINER}" git -C "${HEALTH_PLUGIN_DIR}" rev-parse HEAD || true)"
      label_sha="$(docker inspect -f '{{index .Config.Labels "io.societyprotocol.siwe-auth.ref"}}' "${HEALTH_CONTAINER}" || true)"
      echo "plugin sha in container: ${running_sha:-unknown} (label ${label_sha:-none}, wanted ${PIN_SHA})"
      [ "$running_sha" = "${PIN_SHA}" ] \
        || fail_with_logs "plugin SHA in container '${running_sha}' != pinned ${PIN_SHA}"
      [ "$label_sha" = "${PIN_SHA}" ] \
        || fail_with_logs "image label '${label_sha}' != pinned ${PIN_SHA}"
    fi
  fi
fi

# The new container passed every configured check (or compose up succeeded when
# none is configured). Only now move the rollback tags: the old -good becomes
# -prev and the image just deployed becomes -good. A re-run of the already-good
# build leaves -prev alone, so it can never end up equal to -good.
new_id="$(docker image inspect -f '{{.Id}}' "${SHA_TAG}")"
if old_good_id="$(docker image inspect -f '{{.Id}}' "${IMAGE}-good" 2>/dev/null)" && [ "$old_good_id" != "$new_id" ]; then
  docker tag "${IMAGE}-good" "${IMAGE}-prev"
  echo "rollback image: ${IMAGE}-prev -> ${old_good_id}"
fi
docker tag "${SHA_TAG}" "${IMAGE}-good"
echo "rollback image: ${IMAGE}-good -> ${new_id}"

# Drop old SHA tags beyond KEEP_IMAGES (newest first), but never an image that is
# the -good or -prev image, the current ${IMAGE}, or used by a container. A tag is
# skipped when its image id is protected, not just when its name is.
protected="$(
  for ref in "${IMAGE}-good" "${IMAGE}-prev" "${IMAGE}"; do
    docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null || true
  done
  for c in $(docker ps -q 2>/dev/null || true); do
    docker inspect -f '{{.Image}}' "$c" 2>/dev/null || true
  done
)"
repo_part="${IMAGE%:*}"; tag_part="${IMAGE##*:}"
docker image ls "${repo_part}" --format '{{.Tag}}' \
  | grep -E "^${tag_part}-[0-9a-f]{12}(-p[0-9a-f]{7})?\$" \
  | awk -v keep="${KEEP_IMAGES}" 'NR > keep' \
  | while read -r old; do
      old_id="$(docker image inspect -f '{{.Id}}' "${repo_part}:${old}" 2>/dev/null || true)"
      if [ -n "$old_id" ] && printf '%s\n' "$protected" | grep -qxF "$old_id"; then
        echo "keeping ${repo_part}:${old} (rollback or in-use image)"
        continue
      fi
      docker rmi "${repo_part}:${old}" >/dev/null 2>&1 || true
    done || true

echo "DEPLOY_OK ${SERVICE} image=${SHA_TAG}"
REMOTE
} > "$WORKDIR/remote.sh"

if [ -n "$DRY_RUN" ]; then
  echo "--- DRY_RUN: remote script follows, nothing uploaded ---"
  cat "$WORKDIR/remote.sh"
  exit 0
fi

tar --exclude-vcs -C "$CONTEXT" -czf "$WORKDIR/src.tgz" .
aws s3 cp "$WORKDIR/src.tgz" "s3://${BUCKET}/${PREFIX}.tgz" --region "$REGION"
aws s3 cp "$WORKDIR/remote.sh" "s3://${BUCKET}/${PREFIX}.sh" --region "$REGION"

PARAMS="$WORKDIR/params.json"
python3 - "$BUCKET" "$PREFIX" "$WORKDIR/params.json" <<'PY'
import json, sys
bucket, prefix, path = sys.argv[1:]
# A private directory per run: a fixed /tmp path would let two overlapping runs
# overwrite the script one of them is still reading.
cmd = (
    "set -e; d=$(mktemp -d /tmp/society-deploy.XXXXXX); trap 'rm -rf \"$d\"' EXIT; "
    f"aws s3 cp s3://{bucket}/{prefix}.sh \"$d/deploy.sh\"; bash \"$d/deploy.sh\""
)
json.dump({"commands": [cmd]}, open(path, "w"))
PY

COMMAND_ID="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --timeout-seconds 3600 \
  --comment "deploy ${REPO} ${SERVICE}" \
  --parameters "file://${PARAMS}" \
  --query Command.CommandId --output text)"
echo "command ${COMMAND_ID}"

for _ in $(seq 1 200); do
  STATUS="$(aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo Pending)"
  echo "status ${STATUS}"
  case "$STATUS" in
    Success)
      aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query StandardOutputContent --output text
      exit 0
      ;;
    Failed|Cancelled|TimedOut)
      echo "--- stderr ---"
      aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query StandardErrorContent --output text
      echo "--- last stdout lines ---"
      aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query StandardOutputContent --output text | tail -n 60
      exit 1
      ;;
  esac
  sleep 15
done
echo "timed out waiting for ${COMMAND_ID}"
exit 1
