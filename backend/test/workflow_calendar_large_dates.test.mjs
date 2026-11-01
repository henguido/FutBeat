import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Turn 244: the real step script under pwsh, every HTTP call mocked (no GOAL, no Supabase).
const workflow = await readFile(new URL('../../.github/workflows/global-fixtures.yml', import.meta.url), 'utf8');
const lines = workflow.split(/\r?\n/);
const start = lines.findIndex((l) => /^\s+run: \|\s*$/.test(l));
const indent = ' '.repeat(lines[start].indexOf('run:') + 2);
const body = [];
for (const l of lines.slice(start + 1)) {
  if (l.trim() !== '' && !l.startsWith(indent)) break;
  body.push(l.slice(indent.length));
}
const pwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'], { encoding: 'utf8' });
const skip = pwsh.status === 0 ? false : 'pwsh not available';

// MOCK_PAGES: date=pages. MOCK_TIMEOUT: date=calls that answer 57014. MOCK_STATUS_500: plain failure.
const mock = String.raw`
$script:mockRemaining = [int]$env:MOCK_START_REMAINING
$script:calls = @{}
$script:ingests = 0
function Parse-Map([string]$raw) {
  $map = @{}
  foreach ($pair in @($raw -split ',' | Where-Object { $_ })) { $kv = $pair -split '='; $map[$kv[0]] = [int]$kv[1] }
  return $map
}
$script:pages = Parse-Map $env:MOCK_PAGES
$script:timeouts = Parse-Map $env:MOCK_TIMEOUT
function Start-Sleep { param([int]$Seconds) }
function Invoke-RestMethod {
  param([string]$Uri, [string]$Method, $Headers, [string]$ContentType, [string]$Body, [int]$TimeoutSec, [string]$ResponseHeadersVariable)
  if ($Uri -like '*audience=futbeat-global-ingest*') { return [pscustomobject]@{ value = 'oidc-token' } }
  if ($Uri -like 'https://api.goal-api.com/*') {
    $script:mockRemaining -= 1
    Write-Host "MOCK_GOAL $Uri"
    Set-Variable -Name $ResponseHeadersVariable -Value @{ 'X-RateLimit-Remaining' = @([string]$script:mockRemaining) } -Scope 1
    $date = ($Uri -split '/date/')[1].Split('?')[0]
    $offset = [int]($Uri -split 'offset=')[1]
    $total = if ($script:pages.ContainsKey($date)) { [int]$script:pages[$date] } else { 1 }
    $data = @(1, 2 | ForEach-Object { [pscustomobject]@{ apiId = "$date-$offset-$_"; kickoffUtc = "$($date)T18:00:00Z" } })
    return [pscustomobject]@{ success = $true; data = $data; pagination = [pscustomobject]@{ hasMore = (($offset / 100 + 1) -lt $total); limit = 100 } }
  }
  $p = $Body | ConvertFrom-Json
  if ($p.action -eq 'global-quota-plan') {
    return [pscustomobject]@{ status = 'ok'; plan = [pscustomobject]@{ providerRemaining = $script:mockRemaining; reason = 'ok' } }
  }
  if ($p.action -eq 'calendar-plan') {
    Write-Host "MOCK_PLAN_CALL from=$($p.fromDate) to=$($p.toDate) limit=$($p.limit)"
    $dates = if ($p.requestedOnly -and $env:MOCK_PLAN) { @($env:MOCK_PLAN -split ',') } else { @() }
    return [pscustomobject]@{ dates = $dates }
  }
  if ($p.mode -eq 'hot') { return [pscustomobject]@{ accepted = @($p.events).Count } }
  if ($p.mode -eq 'calendar') {
    $date = @($p.dates)[0]
    Write-Host "MOCK_CAL_CALL date=$date timeout=$TimeoutSec events=$(@($p.events).Count) count=$(@($p.coverage)[0].count)"
    $script:ingests += 1
    if ($env:MOCK_SKIP_AFTER -and $script:ingests -gt [int]$env:MOCK_SKIP_AFTER) {
      return [pscustomobject]@{ status = 'skipped'; reason = 'daily_limit' }
    }
    $script:calls[$date] = [int]$script:calls[$date] + 1
    if ($script:timeouts.ContainsKey($date) -and $script:calls[$date] -le [int]$script:timeouts[$date]) {
      throw 'Response status code does not indicate success: 502 (Bad Gateway). {"code":"57014"}'
    }
    if ($env:MOCK_STATUS_500 -eq $date) { throw 'Response status code does not indicate success: 500' }
    Write-Host "MOCK_CAL dates=$date"
    return [pscustomobject]@{ status = 'ok'; accepted = @($p.events).Count }
  }
  throw "unexpected call $Uri $Body"
}
`;

