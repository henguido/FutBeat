import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import { collectGoalApiBaseIdentities, normalizeGoalApiFixtures } from '../providers/goal_api.mjs';
import { goalFixtureScore } from '../../supabase/functions/_shared/live_events.ts';
import { runChunksWithTimeoutRetry } from '../../supabase/functions/_shared/chunked_rpc.ts';

// 20261008010000 + calendar sub-batches. Production 2026-10-08 (#158/#159,
// v38): 2026-09-19 (1,477 fixtures) hit 57014 (8 s statement timeout) at
// read-current (8.6 s), then at store (11.0 s). A date above
// CALENDAR_SUB_BATCH_MAX (300) is stored in sub-batches with an empty
// coverage and finalized once (deletes + coverage for the whole date).

const ingestSource = await readFile(new URL('../../supabase/functions/futbeat-global-ingest/index.ts', import.meta.url), 'utf8');
const stripImports = (source) => source.replace(/^import\s[\s\S]*?;\r?\n/gm, '');

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

const SQL_RPCS = new Set(['futbeat_reserve_provider_call', 'futbeat_read_ingest_context', 'futbeat_resolve_global_entities',
  'futbeat_complete_provider_call', 'futbeat_read_calendar_range', 'futbeat_store_calendar_range',
  'futbeat_finalize_calendar_date']);
const TIMEOUT = '{"code":"57014","details":null,"hint":null,"message":"canceling statement due to statement timeout"}';

function harness(db, { failStoreCall = null, failFinalize = false } = {}) {
  const calls = [];
  let stores = 0;
  let handler;
  const fetch = async (input, init = {}) => {
    const url = new URL(input);
    const body = init.body ? JSON.parse(init.body) : {};
    const name = url.pathname.split('/').at(-1);
    calls.push({ name, body });
    if (url.origin !== 'https://supabase.test') throw new Error(`Unexpected request ${url.href}`);
    if (!SQL_RPCS.has(name)) throw new Error(`Unexpected RPC ${name}`);
    if (name === 'futbeat_store_calendar_range' && ++stores === failStoreCall) return new Response(TIMEOUT, { status: 500 });
    if (name === 'futbeat_finalize_calendar_date' && failFinalize) return new Response(TIMEOUT, { status: 500 });
    const entries = Object.entries(body);
    const args = entries.map(([k], i) => `${k} => $${i + 1}`).join(',');
    const values = entries.map(([k, v]) => (k === 'p_competition_ids' || k === 'p_team_ids') ? v
      : v != null && typeof v === 'object' ? JSON.stringify(v) : v);
    if (name === 'futbeat_resolve_global_entities') {
      return Response.json((await db.query(`select * from public.${name}(${args})`, values)).rows);
    }
    return Response.json((await db.query(`select public.${name}(${args}) value`, values)).rows[0].value);
  };
  const context = vm.createContext({
    Request, Response, Headers, URL, AbortSignal, TextEncoder, crypto, performance, Error, fetch, setTimeout,
    console: { error: () => {}, warn: () => {}, log: () => {} },
    Deno: { env: { get: (n) => ({ SUPABASE_URL: 'https://supabase.test', SUPABASE_SERVICE_ROLE_KEY: 'test-service-key' })[n] }, serve: (fn) => { handler = fn; } },
    createRemoteJWKSet: () => ({}),
    jwtVerify: async () => ({ payload: { repository: 'henguido/FutBeat', ref: 'refs/heads/main', event_name: 'workflow_dispatch',
      workflow_ref: 'henguido/FutBeat/.github/workflows/global-fixtures.yml@refs/heads/main' } }),
    collectGoalApiBaseIdentities, normalizeGoalApiFixtures, goalFixtureScore, runChunksWithTimeoutRetry,
  });
  vm.runInContext(stripTypeScriptTypes(stripImports(ingestSource)), context);
  const post = async (payload) => {
    const response = await handler(new Request('https://ingest.test/', { method: 'POST',
      headers: { authorization: 'Bearer test-only-oidc' }, body: JSON.stringify(payload) }));
    return { status: response.status, value: await response.json() };
  };
  return {
    context,
    names: () => calls.map((c) => c.name),
    of: (name) => calls.filter((c) => c.name === name),
    calendar: (events, dates) =>
      post({ source: 'GOAL API', mode: 'calendar', dates, coverage: dates.map((date) => ({ date, count: events.length })),
        providerRemaining: 700, events }),
  };
}

