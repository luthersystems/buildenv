#!/usr/bin/env bash
#
# Log the runner's docker in to Docker Hub with Docker Hub OIDC, from INSIDE a
# long step that cannot call docker/login-action again. Workflows log in with
# .github/actions/configure-dockerhub (docker/login-action); this script is
# the same token exchange for the one place a step outlives the token: the
# Claude agent in scout-autofix.yml (up to 120 min; the token lives at most
# 60, with no refresh, and a stale one fails even public pulls with 401).
#
# Exchange (as docker/login-action v4.6.0 src/dockerhub.ts): a GitHub OIDC
# token for audience https://identity.docker.com is traded at
# https://identity.docker.com/oauth/token for a Docker Hub access token.
#
# Env:
#   DOCKERHUB_OIDC_CONNECTIONID   Docker Home OIDC connection ID (default: the shared connection).
#   ACTIONS_ID_TOKEN_REQUEST_URL / ACTIONS_ID_TOKEN_REQUEST_TOKEN
#                                 set by GitHub Actions when the job has
#                                 `permissions: id-token: write` (required).
#   DOCKERHUB_OIDC_USERNAME       Docker org to log in as (default luthersystems).
#   DOCKERHUB_OIDC_EXPIREIN       token lifetime in seconds, 300-3600 (default 3600).
set -euo pipefail

: "${DOCKERHUB_OIDC_CONNECTIONID:=c5a3b4b1-e0dc-4f63-88f4-d71cc0442085}"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?no id-token; the job needs 'permissions: id-token: write'}"
: "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?no id-token; the job needs 'permissions: id-token: write'}"
user="${DOCKERHUB_OIDC_USERNAME:-luthersystems}"
expires="${DOCKERHUB_OIDC_EXPIREIN:-3600}"
identity="https://identity.docker.com"

id_token="$(curl -fsS --retry 3 \
  -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=https%3A%2F%2Fidentity.docker.com" |
  jq -r '.value // empty')"
if [ -z "$id_token" ]; then
  echo "::error title=Docker Hub login::could not get a GitHub OIDC token" >&2
  exit 1
fi

access_token="$(curl -fsS --retry 3 -X POST "${identity}/oauth/token" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  --data-urlencode "subject_token_type=urn:ietf:params:oauth:token-type:id_token" \
  --data-urlencode "subject_token=${id_token}" \
  --data-urlencode "connection_id=${DOCKERHUB_OIDC_CONNECTIONID}" \
  --data-urlencode "expires_in=${expires}" |
  jq -r '.access_token // empty')"
if [ -z "$access_token" ]; then
  echo "::error title=Docker Hub login::Docker Hub OIDC token exchange returned no access_token" >&2
  exit 1
fi
echo "::add-mask::${access_token}"

printf '%s' "$access_token" | docker login --username "$user" --password-stdin
