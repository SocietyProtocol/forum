#!/usr/bin/env bash
# Decide what a workflow run deploys. Reads the event data from environment
# variables and writes target / checkout_ref / plugin_sha to $GITHUB_OUTPUT.
#
# Everything arriving from workflow_dispatch inputs or a repository_dispatch
# payload is untrusted text. It is validated here, and only validated values (or
# constants) are ever written to $GITHUB_OUTPUT, so a value containing a newline
# cannot inject extra output lines.
#
# Env: EVENT PUSH_SHA REF_NAME INPUT_REF INPUT_SHA PAYLOAD_ENV PAYLOAD_SHA GITHUB_OUTPUT
set -eu

# A full lowercase commit SHA. Length plus charset, not a line-anchored regex: grep
# matches per line, so "<40 hex>\nextra" would pass a grep -E '^[0-9a-f]{40}$'.
is_sha40() {
  [ "${#1}" -eq 40 ] || return 1
  case "$1" in
    *[!0123456789abcdef]*) return 1 ;;
  esac
  return 0
}

plugin_sha=""
case "${EVENT:-}" in
  push)
    branch="${REF_NAME:-}"
    is_sha40 "${PUSH_SHA:-}" || { echo "push sha is not a full lowercase SHA" >&2; exit 1; }
    checkout_ref="$PUSH_SHA"
    ;;
  workflow_dispatch)
    branch="${INPUT_REF:-}"
    checkout_ref="$branch"
    plugin_sha="${INPUT_SHA:-}"
    ;;
  repository_dispatch)
    case "${PAYLOAD_ENV:-}" in
      staging) branch=staging ;;
      prod) branch=main ;;
      *) echo "client_payload.env must be exactly staging or prod" >&2; exit 1 ;;
    esac
    checkout_ref="$branch"
    plugin_sha="${PAYLOAD_SHA:-}"
    ;;
  *) echo "unsupported event" >&2; exit 1 ;;
esac

# The branch is matched exactly; the constants below, not the raw input, are what
# gets written out.
case "$branch" in
  main) target=prod; branch=main ;;
  staging) target=staging; branch=staging ;;
  *) echo "ref must be exactly main or staging" >&2; exit 1 ;;
esac
if [ "${EVENT}" != push ]; then
  checkout_ref="$branch"
fi

if [ -n "$plugin_sha" ] && ! is_sha40 "$plugin_sha"; then
  echo "plugin sha must be exactly 40 lowercase hex characters" >&2
  exit 1
fi

{
  printf 'target=%s\n' "$target"
  printf 'checkout_ref=%s\n' "$checkout_ref"
  printf 'plugin_sha=%s\n' "$plugin_sha"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
