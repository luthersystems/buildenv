// Unit tests for scripts/scout-autofix-failure-comment.cjs.
// Run: `make test-scripts` (or `node --test scripts/*.test.cjs`). No dependencies.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const run = require('./scout-autofix-failure-comment.cjs');
const { readTrace, classifyFailure, buildBody, buildSlackText } = run;

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
