import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import {
  classifyGoalStandingsResponse,
  isGoalStandingsNoData,
} from '../../supabase/functions/_shared/goal_standings.ts';

// Issue #116: GOAL "no standings for this league" is a stable NO_DATA for the
// scheduled coverage workflow (green run, SUCCEEDED ledger, bounded negative
// cache), while real failures stay FAILED/red. Generic: synthetic ids and
// names only; no league is special-cased. No network, no real GOAL.

const workflowSource = await readFile(new URL('../../.github/workflows/standings.yml', import.meta.url), 'utf8');
const ingestSource = await readFile(new URL('../../supabase/functions/futbeat-global-ingest/index.ts', import.meta.url), 'utf8');

// ---------------------------------------------------------------------------
// Classification: the TS helper and the workflow's PowerShell function agree.
// ---------------------------------------------------------------------------
const rows = (n) => Array.from({ length: n }, (_, i) => ({ overallLeaguePosition: String(i + 1), team: { id: `t${i}` } }));
const CASES = [
  ['STANDINGS_NOT_FOUND 404', 404, { success: false, error: 'No standings found for this league', code: 'STANDINGS_NOT_FOUND' }, 'no_data', 'STANDINGS_NOT_FOUND'],
  ['STANDINGS_NOT_FOUND 200', 200, { success: false, error: 'No standings found for this league', code: 'STANDINGS_NOT_FOUND' }, 'no_data', 'STANDINGS_NOT_FOUND'],
  ['nested error.code', 404, { success: false, error: { code: 'standings_not_found' } }, 'no_data', 'STANDINGS_NOT_FOUND'],
  ['errorCode field', 404, { success: false, errorCode: 'STANDINGS_NOT_FOUND' }, 'no_data', 'STANDINGS_NOT_FOUND'],
  ['empty table', 200, { success: true, data: [] }, 'no_data', 'EMPTY_STANDINGS'],
  ['valid rows', 200, { success: true, data: rows(4) }, 'rows', 'OK'],
  ['plain 404 (broken endpoint)', 404, { message: 'Not Found' }, 'failed', 'GOAL_STANDINGS_HTTP_404'],
  ['404 without body', 404, null, 'failed', 'GOAL_STANDINGS_HTTP_404'],
  ['500', 500, { success: false, error: 'boom' }, 'failed', 'GOAL_STANDINGS_HTTP_5XX'],
  ['503 with not-found code is still a server error', 503, { code: 'STANDINGS_NOT_FOUND' }, 'failed', 'GOAL_STANDINGS_HTTP_5XX'],
  ['network / timeout', 0, null, 'failed', 'GOAL_STANDINGS_NETWORK'],
  ['401', 401, { code: 'STANDINGS_NOT_FOUND' }, 'failed', 'GOAL_STANDINGS_AUTH'],
  ['403', 403, null, 'failed', 'GOAL_STANDINGS_AUTH'],
  ['429', 429, null, 'failed', 'GOAL_STANDINGS_RATE_LIMITED'],
  ['malformed: data object', 200, { success: true, data: { rows: [] } }, 'failed', 'GOAL_STANDINGS_INVALID_PAYLOAD'],
  ['malformed: success string', 200, { success: 'true', data: rows(3) }, 'failed', 'GOAL_STANDINGS_INVALID_PAYLOAD'],
  ['malformed: success false without code', 200, { success: false }, 'failed', 'GOAL_STANDINGS_INVALID_PAYLOAD'],
  ['malformed: not JSON', 200, null, 'failed', 'GOAL_STANDINGS_INVALID_PAYLOAD'],
  ['malformed: top-level array', 200, [1, 2, 3], 'failed', 'GOAL_STANDINGS_INVALID_PAYLOAD'],
];
const ACTION = { rows: 'standings-ingest', no_data: 'standings-no-data', failed: 'standings-fail' };

