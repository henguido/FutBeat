import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import { WorkerInputError, parseWorkerInput, runProviderHubWork } from '../providers/hub_worker.mjs';
import { createApiFootballProvider } from '../providers/api_football.mjs';

// Provider Hub Phase 1B (#102): the real futbeat-provider-hub-sync Edge
// Function executed in node against the real SQL, with an injected fake
// API-Football transport. The process-level fetch is blocked: no real
// provider (or any other) network call can happen.

globalThis.fetch = async (input) => { throw new Error(`Real network blocked in tests: ${input}`); };

const TOKEN = 'test-only-internal-cron-token-0123456789abcdef';
const API_KEY = 'synthetic-api-football-key-DO-NOT-LEAK';
const source = await readFile(new URL('../../supabase/functions/futbeat-provider-hub-sync/index.ts', import.meta.url), 'utf8');
const stripImports = (text) => text.replace(/^import\s[\s\S]*?;\r?\n/gm, '');

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

/** Fake API-Football transport: records calls and the ledger state at call time. */
function transport(db, respond) {
  const calls = [];
  const fetcher = async (url, options) => {
    const reserved = (await db.query("select count(*)::int n from futbeat_private.provider_call_ledger where provider='api_football' and status='RESERVED'")).rows[0].n;
    calls.push({ url, key: options.headers['x-apisports-key'], reservedAtCallTime: reserved });
    return respond(url);
  };
  return { calls, fetcher };
}
const apiResponse = (body, { status = 200, remaining = '87' } = {}) => ({
  ok: status >= 200 && status < 300,
  status,
  headers: new Headers(remaining == null ? {} : { 'x-ratelimit-requests-remaining': remaining }),
  json: async () => body,
});

function edge(db, fake, { apiKey = API_KEY } = {}) {
  let handler;
  const rpcs = [];
  const fetch = async (input, init = {}) => {
    const url = new URL(input);
    if (url.origin !== 'https://supabase.test' || !url.pathname.startsWith('/rest/v1/rpc/')) {
      throw new Error(`Unexpected request from the Edge Function: ${url.href}`);
    }
    const name = url.pathname.split('/').at(-1);
    rpcs.push(name);
    if (name === 'futbeat_read_goal_live_cron_token') return Response.json(TOKEN);
    const body = init.body ? JSON.parse(init.body) : {};
    const keys = Object.keys(body);
    const values = keys.map((k) => (body[k] !== null && typeof body[k] === 'object' && !Array.isArray(body[k]) ? JSON.stringify(body[k]) : body[k]));
    try {
      const v = (await db.query(`select public.${name}(${keys.map((k, i) => `${k}=>$${i + 1}`).join(',')}) v`, values)).rows[0]?.v;
      return Response.json(v ?? null);
    } catch (error) {
      return new Response(String(error.message), { status: 400 });
    }
  };
  const context = vm.createContext({
    Request, Response, Headers, URL, AbortSignal, TextEncoder, crypto, JSON, Error, console: { error: () => {}, log: () => {}, warn: () => {} },
    fetch,
    Deno: {
      env: { get: (n) => ({ SUPABASE_URL: 'https://supabase.test', SUPABASE_SERVICE_ROLE_KEY: 'test-service-key', FUTBEAT_API_FOOTBALL_KEY: apiKey })[n] },
      serve: (fn) => { handler = fn; },
    },
    WorkerInputError, parseWorkerInput, runProviderHubWork,
    // The only provider factory the worker can reach: the fake transport.
    createApiFootballProvider: (options) => createApiFootballProvider({ ...options, fetcher: fake.fetcher }),
  });
  vm.runInContext(stripTypeScriptTypes(stripImports(source)), context);
  const call = async (body, { token = TOKEN, method = 'POST', raw } = {}) => {
    const response = await handler(new Request('https://worker.test/', {
      method,
      headers: token ? { 'x-futbeat-cron-token': token, 'content-type': 'application/json' } : { 'content-type': 'application/json' },
      ...(method === 'POST' ? { body: raw ?? JSON.stringify(body) } : {}),
    }));
    const text = await response.text();
    return { status: response.status, body: text ? JSON.parse(text) : null };
  };
  return { call, rpcs };
}

