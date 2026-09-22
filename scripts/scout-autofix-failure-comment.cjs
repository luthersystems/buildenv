// Durable record that the REMEDIATION layer died — and WHY.
//
// scout-autofix alerts Slack when it errors, but Slack is ephemeral and nobody
// re-reads it. The scout-drift issue is the durable SLA record, so every failed
// autofix run posts one comment there (deliberately NOT deduplicated: each
// failed run is a distinct day the SLA clock advanced with nobody re-checking
// the drift, and that repetition is the signal).
//
// History of this failure class:
//   * 2026-08-01..03 — three consecutive 429s (subscription weekly cap), found
//     only because a human happened to look (#109 gap 2).
//   * 2026-08-14..18 — five consecutive `error_max_turns` at the 50-turn cap
//     on #115 while an sla:critical clock ran.
//   * 2026-08-31, 2026-09-18..21 — 429 "You've hit your weekly limit"
//     (`seven_day` window, `overageDisabledReason: org_level_disabled`); the
//     agent died in <1s with $0 spent, four days running, while #126 breached
//     its Critical SLA and a NEW nginx-frontend openssl Critical sat unhandled.
//     The comment this script used to post said "no fix is in flight for this
//     drift" — false (PR #127 was open) AND unhelpful (it didn't say the cause
//     was a quota nobody in the repo can fix, or that the new Critical was
//     never looked at).
//
// So the comment now:
//   1. names the concrete cause, parsed from the agent trace that
//      claude-code-action writes to $RUNNER_TEMP/claude-execution-output.json
//      (the job log hides it): quota/429 with its reset time, max-turns, other
//      API/agent error, or "failed outside the agent";
//   2. says plainly this is a FAILURE that needs a human, and that today's
//      remediation pass did NOT complete — so anything new is unhandled;
//   3. lists automation fix PRs that are genuinely still open (instead of
//      asserting none exist);
//   4. exposes a one-line `slack_text` output so the workflow's Slack alert
//      carries the same cause instead of a generic "may have no fix in flight".
//
// Invoked from .github/workflows/scout-autofix.yml as a thin shim:
//
//   uses: actions/github-script@<sha>
//   with:
//     script: |
//       const run = require('./scripts/scout-autofix-failure-comment.cjs');
//       await run({ github, context, core });
//
// Pure helpers (classifyFailure, buildBody, buildSlackText) are exported for
// scripts/scout-autofix-failure-comment.test.cjs (`make test-scripts`).
'use strict';

const fs = require('fs');
const path = require('path');

const LABEL = 'scout-drift';
const BOT_LOGINS = new Set(['claude[bot]', 'claude']);
const TRACE_FILE = 'claude-execution-output.json';

// Read the stream-json trace claude-code-action saves. It is a JSON array of
// SDK messages; tolerate NDJSON too. Returns null when absent/unreadable (the
// job failed before or outside the agent step).
function readTrace(file) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch {
    return null;
  }
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [parsed];
  } catch {
    const out = [];
    for (const line of raw.split('\n')) {
      const t = line.trim();
      if (!t) continue;
      try {
        out.push(JSON.parse(t));
      } catch {
        /* skip non-JSON lines */
      }
    }
    return out.length ? out : null;
  }
}

const iso = (epochSeconds) =>
  Number.isFinite(epochSeconds) ? new Date(epochSeconds * 1000).toISOString().replace('.000Z', 'Z') : null;

// Classify why the agent step failed. Returns
//   { kind, summary, humanAction }
// kind ∈ 'quota' | 'max_turns' | 'api_error' | 'agent_error' | 'outside_agent'
function classifyFailure(trace) {
  if (!trace || !trace.length) {
    return {
      kind: 'outside_agent',
      summary:
        'the job failed before the agent produced a trace (setup step, runner timeout, or cancellation)',
      humanAction:
        'Read the failed step in the run log; the agent trace artifact is empty or missing for this run.',
    };
  }

  const result = [...trace].reverse().find((m) => m && m.type === 'result') || null;
  const rateEvent = [...trace]
    .reverse()
    .find((m) => m && m.type === 'rate_limit_event' && m.rate_limit_info && m.rate_limit_info.status === 'rejected');
  const rateMsg = trace.find((m) => m && m.type === 'assistant' && m.error === 'rate_limit');

  if (rateEvent || rateMsg || (result && result.api_error_status === 429)) {
    const info = (rateEvent && rateEvent.rate_limit_info) || {};
    const window = info.rateLimitType || 'usage';
    const reset = iso(info.resetsAt);
    const said = (result && result.result) || '';
    const overage = info.overageDisabledReason ? ` (extra usage disabled: \`${info.overageDisabledReason}\`)` : '';
    return {
      kind: 'quota',
      summary:
        `the Claude subscription token hit its \`${window}\` usage limit (HTTP 429)${overage}` +
        (reset ? `, resets ${reset}` : '') +
        ' — the agent never started, $0 spent' +
        (said ? ` ("${said}")` : ''),
      humanAction:
        'Not a code bug — capacity. `CLAUDE_CODE_OAUTH_TOKEN` (op://Reliable-Dev/CLAUDE_CODE_OAUTH_TOKEN) is ONE ' +
        'Claude subscription shared with other Luther automation (release-patch here, release/autofix workflows ' +
        'in other repos), and its cap is exhausted. Until it resets nothing autonomous can remediate: fix by ' +
        'hand now (`/scout-fix`), and restore capacity durably — the Bedrock swap (#82), or a dedicated ' +
        'token / org extra usage for this automation.',
    };
  }

  if (result && result.subtype === 'error_max_turns') {
    return {
      kind: 'max_turns',
      summary: `the agent ran out of turns (\`error_max_turns\` after ${result.num_turns} turns) before finishing`,
      humanAction:
        'Read the trace to see where it stalled; finish the remediation by hand (`/scout-fix`) and consider ' +
        'the `--max-turns` budget in scout-autofix.yml.',
    };
  }

  if (result && result.is_error) {
    const msg = String(result.result || result.subtype || 'unknown error').slice(0, 300);
    if (result.api_error_status) {
      return {
        kind: 'api_error',
        summary: `the model API returned HTTP ${result.api_error_status}: "${msg}"`,
        humanAction:
          'If it is auth (401/403), the `CLAUDE_CODE_OAUTH_TOKEN` repo secret needs rotating; otherwise re-run ' +
          'the workflow. Remediate by hand (`/scout-fix`) if the SLA is close.',
      };
    }
    return {
      kind: 'agent_error',
      summary: `the agent ended in an error: "${msg}"`,
      humanAction: 'Read the trace artifact, then remediate by hand (`/scout-fix`) or re-run the workflow.',
    };
  }

  return {
    kind: 'outside_agent',
    summary: 'the agent finished, but a step outside it failed',
    humanAction: 'Read the failed step in the run log.',
  };
}

