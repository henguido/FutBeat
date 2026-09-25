import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';

// Production incident: futbeat_reserve_goal_results_date failed at
// stage="reserve" with "UPDATE requires a WHERE clause" -- only through
// PostgREST (authenticator role, which loads pg_safeupdate for the whole
// session), never in a direct psql session. Root cause: reconcile_goal_
// results_local -> `update futbeat_private.entities ... where id=...` fires
// the invalidate_compact_calendar trigger -> futbeat_private.
// invalidate_calendar_cache() -> a genuinely bare
// `update futbeat_private.catalog_cache_version set revision=revision+1;`
// with no WHERE clause at all. See supabase/migrations/
// 20260923160000_results_reservation_safeupdate_fix.sql for the full trace
// and the fix (adds `where singleton`, the table's own primary key).
//
// pg_safeupdate is a native Postgres C extension (session_preload_libraries)
// and cannot be loaded by the local PGlite (WASM Postgres) engine these
// tests run against -- there is no live safeupdate-enabled run available
// locally. The guard below is therefore a STATIC text check over the actual
// migration SQL: it finds the latest definition of every function in the
// reserve_goal_results_date call graph and asserts none contains a bare
// UPDATE/DELETE (no WHERE clause), the exact shape safeupdate rejects. This
// is what would have caught the original bug before it ever reached
// production, and prevents it from being reintroduced.

const MIGRATIONS_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../supabase/migrations');

// Finds statements that pg_safeupdate would reject: a top-level UPDATE or
// DELETE FROM with no WHERE clause anywhere in the statement. Deliberately
// does NOT flag `INSERT ... ON CONFLICT DO UPDATE SET ...` without a WHERE
// on the conflict action -- pg_safeupdate's post_parse_analyze hook only
// inspects queries whose top-level commandType is UPDATE/DELETE, so an
// INSERT statement (even with an upsert clause) is never checked. This
// matches observed production behavior: the (git-less) production hotfix
// added `WHERE true` to ON CONFLICT DO UPDATE clauses and did NOT fix the
// failure, confirming those were never the problem.
export function findUnsafeStatements(sql) {
  const re = /\b(update|delete\s+from)\s+[a-zA-Z_.]+[\s\S]*?;/gi;
  const hits = [];
  let m;
  while ((m = re.exec(sql))) {
    const stmt = m[0];
    const before = sql.slice(Math.max(0, m.index - 200), m.index).toLowerCase();
    if (/on conflict[\s\S]*do\s*$/.test(before)) continue;
    // `select ... for update [skip locked]` is a row-locking clause, not an
    // UPDATE statement; the bare word "update" there is not the DML keyword.
    if (/\bfor\s*$/.test(before.trimEnd())) continue;
    if (!/\bwhere\b/i.test(stmt)) hits.push(stmt.replace(/\s+/g, ' ').trim());
  }
  return hits;
}

function latestFunctionBody(functionName) {
  const files = fs.readdirSync(MIGRATIONS_DIR).filter(f => f.endsWith('.sql')).sort();
  const escaped = functionName.replace('.', '\\.');
  const re = new RegExp(
    'create (?:or replace )?function\\s+' + escaped + '\\s*\\([^)]*\\)[\\s\\S]*?\\$\\$([\\s\\S]*?)\\$\\$',
    'gi',
  );
  let body = null, definedIn = null;
  for (const f of files) {
    const text = fs.readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8');
    let m, last;
    while ((m = re.exec(text))) last = m;
    re.lastIndex = 0;
    if (last) { body = last[1]; definedIn = f; }
  }
  if (body === null) throw new Error(`No definition found for ${functionName}`);
  return { body, definedIn };
}