let seq = 0;
async function entity(db, kind, payload) {
  const id = `fb_${kind}_p1b${++seq}`;
  await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
  return id;
}
const verified = { type: 'EXPLICIT_VERIFIED', verifiedBy: 'test-review' };
const bind = (db, kind, ext, id) => db.query('select public.futbeat_bind_provider_entity($1,$2,$3,$4,$5) v',
  ['api_football', kind, ext, id, JSON.stringify(verified)]).then((r) => r.rows[0].v);

/** A GOAL canonical match (mapped for GOAL) and, optionally, its API-Football mapping. */
async function seed(db, { status = 'SCHEDULED', score = null, hoursAgo = 3, events = [], mapped = true } = {}) {
  const comp = await entity(db, 'competition', { name: 'Liga Hub' });
  const home = await entity(db, 'team', { name: 'Hub Local' });
  const away = await entity(db, 'team', { name: 'Hub Visita' });
  const start = new Date(Date.now() - hoursAgo * 3600e3).toISOString();
  const match = await entity(db, 'match', { competitionId: comp, homeTeamId: home, awayTeamId: away, startTime: start, status,
    ...(score ? { score: { home: score[0], away: score[1] } } : {}), events,
    provenance: { receivedAt: new Date(Date.now() - (hoursAgo + 1) * 3600e3).toISOString() } });
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [`goal-${seq}`, match]);
  const ext = String(700000 + seq);
  if (mapped) await bind(db, 'match', ext, match);
  return { comp, home, away, match, ext, start };
}
const enable = (db, over = '') => db.query(`update futbeat_private.provider_hub_config set enabled=true${over} where provider='api_football'`);
const ledger = (db) => db.query("select status,http_status,error_code,provider_remaining,metadata from futbeat_private.provider_call_ledger where provider='api_football' order by id").then((r) => r.rows);
const secondary = (db) => db.query('select status,home_score,away_score,reconciliation,events from futbeat_private.provider_secondary_observations order by id').then((r) => r.rows);
const shown = (db, id) => db.query("select futbeat_private.match_read_model(payload) v from futbeat_private.entities where id=$1", [id]).then((r) => r.rows[0].v);

const fixture = (s, { short = 'FT', goals = [2, 0], events = [] } = {}) => ({
  fixture: { id: Number(s.ext), date: s.start, status: { short, elapsed: short === 'FT' ? 90 : 60 } },
  league: { id: 39, name: 'Liga Hub', country: 'Nowhere', season: 2026 },
  teams: { home: { id: 33, name: 'Hub Local' }, away: { id: 34, name: 'Hub Visita' } },
  goals: { home: goals?.[0] ?? null, away: goals?.[1] ?? null },
  events,
});
const envelope = (items) => ({ get: 'fixtures', errors: [], results: items.length, response: items });
const body = (s, over = {}) => ({ provider: 'api_football', reason: 'FINAL_RECONCILIATION', dataType: 'fixtures', matchId: s.match, dryRun: false, ...over });

// ---------------------------------------------------------------------------
// Transport, auth, body validation.
// ---------------------------------------------------------------------------
test('harness: POST only, internal token required, bounded strict body', () => withDb(async (db) => {
  const s = await seed(db);
  const fake = transport(db, () => { throw new Error('no provider call expected'); });
  const { call, rpcs } = edge(db, fake);
  assert.equal((await call(null, { method: 'GET' })).status, 405);
  assert.equal((await call(body(s), { token: null })).status, 403);
  assert.equal((await call(body(s), { token: 'wrong-token-of-sufficient-length-000000' })).status, 403);
  assert.deepEqual(rpcs.filter((n) => n !== 'futbeat_read_goal_live_cron_token'), [], 'nothing runs before auth');
  assert.equal((await call(null, { raw: '{not json' })).status, 400);
  assert.equal((await call({ ...body(s), force: true })).status, 400, 'no force mode');
  assert.equal((await call({ ...body(s), reason: 'EVERYTHING' })).status, 400);
  assert.equal((await call({ ...body(s), dataType: 'odds' })).status, 400);
  assert.equal((await call({ ...body(s), matchId: 'not-a-match' })).status, 400);
  assert.equal((await call({ ...body(s), dryRun: 'false' })).status, 400);
  assert.equal((await call(null, { raw: JSON.stringify({ ...body(s), pad: 'x'.repeat(3000) }) })).status, 413);
  assert.equal(fake.calls.length, 0);
}));