function buildBody({ runUrl, runId, failure, inflightPRs, slaLabels }) {
  const lines = [
    '### ❌ Scout autofix FAILED — this needs a human',
    '',
    `**Cause:** ${failure.summary}.`,
    '',
    `Run: ${runUrl}`,
    '',
    "**Automation did not complete today's remediation pass.** Anything that changed since the last",
    'successful autofix comment on this issue — e.g. a newly-disclosed fixable Critical/High — is',
    "**unhandled**, and this issue's SLA clock keeps running.",
  ];
  if (slaLabels && slaLabels.length) {
    lines.push('', `SLA labels on this issue: ${slaLabels.map((l) => `\`${l}\``).join(', ')}.`);
  }
  lines.push('');
  if (inflightPRs && inflightPRs.length) {
    lines.push(
      'Automation fix PRs opened earlier are still open. They are unaffected by this failure but still need a',
      'maintainer to approve any pending workflow runs and review/merge:',
      ...inflightPRs.map((pr) => `- #${pr.number} — ${pr.title}`),
    );
  } else {
    lines.push('There is no open automation fix PR.');
  }
  lines.push(
    '',
    '**What to do:**',
    `1. ${failure.humanAction}`,
    '2. Once the cause is cleared, re-run the `Scout autofix` workflow (workflow_dispatch) rather than waiting',
    "   for tomorrow's drift cycle.",
    '',
    `Agent transcript: the \`scout-autofix-trace-${runId}\` artifact on the run above (the job log hides it).`,
    '',
    '_Posted by `scout-autofix.yml` via `scripts/scout-autofix-failure-comment.cjs`._',
  );
  return lines.join('\n');
}

function buildSlackText({ runUrl, failure, issue }) {
  const where = issue ? ` on <${issue.html_url}|#${issue.number}>` : '';
  return (
    `❌ *Scout autofix FAILED*${where} — ${failure.summary}. ` +
    "Today's remediation pass did NOT complete, so any new finding is unhandled while the SLA clock runs. " +
    `Needs a human. <${runUrl}|View run>`
  );
}

module.exports = async ({ github, context, core }) => {
  const { owner, repo } = context.repo;
  const runUrl = `${context.serverUrl}/${owner}/${repo}/actions/runs/${context.runId}`;

  const tracePath = path.join(process.env.RUNNER_TEMP || '', TRACE_FILE);
  const failure = classifyFailure(readTrace(tracePath));
  core.info(`Autofix failure classified as ${failure.kind}: ${failure.summary}`);

  // Set the Slack text first so the alert step carries the cause even if the
  // GitHub API calls below fail.
  core.setOutput('slack_text', buildSlackText({ runUrl, failure, issue: null }));

  // Never throw from here on: this step runs under if: failure() and its job
  // is already failing. Losing the comment must not mask the real error.
  let issue;
  try {
    const open = await github.rest.issues.listForRepo({ owner, repo, state: 'open', labels: LABEL });
    issue = open.data[0];
  } catch (err) {
    core.warning(`Could not list ${LABEL} issues: ${err.message}`);
    return;
  }
  if (!issue) {
    core.info(`No open ${LABEL} issue to annotate.`);
    return;
  }
  core.setOutput('slack_text', buildSlackText({ runUrl, failure, issue }));

  let inflightPRs = [];
  try {
    const prs = await github.rest.pulls.list({ owner, repo, state: 'open', per_page: 100 });
    inflightPRs = prs.data.filter((pr) => pr.user && BOT_LOGINS.has(pr.user.login));
  } catch (err) {
    core.warning(`Could not list open PRs: ${err.message}`);
  }

  const slaLabels = (issue.labels || [])
    .map((l) => (typeof l === 'string' ? l : l.name))
    .filter((n) => n && n.startsWith('sla:'));

  try {
    await github.rest.issues.createComment({
      owner,
      repo,
      issue_number: issue.number,
      body: buildBody({ runUrl, runId: context.runId, failure, inflightPRs, slaLabels }),
    });
    core.info(`Flagged autofix failure on #${issue.number}.`);
  } catch (err) {
    core.warning(`Could not comment on #${issue.number}: ${err.message}`);
  }
};

module.exports.readTrace = readTrace;
module.exports.classifyFailure = classifyFailure;
module.exports.buildBody = buildBody;
module.exports.buildSlackText = buildSlackText;
