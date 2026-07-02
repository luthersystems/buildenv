#!/usr/bin/env bash
#
# Post a one-line alert to the Slack #alert channel (incoming webhook).
#
# Usage:  slack-alert.sh "message text"      (or pipe the message on stdin)
# Env:    SLACK_ALERT_WEBHOOK_URL — Slack incoming-webhook URL bound to the
#         #alert channel. Unset ⇒ NO-OP (exit 0), so callers can wire alerting
#         before the webhook/secret exists and nothing breaks.
#
# The message supports Slack mrkdwn: <https://url|label>, *bold*, `code`,
# <!here>, <!channel>. JSON escaping is handled here via jq — callers pass
# plain text and never build JSON.
#
# Contract: NEVER fails the caller (always exits 0). Alerting is best-effort
# egress — a Slack outage must not red a security watch whose GitHub issue +
# labels remain the durable record. Delivery failures surface as ::warning in
# the Actions log. The webhook URL is a secret: never echoed, passed only to
# curl.
#
# Manual end-to-end check once the secret exists: `make slack-test`.
set -uo pipefail

msg="${1:-}"
if [ -z "$msg" ] && [ ! -t 0 ]; then
  msg="$(cat)"
fi
if [ -z "$msg" ]; then
  echo "::warning::slack-alert.sh called with an empty message; nothing sent" >&2
  exit 0
fi

if [ -z "${SLACK_ALERT_WEBHOOK_URL:-}" ]; then
  echo "slack-alert: SLACK_ALERT_WEBHOOK_URL not set; skipping. Message was: ${msg}"
  exit 0
fi

payload="$(jq -cn --arg text "$msg" '{text: $text}')" || {
  echo "::warning::slack-alert.sh: failed to build JSON payload; alert not sent" >&2
  exit 0
}

if curl -sfS --max-time 10 --retry 2 -X POST \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    "$SLACK_ALERT_WEBHOOK_URL" >/dev/null; then
  echo "slack-alert: sent"
else
  echo "::warning::slack-alert.sh: POST to Slack failed; alert not delivered. Message was: ${msg}" >&2
fi
exit 0