// The full call graph reachable from reserve_goal_results_date, before any
// provider fetch: the direct call chain (reserve -> reconcile -> candidate/
// quota/metric/retry helpers) PLUS every trigger function that fires on
// futbeat_private.entities, because reconcile_goal_results_local's
// `update entities ... where id=...` (the write that started this incident)
// fires ALL of them, not just invalidate_calendar_cache -- a fresh reviewer
// caught that the original list only checked the one trigger already known
// to be guilty and missed its 7 siblings.
const RESERVE_CALL_GRAPH = [
  'futbeat_private.reserve_goal_results_date',
  'futbeat_private.reconcile_goal_results_local',
  'futbeat_private.next_goal_results_candidate',
  'futbeat_private.quota_decision',
  'futbeat_private.bump_metric',
  'futbeat_private.bump_calendar_date',
  'futbeat_private.wake_provider_worker',
  'futbeat_private.results_retry_delay',
  'futbeat_private.match_provider_date',
  // Every AFTER/BEFORE trigger function on futbeat_private.entities that an
  // UPDATE OF kind,payload can fire:
  'futbeat_private.invalidate_calendar_cache',
  'futbeat_private.futbeat_index_calendar_match',
  'futbeat_private.preserve_verified_player_media',
  'futbeat_private.track_player_media_coverage',
  'futbeat_private.apply_competition_relevance',
  'futbeat_private.sync_competition_metadata',
  'futbeat_private.normalize_canonical_event_contract',
  'futbeat_private.index_entity_search',
  // Match-detail planning/reservation path (called through PostgREST).
  'futbeat_private.reserve_match_detail_call',
  'futbeat_private.plan_match_detail_coverage',
  'futbeat_private.enqueue_stale_interested_match_detail',
  'futbeat_private.track_match_detail_gain',
  'futbeat_private.track_match_detail_sections',
  'futbeat_private.track_match_detail_failure',
  'futbeat_private.store_match_detail',
  'futbeat_private.request_match_detail',
  'futbeat_private.promote_bulk_lineup',
  'public.futbeat_complete_provider_call',
  // GOAL LIVE reservation (Issue #111).
  'futbeat_private.futbeat_reserve_goal_live_call',
  'futbeat_private.live_poll_need',
  // Standings demand lane (Issue #98).
  'futbeat_private.futbeat_reserve_goal_standings_call',
  'futbeat_private.reconcile_standings_demands',
  'futbeat_private.standings_fresh_for',
  'futbeat_private.match_standings_state',
  'futbeat_private.archive_standings_snapshot',
  'public.futbeat_request_match_standings',
  'public.futbeat_complete_standings_call',
  // Provider Hub Phase 1A (Issue #102).
  'futbeat_private.provider_hub_decision',
  'public.futbeat_reserve_provider_hub_call',
  'public.futbeat_bind_provider_entity',
  'public.futbeat_match_provider_fixture',
  // Provider Hub Phase 1B.
  'public.futbeat_record_secondary_observation',
  'public.futbeat_provider_hub_preview',
  // Standings coverage NO_DATA (Issue #116).
  'public.futbeat_record_standings_no_data',
  'futbeat_private.clear_standings_coverage_no_data',
  // Calendar snapshot materialization path (called through PostgREST).
  'public.futbeat_read_calendar_range',
  'public.futbeat_plan_calendar_snapshots',
  'public.futbeat_build_next_calendar_snapshot',
  'futbeat_private.materialize_calendar_day',
  'futbeat_private.enqueue_calendar_snapshot',
  'futbeat_private.seed_calendar_snapshot_queue',
];

test('safeupdate compat checker: flags a bare UPDATE without WHERE', () => {
  assert.equal(findUnsafeStatements('update t set x=1;').length, 1);
});

test('safeupdate compat checker: flags a bare DELETE without WHERE', () => {
  assert.equal(findUnsafeStatements('delete from t;').length, 1);
});

test('safeupdate compat checker: ignores UPDATE with a WHERE clause', () => {
  assert.equal(findUnsafeStatements('update t set x=1 where id=1;').length, 0);
});

test('safeupdate compat checker: ignores DELETE with a WHERE clause', () => {
  assert.equal(findUnsafeStatements("delete from t where id=1;").length, 0);
});

test('safeupdate compat checker: ignores INSERT ... ON CONFLICT DO UPDATE (pg_safeupdate never inspects it)', () => {
  assert.equal(
    findUnsafeStatements("insert into t(id) values(1) on conflict(id) do update set x=1;").length,
    0,
  );
});

test('safeupdate compat checker: ignores SELECT ... FOR UPDATE SKIP LOCKED (a row lock, not a DML UPDATE)', () => {
  assert.equal(
    findUnsafeStatements('select 1 from t where id=$1 for update skip locked;').length,
    0,
  );
});

