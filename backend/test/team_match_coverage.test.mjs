import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import { collectGoalApiBaseIdentities, normalizeGoalApiFixtures } from '../providers/goal_api.mjs';

// #150 part 2: per-team match coverage. Synthetic identities only (no real
// team, competition or country is special-cased); no real provider call:
// the GOAL API is simulated and any other URL fails the test.

const token = 'test-only-cron-token-not-a-secret-123456789';
const goalKey = 'test-only-goal-key-not-a-secret';
const today = () => new Date().toISOString().slice(0, 10);
const day = (offset) => new Date(Date.now() + offset * 86400e3).toISOString().slice(0, 10);
const at = (hours) => new Date(Date.now() + hours * 3600e3).toISOString();

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

let seq = 0;
async function team(db, { externals = [], name } = {}) {
  const id = `fb_team_cov${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'team',$2)",
    [id, JSON.stringify({ id, name: name ?? `Equipo Cobertura ${seq}`, country: 'Nowhere' })]);
  for (const [i, ext] of externals.entries()) {
    await db.query(`insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id,last_seen_at)
      values('goal_api','team',$1,$2,now()-make_interval(days=>$3))`, [ext, id, i]);
  }
  return id;
}
async function remaining(db, value = 900) {
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,completed_at,provider_remaining)
    values('goal_api','live-goal','test','SUCCEEDED',now(),$1)`, [value]);
}
const fn = async (db, name, args) => {
  const entries = Object.entries(args);
  const sql = `select public.${name}(${entries.map(([k], i) => `${k}=>$${i + 1}`).join(',')}) v`;
  return (await db.query(sql, entries.map(([, v]) => v))).rows[0].v;
};
const request = (db, id, before = null) => fn(db, 'futbeat_request_team_matches', { p_team_id: id, p_before: before });
const reserve = (db, id, ext, page = 0) => fn(db, 'futbeat_reserve_goal_team_fixtures_call',
  { p_team_id: id, p_external_team_id: ext, p_page: page, p_trigger_source: 'test' });
const plan = (db) => fn(db, 'futbeat_team_fixtures_plan', { p_limit: 10 });
const coverage = (db, id) => db.query('select * from futbeat_private.team_match_coverage where team_id=$1', [id]).then((r) => r.rows[0]);
const demands = (db) => db.query('select * from futbeat_private.team_match_demands order by team_id').then((r) => r.rows);
const metric = (db, name) => db.query('select coalesce(sum(value),0)::int n from futbeat_private.demand_metrics where metric=$1', [name])
  .then((r) => r.rows[0].n);
const ledger = (db) => db.query("select * from futbeat_private.provider_call_ledger where call_kind='team-fixtures' order by id").then((r) => r.rows);
const state = (db, id) => db.query('select futbeat_private.team_match_coverage_state($1) v', [id]).then((r) => r.rows[0].v);

const complete = (db, id, { from = day(-180), to = day(120), full = true, raw, received, fresh = received, known = 0 }) =>
  fn(db, 'futbeat_complete_team_fixtures', { p_team_id: id, p_from: from, p_to: to, p_complete: full,
    p_raw: raw ?? received, p_received: received, p_new: fresh - known, p_existing: known });

async function fullCoverage(db, id, extra = {}) {
  await db.query(`insert into futbeat_private.team_match_coverage(team_id,status,covered_from,covered_to,window_complete,last_success_at)
    values($1,'AVAILABLE',current_date-200,current_date+130,true,now())`, [id]);
  if (extra.sql) await db.query(extra.sql, [id]);
}

// ---------------------------------------------------------------------------
// Demand and state (SQL)
// ---------------------------------------------------------------------------

test('complete fresh coverage creates no demand', () => withDb(async (db) => {
  const t = await team(db, { externals: ['cov-a'] });
  await fullCoverage(db, t);
  assert.equal((await state(db, t)).state, 'AVAILABLE');
  const r = await request(db, t);
  assert.equal(r.demandRecorded, false);
  assert.equal((await demands(db)).length, 0);
}));

test('incomplete coverage creates one demand; 100 opens are one logical demand', () => withDb(async (db) => {
  const t = await team(db, { externals: ['cov-b'] });
  assert.equal((await state(db, t)).state, 'PENDING');
  assert.equal((await request(db, t)).demandRecorded, true);
  for (let i = 0; i < 99; i++) await request(db, t);
  const rows = await demands(db);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].request_count, 1); // throttled: one write a minute
  assert.equal(await metric(db, 'team_match_demand_created'), 1);
  assert.equal(await metric(db, 'team_match_demand_deduped'), 99);
  assert.equal((await ledger(db)).length, 0); // opening never reserves provider quota
}));