async function run(env) {
  const dir = await mkdtemp(join(tmpdir(), 'futbeat-wf-244-'));
  try {
    const file = join(dir, 'step.ps1');
    await writeFile(file, mock + '\n' + body.join('\n'), 'utf8');
    const r = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `. '${file}'`], {
      encoding: 'utf8', timeout: 120000,
      env: { ...process.env, GOAL_API_KEY: 'test-key', ACTIONS_ID_TOKEN_REQUEST_URL: 'https://oidc.invalid/token?x=1', ACTIONS_ID_TOKEN_REQUEST_TOKEN: 'test-token',
        GITHUB_EVENT_NAME: 'schedule', MOCK_START_REMAINING: '1000', MOCK_PLAN: '', MOCK_PAGES: '', MOCK_TIMEOUT: '', MOCK_SKIP_AFTER: '', MOCK_STATUS_500: '', ...env },
    });
    const out = `${r.stdout}\n${r.stderr}`;
    return { code: r.status, out,
      goal: [...out.matchAll(/MOCK_GOAL \S+\/date\/(\S+?)\?/g)].map((m) => m[1]),
      calCalls: [...out.matchAll(/MOCK_CAL_CALL date=(\S+) timeout=(\d+) events=(\d+) count=(\d+)/g)].map((m) => ({ date: m[1], timeout: Number(m[2]), events: Number(m[3]), count: Number(m[4]) })),
      stored: [...out.matchAll(/MOCK_CAL dates=(\S+)/g)].map((m) => m[1]) };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

const calendarGoal = (r, date) => r.goal.filter((d) => d === date).length;

test('57014 repeats the same fixtures once and pays no GOAL page', { skip }, async () => {
  const r = await run({ MOCK_PLAN: '2027-03-07,2027-03-08', MOCK_PAGES: '2027-03-07=16', MOCK_TIMEOUT: '2027-03-07=1' });
  assert.equal(calendarGoal(r, '2027-03-07'), 16);
  const attempts = r.calCalls.filter((c) => c.date === '2027-03-07');
  assert.equal(attempts.length, 2);
  assert.deepEqual(attempts[0], attempts[1], 'identical payload');
  assert.equal(attempts[0].events, 32, 'all pages of the date');
  assert.deepEqual(r.stored, ['2027-03-07', '2027-03-08']);
  assert.match(r.out, /CALENDAR_INGEST_RETRY date=2027-03-07 reason=57014/);
  assert.equal(r.code, 0);
});

test('a second 57014 gives up on the date and the run goes on', { skip }, async () => {
  const r = await run({ MOCK_PLAN: '2027-03-07,2027-03-08', MOCK_TIMEOUT: '2027-03-07=2' });
  assert.equal(r.calCalls.filter((c) => c.date === '2027-03-07').length, 2, 'no third attempt');
  assert.deepEqual(r.stored, ['2027-03-08']);
  assert.equal(r.code, 1);
});

test('any other failure is not repeated', { skip }, async () => {
  const r = await run({ MOCK_PLAN: '2027-03-07,2027-03-08', MOCK_STATUS_500: '2027-03-07' });
  assert.equal(r.calCalls.filter((c) => c.date === '2027-03-07').length, 1);
  assert.doesNotMatch(r.out, /CALENDAR_INGEST_RETRY/);
});