const DAY = '2026-09-19';
const at = (minute) => new Date(Date.parse(`${DAY}T00:00:00.000Z`) + minute * 60000).toISOString();
// One fixture per minute offset, its own teams (no match reuse between fixtures).
const fixture = (id, minute) => ({
  apiId: id, kickoffUtc: at(minute), matchStatus: 'NOT_STARTED', matchPeriod: '',
  league: { id: `L${minute % 9}`, name: `League ${minute % 9}` },
  homeTeam: { id: `H-${id}`, name: `Home ${id}` }, awayTeam: { id: `A-${id}`, name: `Away ${id}` },
});
const bigDay = (n, prefix = 'big') => Array.from({ length: n }, (_, i) => fixture(`${prefix}-${i}`, Math.floor(i * 1430 / n)));
const count = (db, sql, args = []) => db.query(sql, args).then((r) => r.rows[0].n);
const calendarRows = (db) => count(db, "select count(*)::int n from futbeat_private.calendar_matches where source='GOAL API'");
const coverageRows = (db) => db.query("select provider_date::text d, fixture_count from futbeat_private.calendar_coverage where provider='goal_api'").then((r) => r.rows);
const lastLedger = async (db) =>
  (await db.query("select status, metadata from futbeat_private.provider_call_ledger where call_kind='calendar-ingest' order by id desc limit 1")).rows[0];
const plain = (value) => JSON.parse(JSON.stringify(value));

test('sub-batches: kickoff order, balanced, a 5-minute bucket is never split, missing kickoffs first', () => withDb(async (db) => {
  const { context } = harness(db);
  assert.equal(context.CALENDAR_SUB_BATCH_MAX, undefined, 'const is module-scoped');
  const small = [fixture('s1', 10), fixture('s2', 5)];
  assert.deepEqual(plain(context.calendarSubBatches(small, 300)), plain([small]), 'at or below the max: one batch, input order');

  const events = bigDay(700);
  const batches = context.calendarSubBatches(events, 300);
  assert.equal(batches.length, 3);
  assert.ok(batches.every((b) => b.length <= 300), batches.map((b) => b.length).join());
  assert.equal(batches.flat().length, 700);
  assert.equal(new Set(batches.flat().map((e) => e.apiId)).size, 700, 'every fixture exactly once');
  const kickoffs = plain(batches.flat().map((e) => Date.parse(e.kickoffUtc)));
  assert.deepEqual(kickoffs, [...kickoffs].sort((a, b) => a - b), 'kickoff order');
  const bucket = (e) => Math.floor(Date.parse(e.kickoffUtc) / 300000);
  for (let i = 1; i < batches.length; i += 1) {
    assert.ok(bucket(batches[i - 1].at(-1)) < bucket(batches[i][0]), `cut ${i} falls between buckets`);
  }

  // 12 fixtures in one bucket + 2 elsewhere, max 5: the bucket stays whole.
  const crowded = [...Array.from({ length: 12 }, (_, i) => fixture(`c${i}`, 600)), fixture('early', 10), fixture('late', 900),
    { apiId: 'nokick', kickoffUtc: '' }];
  const parts = context.calendarSubBatches(crowded, 5);
  assert.equal(parts[0][0].apiId, 'nokick');
  assert.equal(parts.filter((p) => p.some((e) => e.apiId.startsWith('c'))).length, 1, 'one batch holds the whole bucket');
  assert.equal(parts.flat().length, 15);
}));

test('one date at or below 300 fixtures: unchanged single store with its coverage, no finalize', () => withDb(async (db) => {
  const h = harness(db);
  const { status, value } = await h.calendar(bigDay(300, 'one'), [DAY]);
  assert.equal(status, 200, JSON.stringify(value));
  assert.equal(value.accepted, 300);
  assert.equal(h.of('futbeat_read_ingest_context').length, 1);
  assert.deepEqual(h.of('futbeat_store_calendar_range').map((c) => c.body.p_coverage), [[{ date: DAY, count: 300 }]]);
  assert.equal(h.of('futbeat_finalize_calendar_date').length, 0);
  const { metadata } = await lastLedger(db);
  assert.equal(metadata.stageMsBySubBatch, undefined);
  assert.deepEqual(await coverageRows(db), [{ d: DAY, fixture_count: 300 }]);
}));