test('stale, partial or narrow coverage asks again; aliases converge on the canonical team', () => withDb(async (db) => {
  const t = await team(db, { externals: ['cov-c'] });
  await fullCoverage(db, t, { sql: "update futbeat_private.team_match_coverage set last_success_at=now()-interval '5 days' where team_id=$1" });
  assert.equal((await state(db, t)).state, 'STALE');
  await db.query('update futbeat_private.team_match_coverage set last_success_at=now(),window_complete=false where team_id=$1', [t]);
  assert.equal((await state(db, t)).reason, 'partial');
  const alias = await team(db);
  await db.query("insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values($1,$2,'team','test')", [alias, t]);
  await request(db, alias);
  assert.deepEqual((await demands(db)).map((d) => d.team_id), [t]);
}));

test('zero provider mapping: UNAVAILABLE, no demand, never planned', () => withDb(async (db) => {
  const t = await team(db);
  assert.deepEqual(await state(db, t), { state: 'UNAVAILABLE', reason: 'no_provider_source', windowComplete: false });
  assert.equal((await request(db, t)).demandRecorded, false);
  await db.query('insert into futbeat_private.team_match_demands(team_id) values($1)', [t]);
  assert.deepEqual(await plan(db), []);
}));

test('multiple external mappings (and alias mappings) are all planned, most recently seen first', () => withDb(async (db) => {
  const t = await team(db, { externals: ['cov-new', 'cov-old'] });
  const alias = await team(db, { externals: ['cov-alias'] });
  await db.query("update futbeat_private.provider_entities set last_seen_at=now()-interval '9 days' where external_id='cov-alias'");
  await db.query("insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values($1,$2,'team','test')", [alias, t]);
  await request(db, t);
  const [row] = await plan(db);
  assert.equal(row.teamId, t);
  assert.deepEqual(row.externalTeamIds, ['cov-new', 'cov-old', 'cov-alias']);
  assert.equal(row.from, day(-180));
  assert.equal(row.to, day(120));
  assert.equal(row.mode, 'window');
}));

test('followed teams and near matches rank first; demand is consumed by the attempt', () => withDb(async (db) => {
  const plain = await team(db, { externals: ['cov-p'] });
  const followed = await team(db, { externals: ['cov-f'] });
  await db.query("insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth) values('team',$1,1,'DEEP')", [followed]);
  await request(db, followed);
  await request(db, plain);
  assert.deepEqual((await plan(db)).map((r) => [r.teamId, r.reason]), [[followed, 'followed'], [plain, 'profile']]);
  await remaining(db);
  assert.equal((await reserve(db, followed, 'cov-f')).allowed, true);
  assert.deepEqual((await plan(db)).map((r) => r.teamId), [plain]);
}));

// ---------------------------------------------------------------------------
// Reservation: quota, LIVE floor, lease, backoff
// ---------------------------------------------------------------------------

test('lease prevents a second worker; later pages need the lease', () => withDb(async (db) => {
  const t = await team(db, { externals: ['cov-l'] });
  await remaining(db);
  const first = await reserve(db, t, 'cov-l', 0);
  assert.equal(first.allowed, true);
  assert.equal((await reserve(db, t, 'cov-l', 0)).reason, 'team_fixtures_inflight_or_backoff');
  assert.equal((await reserve(db, t, 'cov-l', 1)).allowed, true);
  await db.query('update futbeat_private.team_match_coverage set lease_until=now()-interval \'1 second\' where team_id=$1', [t]);
  assert.equal((await reserve(db, t, 'cov-l', 1)).reason, 'team_fixtures_lease_lost');
  await assert.rejects(reserve(db, t, 'not-this-team', 0), /Invalid GOAL team fixtures reservation/);
  assert.equal(await metric(db, 'team_match_fetch_reserved'), 2);
}));

