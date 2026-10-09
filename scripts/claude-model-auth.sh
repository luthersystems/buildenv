#!/usr/bin/env bash
# Pick and validate the model auth for claude-code-action (#82).
#
# Used by scout-autofix.yml and release-patch.yml before the agent step. The
# repo variable CLAUDE_MODEL_PROVIDER selects the path:
#
#   unset / "subscription"  -> the Claude subscription token (repo secret
#                              CLAUDE_CODE_OAUTH_TOKEN). The current default.
#   "bedrock"               -> Amazon Bedrock via GitHub OIDC. Needs the repo
#                              variables AWS_ROLE_TO_ASSUME, AWS_REGION and
#                              BEDROCK_MODEL (a Bedrock model or inference
#                              profile ID). No token to rotate, no weekly cap.
#
# Fails the job with an ::error that names each missing setting, so a half-done
# switch never looks like an agent failure. Writes `model=<id>` to
# $GITHUB_OUTPUT for the action's --model flag, and `fallback_args`: the
# --fallback-model flag, or empty when the fallback is unset or equals the
# model (the CLI refuses a fallback that is the same as the model).
#
# Env (from the workflow):
#   CLAUDE_MODEL_PROVIDER, AWS_ROLE_TO_ASSUME, AWS_REGION, BEDROCK_MODEL
#   HAS_OAUTH_TOKEN  "true" if secrets.CLAUDE_CODE_OAUTH_TOKEN is non-empty
#   DIRECT_MODEL     model ID for the subscription path
#   DIRECT_FALLBACK_MODEL   optional fallback for the subscription path
#   BEDROCK_FALLBACK_MODEL  optional repo variable; the Bedrock fallback
#                           (default us.anthropic.claude-sonnet-5-5)
set -euo pipefail

provider="${CLAUDE_MODEL_PROVIDER:-subscription}"
out="${GITHUB_OUTPUT:-/dev/stdout}"
missing=()

case "$provider" in
  subscription)
    [[ "${HAS_OAUTH_TOKEN:-}" == "true" ]] || missing+=("secret CLAUDE_CODE_OAUTH_TOKEN")
    [[ -n "${DIRECT_MODEL:-}" ]] || missing+=("DIRECT_MODEL (workflow env)")
    model="${DIRECT_MODEL:-}"
    fallback="${DIRECT_FALLBACK_MODEL:-}"
    ;;
  bedrock)
    [[ -n "${AWS_ROLE_TO_ASSUME:-}" ]] || missing+=("variable AWS_ROLE_TO_ASSUME")
    [[ -n "${AWS_REGION:-}" ]] || missing+=("variable AWS_REGION")
    [[ -n "${BEDROCK_MODEL:-}" ]] || missing+=("variable BEDROCK_MODEL")
    model="${BEDROCK_MODEL:-}"
    fallback="${BEDROCK_FALLBACK_MODEL:-us.anthropic.claude-sonnet-5-5}"
    ;;
  *)
    echo "::error::CLAUDE_MODEL_PROVIDER='${provider}' is not valid. Use 'bedrock', or leave it unset for the subscription token."
    exit 1
    ;;
esac

if ((${#missing[@]})); then
  echo "::error::Claude model auth '${provider}' is not configured. Missing: $(IFS=,; echo "${missing[*]}" | sed 's/,/, /g'). Set them in Settings -> Secrets and variables -> Actions (see #82)."
  exit 1
fi

fallback_args=""
if [[ -n "${fallback}" && "${fallback}" != "${model}" ]]; then
  fallback_args="--fallback-model ${fallback}"
fi

echo "Claude model auth: ${provider} (model ${model}, fallback ${fallback_args:-none})"
echo "model=${model}" >>"$out"
echo "fallback_args=${fallback_args}" >>"$out"
