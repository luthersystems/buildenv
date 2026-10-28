// Unit tests for scripts/scout-autofix-failure-comment.cjs.
// Run: `make test-scripts` (or `node --test scripts/*.test.cjs`). No dependencies.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const run = require('./scout-autofix-failure-comment.cjs');
const { readTrace, classifyFailure, findDeferral, verifyCompleted, buildBody, buildSlackText } = run;

// Trimmed from the real trace of run 35316086178 (2026-09-18), the first of the
// four consecutive 429 failures on #126.
const QUOTA_TRACE = [
  { type: 'system', subtype: 'init', model: 'claude-opus-4-8' },
  {
    type: 'rate_limit_event',
    rate_limit_info: {
      status: 'rejected',
      resetsAt: 1790020800,
      rateLimitType: 'seven_day',
      overageStatus: 'rejected',
      overageDisabledReason: 'org_level_disabled',
    },
  },
  {
    type: 'assistant',
    error: 'rate_limit',
    message: { content: [{ type: 'text', text: "You've hit your weekly limit · resets Sep 21, 8pm (UTC)" }] },
  },
  {
    type: 'result',
    subtype: 'success',
    is_error: true,
    api_error_status: 429,
    num_turns: 1,
    total_cost_usd: 0,
    result: "You've hit your weekly limit · resets Sep 21, 8pm (UTC)",
  },
];

test('classifies the real 2026-09-18 429 trace as quota, with window + reset', () => {
  const f = classifyFailure(QUOTA_TRACE);
  assert.equal(f.kind, 'quota');
  assert.match(f.summary, /seven_day/);
  assert.match(f.summary, /HTTP 429/);
  assert.match(f.summary, /2026-09-21T20:00:00Z/);
  assert.match(f.summary, /org_level_disabled/);
  assert.match(f.humanAction, /#82/);
  // The subscription token is retired (org secret deleted); point at Bedrock.
  assert.doesNotMatch(f.summary + f.humanAction, /CLAUDE_CODE_OAUTH_TOKEN|subscription/);
  assert.match(f.humanAction, /Bedrock/);
});

test('a bare 429 result (no rate_limit_event) is still quota', () => {
  const f = classifyFailure([{ type: 'result', is_error: true, api_error_status: 429, result: 'limit' }]);
  assert.equal(f.kind, 'quota');
});

test('error_max_turns is classified as max_turns', () => {
  const f = classifyFailure([{ type: 'result', subtype: 'error_max_turns', is_error: true, num_turns: 51 }]);
  assert.equal(f.kind, 'max_turns');
  assert.match(f.summary, /51 turns/);
});

test('other API errors keep their status', () => {
  const f = classifyFailure([
    { type: 'result', subtype: 'success', is_error: true, api_error_status: 401, result: 'invalid token' },
  ]);
  assert.equal(f.kind, 'api_error');
  assert.match(f.summary, /HTTP 401/);
  assert.doesNotMatch(f.humanAction, /CLAUDE_CODE_OAUTH_TOKEN/);
  assert.match(f.humanAction, /github-actions-claude-bedrock/);
});

test('non-API agent error', () => {
  const f = classifyFailure([{ type: 'result', subtype: 'error_during_execution', is_error: true }]);
  assert.equal(f.kind, 'agent_error');
});

test('missing/empty trace means the failure was outside the agent', () => {
  assert.equal(classifyFailure(null).kind, 'outside_agent');
  assert.equal(classifyFailure([]).kind, 'outside_agent');
  assert.equal(classifyFailure([{ type: 'result', is_error: false }]).kind, 'outside_agent');
});

test('readTrace handles a JSON array, NDJSON, and a missing file', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'autofix-trace-'));
  const arr = path.join(dir, 'a.json');
  fs.writeFileSync(arr, JSON.stringify(QUOTA_TRACE));
  assert.equal(readTrace(arr).length, QUOTA_TRACE.length);
  const nd = path.join(dir, 'b.json');
  fs.writeFileSync(nd, QUOTA_TRACE.map((m) => JSON.stringify(m)).join('\n') + '\nnot json\n');
  assert.equal(readTrace(nd).length, QUOTA_TRACE.length);
  assert.equal(readTrace(path.join(dir, 'nope.json')), null);
});

