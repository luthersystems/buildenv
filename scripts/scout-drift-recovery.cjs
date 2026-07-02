// Auto-close recovered scout-drift issues (the drift watch's recovery path).
//
// Extracted from .github/workflows/scout-drift.yml so the logic lives in a
// real file and the workflow step is a thin shim:
//
//   uses: actions/github-script@<pin>
//   with:
//     script: |
//       const run = require('./scripts/scout-drift-recovery.cjs');
//       await run({ github, context, core });
//
// Runs when the daily scan came back fully clean (drift == '0'): closes any
// open `scout-drift` issue so the loop self-resets (drift opens it, recovery
// closes it), and posts the ✅ all-clear to Slack #alert (best-effort via
// scripts/slack-alert.sh; no-op without SLACK_ALERT_WEBHOOK_URL).
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
  const runUrl = `${context.serverUrl}/${owner}/${repo}/actions/runs/${context.runId}`;
  const open = await github.rest.issues.listForRepo({
    owner, repo, state: 'open', labels: 'scout-drift', per_page: 100,
  });
  if (!open.data.length) { core.info('No open scout-drift issue to close.'); return; }
  for (const issue of open.data) {
    await github.rest.issues.createComment({
      owner, repo, issue_number: issue.number,
      body: `✅ All required images are back at Docker Scout grade A as of the latest \`Scout drift watch\` ([run](${runUrl})). Auto-closing.`,
    });
    await github.rest.issues.update({
      owner, repo, issue_number: issue.number, state: 'closed', state_reason: 'completed',
    });
    slack(core, `✅ *Scout drift resolved* — all required images back at grade A; auto-closed <${issue.html_url}|#${issue.number}>.`);
    core.info(`Closed recovered scout-drift issue #${issue.number}`);
  }
};