function powershell() {
  for (const exe of ['pwsh', 'powershell']) {
    const probe = spawnSync(exe, ['-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.Major'], { encoding: 'utf8' });
    if (probe.status === 0) return exe;
  }
  return null;
}
const PS = powershell();

// The workflow's `run: |` script, de-indented.
function workflowScript() {
  const lines = workflowSource.split(/\r?\n/);
  const start = lines.findIndex((line) => /^\s+run: \|\s*$/.test(line));
  const body = lines.slice(start + 1);
  const indent = body.find((line) => line.trim()).match(/^\s*/)[0].length;
  return body.map((line) => line.slice(indent)).join('\n');
}
function outcomeBlock() {
  const script = workflowScript();
  const from = script.indexOf('# BEGIN standings-outcome');
  const to = script.indexOf('# END standings-outcome');
  assert.ok(from >= 0 && to > from, 'outcome block present');
  return script.slice(from, to);
}
async function runPs(script) {
  const dir = await mkdtemp(path.join(tmpdir(), 'futbeat-ps-'));
  try {
    const file = path.join(dir, 'run.ps1');
    await writeFile(file, '﻿' + script, 'utf8');
    const result = spawnSync(PS, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', file],
      { encoding: 'utf8', env: { ...process.env, GOAL_API_KEY: 'test-only-goal-key', ACTIONS_ID_TOKEN_REQUEST_URL: 'https://oidc.test/?x=1', ACTIONS_ID_TOKEN_REQUEST_TOKEN: 'test-only' } });
    return result;
  } finally { await rm(dir, { recursive: true, force: true }); }
}

test('classification: STANDINGS_NOT_FOUND/empty are NO_DATA; network, auth, 429, 5xx, other 404 and malformed are FAILED', () => {
  for (const [label, status, body, kind, code] of CASES) {
    const out = classifyGoalStandingsResponse(status, body);
    assert.deepEqual([out.kind, out.code], [kind, code], label);
  }
  // Server-side guard for a reported no-data.
  assert.equal(isGoalStandingsNoData(404, 'STANDINGS_NOT_FOUND'), true);
  assert.equal(isGoalStandingsNoData(200, 'EMPTY_STANDINGS'), true);
  assert.equal(isGoalStandingsNoData(404, 'EMPTY_STANDINGS'), false);
  assert.equal(isGoalStandingsNoData(500, 'STANDINGS_NOT_FOUND'), false);
  assert.equal(isGoalStandingsNoData(null, 'STANDINGS_NOT_FOUND'), false);
  assert.equal(isGoalStandingsNoData(404, 'GOAL_STANDINGS_HTTP_404'), false);
});

test('workflow PowerShell classification matches the TS helper case by case', { skip: PS ? false : 'no PowerShell available' }, async () => {
  const lines = [outcomeBlock(), '$results = @()'];
  for (const [label, status, body] of CASES) {
    const json = body == null ? '$null' : `('${JSON.stringify(body).replace(/'/g, "''")}' | ConvertFrom-Json)`;
    lines.push(`$o = Get-StandingsOutcome ${status} ${json}`);
    lines.push(`$results += [pscustomobject]@{ label = '${label.replace(/'/g, "''")}'; action = $o.action; code = $o.code }`);
  }
  lines.push('ConvertTo-Json -InputObject $results -Compress');
  const result = await runPs(lines.join('\n'));
  assert.equal(result.status, 0, result.stderr);
  const got = JSON.parse(result.stdout.trim().split(/\r?\n/).at(-1));
  for (const [label, , , kind, code] of CASES) {
    const row = got.find((r) => r.label === label);
    assert.deepEqual([row.action, row.code], [ACTION[kind], code], `PowerShell: ${label}`);
  }
});