test('a long date that reaches the reserve is dropped whole: nothing partial is stored', { skip }, async () => {
  const r = await run({ MOCK_START_REMAINING: '420', MOCK_PLAN: '2027-03-07,2027-03-08', MOCK_PAGES: '2027-03-07=80' });
  // 420 minus 4 hot pages, 66 pages to the 350 reserve.
  assert.equal(calendarGoal(r, '2027-03-08'), 0, 'stops there');
  assert.deepEqual(r.calCalls, [], 'no ingest of a partial date');
  assert.match(r.out, /CALENDAR_DATE_PARTIAL date=2027-03-07/);
  assert.ok(Math.min(...[...r.out.matchAll(/remaining=(\d+) requests/g)].map((m) => Number(m[1]))) >= 350, 'reserve intact');
  assert.equal(r.code, 0);
});

test('a date of 30 pages with quota is ingested whole, inside the longer call limit', { skip }, async () => {
  const r = await run({ MOCK_PLAN: '2027-03-07', MOCK_PAGES: '2027-03-07=30' });
  assert.equal(r.calCalls[0].events, 60);
  assert.equal(r.calCalls[0].count, 60);
  assert.equal(r.calCalls[0].timeout, 140);
});

test('skipped stops at once: no later date is paid', { skip }, async () => {
  const r = await run({ MOCK_PLAN: '2027-03-07,2027-03-08,2027-03-09', MOCK_SKIP_AFTER: '1' });
  assert.deepEqual(r.stored, ['2027-03-07']);
  assert.equal(calendarGoal(r, '2027-03-09'), 0);
  assert.match(r.out, /CALENDAR_EXPAND_STOP reason=ingest_skipped detail=daily_limit/);
  assert.equal(r.code, 0);
});

test('the same date in two tiers is fetched once', { skip }, async () => {
  const r = await run({ MOCK_PLAN: '2027-03-07,2027-03-07' });
  assert.equal(calendarGoal(r, '2027-03-07'), 1);
  assert.deepEqual(r.stored, ['2027-03-07']);
});

test('without fresh quota: near dates to +14 on a budget of 45, no wide plan', { skip }, async () => {
  const plan = Array.from({ length: 13 }, (_, i) => `2027-03-${String(i + 2).padStart(2, '0')}`);
  const r = await run({ MOCK_START_REMAINING: '600', MOCK_PLAN: plan.join(','), MOCK_PAGES: plan.map((d) => `${d}=10`).join(',') });
  assert.match(r.out, /CALENDAR_EXPAND_GATE expand=False/);
  assert.match(r.out, /MOCK_PLAN_CALL from=\S+ to=\S+ limit=13/);
  assert.doesNotMatch(r.out, /limit=45/);
  assert.match(r.out, /CALENDAR_FETCH date=\S+ fixtures=\d+ remaining=\d+ requests=10 used=50/);
  assert.doesNotMatch(r.out, /used=60/);
  assert.match(r.out, /CALENDAR_EXPAND_STOP reason=quota_reserve/);
});

test('with fresh quota the budget stays 90 and nothing starts past it', { skip }, async () => {
  const plan = Array.from({ length: 13 }, (_, i) => `2027-03-${String(i + 2).padStart(2, '0')}`);
  const r = await run({ MOCK_PLAN: plan.join(','), MOCK_PAGES: plan.map((d) => `${d}=30`).join(',') });
  assert.match(r.out, /CALENDAR_EXPAND_GATE expand=True/);
  assert.match(r.out, /used=90/);
  assert.doesNotMatch(r.out, /used=120/);
  assert.equal(r.stored.length, 3);
});

test('resuming: only what the plan still returns is fetched', { skip }, async () => {
  const first = await run({ MOCK_PLAN: '2027-03-07,2027-03-08', MOCK_SKIP_AFTER: '1' });
  assert.deepEqual(first.stored, ['2027-03-07']);
  const second = await run({ MOCK_PLAN: '2027-03-08' });
  assert.deepEqual(second.stored, ['2027-03-08']);
  assert.equal(calendarGoal(second, '2027-03-07'), 0);
});