test('A. dryRun (default) = routing, quota and mapping plan; zero network, zero ledger, zero writes', () => withDb(async (db) => {
  const s = await seed(db);
  await enable(db);
  const fake = transport(db, () => { throw new Error('dry run must not call'); });
  const { call } = edge(db, fake);
  const { dryRun, ...noDry } = body(s);
  const r = await call(noDry);
  assert.equal(r.status, 200);
  assert.deepEqual([r.body.status, r.body.dryRun, r.body.providerCalls], ['dry_run', true, 0]);
  assert.deepEqual(r.body.plan, { endpoint: '/fixtures', params: { id: s.ext }, requestUnits: 1 });
  assert.equal(r.body.routing.quota.allowed, true);
  assert.equal(fake.calls.length, 0);
  assert.deepEqual(await ledger(db), []);
  assert.deepEqual(await secondary(db), []);
}));

test('B. disabled provider (production config): skipped, zero network, zero ledger', () => withDb(async (db) => {
  const s = await seed(db);
  const fake = transport(db, () => { throw new Error('disabled must not call'); });
  const r = await edge(db, fake).call(body(s));
  assert.deepEqual([r.body.status, r.body.why, r.body.providerCalls], ['skipped', 'DISABLED', 0]);
  assert.equal(fake.calls.length, 0);
  assert.deepEqual(await ledger(db), []);
}));

const counts = (db) => db.query(`select
    (select count(*)::int from futbeat_private.provider_call_ledger) ledger,
    (select count(*)::int from futbeat_private.provider_secondary_observations) secondary,
    (select count(*)::int from futbeat_private.provider_observations) observations,
    (select count(*)::int from futbeat_private.provider_fixture_diagnostics) diagnostics,
    (select count(*)::int from futbeat_private.provider_entities) mappings,
    (select count(*)::int from futbeat_private.entities) entities`).then((r) => r.rows[0]);

test('A2. dryRun with the UNTOUCHED production config (api_football disabled): plan + clear disabled flag, zero network/ledger/writes', () => withDb(async (db) => {
  const s = await seed(db);
  const config = () => db.query("select enabled,daily_budget,minute_budget from futbeat_private.provider_hub_config where provider='api_football'").then((r) => r.rows[0]);
  assert.equal((await config()).enabled, false, 'no synthetic enable in this test');
  const before = await counts(db);
  const fake = transport(db, () => { throw new Error('dry run must not call'); });
  const { call } = edge(db, fake);
  const { dryRun, ...noDry } = body(s);

  const r = await call(noDry);
  assert.equal(r.status, 200);
  assert.deepEqual([r.body.status, r.body.dryRun, r.body.providerCalls], ['dry_run', true, 0]);
  assert.equal(r.body.providerEnabled, false);
  assert.equal(r.body.executionBlockedBy, 'DISABLED');
  assert.deepEqual(r.body.plan, { endpoint: '/fixtures', params: { id: s.ext }, requestUnits: 1 });
  assert.deepEqual(r.body.routing.mapping, { state: 'MAPPED', externalMatchId: s.ext });
  assert.deepEqual([r.body.routing.quota.allowed, r.body.routing.quota.reason], [false, 'provider_disabled']);
  assert.deepEqual(r.body.routing.rejected.find((x) => x.provider === 'api_football'), { provider: 'api_football', reason: 'DISABLED' });
  assert.deepEqual(r.body.routing.ifEnabled.quota, { allowed: true, reason: null });
  assert.deepEqual(r.body.routing.ifEnabled.candidates, ['goal_api', 'api_football']);

  // Execution stays refused while disabled.
  const exec = await call(body(s));
  assert.deepEqual([exec.body.status, exec.body.why, exec.body.providerCalls, exec.body.providerEnabled], ['skipped', 'DISABLED', 0, false]);

  assert.equal(fake.calls.length, 0);
  assert.deepEqual(await counts(db), before, 'zero ledger rows, zero writes');
  assert.deepEqual(await config(), { enabled: false, daily_budget: 100, minute_budget: 10 });
}));