test('results-only reserve call graph has no UPDATE/DELETE that pg_safeupdate would reject', () => {
  const offenders = [];
  for (const fn of RESERVE_CALL_GRAPH) {
    const { body, definedIn } = latestFunctionBody(fn);
    for (const stmt of findUnsafeStatements(body)) offenders.push(`${fn} (${definedIn}): ${stmt}`);
  }
  assert.equal(
    offenders.length, 0,
    `Found SQL incompatible with pg_safeupdate (missing WHERE clause):\n${offenders.join('\n')}`,
  );
});

// Functional regression: the actual production trigger. A results-due match
// with a provider observation whose raw kickoff differs from the stored
// startTime makes reconcile_goal_results_local correct startTime -- the one
// payload field NOT covered by invalidate_calendar_cache's score/status/
// minute/events/statistics/provenance ignore-list, so it is the one change
// that reaches the (fixed) bare UPDATE on catalog_cache_version. This proves
// the fix does not just avoid the crash but still does its job: the cache
// version actually increments.
let seq = 0;
async function seedKickoffCorrectableMatch(db, { daysAgo = 3 } = {}) {
  const n = ++seq;
  const comp = `fb_comp_su_${n}`, home = `fb_team_su_h${n}`, away = `fb_team_su_a${n}`, match = `fb_match_su_${n}`;
  const date = new Date(); date.setUTCDate(date.getUTCDate() - daysAgo);
  const dateStr = date.toISOString().slice(0, 10);
  const start = `${dateStr}T18:00:00.000Z`;
  for (const [id, kind, payload] of [
    [comp, 'competition', { id: comp, name: `Liga ${n}` }],
    [home, 'team', { id: home, name: `Home ${n}` }],
    [away, 'team', { id: away, name: `Away ${n}` }],
    [match, 'match', { id: match, competitionId: comp, homeTeamId: home, awayTeamId: away,
      startTime: start, status: 'SCHEDULED', events: [], statistics: [] }],
  ]) await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
  const external = `ext-${match}`;
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [external, match]);
  // A LIVE observation with a corrected kickoff, received after the match
  // was indexed: reconcile_goal_results_local rewrites startTime from it
  // (line ~222 of reconcile_goal_results_local) without touching score,
  // status, minute or provenance.
  await db.query(`insert into futbeat_private.provider_observations(
      provider,external_match_id,canonical_match_id,received_at,provider_observed_at,
      status,minute,home_score,away_score,events,payload_hash,raw_payload)
    values('goal_api',$1,$2,now(),now(),'LIVE',5,null,null,'[]',md5(random()::text)||md5(clock_timestamp()::text),$3)`,
    [external, match, JSON.stringify({ kickoffUtc: `${dateStr}T20:30:00.000Z` })]);
  return { match, external, dateStr };
}

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

test('local repair correcting only startTime still bumps catalog_cache_version (the fixed bare UPDATE is not a silent no-op)', () => withDb(async (db) => {
  const { match, dateStr } = await seedKickoffCorrectableMatch(db);
  const before = (await db.query('select revision from futbeat_private.catalog_cache_version')).rows[0].revision;
  const result = (await db.query('select futbeat_private.reconcile_goal_results_local($1) v', [dateStr])).rows[0].v;
  assert.equal(result.updated, 1);
  const row = (await db.query('select (payload->>\'startTime\')::timestamptz as start_time, payload->>\'status\' as status from futbeat_private.entities where id=$1', [match])).rows[0];
  assert.equal(new Date(row.start_time).toISOString(), `${dateStr}T20:30:00.000Z`);
  assert.equal(row.status, 'SCHEDULED', 'only startTime changed, exactly the case that used to crash safeupdate');
  const after = (await db.query('select revision from futbeat_private.catalog_cache_version')).rows[0].revision;
  assert.ok(after > before, `catalog_cache_version.revision should increment (before=${before}, after=${after})`);
}));

test('background date reservation completes through the exact previously-crashing kickoff-correction path and reserves a real attempt', () => withDb(async (db) => {
  const { dateStr } = await seedKickoffCorrectableMatch(db);
  const plan = (await db.query("select futbeat_private.reserve_goal_results_date('test') v")).rows[0].v;
  // Local repair alone cannot resolve a still-SCHEDULED match, so the date
  // stays due and reserve_goal_results_date must proceed to a real
  // reservation -- entirely through the code path that used to throw.
  assert.equal(plan.allowed, true);
  assert.equal(plan.date, dateStr);
  assert.equal(plan.localRepair.updated, 1);
  assert.equal(plan.attempt, 1);
}));

