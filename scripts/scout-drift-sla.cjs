// Drift-issue + remediation-SLA state machine for the daily Scout drift watch.
//
// Extracted from .github/workflows/scout-drift.yml so the logic lives in a
// real, lintable, unit-testable file and the workflow step is a thin shim:
//
//   uses: actions/github-script@<pin>
//   with:
//     script: |
//       const run = require('./scripts/scout-drift-sla.cjs');
//       await run({ github, context, core });
//
// Inputs (env):
//   WORST_SEVERITY            'critical' | 'high' | 'none'  (from the scan step)
//   SLACK_ALERT_WEBHOOK_URL   optional — consumed by scripts/slack-alert.sh
// Inputs (files, repo root): summary.md (scan report), .github/scout-sla.json
//
// What it does (unchanged semantics from the in-YAML version, #86):
//   - opens or refreshes the single open `scout-drift` issue with the scan body
//   - starts the SLA clock (sla:critical / sla:high label) when fixable C/H
//     findings appear; escalates sla:at-risk → sla:breached per scout-sla.json
//     (clock measured from issue creation; breach also fails the run)
// New: posts Slack #alert messages at each lifecycle transition, plus a daily
// countdown while a clock is running. Slack alerts are posted INLINE from the
// watch (not an issues:-triggered workflow) because this issue is created with
// the default GITHUB_TOKEN, whose events do NOT trigger other workflows
// (GitHub's anti-recursion guard) — an event-driven alerter would silently
// miss the main event. Delivery is best-effort via scripts/slack-alert.sh
// (no-op without the secret, never throws): the issue + labels stay the
// durable SLA record; Slack is egress only.
'use strict';

const fs = require('fs');
const { execFileSync } = require('child_process');

// Single Slack transport: scripts/slack-alert.sh (handles the unset-secret
// no-op, JSON escaping, timeouts, and never exits non-zero).
const slack = (core, text) => {
  try {
    execFileSync('bash', ['scripts/slack-alert.sh', text], { stdio: 'inherit' });
  } catch (e) {
    core.warning(`slack-alert.sh failed: ${e}`);
  }
};