test('A3. disabled dry-run still applies every other gate (BASE_LIVE, unmapped)', () => withDb(async (db) => {
  const s = await seed(db);
  const u = await seed(db, { mapped: false });
  const fake = transport(db, () => { throw new Error('must not call'); });
  const { call } = edge(db, fake);
  const live = await call(body(s, { reason: 'BASE_LIVE', dataType: 'live', dryRun: true }));
  assert.deepEqual([live.body.status, live.body.why, live.body.providerEnabled], ['skipped', 'REASON_NOT_ALLOWED_FOR_SECONDARY', false]);
  const unmapped = await call(body(u, { dryRun: true }));
  assert.deepEqual([unmapped.body.status, unmapped.body.providerCalls], ['unmapped', 0]);
  assert.equal(unmapped.body.plan, undefined);
  assert.equal(fake.calls.length, 0);
  assert.deepEqual(await ledger(db), []);
}));

test('C. BASE_LIVE never selects API-Football', () => withDb(async (db) => {
  const s = await seed(db);
  await enable(db);
  const fake = transport(db, () => { throw new Error('base live must not call'); });
  const r = await edge(db, fake).call(body(s, { reason: 'BASE_LIVE', dataType: 'live' }));
  assert.deepEqual([r.body.status, r.body.why], ['skipped', 'REASON_NOT_ALLOWED_FOR_SECONDARY']);
  assert.deepEqual(r.body.routing.candidates, ['goal_api']);
  assert.equal(fake.calls.length, 0);
}));

test('D/E. unmapped and ambiguous matches: zero network, zero ledger', () => withDb(async (db) => {
  await enable(db);
  const unmapped = await seed(db, { mapped: false });
  const fake = transport(db, () => { throw new Error('unmapped must not call'); });
  const { call } = edge(db, fake);
  assert.equal((await call(body(unmapped))).body.status, 'unmapped');
  // Ambiguous: two GOAL fixtures of the same pairing within tolerance.
  const s = await seed(db, { mapped: false });
  await entity(db, 'match', { competitionId: s.comp, homeTeamId: s.home, awayTeamId: s.away,
    startTime: new Date(Date.parse(s.start) + 5 * 60000).toISOString(), status: 'SCHEDULED' });
  await bind(db, 'competition', '39', s.comp);
  await bind(db, 'team', '33', s.home);
  await bind(db, 'team', '34', s.away);
  const m = (await db.query("select public.futbeat_match_provider_fixture('api_football','990001','39','33','34',$1) v", [s.start])).rows[0].v;
  assert.equal(m.status, 'AMBIGUOUS');
  assert.equal((await call(body(s))).body.status, 'ambiguous');
  assert.equal(fake.calls.length, 0);
  assert.deepEqual(await ledger(db), []);
}));

test('F/H/N/O. mapped exact fixture: reservation first, ONE call, SUCCEEDED with provider remaining', () => withDb(async (db) => {
  const s = await seed(db);
  await enable(db);
  const fake = transport(db, () => apiResponse(envelope([fixture(s)]), { remaining: '87' }));
  const r = await edge(db, fake).call(body(s));
  assert.equal(r.body.status, 'ok');
  assert.equal(fake.calls.length, 1);
  assert.equal(fake.calls[0].url, `https://v3.football.api-sports.io/fixtures?id=${s.ext}`);
  assert.equal(fake.calls[0].key, API_KEY, 'server-side key only on the provider request');
  assert.equal(fake.calls[0].reservedAtCallTime, 1, 'persistent reservation exists before the network call');
  const [row] = await ledger(db);
  assert.deepEqual([row.status, row.http_status, row.error_code, row.provider_remaining], ['SUCCEEDED', 200, null, 87]);
  assert.equal(row.metadata.providerHub, true);
  assert.equal(r.body.providerRemaining, 87);
  assert.ok(!JSON.stringify(r.body).includes(API_KEY));
}));

