// Retry-or-escalate a FAILED publish of a tagged release.
//
// Loaded by .github/workflows/publish-recovery.yml as a thin shim:
//
//   uses: actions/github-script@<pin>
//   with:
//     script: |
//       const run = require('./scripts/publish-recovery.cjs');
//       await run({ github, context, core });
//
// Why this exists (#109, the v0.1.12 / #107 incident):
// scout-autofix treats `gh release create` as the end of remediation — nothing
// verified that the publish.yml run the tag triggered actually SUCCEEDED. On
// 2026-07-31 the v0.1.12 publish died on a transient `docker login` timeout
// during a Docker Hub wobble; fail-fast cancelled the matrix, push-manifests
// was skipped, and `:latest` kept serving the vulnerable v0.1.11 for THREE DAYS
// while the drift issue's last word read "Remediated". A cut release that never
// published is worse than no release: the durable SLA record says fixed while
// the fix is not live.
//
// Behaviour, keyed on the failed run's attempt number:
//   attempt 1  → re-run the failed jobs once. Every publish failure seen so far
//                has been transient infrastructure (Docker Hub login timeout;
//                proxy.golang.org stream error on v0.1.10), and both cleared on
//                a plain re-run.
//   attempt 2+ → do NOT retry again. Comment on every open `scout-drift` issue
//                (the durable SLA record) and alert Slack, then fail this run so
//                it is red in the Actions tab. Silence is not green.
// The attempt check is also the infinite-loop guard: a re-run completes as
// attempt 2, lands back here, and takes the escalate branch instead.
'use strict';

const { execFileSync } = require('child_process');

const slack = (core, text) => {
  try {
    execFileSync('bash', ['scripts/slack-alert.sh', text], { stdio: 'inherit' });
  } catch (e) {
    core.warning(`slack-alert.sh failed: ${e}`);
  }
};

module.exports = async ({ github, context, core }) => {
  const { owner, repo } = context.repo;
  const wr = context.payload.workflow_run;
  const tag = wr.head_branch;
  const runUrl = wr.html_url;
  const attempt = wr.run_attempt;

  if (attempt < 2) {
    await github.rest.actions.reRunWorkflowFailedJobs({ owner, repo, run_id: wr.id });
    core.info(`Publish of ${tag} failed (attempt ${attempt}); re-ran its failed jobs.`);
    slack(
      core,
      `🔁 *Publish failed — auto-retrying* — \`${tag}\` publish failed (attempt ${attempt}); ` +
        `re-running the failed jobs once. <${runUrl}|View run>`,
    );
    return;
  }

  // Attempt 2+ failed: this is not a transient flake. The images are NOT
  // published — `:latest` still serves the previous release, so whatever this
  // release was remediating is still exposed.
  const body = [
    `### ⚠️ Publish of \`${tag}\` failed again (attempt ${attempt}) — the fix is **not live**`,
    '',
    `The release was cut, but [its publish run](${runUrl}) failed twice, so the images were never pushed.`,
    '`:latest` still serves the previous release and **this issue\'s SLA clock is still running**.',
    '',
    'A single automatic re-run has already been tried and did not clear it, so this needs a human:',
    'diagnose the publish failure, then either re-run it or cut a fresh patch release.',
    '',
    '_Posted by `publish-recovery.yml` (#109)._',
  ].join('\n');

  const open = await github.rest.issues.listForRepo({
    owner, repo, state: 'open', labels: 'scout-drift', per_page: 100,
  });
  for (const issue of open.data) {
    await github.rest.issues.createComment({
      owner, repo, issue_number: issue.number, body,
    });
    core.info(`Commented publish failure on scout-drift issue #${issue.number}`);
  }

  const where = open.data.length
    ? ` Commented on ${open.data.map((i) => `#${i.number}`).join(', ')}.`
    : ' (no open scout-drift issue to annotate).';
  slack(
    core,
    `🔴 *Publish FAILED after retry* — \`${tag}\` did not publish (attempt ${attempt}), so ` +
      `\`:latest\` still serves the previous images and any fix this release carried is NOT live.` +
      `${where} <${runUrl}|View run>`,
  );

  core.setFailed(`Publish of ${tag} failed after an automatic retry; escalated.`);
};