test('existing results_date_attempts row is updated (not duplicated) on a second reservation of the same date', () => withDb(async (db) => {
  const { dateStr } = await seedKickoffCorrectableMatch(db, { daysAgo: 5 });
  const first = (await db.query("select futbeat_private.reserve_goal_results_date('test') v")).rows[0].v;
  assert.equal(first.allowed, true);
  assert.equal(first.attempt, 1, 'new results_date_attempts row: first attempt');
  const rowsAfterFirst = (await db.query("select count(*)::int n from futbeat_private.results_date_attempts where provider_date=$1", [dateStr])).rows[0].n;
  assert.equal(rowsAfterFirst, 1);
  // Make the date reservable again immediately (bypass its own backoff) and
  // reserve it a second time.
  await db.query("update futbeat_private.results_date_attempts set next_retry_at=now()-interval '1 minute' where provider_date=$1", [dateStr]);
  const second = (await db.query("select futbeat_private.reserve_goal_results_date('test') v")).rows[0].v;
  assert.equal(second.allowed, true);
  assert.equal(second.date, dateStr);
  assert.equal(second.attempt, 2, 'existing results_date_attempts row: attempt_count increments in place');
  const rowsAfterSecond = (await db.query("select count(*)::int n from futbeat_private.results_date_attempts where provider_date=$1", [dateStr])).rows[0].n;
  assert.equal(rowsAfterSecond, 1, 'still exactly one row: UPDATE via ON CONFLICT, not a new INSERT');
}));

// Two calls in sequence within the same test process, not two truly
// concurrent connections -- PGlite is single-connection, so this exercises
// the backoff/bookkeeping half of mutual exclusion (a reserved date drops
// out of candidacy immediately), not lock contention itself. The advisory
// lock (pg_advisory_xact_lock) is untouched by this fix either way.
test('two sequential reservations never double-book the same date (backoff bookkeeping survives the fix)', () => withDb(async (db) => {
  const a = await seedKickoffCorrectableMatch(db, { daysAgo: 10 });
  const b = await seedKickoffCorrectableMatch(db, { daysAgo: 11 });
  const first = (await db.query("select futbeat_private.reserve_goal_results_date('test') v")).rows[0].v;
  assert.equal(first.allowed, true);
  const second = (await db.query("select futbeat_private.reserve_goal_results_date('test') v")).rows[0].v;
  assert.equal(second.allowed, true);
  assert.notEqual(second.date, first.date, 'the just-reserved date is now in backoff, so the second call picks the other candidate');
  const dates = (await db.query('select distinct provider_date::text d from futbeat_private.results_date_attempts order by d')).rows.map(r => r.d);
  assert.deepEqual(dates.sort(), [a.dateStr, b.dateStr].sort());
}));

// End-to-end: the real results-only worker, driving the real reservation SQL
// through PGlite (same harness pattern as results_only_worker.test.mjs),
// seeded with the exact kickoff-correction shape that used to fail at
// stage="reserve" in production. IMPORTANT: PGlite cannot load pg_safeupdate
// (a native C extension), so this test's pass/fail is unaffected by whether
// the fix is applied -- it cannot reproduce the crash and never could. What
// it proves is functional: the worker's behavior around the reserve stage
// (candidate selection, local repair, attempt bookkeeping, and the pipeline
// past it) is unchanged by the fix. The only test in this file that actually
// fails without the fix is the static contract test above -- verified by
// temporarily stripping `where singleton` from the migration and confirming
// it, and only it, goes red.
const token = 'test-only-cron-token-not-a-secret-123456789';
const goalKey = 'test-only-goal-key-not-a-secret';
const unhandled = Symbol('unhandled');
const workerSource = await readFile(new URL('../../supabase/functions/futbeat-goal-live-sync/index.ts', import.meta.url), 'utf8');
const paginationSource = await readFile(new URL('../../supabase/functions/_shared/results_pagination.ts', import.meta.url), 'utf8');
const stripImports = source => source.replace(/^import\s[\s\S]*?;\r?\n/gm, '');