test('quota denied means zero reservation; LIVE keeps its floor; own daily cap', () => withDb(async (db) => {
  const t = await team(db, { externals: ['cov-q'] });
  await remaining(db, 250); // below the coverage floor (300), above LIVE (20)
  const denied = await reserve(db, t, 'cov-q');
  assert.equal(denied.allowed, false);
  assert.equal(denied.reason, 'provider_remaining_reserve');
  assert.equal((await ledger(db)).length, 0);
  assert.equal(await coverage(db, t), undefined, 'no lease taken when quota says no');
  const live = (await db.query("select futbeat_private.quota_decision('goal_api','live-goal','live') v")).rows[0].v;
  assert.equal(live.allowed, true);
  await remaining(db, 900);
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,completed_at)
    select 'goal_api','team-fixtures','test','SUCCEEDED',now() from generate_series(1,60)`);
  assert.equal((await reserve(db, t, 'cov-q')).reason, 'kind_daily_cap');
}));

test('one failed page changes nothing team-level; a team failure backs off and is never NO_DATA', () => withDb(async (db) => {
  const t = await team(db, { externals: ['cov-e', 'cov-e2'] });
  await remaining(db);
  const r = await reserve(db, t, 'cov-e');
  await db.query(`select public.futbeat_complete_provider_call(p_reservation_id=>$1,p_status=>'FAILED',p_provider_remaining=>null,
    p_http_status=>404,p_error_code=>'X',p_metadata=>'{}')`, [r.reservationId]);
  // The batch keeps its lease: the next identity can still be paged.
  let c = await coverage(db, t);
  assert.ok(new Date(c.lease_until) > new Date(), 'lease kept after an individual failure');
  assert.equal(c.status, 'PENDING');
  assert.equal((await reserve(db, t, 'cov-e2', 1)).allowed, true);
  // Every identity 404: long backoff (stale mappings), never NO_DATA.
  const failed = await fn(db, 'futbeat_fail_team_fixtures', { p_team_id: t, p_reason: 'FETCH_FAILED', p_http_statuses: JSON.stringify([404, 404]) });
  assert.equal(failed.state, 'PENDING');
  c = await coverage(db, t);
  assert.equal(c.status, 'FETCH_FAILED');
  assert.equal(c.lease_until, null);
  assert.equal(c.window_complete, false);
  assert.ok(new Date(c.next_retry_at) > new Date(Date.now() + 6 * 86400e3));
  assert.equal((await reserve(db, t, 'cov-e')).reason, 'team_fixtures_inflight_or_backoff');
  // A 500 backs off briefly (exponential), still never NO_DATA.
  await db.query('update futbeat_private.team_match_coverage set next_retry_at=null where team_id=$1', [t]);
  await reserve(db, t, 'cov-e');
  await fn(db, 'futbeat_fail_team_fixtures', { p_team_id: t, p_reason: 'FETCH_FAILED', p_http_statuses: JSON.stringify([500]) });
  c = await coverage(db, t);
  assert.ok(new Date(c.next_retry_at) < new Date(Date.now() + 86400e3 + 60e3));
  assert.notEqual((await state(db, t)).state, 'NO_DATA');
  assert.equal(await metric(db, 'team_match_fetch_failed'), 2);
}));

test('partial answers never mark the window complete; only a confirmed empty answer is NO_DATA', () => withDb(async (db) => {
  const t = await team(db, { externals: ['cov-w'] });
  await remaining(db);
  await reserve(db, t, 'cov-w');
  const partial = await complete(db, t, { full: false, received: 100 });
  assert.deepEqual([partial.state, partial.reason], ['STALE', 'partial']);
  let c = await coverage(db, t);
  assert.equal(c.window_complete, false);
  assert.equal(c.covered_from, null);
  assert.ok(new Date(c.next_retry_at) > new Date());
  await db.query('update futbeat_private.team_match_coverage set next_retry_at=null where team_id=$1', [t]);
  await reserve(db, t, 'cov-w');
  const full = await complete(db, t, { received: 40, fresh: 40, known: 30 });
  assert.equal(full.state, 'AVAILABLE');
  c = await coverage(db, t);
  assert.equal(c.window_complete, true);
  assert.equal(await metric(db, 'team_match_fixtures_new'), 110);
  assert.equal(await metric(db, 'team_match_fixtures_existing'), 30);

  const empty = await team(db, { externals: ['cov-empty'] });
  await reserve(db, empty, 'cov-empty');
  const none = await complete(db, empty, { raw: 0, received: 0 });
  assert.equal(none.state, 'NO_DATA');
  assert.equal(await metric(db, 'team_match_fetch_no_data'), 1);
}));

test('raw items that do not normalize are a schema failure, never NO_DATA', () => withDb(async (db) => {
  const t = await team(db, { externals: ['cov-s'] });
  await remaining(db);
  await reserve(db, t, 'cov-s');
  const out = await complete(db, t, { raw: 10, received: 0 });
  assert.notEqual(out.state, 'NO_DATA');
  const c = await coverage(db, t);
  assert.equal(c.status, 'FETCH_FAILED');
  assert.equal(c.window_complete, false);
  assert.equal(c.last_error, 'NORMALIZATION_FAILED');
  assert.equal(c.lease_until, null);
  assert.ok(new Date(c.next_retry_at) > new Date(), 'retry is scheduled');
  assert.equal(await metric(db, 'team_match_fetch_no_data'), 0);
  // After the backoff the team can be asked again.
  await db.query('update futbeat_private.team_match_coverage set next_retry_at=now()-interval \'1 second\' where team_id=$1', [t]);
  assert.equal((await request(db, t)).demandRecorded, true);
  assert.equal((await plan(db)).length, 1);
}));

test('fewer accepted than raw never completes the window, even when the worker says complete', () => withDb(async (db) => {
  const t = await team(db, { externals: ['cov-r'] });
  await remaining(db);
  await reserve(db, t, 'cov-r');
  const out = await complete(db, t, { raw: 12, received: 8 });
  assert.equal(out.windowComplete, false);
  const c = await coverage(db, t);
  assert.equal(c.window_complete, false);
  assert.equal(c.covered_from, null);
  assert.equal(c.status, 'AVAILABLE');
  assert.equal(c.last_error, 'PARTIAL_WINDOW');
  await assert.rejects(complete(db, t, { raw: 3, received: 3, fresh: 5 }), /Invalid team fixtures completion/);
}));

test('end of Resultados asks centrally for the older window (backfill)', () => withDb(async (db) => {
  const t = await team(db, { externals: ['cov-h'] });
  await fullCoverage(db, t);
  const oldest = (await coverage(db, t)).covered_from.toISOString().slice(0, 10);
  const r = await request(db, t, oldest);
  assert.equal(r.backfill, true);
  assert.equal(r.demandRecorded, true);
  const [row] = await plan(db);
  assert.equal(row.mode, 'history');
  assert.equal(row.to, oldest);
  assert.equal(row.from, new Date(Date.parse(oldest) - 180 * 86400e3).toISOString().slice(0, 10));
  // Older than the 3-year floor: nothing more is asked.
  assert.equal((await request(db, t, day(-1200))).backfill, false);
}));

// ---------------------------------------------------------------------------
// Worker + ingest end to end (real handlers, local SQL, simulated GOAL)
// ---------------------------------------------------------------------------

const workerSource = await readFile(new URL('../../supabase/functions/futbeat-goal-live-sync/index.ts', import.meta.url), 'utf8');
const ingestSource = await readFile(new URL('../../supabase/functions/futbeat-global-ingest/index.ts', import.meta.url), 'utf8');
const paginationSource = await readFile(new URL('../../supabase/functions/_shared/results_pagination.ts', import.meta.url), 'utf8');
const liveEventsSource = await readFile(new URL('../../supabase/functions/_shared/live_events.ts', import.meta.url), 'utf8');
const stripImports = (source) => source.replace(/^import\s[\s\S]*?;\r?\n/gm, '');

function edge(source, fetch, logs, globals = {}) {
  let handler;
  const context = vm.createContext({
    Request, Response, Headers, URL, URLSearchParams, AbortSignal, TextEncoder, crypto, performance, Error,
    fetch,
    console: { error: (...a) => logs.push(a), warn: (...a) => logs.push(a), log: (...a) => logs.push(a) },
    Deno: {
      env: { get: (name) => ({ SUPABASE_URL: 'https://supabase.test', SUPABASE_SERVICE_ROLE_KEY: 'test-service-key' })[name] },
      serve: (f) => { handler = f; },
    },
    ...globals,
  });
  vm.runInContext(stripTypeScriptTypes(stripImports(source)), context);
  return { handler, context };
}

const SQL_RPCS = new Set(['futbeat_team_fixtures_plan', 'futbeat_reserve_goal_team_fixtures_call',
  'futbeat_complete_provider_call', 'futbeat_resolve_global_entities', 'futbeat_read_entity_detail',
  'futbeat_known_goal_fixtures', 'futbeat_store_calendar_range', 'futbeat_complete_team_fixtures',
  'futbeat_fail_team_fixtures']);

function harness(db, provider) {
  const calls = [], logs = [], unexpected = [];
  let ingest;
  const fetch = async (input, init = {}) => {
    const url = new URL(input);
    const body = init.body ? JSON.parse(init.body) : {};
    calls.push({ url: url.href, body, init });
    if (url.origin === 'https://supabase.test' && url.pathname.startsWith('/rest/v1/rpc/')) {
      const name = url.pathname.split('/').at(-1);
      if (name === 'futbeat_read_goal_live_cron_token') return Response.json(token);
      if (name === 'futbeat_read_goal_live_secret') return Response.json(goalKey);
      if (!SQL_RPCS.has(name)) { unexpected.push(name); throw new Error(`Unexpected RPC ${name}`); }
      const entries = Object.entries(body);
      const args = entries.map(([k], i) => `${k} => $${i + 1}`).join(',');
      const values = entries.map(([, v]) => v != null && typeof v === 'object' ? JSON.stringify(v) : v);
      if (name === 'futbeat_resolve_global_entities') {
        return Response.json((await db.query(`select * from public.${name}(${args})`, values)).rows);
      }
      return Response.json((await db.query(`select public.${name}(${args}) value`, values)).rows[0].value);
    }
    if (url.origin === 'https://api.goal-api.com') {
      assert.equal(init.headers.Authorization, `Bearer ${goalKey}`);
      return provider(url);
    }
    if (url.href === 'https://supabase.test/functions/v1/futbeat-global-ingest') {
      assert.equal(init.headers['x-futbeat-cron-token'], token);
      return ingest(new Request(url, init));
    }
    unexpected.push(url.href);
    throw new Error(`Unexpected request ${url.href}`);
  };
  const worker = edge((paginationSource + '\n' + liveEventsSource).replace(/^export /gm, '') + '\n' + workerSource, fetch, logs);
  ingest = edge(ingestSource, fetch, logs, {
    collectGoalApiBaseIdentities, normalizeGoalApiFixtures,
    createRemoteJWKSet: () => () => { throw new Error('OIDC must not run'); },
    jwtVerify: () => { throw new Error('OIDC must not run'); },
  }).handler;
  return {
    calls, logs,
    providers: () => calls.filter((c) => new URL(c.url).origin === 'https://api.goal-api.com'),
    async run(body = { trigger: 'team-fixtures-only' }) {
      const response = await worker.handler(new Request('https://worker.test/', {
        method: 'POST', headers: { 'x-futbeat-cron-token': token }, body: JSON.stringify(body) }));
      const value = await response.json();
      assert.deepEqual(unexpected, [], 'no unmocked network or RPC surface');
      return { status: response.status, value };
    },
  };
}

const fixture = (id, hours, { league = ['lg-1', 'Liga Sintética'], home, away, status = 'NOT_STARTED', score } = {}) => ({
  apiId: id, kickoffUtc: at(hours), matchStatus: status,
  league: { id: league[0], name: league[1] },
  homeTeam: { id: home[0], name: home[1] }, awayTeam: { id: away[0], name: away[1] },
  ...(score ? { homeTeamScore: score[0], awayTeamScore: score[1] } : {}),
});
const goalPage = (data, hasMore = false, remainingValue = 800) => new Response(JSON.stringify({
  success: true, data, pagination: { total: data.length, limit: 100, offset: 0, hasMore } }),
{ status: 200, headers: { 'x-ratelimit-remaining': String(remainingValue), 'content-type': 'application/json' } });

async function seedTeam(db, externals) {
  const t = await team(db, { externals });
  await remaining(db);
  return t;
}
const readTeam = async (db, id, bucket) =>
  (await db.query("select public.futbeat_read_team_matches($1,$2,null,50) v", [id, bucket])).rows[0].v.matches;

test('worker: two external ids, several competitions, past + future, dedup with date-ingest and reschedule', () => withDb(async (db) => {
  const t = await seedTeam(db, ['ext-main', 'ext-second']);
  const us = ['ext-main', 'Equipo Cobertura'];
  // A date-ingest stored fx-1 first (same GOAL fixture id).
  const snapshot = await normalizeGoalApiFixtures([fixture('fx-1', 48, { home: us, away: ['r-1', 'Rival Uno'] })],
    async (kind, external, identity) => (await db.query(
      'select public.futbeat_resolve_global_entity($1,$2,$3,$4) id', ['goal_api', kind, external, identity.name])).rows[0].id,
    new Date().toISOString());
  await db.query("select public.futbeat_store_calendar_range('goal_api',now(),'[]'::jsonb,$1)", [JSON.stringify(snapshot)]);
  const existingId = snapshot.matches[0].id;
  await request(db, t);

  const h = harness(db, (url) => {
    const params = Object.fromEntries(url.searchParams);
    assert.equal(params.from, day(-180));
    assert.equal(params.to, day(120));
    assert.equal(params.limit, '100');
    if (url.pathname === '/v1/teams/ext-main/fixtures') {
      return goalPage([
        // fx-1 rescheduled one day later by the provider.
        fixture('fx-1', 72, { home: us, away: ['r-1', 'Rival Uno'] }),
        fixture('fx-2', -240, { home: ['r-2', 'Rival Dos'], away: us, status: 'FINISHED', score: [0, 2] }),
        fixture('fx-3', 24 * 30, { league: ['lg-2', 'Copa Sintética'], home: us, away: ['r-3', 'Rival Tres'] }),
      ]);
    }
    if (url.pathname === '/v1/teams/ext-second/fixtures') {
      // Same fixture seen through the second identity, plus one more.
      return goalPage([
        fixture('fx-3', 24 * 30, { league: ['lg-2', 'Copa Sintética'], home: us, away: ['r-3', 'Rival Tres'] }),
        fixture('fx-4', -24 * 60, { league: ['lg-3', 'Amistoso Sintético'], home: us, away: ['r-4', 'Rival Cuatro'],
          status: 'FINISHED', score: [1, 1] }),
      ]);
    }
    throw new Error(`unexpected provider path ${url.pathname}`);
  });
  const { value } = await h.run();
  assert.equal(value.result.status, 'ok', JSON.stringify({ value, logs: h.logs }));
  assert.equal(value.providerCalls, 2);
  assert.equal(value.reservations, 2);
  assert.equal(value.result.newMatches, 3);
  assert.equal(value.result.existingMatches, 1);
  assert.equal(value.result.windowComplete, true);
  assert.ok(h.providers().every((c) => c.init.redirect === 'error'));

  const matches = (await db.query(`select e.id,e.payload from futbeat_private.entities e
    join futbeat_private.provider_entities p on p.canonical_id=e.id and p.provider='goal_api' and p.kind='match'
    where p.external_id=any($1)`, [['fx-1', 'fx-2', 'fx-3', 'fx-4']])).rows;
  assert.equal(matches.length, 4, 'one canonical match per GOAL fixture');
  const fx1 = matches.find((m) => m.id === existingId);
  assert.ok(fx1, 'the date-ingested match keeps its canonical id');
  assert.ok(Math.abs(Date.parse(fx1.payload.startTime) - Date.parse(at(72))) < 60e3, 'reschedule updated the same match');
  // Canonical ids everywhere: the team, not its provider ids.
  assert.ok(matches.every((m) => [m.payload.homeTeamId, m.payload.awayTeamId].includes(t)));
  assert.equal(new Set(matches.map((m) => m.payload.competitionId)).size, 3);
  const comps = (await db.query("select id from futbeat_private.entities where kind='competition' and id=any($1)",
    [matches.map((m) => m.payload.competitionId)])).rows;
  assert.equal(comps.length, 3, 'provider leagues resolved to canonical competitions');

  // #152 read model sees them with no extra step.
  const upcoming = (await readTeam(db, t, 'upcoming')).map((m) => m.id);
  const results = (await readTeam(db, t, 'results')).map((m) => m.id);
  assert.equal(upcoming.length, 2);
  assert.equal(results.length, 2);
  assert.ok(upcoming.includes(existingId));

  const c = await coverage(db, t);
  assert.equal(c.status, 'AVAILABLE');
  assert.equal(c.window_complete, true);
  assert.equal(c.covered_from.toISOString().slice(0, 10), day(-180));
  assert.equal((await state(db, t)).state, 'AVAILABLE');
  assert.equal((await ledger(db)).filter((r) => r.status === 'SUCCEEDED').length, 2);

  // Served from the central cache now: no second provider call.
  const again = await h.run();
  assert.equal(again.value.result.reason, 'no_team_fixtures_due');
  assert.equal(h.providers().length, 2);
  assert.equal((await request(db, t)).demandRecorded, false);
}));

const storeFixtures = async (db, fixtures, resolveMatch = null) => {
  const snapshot = await normalizeGoalApiFixtures(fixtures, async (kind, external, identity) => {
    if (kind === 'match' && resolveMatch) return resolveMatch(external);
    return (await db.query('select public.futbeat_resolve_global_entity($1,$2,$3,$4) id',
      ['goal_api', kind, external, identity.name])).rows[0].id;
  }, new Date().toISOString());
  await db.query("select public.futbeat_store_calendar_range('goal_api',now(),'[]'::jsonb,$1)", [JSON.stringify(snapshot)]);
  return snapshot;
};
const byIdentity = (answers) => (url) => {
  const ext = url.pathname.split('/')[3];
  const answer = answers[ext];
  if (typeof answer === 'number') return new Response(JSON.stringify({ success: false }), { status: answer });
  if (Array.isArray(answer)) return goalPage(answer);
  throw new Error(`unexpected identity ${ext}`);
};
const many = (n, ext, prefix) => Array.from({ length: n }, (_, i) => fixture(`${prefix}-${i}`, -24 * (i + 1),
  { home: [ext, 'Equipo'], away: [`${prefix}-r${i}`, `Rival ${i}`], status: 'FINISHED', score: [1, 0] }));

test('worker: identity A 404 + identity B 20 fixtures stores 20, never NO_DATA', () => withDb(async (db) => {
  const t = await seedTeam(db, ['id-a', 'id-b']);
  await request(db, t);
  const h = harness(db, byIdentity({ 'id-a': 404, 'id-b': many(20, 'id-b', 'fb20') }));
  const { value } = await h.run();
  assert.equal(value.result.status, 'ok', JSON.stringify(value));
  assert.equal(value.providerCalls, 2, 'the second identity is still tried');
  assert.equal(value.result.accepted, 20);
  assert.equal(value.result.windowComplete, false);
  assert.equal(value.result.failedIdentities, 1);
  const st = await state(db, t);
  assert.deepEqual([st.state, st.reason], ['STALE', 'partial']);
  assert.equal((await readTeam(db, t, 'results')).length, 20);
  const rows = (await ledger(db)).map((r) => [r.metadata.externalTeamId, r.status, r.http_status]);
  assert.deepEqual(rows, [['id-a', 'FAILED', 404], ['id-b', 'SUCCEEDED', 200]]);
}));

test('worker: A 404 + B empty 200 is not NO_DATA; A empty + B empty is', () => withDb(async (db) => {
  const t = await seedTeam(db, ['na-a', 'na-b']);
  await request(db, t);
  const h = harness(db, byIdentity({ 'na-a': 404, 'na-b': [] }));
  const first = await h.run();
  assert.equal(first.value.result.status, 'ok', JSON.stringify(first.value));
  const st = await state(db, t);
  assert.notEqual(st.state, 'NO_DATA');
  assert.equal((await coverage(db, t)).last_error, 'PARTIAL_IDENTITIES');

  const u = await seedTeam(db, ['ne-a', 'ne-b']);
  await request(db, u);
  const h2 = harness(db, byIdentity({ 'ne-a': [], 'ne-b': [] }));
  const second = await h2.run();
  assert.equal(second.value.result.status, 'ok', JSON.stringify(second.value));
  assert.equal(h2.providers().length, 2);
  assert.equal((await state(db, u)).state, 'NO_DATA');
}));

test('worker: A 500 + B fixtures keeps the fixtures, window not complete, lease kept for B', () => withDb(async (db) => {
  const t = await seedTeam(db, ['f5-a', 'f5-b']);
  await request(db, t);
  const h = harness(db, byIdentity({ 'f5-a': 500, 'f5-b': many(4, 'f5-b', 'fb5') }));
  const { value } = await h.run();
  assert.equal(value.result.status, 'ok', JSON.stringify(value));
  assert.equal(value.reservations, 2, 'B was reserved after A failed: the lease survived');
  const c = await coverage(db, t);
  assert.equal(c.window_complete, false);
  assert.equal(c.lease_until, null, 'released once, at the end of the batch');
  assert.equal((await readTeam(db, t, 'results')).length, 4);
}));

test('worker: 10 raw items the normalizer cannot read are not NO_DATA and keep stored data', () => withDb(async (db) => {
  const t = await seedTeam(db, ['sch-a']);
  await storeFixtures(db, [fixture('fx-old', -48, { home: ['sch-a', 'Equipo'], away: ['sch-r', 'Rival'], status: 'FINISHED', score: [2, 1] })]);
  await request(db, t);
  // Unknown shape: no league/team objects the normalizer understands.
  const unknown = Array.from({ length: 10 }, (_, i) => ({ apiId: `raw-${i}`, date: day(-i), teams: `x${i}` }));
  const h = harness(db, byIdentity({ 'sch-a': unknown }));
  const { value } = await h.run();
  assert.equal(value.result.status, 'ok', JSON.stringify(value));
  assert.equal(value.result.accepted, 0);
  const c = await coverage(db, t);
  assert.notEqual(c.status, 'NO_DATA');
  assert.equal(c.window_complete, false);
  assert.equal(c.last_error, 'NORMALIZATION_FAILED');
  assert.ok(new Date(c.next_retry_at) > new Date());
  assert.equal((await readTeam(db, t, 'results')).length, 1, 'existing data intact');
}));

test('worker: raw > accepted does not complete the window', () => withDb(async (db) => {
  const t = await seedTeam(db, ['ra-a']);
  await request(db, t);
  const h = harness(db, byIdentity({ 'ra-a': [...many(3, 'ra-a', 'ra'), { apiId: 'ra-bad', nothing: true }] }));
  const { value } = await h.run();
  assert.equal(value.result.accepted, 3);
  assert.equal(value.result.windowComplete, false);
  assert.equal((await coverage(db, t)).window_complete, false);
}));

test('worker: a match stored without a GOAL mapping counts as existing, not new', () => withDb(async (db) => {
  const t = await seedTeam(db, ['ex-a']);
  // Stored by another path: same teams and kickoff, no GOAL fixture mapping.
  const kickoff = 30;
  const stored = await storeFixtures(db,
    [fixture('other-provider', kickoff, { home: ['ex-a', 'Equipo'], away: ['ex-r', 'Rival'] })],
    async () => 'fb_match_unmapped_manual');
  assert.equal(stored.matches[0].id, 'fb_match_unmapped_manual');
  await request(db, t);
  const h = harness(db, byIdentity({ 'ex-a': [
    fixture('goal-fx', kickoff, { home: ['ex-a', 'Equipo'], away: ['ex-r', 'Rival'] }),
    fixture('goal-new', 24 * 9, { home: ['ex-a', 'Equipo'], away: ['ex-r2', 'Rival Dos'] }),
  ] }));
  const { value } = await h.run();
  assert.equal(value.result.status, 'ok', JSON.stringify(value));
  assert.equal(value.result.existingMatches, 1);
  assert.equal(value.result.newMatches, 1);
  const ids = (await readTeam(db, t, 'upcoming')).map((m) => m.id);
  assert.ok(ids.includes('fb_match_unmapped_manual'), 'deduplicated onto the existing canonical match');
  assert.equal(ids.length, 2);
}));

test('worker: provider error keeps stored data and backs off; quota denial makes no call', () => withDb(async (db) => {
  const t = await seedTeam(db, ['ext-err']);
  const kept = await normalizeGoalApiFixtures([fixture('fx-kept', 24, { home: ['ext-err', 'Equipo'], away: ['r-9', 'Rival'] })],
    async (kind, external, identity) => (await db.query(
      'select public.futbeat_resolve_global_entity($1,$2,$3,$4) id', ['goal_api', kind, external, identity.name])).rows[0].id,
    new Date().toISOString());
  await db.query("select public.futbeat_store_calendar_range('goal_api',now(),'[]'::jsonb,$1)", [JSON.stringify(kept)]);
  await request(db, t);
  const h = harness(db, () => new Response(JSON.stringify({ success: false }), { status: 500 }));
  const { value } = await h.run();
  assert.equal(value.result.status, 'failed');
  assert.equal(h.providers().length, 1);
  assert.equal(h.calls.filter((c) => c.url.endsWith('/futbeat-global-ingest')).length, 0);
  assert.equal((await coverage(db, t)).status, 'FETCH_FAILED');
  assert.equal((await readTeam(db, t, 'upcoming')).length, 1, 'stored matches survive a failure');

  const q = await seedTeam(db, ['ext-quota']);
  await remaining(db, 100);
  await db.query("update futbeat_private.team_match_coverage set next_retry_at=now()+interval '1 day'");
  await request(db, q);
  const denied = harness(db, () => { throw new Error('provider must not be called'); });
  const out = await denied.run();
  assert.equal(out.value.result.status, 'skipped');
  assert.equal(out.value.result.reason, 'provider_remaining_reserve');
  assert.equal(denied.providers().length, 0);
}));

test('worker: page cap with more pages left stores the fixtures but not a complete window', () => withDb(async (db) => {
  const t = await seedTeam(db, ['ext-many']);
  await request(db, t);
  let n = 0;
  const h = harness(db, (url) => {
    const offset = Number(url.searchParams.get('offset'));
    const data = Array.from({ length: 100 }, (_, i) => fixture(`fx-p${offset + i}`, -24 * (n * 100 + i + 1) / 10,
      { home: ['ext-many', 'Equipo'], away: [`r-p${offset + i}`, `Rival ${offset + i}`], status: 'FINISHED', score: [1, 0] }));
    n++;
    return goalPage(data, true);
  });
  const { value } = await h.run();
  assert.equal(value.result.status, 'ok', JSON.stringify(value));
  assert.equal(value.providerCalls, 3);
  assert.equal(value.result.windowComplete, false);
  const c = await coverage(db, t);
  assert.equal(c.window_complete, false);
  assert.equal(c.covered_from, null);
  assert.notEqual((await state(db, t)).state, 'AVAILABLE');
  assert.equal(value.result.newMatches, 300);
}));

test('worker lane accepts no overrides and is not part of any cron run', () => withDb(async (db) => {
  const h = harness(db, () => { throw new Error('no provider'); });
  const bad = await h.run({ trigger: 'team-fixtures-only', teamId: 'fb_team_evil' });
  assert.equal(bad.status, 400);
  const none = await h.run();
  assert.equal(none.value.result.reason, 'no_team_fixtures_due');
  assert.equal(h.providers().length, 0);
  // Only the manual trigger calls the lane.
  assert.deepEqual(workerSource.match(/syncOneTeamFixtures\(/g).length, 2); // definition + manual wrapper
  assert.match(workerSource, /trigger === "team-fixtures-only"/);
}));

// ---------------------------------------------------------------------------
// Static guards
// ---------------------------------------------------------------------------

const migration = await readFile(new URL('../../supabase/migrations/20260929110000_team_match_coverage.sql', import.meta.url), 'utf8');
const apiSource = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
const stripSqlComments = (sql) => sql.replace(/--[^\n]*/g, '');

test('no cron, secret, Provider Hub or hardcoded team in this change', async () => {
  const code = stripSqlComments(migration);
  assert.doesNotMatch(code, /cron\.|schedule\s*\(/i);
  assert.doesNotMatch(code, /vault|secret/i);
  assert.doesNotMatch(code, /provider_hub/i);
  for (const source of [code, apiSource, workerSource, ingestSource]) {
    assert.doesNotMatch(source, /costa rica|santos|fb_team_1d0167e3|fb_team_0da8c678/i);
  }
});

test('API: demand never blocks the profile read (cache-first)', () => {
  assert.match(apiSource, /'futbeat_request_team_matches',\s*\{ p_team_id: id \}/);
  assert.match(apiSource, /if \(matchesError\) console\.warn\('team matches demand unavailable'\);/);
  assert.match(apiSource, /if \(historyError\) console\.warn\('team history demand unavailable'\);/);
  assert.doesNotMatch(apiSource, /goal-api\.com|\bfetch\(/i);
});

test('mobile contains no provider URL or call', async () => {
  const offenders = [];
  const walk = async (dir) => {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const path = new URL(entry.name + (entry.isDirectory() ? '/' : ''), dir);
      if (entry.isDirectory()) await walk(path);
      else if (entry.name.endsWith('.dart')) {
        const source = (await readFile(path, 'utf8')).toLowerCase();
        for (const host of ['api.goal-api.com', 'goal-api.com/v1', 'api-sports.io', 'api-football', 'thesportsdb']) {
          if (source.includes(host)) offenders.push(`${entry.name}:${host}`);
        }
      }
    }
  };
  await walk(new URL('../../apps/mobile/lib/', import.meta.url));
  assert.deepEqual(offenders, []);
});

test('demand and planner queries are indexed', () => withDb(async (db) => {
  const idx = (await db.query(`select indexname from pg_indexes where schemaname='futbeat_private'
    and tablename in ('team_match_demands','team_match_coverage','entities')`)).rows.map((r) => r.indexname);
  for (const name of ['team_match_demands_pkey', 'team_match_demands_requested_idx', 'team_match_coverage_pkey',
    'entities_match_home_team_idx', 'entities_match_away_team_idx']) assert.ok(idx.includes(name), name);
}));