test('ledger is SUCCEEDED only after ingest: a failed secondary-observation write completes it FAILED, one call, no retry', () => withDb(async (db) => {
  const s = await seed(db);
  await enable(db);
  // Force the final ingest step to fail (message must never reach the ledger).
  await db.query(`create or replace function public.futbeat_record_secondary_observation(p_provider text,p_match_id text,p_observation jsonb)
    returns jsonb language plpgsql as $$ begin raise exception 'forced ingest failure raw-detail-xyz'; end $$`);
  const fake = transport(db, () => apiResponse(envelope([fixture(s)]), { remaining: '86' }));
  const r = await edge(db, fake).call(body(s));
  assert.equal(r.status, 200);
  assert.deepEqual([r.body.status, r.body.errorCode, r.body.stage, r.body.retry, r.body.providerCalls],
    ['failed', 'PROVIDER_HUB_INGEST_FAILED', 'record_observation', false, 1]);
  assert.equal(fake.calls.length, 1, 'exactly one provider call, no retry');
  assert.equal(fake.calls[0].reservedAtCallTime, 1);
  const rows = await ledger(db);
  assert.equal(rows.length, 1);
  const [row] = rows;
  assert.deepEqual([row.status, row.http_status, row.error_code, row.provider_remaining], ['FAILED', 200, 'PROVIDER_HUB_INGEST_FAILED', 86]);
  assert.equal(row.metadata.stage, 'record_observation');
  assert.equal(row.metadata.retry, false);
  assert.ok(Number.isFinite(row.metadata.durationMs));
  assert.ok(!rows.some((x) => x.status === 'SUCCEEDED' || x.status === 'RESERVED'));
  const stored = JSON.stringify(rows) + JSON.stringify(r.body);
  assert.ok(!stored.includes('raw-detail-xyz'), 'no raw error text');
  assert.ok(!stored.includes(API_KEY), 'no secret');
  assert.deepEqual(await secondary(db), []);
}));

test('G. quota denial: zero network', () => withDb(async (db) => {
  const s = await seed(db);
  await enable(db, ',daily_budget=1');
  await db.query("select public.futbeat_reserve_provider_hub_call('api_football','fixture','other',1)");
  const fake = transport(db, () => { throw new Error('quota denial must not call'); });
  const r = await edge(db, fake).call(body(s));
  assert.deepEqual([r.body.status, r.body.why], ['skipped', 'QUOTA_EXHAUSTED']);
  assert.equal(r.body.routing.quota.reason, 'provider_daily_budget');
  assert.equal(fake.calls.length, 0);
}));

test('G/H. the persistent reservation is the last gate: a race lost at reservation time makes no call', () => withDb(async (db) => {
  const s = await seed(db);
  await enable(db);
  let calls = 0;
  const rpc = async (name, args) => {
    if (name === 'futbeat_reserve_provider_hub_call') {
      return { allowed: false, reason: 'provider_minute_budget' }; // someone else took the slot
    }
    const keys = Object.keys(args);
    return (await db.query(`select public.${name}(${keys.map((k, i) => `${k}=>$${i + 1}`).join(',')}) v`,
      keys.map((k) => args[k]))).rows[0]?.v ?? null;
  };
  const r = await runProviderHubWork(parseWorkerInput(body(s)), {
    rpc, readApiKey: async () => API_KEY,
    createProvider: () => ({ fetchFixture: async () => { calls++; throw new Error('never'); } }),
  });
  assert.deepEqual([r.status, r.why, r.providerCalls], ['skipped', 'provider_minute_budget', 0]);
  assert.equal(calls, 0);
  // A missing secret is detected before any reservation is spent.
  const noKey = await runProviderHubWork(parseWorkerInput(body(s)), {
    rpc: async (name, args) => (name === 'futbeat_reserve_provider_hub_call' ? assert.fail('no reservation without a key') : rpc(name, args)),
    readApiKey: async () => '',
    createProvider: () => assert.fail('no provider without a key'),
  });
  assert.deepEqual([noKey.status, noKey.why], ['skipped', 'missing_secret']);
  assert.deepEqual(await ledger(db), []);
}));