test('large date (700): 3 sub-batches, read-current per sub-window, stores without coverage, one finalize with all ids', () => withDb(async (db) => {
  const h = harness(db);
  const { status, value } = await h.calendar(bigDay(700), [DAY]);
  assert.equal(status, 200, JSON.stringify(value));
  assert.equal(value.accepted, 700);
  assert.equal(value.result.coveredDates, 1);

  const reads = h.of('futbeat_read_ingest_context').map((c) => c.body);
  assert.equal(reads.length, 3);
  for (let i = 1; i < reads.length; i += 1) assert.ok(reads[i - 1].p_to < reads[i].p_from, 'disjoint ascending windows');
  const stores = h.of('futbeat_store_calendar_range').map((c) => c.body);
  assert.deepEqual(stores.map((b) => b.p_coverage), [[], [], []]);
  assert.ok(stores.every((b) => b.p_snapshot.matches.length <= 300));
  assert.equal(stores.reduce((n, b) => n + b.p_snapshot.matches.length, 0), 700);
  assert.ok(h.of('futbeat_resolve_global_entities').every((c) => c.body.p_items.length <= 50));

  const finals = h.of('futbeat_finalize_calendar_date').map((c) => c.body);
  assert.equal(finals.length, 1);
  assert.equal(finals[0].p_date, DAY);
  assert.equal(finals[0].p_count, 700);
  assert.equal(finals[0].p_match_ids.length, 700);
  assert.deepEqual(finals[0].p_match_ids, stores.flatMap((b) => b.p_snapshot.matches.map((m) => m.id)).sort());
  // Order: every store before the finalize, then the ledger.
  const names = h.names();
  assert.ok(names.lastIndexOf('futbeat_store_calendar_range') < names.indexOf('futbeat_finalize_calendar_date'));

  assert.equal(await calendarRows(db), 700);
  assert.deepEqual(await coverageRows(db), [{ d: DAY, fixture_count: 700 }]);
  const { status: ledgerStatus, metadata } = await lastLedger(db);
  assert.equal(ledgerStatus, 'SUCCEEDED');
  const subs = metadata.stageMsBySubBatch[DAY];
  assert.equal(subs.length, 3);
  assert.equal(subs.reduce((n, s) => n + s.fixtures, 0), 700);
  for (const sub of subs) {
    for (const key of ['resolve-base', 'read-current', 'normalize', 'store']) assert.equal(typeof sub[key], 'number', key);
  }
  for (const key of ['resolve-base', 'read-current', 'store', 'finalize']) {
    assert.equal(typeof metadata.stageMsByDate[DAY][key], 'number', key);
  }
}));

test('large date: a sub-batch never deletes another sub-batch; the finalize removes only a fixture GOAL no longer lists', () => withDb(async (db) => {
  const day = bigDay(700);
  const gone = fixture('gone', 700);
  const first = await harness(db).calendar([...day, gone], [DAY]);
  assert.equal(first.status, 200, JSON.stringify(first.value));
  assert.equal(await calendarRows(db), 701);
  const goneId = (await db.query("select canonical_id from futbeat_private.provider_entities where provider='goal_api' and kind='match' and external_id='gone'")).rows[0].canonical_id;

  const h = harness(db);
  const again = await h.calendar(day, [DAY]);
  assert.equal(again.status, 200, JSON.stringify(again.value));
  assert.equal(await calendarRows(db), 700);
  assert.equal(await count(db, 'select count(*)::int n from futbeat_private.calendar_matches where match_id=$1', [goneId]), 0);
  assert.equal(h.of('futbeat_finalize_calendar_date')[0].body.p_match_ids.includes(goneId), false);
  // The match entity itself is kept (only the date index row goes), as with
  // futbeat_store_calendar_range.
  assert.equal(await count(db, "select count(*)::int n from futbeat_private.entities where id=$1 and kind='match'", [goneId]), 1);
}));

test('large date re-run is idempotent: no new matches, mappings or index rows; one coverage row', () => withDb(async (db) => {
  const day = bigDay(640);
  assert.equal((await harness(db).calendar(day, [DAY])).status, 200);
  const matches = await count(db, "select count(*)::int n from futbeat_private.entities where kind='match'");
  const mappings = await count(db, 'select count(*)::int n from futbeat_private.provider_entities');
  const again = await harness(db).calendar(day, [DAY]);
  assert.equal(again.status, 200, JSON.stringify(again.value));
  assert.equal(again.value.accepted, 640);
  assert.equal(await count(db, "select count(*)::int n from futbeat_private.entities where kind='match'"), matches);
  assert.equal(await count(db, 'select count(*)::int n from futbeat_private.provider_entities'), mappings);
  assert.equal(await calendarRows(db), 640);
  assert.equal(await count(db, `select count(*)::int n from (select payload->>'homeTeamId', payload->>'awayTeamId', payload->>'startTime'
    from futbeat_private.entities where kind='match' group by 1,2,3 having count(*)>1) x`), 0, 'no duplicate fixtures');
  assert.deepEqual(await coverageRows(db), [{ d: DAY, fixture_count: 640 }]);
}));