function edge(source, fetch, logs) {
  let handler;
  const context = vm.createContext({
    Request, Response, Headers, URL, AbortSignal, TextEncoder, crypto, performance, Error,
    fetch,
    console: { error: (...args) => logs.push(args), warn: (...args) => logs.push(args), log: (...args) => logs.push(args) },
    Deno: {
      env: { get: name => ({ SUPABASE_URL: 'https://supabase.test', SUPABASE_SERVICE_ROLE_KEY: 'test-service-key' })[name] },
      serve: fn => { handler = fn; },
    },
  });
  vm.runInContext(stripTypeScriptTypes(stripImports(source)), context);
  return { handler, context };
}

function sqlRpc(db) {
  const allowed = new Set([
    'futbeat_reserve_goal_results_date', 'futbeat_link_goal_live_matches',
    'futbeat_record_live_batch', 'futbeat_finalize_goal_results_date',
    'futbeat_complete_results_date_attempt', 'futbeat_complete_provider_call',
  ]);
  return async (name, body) => {
    if (!allowed.has(name)) return unhandled;
    const entries = Object.entries(body);
    const args = entries.map(([key], i) => `${key} => $${i + 1}`).join(',');
    const values = entries.map(([, value]) => value != null && typeof value === 'object' ? JSON.stringify(value) : value);
    return (await db.query(`select public.${name}(${args}) value`, values)).rows[0].value;
  };
}

function worker(db, provider) {
  const calls = [], logs = [], unexpected = [];
  const rpc = sqlRpc(db);
  const fetch = async (input, init = {}) => {
    const url = new URL(input);
    const body = init.body ? JSON.parse(init.body) : {};
    calls.push({ url: url.href, body, init });
    if (url.origin === 'https://supabase.test' && url.pathname.startsWith('/rest/v1/rpc/')) {
      const name = url.pathname.split('/').at(-1);
      if (name === 'futbeat_read_goal_live_cron_token') return Response.json(token);
      if (name === 'futbeat_read_goal_live_secret') return Response.json(goalKey);
      const result = await rpc(name, body);
      if (result !== unhandled) return Response.json(result);
      unexpected.push(url.href);
      throw new Error(`Unmocked RPC: ${name}`);
    }
    if (url.href.startsWith('https://api.goal-api.com/v1/results/date/')) {
      return provider(url, init);
    }
    unexpected.push(url.href);
    throw new Error(`Unexpected mocked request: ${url.href}`);
  };
  const pagination = paginationSource.replace(/^export /gm, '');
  const runner = edge(pagination + '\n' + workerSource, fetch, logs);
  return {
    logs, unexpected,
    async invoke() {
      const response = await runner.handler(new Request('https://worker.test/', {
        method: 'POST', headers: { 'x-futbeat-cron-token': token },
        body: JSON.stringify({ trigger: 'results-only' }),
      }));
      return { status: response.status, value: await response.json() };
    },
  };
}

function resultFixture(external, { status = 'FINISHED', home = 2, away = 1 } = {}) {
  return {
    apiId: external, matchStatus: status, matchPeriod: 'FULL_TIME', matchElapsed: '90',
    homeTeamScore: home, awayTeamScore: away, events: [], cards: [], substitutions: [],
  };
}

test('results-only worker completes the kickoff-correction case end to end (functional check; cannot reproduce the safeupdate crash locally)', () => withDb(async (db) => {
  const { external, dateStr } = await seedKickoffCorrectableMatch(db);
  const w = worker(db, () => Response.json({
    success: true, data: [resultFixture(external)], pagination: { total: 1, hasMore: false },
  }));
  const result = await w.invoke();
  assert.equal(result.status, 200);
  assert.deepEqual(w.unexpected, []);
  assert.notEqual(result.value.results?.stage, 'reserve', `worker must not fail at stage=reserve; got: ${JSON.stringify(result.value)}`);
  assert.equal(result.value.results.status, 'ok', JSON.stringify(result.value));
  assert.equal(result.value.results.finalized?.resultsComplete, true, JSON.stringify(result.value));
  const status = (await db.query(
    "select payload->>'status' s from futbeat_private.entities where id in (select canonical_id from futbeat_private.provider_entities where provider='goal_api' and external_id=$1)",
    [external],
  )).rows[0].s;
  assert.equal(status, 'FINISHED_PENDING_VERIFICATION');
}));