for (const [label, response, code, http] of [
  ['M. 5xx', () => apiResponse({}, { status: 503 }), 'API_FOOTBALL_HTTP_5XX', 503],
  ['K. 429', () => apiResponse({}, { status: 429, remaining: '0' }), 'API_FOOTBALL_RATE_LIMITED', 429],
  ['L. 401', () => apiResponse({}, { status: 401 }), 'API_FOOTBALL_AUTH', 401],
  ['L. 403', () => apiResponse({}, { status: 403 }), 'API_FOOTBALL_AUTH', 403],
  ['I. envelope error', () => apiResponse({ errors: { token: `Error/Missing application key ${API_KEY}` }, response: [] }), 'API_FOOTBALL_AUTH', 200],
  ['I. timeout', () => { const e = new Error('timeout'); e.name = 'TimeoutError'; throw e; }, 'API_FOOTBALL_TIMEOUT', null],
  ['I. wrong fixture in payload', null, 'API_FOOTBALL_INVALID_PAYLOAD', 200],
]) {
  test(`${label}: ledger FAILED with a safe code, no retry, no key`, () => withDb(async (db) => {
    const s = await seed(db);
    await enable(db);
    const fake = transport(db, response ?? (() => apiResponse(envelope([{ ...fixture(s), fixture: { id: 1, status: { short: 'FT' } } }]))));
    const r = await edge(db, fake).call(body(s));
    assert.deepEqual([r.body.status, r.body.errorCode, r.body.retry], ['failed', code, false]);
    assert.equal(fake.calls.length, 1, 'exactly one attempt');
    const [row] = await ledger(db);
    assert.deepEqual([row.status, row.error_code, row.http_status], ['FAILED', code, http]);
    assert.ok(!JSON.stringify({ r: r.body, row }).includes(API_KEY));
    assert.deepEqual(await secondary(db), []);
  }));
}

test('J. suspended account: classified, health UNAVAILABLE, the next run makes no call (no retry loop)', () => withDb(async (db) => {
  const s = await seed(db);
  await enable(db);
  const fake = transport(db, () => apiResponse({
    get: 'fixtures', parameters: { id: s.ext },
    errors: { access: 'Your account is suspended, check on https://dashboard.api-football.com.' },
    results: 0, paging: { current: 1, total: 1 }, response: [],
  }, { remaining: null }));
  const { call } = edge(db, fake);
  const r = await call(body(s));
  assert.deepEqual([r.body.status, r.body.errorCode], ['failed', 'API_FOOTBALL_ACCOUNT_SUSPENDED']);
  const [row] = await ledger(db);
  assert.deepEqual([row.status, row.error_code, row.http_status], ['FAILED', 'API_FOOTBALL_ACCOUNT_SUSPENDED', 200]);
  const status = (await db.query('select public.futbeat_provider_hub_status() v')).rows[0].v.providers.find((p) => p.provider === 'api_football');
  assert.deepEqual([status.health, status.lastErrorCode], ['UNAVAILABLE', 'API_FOOTBALL_ACCOUNT_SUSPENDED']);
  const again = await call(body(s));
  assert.deepEqual([again.body.status, again.body.why], ['skipped', 'UNHEALTHY']);
  assert.equal(fake.calls.length, 1);
  assert.equal((await ledger(db)).length, 1);
}));