module.exports = async ({ github, context, core }) => {
  const sla = JSON.parse(fs.readFileSync('.github/scout-sla.json', 'utf8'));
  const worst = process.env.WORST_SEVERITY; // 'critical' | 'high' | 'none'
  const body = fs.readFileSync('summary.md', 'utf8');
  const title = 'Docker Scout: published image(s) dropped below grade A';
  const { owner, repo } = context.repo;

  const ensureLabel = async (name, color, description) => {
    try { await github.rest.issues.createLabel({ owner, repo, name, color, description }); }
    catch (e) { /* already exists */ }
  };
  await ensureLabel('scout-drift', 'b60205', 'A published image fell below Docker Scout grade A');
  await ensureLabel('sla:critical', 'b60205', 'Fixable Critical CVE — 15-day remediation SLA');
  await ensureLabel('sla:high', 'd93f0b', 'Fixable High CVE — 30-day remediation SLA');
  await ensureLabel('sla:at-risk', 'fbca04', 'Remediation SLA deadline approaching');
  await ensureLabel('sla:breached', '000000', 'Remediation SLA deadline passed');

  // Open or refresh the single open scout-drift issue.
  const open = await github.rest.issues.listForRepo({
    owner, repo, state: 'open', labels: 'scout-drift', per_page: 100,
  });
  let issue;
  const isNew = !open.data.length;
  if (!isNew) {
    issue = open.data[0];
    await github.rest.issues.createComment({ owner, repo, issue_number: issue.number, body });
    core.info(`Refreshed existing issue #${issue.number}`);
  } else {
    issue = (await github.rest.issues.create({ owner, repo, title, body, labels: ['scout-drift'] })).data;
    core.info(`Opened issue #${issue.number}`);
  }
  const issueRef = `<${issue.html_url}|#${issue.number}>`;

  const labelsNow = new Set((issue.labels || []).map(l => (typeof l === 'string' ? l : l.name)));

  // No fixable Critical/High behind the drift (e.g. a stale-base-digest policy
  // only): no CVE SLA clock — the autonomous republish handles it. Alert once
  // when the issue opens; daily refreshes stay GitHub-only so a lingering
  // no-clock condition (e.g. a Scout-side evaluation gap) doesn't ping daily.
  if (worst !== 'critical' && worst !== 'high') {
    if (isNew) {
      slack(core, `🟠 *Docker Scout drift* — published buildenv image(s) flagged, but no fixable Critical/High (no SLA clock; the autonomous loop handles it). ${issueRef}`);
    }
    core.info(`Worst fixable severity = ${worst}; no CVE SLA clock.`);
    return;
  }

  const deadlineDays = worst === 'critical' ? sla.critical_days : sla.high_days;
  const buffer = sla.escalate_buffer_days;
  const ageDays = (Date.now() - new Date(issue.created_at).getTime()) / 86400000;
  const remaining = deadlineDays - ageDays;
  const age = Math.floor(ageDays);

  // Clock start = the sla:<sev> label transition. Covers both a brand-new
  // issue with fixable C/H and an existing no-clock issue escalating into one.
  // (The clock is measured from issue creation, matching the label semantics.)
  const sevLabel = worst === 'critical' ? 'sla:critical' : 'sla:high';
  if (!labelsNow.has(sevLabel)) {
    await github.rest.issues.addLabels({ owner, repo, issue_number: issue.number, labels: [sevLabel] });
    const due = new Date(new Date(issue.created_at).getTime() + deadlineDays * 86400000).toISOString().slice(0, 10);
    slack(core, `🔴 *SLA clock started* — fixable *${worst.toUpperCase()}* CVE(s) on published buildenv image(s). Fix must be published by *${due}* (${deadlineDays}-day SLA). ${issueRef}`);
  }

  if (ageDays >= deadlineDays && !labelsNow.has('sla:breached')) {
    await github.rest.issues.addLabels({ owner, repo, issue_number: issue.number, labels: ['sla:breached'] });
    await github.rest.issues.createComment({ owner, repo, issue_number: issue.number,
      body: `🚨 **SLA BREACHED** — this fixable **${worst}** finding has been open ${age} days, past the ${deadlineDays}-day remediation deadline (.github/scout-sla.json). Remediate and ship a release now.` });
    slack(core, `<!channel> 🚨 *SLA BREACHED* — fixable *${worst}* finding open ${age}d, past the ${deadlineDays}-day deadline. Remediate and ship now. ${issueRef}`);
    core.setFailed(`SLA breached on #${issue.number} (${worst}, ${age}d > ${deadlineDays}d)`);
  } else if (remaining <= buffer && !labelsNow.has('sla:at-risk') && !labelsNow.has('sla:breached')) {
    await github.rest.issues.addLabels({ owner, repo, issue_number: issue.number, labels: ['sla:at-risk'] });
    await github.rest.issues.createComment({ owner, repo, issue_number: issue.number,
      body: `⏰ **SLA at risk** — fixable **${worst}** finding open ${age} days; **${Math.ceil(remaining)} day(s) left** of the ${deadlineDays}-day deadline. Approve/merge the fix PR (or cut the release) to stay compliant.` });
    slack(core, `<!here> ⏰ *SLA at risk* — fixable *${worst}* open ${age}d; *${Math.ceil(remaining)} day(s) left* of the ${deadlineDays}-day deadline. Approve/merge the fix PR to stay compliant. ${issueRef}`);
    core.warning(`SLA at risk on #${issue.number} (${worst}, ${Math.ceil(remaining)}d left)`);
  } else {
    // Steady-state day while a clock runs: daily Slack countdown, escalating
    // with the same thresholds the labels use. The label-transition alerts
    // above fire once; these keep the channel current until resolution.
    if (ageDays >= deadlineDays) {
      slack(core, `<!channel> 🚨 *SLA breach ongoing* — fixable *${worst}* open ${age}d (deadline was ${deadlineDays}d). ${issueRef}`);
    } else if (remaining <= buffer) {
      slack(core, `<!here> ⏰ *SLA countdown* — fixable *${worst}*: *${Math.ceil(remaining)} day(s) left* of ${deadlineDays}. ${issueRef}`);
    } else {
      slack(core, `⏳ *SLA countdown* — fixable *${worst}* open ${age}d; ${Math.ceil(remaining)}d left of the ${deadlineDays}-day deadline. ${issueRef}`);
    }
    core.info(`SLA ok on #${issue.number} (${worst}, ${age}d of ${deadlineDays}d)`);
  }
};
