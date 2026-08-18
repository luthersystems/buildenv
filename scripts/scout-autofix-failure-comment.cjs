// Durable record that the REMEDIATION layer died.
//
// scout-autofix already alerts Slack when it errors, but Slack is ephemeral and
// nobody re-reads it. The scout-drift issue is the durable SLA record, and until
// now a dead autofix left NO trace there at all: a reader saw only the daily
// "still drifting" refreshes, with nothing to say a fix had been attempted and
// failed.
//
// That gap has now bitten twice. 2026-08-01..03: three consecutive 429s
// (subscription weekly cap), found only because a human happened to look
// (#109 gap 2). 2026-08-14..18: five consecutive `error_max_turns` failures at
// the 50-turn cap on issue #115, while an sla:critical clock ran, ~$5 and 24min
// burned per run, nothing shipped, and the issue said nothing about it.
//
// Posts one comment per failure onto the open scout-drift issue. Deliberately
// NOT deduplicated: each failed run is a distinct day the SLA clock advanced
// with no fix in flight, and that repetition is the signal.
//
// Invoked from .github/workflows/scout-autofix.yml as a thin shim:
//
//   uses: actions/github-script@<sha>
//   with:
//     script: |
//       const run = require('./scripts/scout-autofix-failure-comment.cjs');
//       await run({ github, context, core });

const LABEL = 'scout-drift';

module.exports = async ({ github, context, core }) => {
  const { owner, repo } = context.repo;
  const runUrl = `${context.serverUrl}/${owner}/${repo}/actions/runs/${context.runId}`;

  const body = [
    '⚠️ **Scout autofix failed — no fix is in flight for this drift.**',
    '',
    `Run: ${runUrl}`,
    '',
    'The remediation layer errored rather than producing a fix, so this issue is',
    'still open with its SLA clock running and nothing queued to resolve it.',
    '',
    'A human needs to either remediate by hand (`/scout-fix`) or repair the',
    'autofix job. Check the `scout-autofix-trace-*` artifact on the run above for',
    'the agent transcript; the job log itself hides it.',
  ].join('\n');

  let open;
  try {
    open = await github.rest.issues.listForRepo({
      owner,
      repo,
      state: 'open',
      labels: LABEL,
    });
  } catch (err) {
    // Never fail the caller: this step runs under if: failure() and its whole
    // job is already failing. Losing the comment must not mask the real error.
    core.warning(`Could not list ${LABEL} issues: ${err.message}`);
    return;
  }

  const issue = open.data[0];
  if (!issue) {
    core.info(`No open ${LABEL} issue to annotate; autofix may have failed for an unrelated reason.`);
    return;
  }

  try {
    await github.rest.issues.createComment({
      owner,
      repo,
      issue_number: issue.number,
      body,
    });
    core.info(`Flagged autofix failure on #${issue.number}.`);
  } catch (err) {
    core.warning(`Could not comment on #${issue.number}: ${err.message}`);
  }
};