// ---------------------------------------------------------------------------
// Event dedup and reconciliation precedence.
// ---------------------------------------------------------------------------
test('P/Q. API-Football + GOAL same goal -> one canonical event; a conflicting event stays separate', () => withDb(async (db) => {
  const scorer = await entity(db, 'player', { name: 'Goleador Hub' });
  const s = await seed(db, { status: 'FINISHED_PENDING_VERIFICATION', score: [1, 0], events: [] });
  await db.query("update futbeat_private.entities set payload=payload||jsonb_build_object('events',$2::jsonb) where id=$1",
    [s.match, JSON.stringify([{ id: 'goal-ev-1', type: 'GOAL', minute: 20, teamId: s.home, playerId: scorer }])]);
  await bind(db, 'player', '5501', scorer);
  await enable(db);
  const events = [
    { time: { elapsed: 21, extra: null }, team: { id: 33 }, player: { id: 5501, name: 'Goleador Hub' }, assist: {}, type: 'Goal', detail: 'Normal Goal' },
    // Same minute, other team: never merged.
    { time: { elapsed: 20, extra: null }, team: { id: 34 }, player: { id: 5999, name: 'Unmapped Player' }, assist: {}, type: 'Card', detail: 'Yellow Card' },
  ];
  const fake = transport(db, () => apiResponse(envelope([fixture(s, { goals: [1, 0], events })])));
  const r = await edge(db, fake).call(body(s));
  assert.equal(r.body.status, 'ok');
  assert.deepEqual([r.body.events.goalEvents, r.body.events.secondaryEvents, r.body.events.canonicalEvents,
    r.body.events.confirmedByBoth, r.body.events.secondaryOnly], [1, 2, 2, 1, 1]);
  const [obs] = await secondary(db);
  const card = obs.events.find((e) => e.type === 'YELLOW_CARD');
  assert.deepEqual([card.teamId, card.playerId], [s.away, null], 'unmapped player never created by name');
  assert.equal((await db.query("select count(*)::int n from futbeat_private.entities where kind='player' and payload->>'name'='Unmapped Player'")).rows[0].n, 0);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.canonical_events')).rows[0].n, 0, 'no canonical/push writes in 1B');
}));

test('R. a secondary result never overwrites stronger GOAL evidence (CONFLICT, nothing promoted)', () => withDb(async (db) => {
  const s = await seed(db, { status: 'FINISHED_PENDING_VERIFICATION', score: [2, 1] });
  await enable(db);
  const before = await shown(db, s.match);
  const fake = transport(db, () => apiResponse(envelope([fixture(s, { goals: [1, 1] })])));
  const r = await edge(db, fake).call(body(s));
  assert.deepEqual([r.body.reconciliation.decision, r.body.reconciliation.reason], ['CONFLICT', 'goal_terminal_differs']);
  assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_observations where provider='api_football'")).rows[0].n, 0);
  const after = await shown(db, s.match);
  assert.deepEqual([after.status, after.score], [before.status, before.score]);
  assert.deepEqual(after.score, { home: 2, away: 1 });
}));

test('S. a missing GOAL result is supplemented by terminal secondary evidence (read model rules)', () => withDb(async (db) => {
  const s = await seed(db, { status: 'SCHEDULED', hoursAgo: 4 });
  await enable(db);
  assert.notEqual((await shown(db, s.match)).status, 'FINISHED_PENDING_VERIFICATION');
  const fake = transport(db, () => apiResponse(envelope([fixture(s, { goals: [2, 0] })])));
  const r = await edge(db, fake).call(body(s));
  assert.equal(r.body.reconciliation.decision, 'APPLIED_FINAL');
  const view = await shown(db, s.match);
  assert.deepEqual([view.status, view.score], ['FINISHED_PENDING_VERIFICATION', { home: 2, away: 0 }]);
}));

test('T. never final by clock: non-terminal or incomplete secondary evidence is stored only', () => withDb(async (db) => {
  await enable(db);
  for (const [short, goals, reason] of [['2H', [1, 0], 'not_terminal'], ['FT', null, 'incomplete_score']]) {
    const s = await seed(db, { status: 'SCHEDULED', hoursAgo: 5 });
    const fake = transport(db, () => apiResponse(envelope([fixture(s, { short, goals })])));
    const r = await edge(db, fake).call(body(s));
    assert.deepEqual([r.body.reconciliation.decision, r.body.reconciliation.reason], ['STORED_ONLY', reason]);
    assert.notEqual((await shown(db, s.match)).status, 'FINISHED_PENDING_VERIFICATION');
  }
  assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_observations where provider='api_football'")).rows[0].n, 0);
}));

