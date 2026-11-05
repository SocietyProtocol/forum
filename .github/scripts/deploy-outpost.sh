#!/usr/bin/env bash
# Upload this repo (or CONTEXT) and rebuild one outpost image on AWS.
#
# This script is copied by several repos (forum, web client, subgraph). Every
# feature below is opt-in through environment variables, so a repo that sets
# only IMAGE / SERVICE keeps the original behaviour (plus the rollback tags).
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
#   KEEP_IMAGES                         SHA-tagged images to keep per IMAGE (default 5)
#   DEPLOY_SHA                          commit being deployed (default GITHUB_SHA); set it
#                                       when the workflow checks out a ref other than
#                                       the event commit (workflow/repository dispatch)
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
HEALTH_URL_PATH="${HEALTH_URL_PATH:-}"
HEALTH_CONTAINER="${HEALTH_CONTAINER:-society-${SERVICE}-1}"
HEALTH_PORT="${HEALTH_PORT:-80}"
HEALTH_EXPECT_BODY="${HEALTH_EXPECT_BODY:-}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-600}"
HEALTH_PLUGIN_DIR="${HEALTH_PLUGIN_DIR:-}"
EXPECT_PLUGIN_VERSION="${EXPECT_PLUGIN_VERSION:-}"
POST_DEPLOY_CMD="${POST_DEPLOY_CMD:-}"
KEEP_IMAGES="${KEEP_IMAGES:-5}"
DRY_RUN="${DRY_RUN:-}"
DEPLOY_SHA="${DEPLOY_SHA:-$GITHUB_SHA}"

case "$IMAGE" in *:*) ;; *) IMAGE="${IMAGE}:latest" ;; esac
case "$HEALTH_TIMEOUT_SECONDS$HEALTH_PORT$KEEP_IMAGES" in
  *[!0-9]*) echo "HEALTH_TIMEOUT_SECONDS, HEALTH_PORT and KEEP_IMAGES must be integers" >&2; exit 2 ;;
esac

mask_url() { sed -E 's#//[^/@ ]*@#//***@#g'; }

# Pin another repo's commit so the Docker build fetches exactly that SHA.
PIN_TAG_SUFFIX=""
if [ -n "$PIN_REPO_URL" ]; then
  : "${PIN_BUILD_ARG:?set PIN_BUILD_ARG with PIN_REPO_URL}"
  if [ -z "$PIN_SHA" ]; then
    PIN_SHA="$(git ls-remote "$PIN_REPO_URL" "refs/heads/${PIN_BRANCH}" | awk 'NR==1 {print $1}')"
  fi
  if ! printf '%s' "$PIN_SHA" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "could not resolve a 40-char SHA for ${PIN_BRANCH} of $(printf '%s' "$PIN_REPO_URL" | mask_url)" >&2
    exit 1
  fi
  echo "pinned ${PIN_BUILD_ARG}=${PIN_SHA} (branch ${PIN_BRANCH} of $(printf '%s' "$PIN_REPO_URL" | mask_url))"
  BUILD_ARGS="${BUILD_ARGS} --build-arg ${PIN_BUILD_ARG}=${PIN_SHA}"
  PIN_TAG_SUFFIX="-p${PIN_SHA:0:7}"
fi
SHA_TAG="${IMAGE}-${DEPLOY_SHA:0:12}${PIN_TAG_SUFFIX}"

REPO="${GITHUB_REPOSITORY##*/}"
PREFIX="deploy/${REPO}/${DEPLOY_SHA}-${SERVICE}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# The remote script is a fixed body (quoted heredoc) preceded by a prelude that
# exports each value with printf %q, so no value is ever re-parsed as shell code.
{
  echo "#!/usr/bin/env bash"
  for var in BUCKET PREFIX ENVFILE BUILD_ARGS IMAGE SHA_TAG SERVICE PIN_SHA \
    HEALTH_URL_PATH HEALTH_CONTAINER HEALTH_PORT HEALTH_EXPECT_BODY \
    HEALTH_TIMEOUT_SECONDS HEALTH_PLUGIN_DIR EXPECT_PLUGIN_VERSION \
    POST_DEPLOY_CMD KEEP_IMAGES; do
    printf 'export %s=%q\n' "$var" "${!var}"
  done
  cat <<'REMOTE'
set -eu

log_tail() { # last 50 container log lines with obvious credentials masked
  docker logs --tail 50 "$1" 2>&1 | tail -n 50 \
    | sed -E 's#(://[^/@ :]+:)[^@ ]+@#\1***@#g; s#((token|secret|password|passwd|key)[A-Za-z_]*[=:] *)[^ ]+#\1***#Ig' || true
}
fail_with_logs() {
  echo "DEPLOY_FAILED ${SERVICE}: $1" >&2
  echo "--- last 50 log lines of ${HEALTH_CONTAINER} ---" >&2
  log_tail "$HEALTH_CONTAINER" >&2
  echo "Rollback: docker tag ${IMAGE}-prev ${IMAGE} && cd /opt/society && docker compose -f apps.yml up -d --no-deps --force-recreate ${SERVICE}" >&2
  exit 1
}

rm -rf /tmp/society-src
mkdir -p /tmp/society-src
aws s3 cp "s3://${BUCKET}/${PREFIX}.tgz" /tmp/society-src.tgz
tar -xzf /tmp/society-src.tgz -C /tmp/society-src
if [ -n "${ENVFILE}" ]; then
  cp "${ENVFILE}" /tmp/society-src/.env.production
fi

# Keep a rollback image: the current tag is about to be overwritten by the build.
# Skip when the current image already is this exact build (a re-run), so a re-run
# cannot overwrite the good -prev image with the same failing image.
if docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  cur_id="$(docker image inspect -f '{{.Id}}' "${IMAGE}")"
  same_id="$(docker image inspect -f '{{.Id}}' "${SHA_TAG}" 2>/dev/null || true)"
  if [ "$cur_id" != "$same_id" ]; then
    docker tag "${IMAGE}" "${IMAGE}-prev"
    echo "rollback image: ${IMAGE}-prev -> ${cur_id}"
  else
    echo "current ${IMAGE} is already ${SHA_TAG}; leaving ${IMAGE}-prev untouched"
  fi
else
  echo "no existing ${IMAGE}; no rollback image to keep"
fi

# shellcheck disable=SC2086
docker build --network=host ${BUILD_ARGS} -t "${IMAGE}" -t "${SHA_TAG}" /tmp/society-src
rm -rf /tmp/society-src /tmp/society-src.tgz

# Drop old SHA tags beyond KEEP_IMAGES (newest first). Untagging never removes an
# image another tag (including -prev) or a running container still uses.
repo_part="${IMAGE%:*}"; tag_part="${IMAGE##*:}"
docker image ls "${repo_part}" --format '{{.Tag}}' \
  | grep -E "^${tag_part}-[0-9a-f]{12}(-p[0-9a-f]{7})?\$" \
  | awk -v keep="${KEEP_IMAGES}" 'NR > keep' \
  | while read -r old; do docker rmi "${repo_part}:${old}" >/dev/null 2>&1 || true; done || true

cd /opt/society
docker compose -f apps.yml up -d --no-deps --force-recreate "${SERVICE}"

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
cmd = f"aws s3 cp s3://{bucket}/{prefix}.sh /tmp/society-deploy.sh && bash /tmp/society-deploy.sh && rm -f /tmp/society-deploy.sh"
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