test('failure halfway: earlier sub-batches stay stored, nothing is deleted, the date stays uncovered; the retry completes', () => withDb(async (db) => {
  // A previous complete run of the date, including a fixture GOAL later drops.
  const day = bigDay(700);
  const gone = fixture('gone', 700);
  assert.equal((await harness(db).calendar([...day, gone], [DAY])).status, 200);
  await db.query("delete from futbeat_private.calendar_coverage where provider='goal_api'");
  const newcomer = fixture('newcomer', 1);

  const h = harness(db, { failStoreCall: 2 });
  const failed = await h.calendar([newcomer, ...day], [DAY]);
  assert.equal(failed.status, 502);
  assert.equal(failed.value.stage, 'store');
  assert.equal(failed.value.failedDate, DAY);
  assert.equal(failed.value.failedSubBatch, 1);
  assert.equal(failed.value.storedSubBatches, 1);
  assert.deepEqual(failed.value.storedDates, []);
  assert.equal(h.of('futbeat_store_calendar_range').length, 2, 'the third sub-batch is not attempted');
  assert.equal(h.of('futbeat_finalize_calendar_date').length, 0, 'no finalize after a failed sub-batch');
  assert.equal(await calendarRows(db), 702, 'sub-batch 1 added the newcomer; the dropped fixture is not deleted yet');
  assert.deepEqual(await coverageRows(db), [], 'the date is not marked covered');
  const { status: ledgerStatus, metadata } = await lastLedger(db);
  assert.equal(ledgerStatus, 'FAILED');
  assert.equal(metadata.failedSubBatch, 1);
  assert.equal(metadata.stageMsBySubBatch[DAY].length, 2);
  assert.equal(typeof metadata.stageMsBySubBatch[DAY][1].store, 'number');

  const retry = await harness(db).calendar([newcomer, ...day], [DAY]);
  assert.equal(retry.status, 200, JSON.stringify(retry.value));
  assert.equal(await calendarRows(db), 701, 'newcomer kept, dropped fixture removed');
  assert.deepEqual(await coverageRows(db), [{ d: DAY, fixture_count: 701 }]);
  assert.equal(await count(db, `select count(*)::int n from (select payload->>'homeTeamId', payload->>'awayTeamId', payload->>'startTime'
    from futbeat_private.entities where kind='match' group by 1,2,3 having count(*)>1) x`), 0, 'no duplicates after the retry');
}));

test('failure at finalize: all sub-batches stored, nothing deleted, the date stays uncovered', () => withDb(async (db) => {
  const day = bigDay(640);
  const gone = fixture('gone', 700);
  assert.equal((await harness(db).calendar([...day, gone], [DAY])).status, 200);
  await db.query("delete from futbeat_private.calendar_coverage where provider='goal_api'");
  const h = harness(db, { failFinalize: true });
  const failed = await h.calendar(day, [DAY]);
  assert.equal(failed.status, 502);
  assert.equal(failed.value.stage, 'finalize');
  assert.equal(failed.value.failedDate, DAY);
  assert.equal(failed.value.failedSubBatch, undefined);
  assert.equal(await calendarRows(db), 641);
  assert.deepEqual(await coverageRows(db), []);
}));

test('SQL finalize: refuses unstored ids and invalid payloads; service_role only', () => withDb(async (db) => {
  assert.equal((await harness(db).calendar(bigDay(3, 'tiny'), [DAY])).status, 200);
  const stored = (await db.query("select match_id from futbeat_private.calendar_matches order by 1")).rows.map((r) => r.match_id);
  const call = (ids, provider = 'goal_api', n = 3) => db.query(
    'select public.futbeat_finalize_calendar_date($1,now(),$2::date,$3,$4::jsonb) v', [provider, DAY, n, JSON.stringify(ids)]);
  await assert.rejects(call([...stored, 'fb_match_never_stored']), /not stored/);
  await assert.rejects(call(stored, 'other'), /Invalid calendar date finalize payload/);
  await assert.rejects(call([1, 2]), /Invalid calendar date finalize payload/);
  await assert.rejects(call(stored, 'goal_api', -1), /Invalid calendar date finalize payload/);
  assert.equal(await calendarRows(db), 3, 'a refused finalize deletes nothing');
  const ok = (await call(stored.slice(1))).rows[0].v;
  assert.deepEqual(ok, { matches: 2, deleted: 1, coveredDates: 1 });
  assert.deepEqual((await call(stored.slice(1))).rows[0].v, { matches: 2, deleted: 0, coveredDates: 1 }, 'idempotent');
  const grants = (await db.query(`select grantee from information_schema.routine_privileges
    where routine_name='futbeat_finalize_calendar_date' and privilege_type='EXECUTE' group by grantee order by grantee`)).rows.map((r) => r.grantee);
  assert.equal(grants.includes('anon'), false);
  assert.equal(grants.includes('authenticated'), false);
  assert.ok(grants.includes('service_role'));
}));