test('secondary observations stay out of the read model until reconciled', () => withDb(async (db) => {
  const s = await seed(db, { status: 'SCHEDULED', hoursAgo: 5 });
  await enable(db);
  const fake = transport(db, () => apiResponse(envelope([fixture(s, { short: '2H', goals: [3, 3] })])));
  await edge(db, fake).call(body(s));
  const view = await shown(db, s.match);
  assert.notDeepEqual(view.score, { home: 3, away: 3 }, 'a stored-only LIVE observation never feeds the read model');
}));

// ---------------------------------------------------------------------------
// Scope guards.
// ---------------------------------------------------------------------------
test('U. Sportmonks (and unknown providers) are never executable', () => withDb(async (db) => {
  const s = await seed(db);
  await db.query("update futbeat_private.provider_hub_config set enabled=true,daily_budget=10 where provider='sportmonks'");
  const fake = transport(db, () => { throw new Error('never'); });
  const { call } = edge(db, fake);
  assert.deepEqual([(await call(body(s, { provider: 'sportmonks' }))).body.why], ['provider_not_executable']);
  assert.deepEqual([(await call(body(s, { provider: 'goal_api' }))).body.why], ['provider_not_executable']);
  assert.deepEqual([(await call(body(s, { provider: 'mystery' }))).body.why], ['unknown_provider']);
  assert.equal(fake.calls.length, 0);
}));

test('production config stays disabled; GOAL quota untouched by the worker', () => withDb(async (db) => {
  assert.deepEqual((await db.query('select provider,enabled from futbeat_private.provider_hub_config order by provider')).rows,
    [{ provider: 'api_football', enabled: false }, { provider: 'goal_api', enabled: true }, { provider: 'sportmonks', enabled: false }]);
  const decide = () => db.query("select futbeat_private.quota_decision('goal_api','live-goal','live') v").then((r) => r.rows[0].v);
  const before = await decide();
  const s = await seed(db);
  await enable(db);
  await edge(db, transport(db, () => apiResponse(envelope([fixture(s)])))).call(body(s));
  assert.deepEqual(await decide(), before);
  assert.equal(before.floor, 20);
  assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_call_ledger where provider='goal_api'")).rows[0].n, 0);
}));

test('V/W/X. legacy functions unscheduled; no cron or workflow calls the new worker', async () => {
  const migrationsDir = new URL('../../supabase/migrations/', import.meta.url);
  for (const name of (await readdir(migrationsDir)).filter((f) => f.endsWith('.sql'))) {
    const text = await readFile(new URL(name, migrationsDir), 'utf8');
    assert.doesNotMatch(text, /futbeat-provider-hub-sync/, `${name} must not schedule the hub worker`);
    if (name > '20260925071000') {
      assert.doesNotMatch(text, /http_post\(\s*url\s*:=\s*'[^']*\/functions\/v1\/futbeat-(live|fixtures)-sync'/, name);
    }
  }
  const workflows = new URL('../../.github/workflows/', import.meta.url);
  for (const name of await readdir(workflows)) {
    assert.doesNotMatch(await readFile(new URL(name, workflows), 'utf8'), /futbeat-provider-hub-sync|provider-hub/, name);
  }
  for (const legacy of ['futbeat-live-sync', 'futbeat-fixtures-sync']) {
    const text = await readFile(new URL(`../../supabase/functions/${legacy}/index.ts`, import.meta.url), 'utf8');
    assert.match(text, /^\/\/ DEPRECATED \(legacy, unscheduled\)/);
  }
  const config = await readFile(new URL('../../supabase/config.toml', import.meta.url), 'utf8');
  assert.match(config, /\[functions\.futbeat-provider-hub-sync\]\s*\nverify_jwt = false/);
});