test('body reads as a failure, never claims "no fix is in flight", and lists open fix PRs', () => {
  const body = buildBody({
    runUrl: 'https://example/run/1',
    runId: 1,
    failure: classifyFailure(QUOTA_TRACE),
    inflightPRs: [{ number: 127, title: 'fix(scout): bump x/crypto' }],
    slaLabels: ['sla:critical', 'sla:breached'],
  });
  assert.match(body, /FAILED — this needs a human/);
  assert.doesNotMatch(body, /no fix is in flight/i);
  assert.match(body, /#127/);
  assert.match(body, /`sla:breached`/);
  assert.match(body, /unhandled/);
  assert.match(body, /scout-autofix-trace-1/);
});

test('body says so explicitly when no automation PR is open', () => {
  const body = buildBody({
    runUrl: 'u',
    runId: 2,
    failure: classifyFailure(null),
    inflightPRs: [],
    slaLabels: [],
  });
  assert.match(body, /no open automation fix PR/);
  assert.doesNotMatch(body, /SLA labels/);
});

test('slack text carries the cause and the issue link', () => {
  const t = buildSlackText({
    runUrl: 'https://example/run/1',
    failure: classifyFailure(QUOTA_TRACE),
    issue: { number: 126, html_url: 'https://example/issues/126' },
  });
  assert.match(t, /FAILED/);
  assert.match(t, /#126/);
  assert.match(t, /seven_day/);
  assert.match(t, /Needs a human/);
});

// End-to-end through the github-script entrypoint with a fake client.
function fakeEnv({ issues = [], prs = [], failList = false } = {}) {
  const calls = { comments: [], outputs: {}, warnings: [] };
  const github = {
    rest: {
      issues: {
        listForRepo: async () => {
          if (failList) throw new Error('boom');
          return { data: issues };
        },
        createComment: async (args) => {
          calls.comments.push(args);
        },
      },
      pulls: { list: async () => ({ data: prs }) },
    },
  };
  const context = { repo: { owner: 'o', repo: 'r' }, serverUrl: 'https://gh', runId: 42 };
  const core = {
    info: () => {},
    warning: (m) => calls.warnings.push(m),
    setOutput: (k, v) => {
      calls.outputs[k] = v;
    },
  };
  return { github, context, core, calls };
}

test('entrypoint: comments on the open scout-drift issue with the parsed cause', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'autofix-run-'));
  fs.writeFileSync(path.join(dir, 'claude-execution-output.json'), JSON.stringify(QUOTA_TRACE));
  const prev = process.env.RUNNER_TEMP;
  process.env.RUNNER_TEMP = dir;
  try {
    const env = fakeEnv({
      issues: [{ number: 126, html_url: 'https://gh/o/r/issues/126', labels: [{ name: 'scout-drift' }, { name: 'sla:breached' }] }],
      prs: [
        { number: 127, title: 'fix', user: { login: 'claude[bot]' } },
        { number: 200, title: 'human', user: { login: 'someone' } },
      ],
    });
    await run(env);
    assert.equal(env.calls.comments.length, 1);
    const { issue_number, body } = env.calls.comments[0];
    assert.equal(issue_number, 126);
    assert.match(body, /seven_day/);
    assert.match(body, /#127/);
    assert.doesNotMatch(body, /#200/);
    assert.match(body, /`sla:breached`/);
    assert.match(env.calls.outputs.slack_text, /#126/);
  } finally {
    if (prev === undefined) delete process.env.RUNNER_TEMP;
    else process.env.RUNNER_TEMP = prev;
  }
});

test('entrypoint: never throws, and still emits slack_text, when the API fails', async () => {
  const env = fakeEnv({ failList: true });
  await run(env);
  assert.equal(env.calls.comments.length, 0);
  assert.ok(env.calls.outputs.slack_text);
  assert.equal(env.calls.warnings.length, 1);
});

// Trimmed from the real trace of run 40644785612 (2026-10-28, issue #180). The
// agent started two ~20-minute image builds in the background, armed a
// Monitor, called ScheduleWakeup, and ended its turn with "Nothing is
// published or opened yet ... I'll check back in about 30 minutes". A headless
// `claude -p` run has nobody to wake it: the session ended there, the step
// reported success, and the rebuild that would have cleared the Critical on
// #180 was never cut, nor the fix PR opened, nor a comment posted.
const DEFERRED_TRACE = [
  { type: 'system', subtype: 'init', model: 'us.anthropic.claude-opus-5-5' },
  {
    type: 'assistant',
    message: {
      content: [
        {
          type: 'tool_use',
          name: 'Bash',
          input: {
            command: 'cd images && make PLATFORMS=linux/amd64 DOCKER_BUILDX_OPTS=--load build-godynamic',
            run_in_background: true,
          },
        },
      ],
    },
  },
  {
    type: 'assistant',
    message: { content: [{ type: 'tool_use', name: 'Monitor', input: { description: 'builds finishing' } }] },
  },
  {
    type: 'assistant',
    message: {
      content: [
        { type: 'tool_use', name: 'ScheduleWakeup', input: { delaySeconds: 1800, prompt: 'Continue the scout-fix remediation' } },
      ],
    },
  },
  {
    type: 'result',
    subtype: 'success',
    is_error: false,
    num_turns: 34,
    terminal_reason: 'completed',
    result: "Nothing is published or opened yet. Two local builds are running, and I'll check back in about 30 minutes.",
  },
];

test('findDeferral: the real 2026-10-28 trace deferred work past the end of the run', () => {
  const d = findDeferral(DEFERRED_TRACE);
  assert.ok(d, 'expected a deferral');
  assert.deepEqual(d.tools, ['ScheduleWakeup', 'Monitor', 'Bash(run_in_background)']);
});

test('findDeferral: a run that waits in the foreground is not a deferral', () => {
  const t = [
    {
      type: 'assistant',
      message: { content: [{ type: 'tool_use', name: 'Bash', input: { command: 'make build-godynamic', timeout: 3600000 } }] },
    },
    { type: 'result', subtype: 'success', is_error: false, result: 'Cut v0.1.50 and commented on #180.' },
  ];
  assert.equal(findDeferral(t), null);
  assert.equal(findDeferral(null), null);
  // A background Bash alone is not proof: the agent may have read its result
  // before ending. Only a wakeup, cron or monitor proves it meant to come back.
  const bgOnly = [
    { type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Bash', input: { command: 'make', run_in_background: true } }] } },
  ];
  assert.equal(findDeferral(bgOnly), null);
});

test('classifies a successful-looking run that deferred work as deferred, not outside_agent', () => {
  const f = classifyFailure(DEFERRED_TRACE);
  assert.equal(f.kind, 'deferred');
  assert.match(f.summary, /ScheduleWakeup/);
  assert.match(f.summary, /nothing re-invokes/);
  assert.match(f.humanAction, /scout-fix/);
});

test('verify entrypoint: fails the step on a deferred trace, passes a clean one', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'autofix-verify-'));
  const file = path.join(dir, 'claude-execution-output.json');
  const failed = [];
  const core = { setFailed: (m) => failed.push(m), info: () => {} };

  fs.writeFileSync(file, JSON.stringify(DEFERRED_TRACE));
  verifyCompleted({ core, tracePath: file });
  assert.equal(failed.length, 1);
  assert.match(failed[0], /ended its run with work deferred/);

  fs.writeFileSync(file, JSON.stringify([{ type: 'result', subtype: 'success', is_error: false }]));
  verifyCompleted({ core, tracePath: file });
  assert.equal(failed.length, 1, 'a clean trace must not fail the step');
});