// Runs the real workflow script with Invoke-WebRequest (GOAL) and
// Invoke-RestMethod (OIDC + FutBeat endpoint) mocked; every backend action is
// printed as `CALL <json>`.
async function runWorkflow({ status, body, network = false }) {
  const content = body == null ? '' : JSON.stringify(body);
  const mocks = `
function Invoke-RestMethod {
  param($Uri, $Headers, $Method, $ContentType, $Body, $TimeoutSec)
  if ([string]$Uri -like 'https://oidc.test/*') { return [pscustomobject]@{ value = 'test-only-oidc' } }
  [Console]::WriteLine('CALL ' + $Body)
  $payload = $Body | ConvertFrom-Json
  switch ($payload.action) {
    'standings-plan' { return [pscustomobject]@{ status = 'ok'; reservation = [pscustomobject]@{ reservationId = 7; competitionId = 'fb_comp_ps'; externalLeagueId = 'ps-league' } } }
    'standings-no-data' { return [pscustomobject]@{ status = 'no_data'; retryAt = '2026-01-01T00:00:00Z' } }
    'standings-ingest' { return [pscustomobject]@{ status = 'ok'; rows = @($payload.rows).Count } }
    default { return [pscustomobject]@{ status = 'ok' } }
  }
}
function Invoke-WebRequest {
  param($Uri, $Headers, [switch]$SkipHttpErrorCheck, $TimeoutSec)
  if (-not $SkipHttpErrorCheck) { throw 'SkipHttpErrorCheck is required' }
  if ([string]$Uri -ne 'https://api.goal-api.com/v1/standings/ps-league') { throw "unexpected $Uri" }
  ${network ? "throw 'The operation has timed out.'" : ''}
  return [pscustomobject]@{ StatusCode = ${status}; Headers = @{ 'X-RateLimit-Remaining' = @('321') }; Content = '${content.replace(/'/g, "''")}' }
}
`;
  const script = workflowScript();
  const result = await runPs(mocks + '\n' + script);
  const calls = result.stdout.split(/\r?\n/).filter((l) => l.startsWith('CALL ')).map((l) => JSON.parse(l.slice(5)));
  return { exit: result.status, calls, stdout: result.stdout, stderr: result.stderr };
}

test('workflow: STANDINGS_NOT_FOUND -> standings-no-data, exit 0, never standings-fail', { skip: PS ? false : 'no PowerShell available' }, async () => {
  const run = await runWorkflow({ status: 404, body: { success: false, error: 'No standings found for this league', code: 'STANDINGS_NOT_FOUND' } });
  assert.equal(run.exit, 0, run.stderr);
  assert.deepEqual(run.calls.map((c) => c.action), ['standings-plan', 'standings-no-data']);
  const report = run.calls[1];
  assert.deepEqual([report.reservationId, report.competitionId, report.httpStatus, report.providerCode, report.providerRemaining],
    [7, 'fb_comp_ps', 404, 'STANDINGS_NOT_FOUND', 321], 'status, provider code and remaining preserved');
  assert.match(run.stdout, /STANDINGS_NO_DATA competition=fb_comp_ps code=STANDINGS_NOT_FOUND status=404/);
});

test('workflow: HTTP 500 -> standings-fail with the real status, run fails', { skip: PS ? false : 'no PowerShell available' }, async () => {
  const run = await runWorkflow({ status: 500, body: { success: false, error: 'boom' } });
  assert.notEqual(run.exit, 0);
  assert.deepEqual(run.calls.map((c) => c.action), ['standings-plan', 'standings-fail']);
  assert.deepEqual([run.calls[1].httpStatus, run.calls[1].errorCode, run.calls[1].providerRemaining], [500, 'GOAL_STANDINGS_HTTP_5XX', 321]);
});

test('workflow: network timeout -> standings-fail (no status), run fails', { skip: PS ? false : 'no PowerShell available' }, async () => {
  const run = await runWorkflow({ network: true });
  assert.notEqual(run.exit, 0);
  assert.deepEqual(run.calls.map((c) => c.action), ['standings-plan', 'standings-fail']);
  assert.deepEqual([run.calls[1].httpStatus, run.calls[1].errorCode], [null, 'GOAL_STANDINGS_NETWORK']);
});

test('workflow: valid rows -> standings-ingest, exit 0', { skip: PS ? false : 'no PowerShell available' }, async () => {
  const data = rows(3).map((r) => ({ ...r, season: '2026' }));
  const run = await runWorkflow({ status: 200, body: { success: true, data } });
  assert.equal(run.exit, 0, run.stderr);
  assert.deepEqual(run.calls.map((c) => c.action), ['standings-plan', 'standings-ingest']);
  assert.deepEqual([run.calls[1].rows.length, run.calls[1].season, run.calls[1].providerRemaining], [3, '2026', 321]);
});

test('workflow: malformed success payload -> standings-fail, run fails (never hidden as no-data)', { skip: PS ? false : 'no PowerShell available' }, async () => {
  const run = await runWorkflow({ status: 200, body: { success: true, data: { unexpected: true } } });
  assert.notEqual(run.exit, 0);
  assert.deepEqual(run.calls.map((c) => c.action), ['standings-plan', 'standings-fail']);
  assert.equal(run.calls[1].errorCode, 'GOAL_STANDINGS_INVALID_PAYLOAD');
});

// ---------------------------------------------------------------------------
// Backend: the real futbeat-global-ingest handler against the real SQL.
// ---------------------------------------------------------------------------
const stripImports = (source) => source.replace(/^import\s[\s\S]*?;\r?\n/gm, '');
function ingest(db) {
  let handler;
  const fetch = async (input, init = {}) => {
    const url = new URL(input);
    if (url.origin !== 'https://supabase.test' || !url.pathname.startsWith('/rest/v1/rpc/')) throw new Error(`Unexpected request ${url.href}`);
    const name = url.pathname.split('/').at(-1);
    const body = init.body ? JSON.parse(init.body) : {};
    const keys = Object.keys(body);
    const values = keys.map((k) => (body[k] !== null && typeof body[k] === 'object' ? JSON.stringify(body[k]) : body[k]));
    try {
      const result = (await db.query(`select public.${name}(${keys.map((k, i) => `${k}=>$${i + 1}`).join(',')}) v`, values)).rows[0]?.v;
      return Response.json(result ?? null);
    } catch (error) {
      return new Response(String(error.message), { status: 400 });
    }
  };
  const context = vm.createContext({
    Request, Response, Headers, URL, AbortSignal, TextEncoder, crypto, performance, Error, fetch,
    console: { error: () => {}, warn: () => {}, log: () => {} },
    Deno: { env: { get: (n) => ({ SUPABASE_URL: 'https://supabase.test', SUPABASE_SERVICE_ROLE_KEY: 'test-service-key' })[n] }, serve: (fn) => { handler = fn; } },
    createRemoteJWKSet: () => ({}),
    jwtVerify: async () => ({ payload: { repository: 'henguido/FutBeat', ref: 'refs/heads/main', event_name: 'schedule',
      workflow_ref: 'henguido/FutBeat/.github/workflows/standings.yml@refs/heads/main' } }),
    isGoalStandingsNoData,
  });
  vm.runInContext(stripTypeScriptTypes(stripImports(ingestSource)), context);
  return async (body) => {
    const response = await handler(new Request('https://ingest.test/', { method: 'POST', headers: { authorization: 'Bearer test-only-oidc' }, body: JSON.stringify(body) }));
    return { status: response.status, value: await response.json() };
  };
}

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
let seq = 0;
async function competition(db, { name = 'Shared Name League', season = '2026' } = {}) {
  const n = ++seq;
  const id = `fb_comp_nd${n}`, ext = `nd-league-${n}`;
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)", [id, JSON.stringify({ id, name, country: 'Nowhere', season })]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','competition',$1,$2)", [ext, id]);
  const match = `fb_match_nd${n}`;
  for (const t of [`fb_team_nd${n}a`, `fb_team_nd${n}b`]) await db.query("insert into futbeat_private.entities values($1,'team',$2)", [t, JSON.stringify({ id: t, name: t })]);
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [match, JSON.stringify({
    id: match, competitionId: id, homeTeamId: `fb_team_nd${n}a`, awayTeamId: `fb_team_nd${n}b`, season, status: 'SCHEDULED',
    startTime: new Date(Date.now() + 48 * 3600e3).toISOString(), events: [], statistics: [] })]);
  return { id, ext, match };
}
const remaining = (db, value = 900) => db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,provider_remaining)
  values('goal_api','global-ingest','test',now(),now(),'SUCCEEDED',$1)`, [value]);
const ledger = (db, id) => db.query('select status,http_status,error_code,metadata from futbeat_private.provider_call_ledger where id=$1', [id]).then((r) => r.rows[0]);
const coverageState = (db, comp) => db.query('select status,external_league_id,provider_error_code,http_status,next_retry_at from futbeat_private.standings_coverage_state where competition_id=$1', [comp.id]).then((r) => r.rows[0]);
const goalRows = (n = 3) => Array.from({ length: n }, (_, i) => ({
  overallLeaguePosition: String(i + 1), overallLeaguePlayed: '3', overallLeagueW: String(3 - i), overallLeagueD: '0',
  overallLeagueL: String(i), overallLeagueGF: '5', overallLeagueGA: '3', overallLeaguePTS: String((3 - i) * 3), season: '2026',
  team: { id: `nd-team-${seq}-${i}`, name: `ND Team ${seq}-${i}`, country: { name: 'Nowhere' } } }));
const notFound = (plan) => ({ action: 'standings-no-data', reservationId: plan.reservation.reservationId,
  competitionId: plan.reservation.competitionId, externalLeagueId: plan.reservation.externalLeagueId,
  httpStatus: 404, providerCode: 'STANDINGS_NOT_FOUND', providerRemaining: 500 });

test('1/5. STANDINGS_NOT_FOUND (404): SUCCEEDED ledger with status and code, bounded negative cache', () => withDb(async (db) => {
  await remaining(db);
  const comp = await competition(db);
  const call = ingest(db);
  const plan = (await call({ action: 'standings-plan' })).value;
  assert.equal(plan.reservation.competitionId, comp.id);
  const res = await call(notFound(plan));
  assert.equal(res.status, 200);
  assert.equal(res.value.status, 'no_data');
  const row = await ledger(db, plan.reservation.reservationId);
  assert.deepEqual([row.status, row.http_status, row.error_code, row.metadata.outcome, row.metadata.providerCode],
    ['SUCCEEDED', 404, null, 'NO_DATA', 'STANDINGS_NOT_FOUND']);
  const state = await coverageState(db, comp);
  assert.deepEqual([state.status, state.external_league_id, state.provider_error_code, state.http_status],
    ['NO_DATA', comp.ext, 'STANDINGS_NOT_FOUND', 404]);
  const days = (new Date(state.next_retry_at) - Date.now()) / 86400e3;
  assert.ok(days > 2.9 && days <= 3.01, `standingsNoDataDays TTL (${days})`);
  // Recording twice is refused (no double completion).
  assert.equal((await call(notFound(plan))).status, 502);
}));

test('2/3. planner skips the competition while NO_DATA is valid; eligible again after next_retry_at', () => withDb(async (db) => {
  await remaining(db);
  const comp = await competition(db);
  const call = ingest(db);
  await call(notFound((await call({ action: 'standings-plan' })).value));
  const during = (await call({ action: 'standings-plan' })).value;
  assert.equal(during.status, 'skipped');
  assert.equal(during.reservation.reason, 'no_standings_due');
  await db.query("update futbeat_private.standings_coverage_state set next_retry_at=now()-interval '1 second' where competition_id=$1", [comp.id]);
  const after = (await call({ action: 'standings-plan' })).value;
  assert.equal(after.reservation.competitionId, comp.id);
}));

test('4. a table that appears later is stored and clears the negative cache', () => withDb(async (db) => {
  await remaining(db);
  const comp = await competition(db);
  const call = ingest(db);
  await call(notFound((await call({ action: 'standings-plan' })).value));
  await db.query("update futbeat_private.standings_coverage_state set next_retry_at=now()-interval '1 second' where competition_id=$1", [comp.id]);
  const plan = (await call({ action: 'standings-plan' })).value;
  const res = await call({ action: 'standings-ingest', reservationId: plan.reservation.reservationId, competitionId: comp.id,
    externalLeagueId: comp.ext, season: '2026', providerRemaining: 400, rows: goalRows() });
  assert.equal(res.status, 200);
  assert.equal(await coverageState(db, comp), undefined, 'NO_DATA cleared');
  assert.equal((await db.query('select count(*)::int n from futbeat_private.standings_cache where competition_id=$1', [comp.id])).rows[0].n, 1);
  const ctx = (await db.query('select public.futbeat_read_match_context($1) v', [comp.match])).rows[0].v;
  assert.equal(ctx.standings.length, 1, 'future reads show the table');
  assert.equal((await call({ action: 'standings-plan' })).value.status, 'skipped', 'fresh table: coverage back to normal');
}));

test('6/7/8. real failures stay FAILED with no negative cache; no-data reports for them are refused', () => withDb(async (db) => {
  await remaining(db);
  const comp = await competition(db);
  const call = ingest(db);
  for (const [httpStatus, errorCode] of [[500, 'GOAL_STANDINGS_HTTP_5XX'], [null, 'GOAL_STANDINGS_NETWORK'],
    [401, 'GOAL_STANDINGS_AUTH'], [403, 'GOAL_STANDINGS_AUTH'], [404, 'GOAL_STANDINGS_HTTP_404']]) {
    await db.query("delete from futbeat_private.provider_call_ledger where call_kind='standings'");
    const plan = (await call({ action: 'standings-plan' })).value;
    assert.equal(plan.reservation.competitionId, comp.id);
    // The server never accepts a real failure as "no data".
    const bogus = await call({ ...notFound(plan), httpStatus, providerCode: errorCode });
    assert.equal(bogus.status, 400, `no-data refused for ${errorCode}`);
    const res = await call({ action: 'standings-fail', reservationId: plan.reservation.reservationId, competitionId: comp.id,
      externalLeagueId: comp.ext, httpStatus, errorCode, providerRemaining: 500 });
    assert.equal(res.status, 200);
    const row = await ledger(db, plan.reservation.reservationId);
    assert.deepEqual([row.status, row.http_status, row.error_code], ['FAILED', httpStatus, errorCode]);
    assert.equal(await coverageState(db, comp), undefined, 'no negative cache for a real failure');
  }
  // 500 with the not-found code is also refused as no-data.
  const plan = (await call({ action: 'standings-plan' })).value;
  assert.equal((await call({ ...notFound(plan), httpStatus: 500 })).status, 400);
}));

test('9. malformed success payload is never recorded as no-data (ingest validation stays)', () => withDb(async (db) => {
  await remaining(db);
  const comp = await competition(db);
  const call = ingest(db);
  const plan = (await call({ action: 'standings-plan' })).value;
  assert.equal((await call({ ...notFound(plan), httpStatus: 200, providerCode: 'GOAL_STANDINGS_INVALID_PAYLOAD' })).status, 400);
  assert.equal((await call({ action: 'standings-ingest', reservationId: plan.reservation.reservationId, competitionId: comp.id,
    externalLeagueId: comp.ext, rows: { unexpected: true } })).status, 400);
  assert.equal(await coverageState(db, comp), undefined);
}));

test('10. #98 user demand is untouched: coverage NO_DATA never blocks or marks the exact-season demand', () => withDb(async (db) => {
  await remaining(db);
  const comp = await competition(db);
  const call = ingest(db);
  await call(notFound((await call({ action: 'standings-plan' })).value));
  const st = (await db.query('select public.futbeat_request_match_standings($1) v', [comp.match])).rows[0].v;
  assert.deepEqual([st.standings, st.standingsPending], ['pending', true]);
  const demand = (await db.query("select public.futbeat_reserve_standings_demand_call('t') v")).rows[0].v;
  assert.deepEqual([demand.allowed, demand.competitionId, demand.source], [true, comp.id, 'user']);
  // A user-demand reservation can never be completed through the coverage no-data path.
  assert.match((await db.query('select public.futbeat_record_standings_no_data($1,404,$2) v', [demand.reservationId, 'STANDINGS_NOT_FOUND'])
    .catch((e) => ({ rows: [{ v: e.message }] }))).rows[0].v, /Unknown or completed standings coverage reservation/);
  // Exact-season NO_DATA of #98 keeps its own behaviour.
  const done = (await db.query('select public.futbeat_complete_standings_call($1,false,404,null) v', [demand.reservationId])).rows[0].v;
  assert.equal(done.status, 'NO_DATA');
  const again = (await db.query('select public.futbeat_request_match_standings($1) v', [comp.match])).rows[0].v;
  assert.deepEqual([again.standings, again.standingsPending], ['unavailable', false]);
}));

test('11. LIVE floor unchanged', () => withDb(async (db) => {
  const live = (await db.query("select futbeat_private.quota_decision('goal_api','live-goal','live') v")).rows[0].v;
  assert.equal(live.floor, 20);
}));

test('12. same-name competitions: negative cache is per canonical id, never by name', () => withDb(async (db) => {
  await remaining(db);
  const a = await competition(db, { name: 'Twin League' });
  const b = await competition(db, { name: 'Twin League' });
  const call = ingest(db);
  const first = (await call({ action: 'standings-plan' })).value;
  const noData = first.reservation.competitionId === a.id ? a : b;
  const other = noData === a ? b : a;
  await call(notFound(first));
  const next = (await call({ action: 'standings-plan' })).value;
  assert.equal(next.reservation.competitionId, other.id, 'the twin is still served');
  assert.equal(await coverageState(db, other), undefined);
}));

test('13. a changed provider mapping retries at once (the negative cache belongs to the old mapping)', () => withDb(async (db) => {
  await remaining(db);
  const comp = await competition(db);
  const call = ingest(db);
  await call(notFound((await call({ action: 'standings-plan' })).value));
  assert.equal((await call({ action: 'standings-plan' })).value.status, 'skipped');
  await db.query("update futbeat_private.provider_entities set external_id='nd-league-remapped' where canonical_id=$1 and kind='competition'", [comp.id]);
  const plan = (await call({ action: 'standings-plan' })).value;
  assert.deepEqual([plan.reservation.competitionId, plan.reservation.externalLeagueId], [comp.id, 'nd-league-remapped']);
}));

test('security: the no-data RPC and state table are service-only', () => withDb(async (db) => {
  const can = async (role) => (await db.query("select has_function_privilege($1,'public.futbeat_record_standings_no_data(bigint,integer,text,integer,text)','EXECUTE') ok", [role])).rows[0].ok;
  assert.equal(await can('anon'), false);
  assert.equal(await can('authenticated'), false);
  assert.equal(await can('service_role'), true);
  const table = async (role) => (await db.query("select has_table_privilege($1,'futbeat_private.standings_coverage_state','SELECT') ok", [role])).rows[0].ok;
  assert.equal(await table('anon'), false);
  assert.equal(await table('authenticated'), false);
}));
