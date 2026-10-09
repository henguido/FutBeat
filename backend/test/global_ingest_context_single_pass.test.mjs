import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import { collectGoalApiBaseIdentities, normalizeGoalApiFixtures } from '../providers/goal_api.mjs';
import { goalFixtureScore } from '../../supabase/functions/_shared/live_events.ts';
import { runChunksWithTimeoutRetry } from '../../supabase/functions/_shared/chunked_rpc.ts';

// 20261007010000 + per-date calendar ingest. Production 2026-10-07: calendar
// batches of three dates failed at read-current (57014, 8.9 s / 13.1 s).
// futbeat_read_ingest_context (20261005110000) built its subset and applied
// the redirects three times and rewrote match ids with one function call per
// id; one day took 5.1 s, three days > 2 min. The new body must return the
// SAME jsonb; the calendar ingest now runs resolve-base, read-current,
// normalize and store once per UTC date.

const migration = (name) => readFile(new URL(`../../supabase/migrations/${name}`, import.meta.url), 'utf8');
const ingestSource = await readFile(new URL('../../supabase/functions/futbeat-global-ingest/index.ts', import.meta.url), 'utf8');
const stripImports = (source) => source.replace(/^import\s[\s\S]*?;\r?\n/gm, '');

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

// The 20261005110000 body, kept as futbeat_private.read_ingest_context_v1.
async function installPrevious(db) {
  const sql = await migration('20261005110000_ingest_targeted_context.sql');
  const body = sql.slice(sql.indexOf('create or replace function'), sql.indexOf('$$;') + 3)
    .replace('public.futbeat_read_ingest_context', 'futbeat_private.read_ingest_context_v1');
  await db.exec(body);
}

const both = async (db, args) => {
  const sql = (fn) => `select ${fn}($1::text[],$2::text[],$3::timestamptz,$4::timestamptz) v`;
  const next = (await db.query(sql('public.futbeat_read_ingest_context'), args)).rows[0].v;
  const prev = (await db.query(sql('futbeat_private.read_ingest_context_v1'), args)).rows[0].v;
  return { next, prev };
};

async function seedEntities(db, ids) {
  for (const [id, kind] of ids) {
    await db.query("insert into futbeat_private.entities(id,kind,payload) values($1,$2,$3) on conflict(id) do nothing",
      [id, kind, JSON.stringify({ id, name: `Stored ${id}` })]);
  }
}

test('SQL: same output as the 20261005110000 body (redirect chains, aliases, nulls, bad kickoffs, window edges)', () => withDb(async (db) => {
  await installPrevious(db);
  const base = Date.parse('2026-09-19T00:00:00.000Z');
  const at = (minutes) => new Date(base + minutes * 60000).toISOString();
  // Redirects: competition c9 -> c1; team chain t8 -> t7 -> t1; t6 -> t2.
  await seedEntities(db, [['fb_c1', 'competition'], ['fb_c9', 'competition'], ['fb_t1', 'team'], ['fb_t7', 'team'], ['fb_t8', 'team'], ['fb_t2', 'team'], ['fb_t6', 'team']]);
  for (const [alias, canonical, kind] of [['fb_c9', 'fb_c1', 'competition'], ['fb_t7', 'fb_t1', 'team'], ['fb_t8', 'fb_t7', 'team'], ['fb_t6', 'fb_t2', 'team']]) {
    await db.query("insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values($1,$2,$3,'test')", [alias, canonical, kind]);
  }
  const teams = ['fb_t1', 'fb_t2', 'fb_t3', 'fb_t4', 'fb_t5', 'fb_t6', 'fb_t7', 'fb_t8'];
  const snapshot = {
    schemaVersion: 1, demo: false, updatedAt: at(0), players: [{ id: 'p1', teamId: 'fb_t8' }],
    competitions: [{ id: 'fb_c1', name: 'One' }, { id: 'fb_c2', name: 'Two' }, { id: 'fb_c9', name: 'Alias of one' }, { id: 'fb_c3', name: 'Three' }],
    teams: teams.map((id) => ({ id, name: `Team ${id}`, competitionId: 'fb_c1' })),
    matches: [],
  };
  let n = 0;
  for (let i = 0; i < teams.length; i += 1) {
    for (let j = 0; j < teams.length; j += 1) {
      if (i === j) continue;
      n += 1;
      snapshot.matches.push({
        id: `m${n}`, homeTeamId: teams[i], awayTeamId: teams[j],
        competitionId: n % 7 === 0 ? null : n % 5 === 0 ? 'fb_c9' : n % 3 === 0 ? 'fb_c2' : 'fb_c1',
        startTime: n % 11 === 0 ? 'not a date' : n % 13 === 0 ? '' : at((n * 37) % 2880),
        status: 'SCHEDULED', events: [],
      });
    }
  }
  snapshot.matches.push({ id: 'no-competition-key', homeTeamId: 'fb_t1', awayTeamId: 'fb_t2', startTime: at(60) });
  await db.query("insert into futbeat_private.imports(job_id,received_at,raw_payload,snapshot) values('single-pass',now()+interval '1 minute','{}'::jsonb,$1)", [JSON.stringify(snapshot)]);

  const cases = [
    [['fb_c1', 'fb_c2'], ['fb_t1', 'fb_t2', 'fb_t3'], at(0), at(1440)],
    [['fb_c1', 'fb_c2', 'fb_c3', 'missing'], teams, at(-10), at(3000)],
    [['fb_c1'], ['fb_t1', 'fb_t2'], at(65), at(65)], // window edges: +-5 min exactly
    [['fb_c9'], ['fb_t8', 'fb_t6'], at(0), at(2880)], // aliases requested directly
    [[], ['fb_t4', 'fb_t5', 'fb_t4'], at(100), at(900)], // duplicates in the request
    [['fb_c1'], ['fb_t1'], null, null], // no window: no matches
    [['fb_c1', 'fb_c2'], [], at(0), at(2880)],
    [[], [], null, null],
    [null, null, at(0), at(1)],
  ];
  for (const args of cases) {
    const { next, prev } = await both(db, args);
    assert.deepEqual(next, prev, JSON.stringify(args));
  }
  // Non-trivial: matches came back, with redirected ids, and null competition ids stayed null items.
  const wide = (await both(db, cases[1])).next;
  assert.ok(wide.matches.length > 20);
  assert.ok(wide.matches.every((m) => m === null || !['fb_t6', 'fb_t7', 'fb_t8'].includes(m.homeTeamId)));
  assert.ok(wide.matches.includes(null), 'a match without competitionId is a null item, as before');

  // Randomized cross-check.
  let seed = 7;
  const rand = (k) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % k; };
  for (let round = 0; round < 25; round += 1) {
    const pick = (list) => list.filter(() => rand(2) === 0);
    const from = rand(2880) - 60;
    const args = [pick(['fb_c1', 'fb_c2', 'fb_c3', 'fb_c9']), pick(teams), at(from), at(from + rand(1500))];
    const { next, prev } = await both(db, args);
    assert.deepEqual(next, prev, JSON.stringify(args));
  }
}));

test('SQL: no import at all -> empty context, as before', () => withDb(async (db) => {
  await installPrevious(db);
  await db.exec('delete from futbeat_private.imports');
  const { next, prev } = await both(db, [['c1'], ['t1'], '2026-09-19T00:00:00Z', '2026-09-20T00:00:00Z']);
  assert.deepEqual(next, prev);
  assert.deepEqual(next, { competitions: [], teams: [], matches: [] });
}));

test('SQL: same signature, STABLE, SECURITY DEFINER, empty search_path, service_role only', () => withDb(async (db) => {
  const row = (await db.query("select provolatile, prosecdef, proconfig from pg_proc where proname='futbeat_read_ingest_context'")).rows;
  assert.equal(row.length, 1);
  assert.equal(row[0].provolatile, 's');
  assert.equal(row[0].prosecdef, true);
  assert.deepEqual(row[0].proconfig, ['search_path=""']);
  const sig = 'public.futbeat_read_ingest_context(text[],text[],timestamptz,timestamptz)';
  for (const [role, expected] of [['anon', false], ['authenticated', false], ['service_role', true]]) {
    assert.equal((await db.query('select has_function_privilege($1,$2,\'execute\') ok', [role, sig])).rows[0].ok, expected, role);
  }
  const src = await migration('20261007010000_ingest_context_single_pass.sql');
  assert.doesNotMatch(src, /lateral \(select futbeat_private\.futbeat_apply_entity_redirects_snapshot/i, 'no flattened LATERAL');
  const code = src.split(/\r?\n/).map((line) => line.replace(/--.*$/, '')).join('\n');
  assert.equal(code.match(/futbeat_apply_entity_redirects_snapshot\(/g).length, 1, 'redirects applied once');
  assert.doesNotMatch(code, /\b(insert|update|delete)\b/i, 'read-only');
}));

// ---- Edge function harness (calendar + hot) ----

const SQL_RPCS = new Set(['futbeat_reserve_provider_call', 'futbeat_read_ingest_context', 'futbeat_resolve_global_entities',
  'futbeat_store_global_fixture_window', 'futbeat_complete_provider_call', 'futbeat_read_calendar_range', 'futbeat_store_calendar_range']);

function harness(db, { failStoreOn = null } = {}) {
  const calls = [];
  let handler;
  const fetch = async (input, init = {}) => {
    const url = new URL(input);
    const body = init.body ? JSON.parse(init.body) : {};
    const name = url.pathname.split('/').at(-1);
    calls.push({ name, origin: url.origin, body });
    if (url.origin !== 'https://supabase.test') throw new Error(`Unexpected request ${url.href}`);
    if (!SQL_RPCS.has(name)) throw new Error(`Unexpected RPC ${name}`);
    if (name === 'futbeat_store_calendar_range' && failStoreOn && body.p_coverage[0]?.date === failStoreOn) {
      return new Response('{"code":"57014","details":null,"hint":null,"message":"canceling statement due to statement timeout"}', { status: 500 });
    }
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
    calls, context,
    names: () => calls.map((c) => c.name),
    of: (name) => calls.filter((c) => c.name === name),
    calendar: (events, dates, coverage = dates.map((date) => ({ date, count: events.length }))) =>
      post({ source: 'GOAL API', mode: 'calendar', dates, coverage, providerRemaining: 700, events }),
    hot: (events, dates) => post({ source: 'GOAL API', mode: 'hot', dates, providerRemaining: 500, events }),
  };
}

const fixture = (id, date, hour, league, home, away, status = 'NOT_STARTED') => ({
  apiId: id, kickoffUtc: `${date}T${String(hour).padStart(2, '0')}:30:00.000Z`, matchStatus: status, matchPeriod: '',
  league: { id: league, name: `League ${league}` }, homeTeam: { id: home, name: `Team ${home}` }, awayTeam: { id: away, name: `Team ${away}` },
});
const D = ['2026-09-18', '2026-09-19', '2026-09-20'];
const count = (db, sql, args = []) => db.query(sql, args).then((r) => r.rows[0].n);
const lastLedger = async (db, kind = 'calendar-ingest') =>
  (await db.query('select status, metadata from futbeat_private.provider_call_ledger where call_kind=$1 order by id desc limit 1', [kind])).rows[0];

test('calendar, 1 date: one targeted read and one store for that date; per-date stageMs in the ledger', () => withDb(async (db) => {
  const h = harness(db);
  const events = [fixture('a1', D[0], 12, 'L1', 'A', 'B'), fixture('a2', D[0], 18, 'L2', 'C', 'D')];
  const { status, value } = await h.calendar(events, [D[0]]);
  assert.equal(status, 200, JSON.stringify(value));
  assert.equal(value.accepted, 2);
  assert.equal(h.of('futbeat_read_ingest_context').length, 1);
  const ctx = h.of('futbeat_read_ingest_context')[0].body;
  assert.equal(ctx.p_competition_ids.length, 2);
  assert.equal(ctx.p_team_ids.length, 4);
  assert.equal(ctx.p_from, `${D[0]}T12:30:00.000Z`);
  assert.equal(ctx.p_to, `${D[0]}T18:30:00.000Z`);
  assert.deepEqual(h.of('futbeat_store_calendar_range').map((c) => c.body.p_coverage), [[{ date: D[0], count: 2 }]]);
  assert.equal(h.names().includes('futbeat_read_snapshot'), false);
  const { status: ledgerStatus, metadata } = await lastLedger(db);
  assert.equal(ledgerStatus, 'SUCCEEDED');
  for (const key of ['resolve-base', 'read-current', 'normalize', 'store']) {
    assert.equal(typeof metadata.stageMsByDate[D[0]][key], 'number', key);
    assert.equal(typeof metadata.stageMs[key], 'number', key);
  }
  assert.equal(typeof metadata.stageMs['read-calendar'], 'number');
}));

test('calendar, 3 dates: one context read per date with only that date ids and window, stored in date order', () => withDb(async (db) => {
  const h = harness(db);
  const events = [
    fixture('b1', D[0], 10, 'L1', 'A', 'B'), fixture('b2', D[1], 15, 'L1', 'A', 'C'),
    fixture('b3', D[2], 9, 'L2', 'D', 'E'), fixture('b4', D[1], 20, 'L3', 'F', 'G'),
  ];
  const { status, value } = await h.calendar(events, D);
  assert.equal(status, 200, JSON.stringify(value));
  assert.equal(value.accepted, 4);
  assert.equal(value.result.coveredDates, 3);
  const reads = h.of('futbeat_read_ingest_context').map((c) => c.body);
  assert.equal(reads.length, 3);
  assert.deepEqual(reads.map((r) => [r.p_from, r.p_to]), [
    [`${D[0]}T10:30:00.000Z`, `${D[0]}T10:30:00.000Z`],
    [`${D[1]}T15:30:00.000Z`, `${D[1]}T20:30:00.000Z`],
    [`${D[2]}T09:30:00.000Z`, `${D[2]}T09:30:00.000Z`]]);
  assert.deepEqual(reads.map((r) => [r.p_competition_ids.length, r.p_team_ids.length]), [[1, 2], [2, 4], [1, 2]]);
  assert.deepEqual(h.of('futbeat_store_calendar_range').map((c) => c.body.p_coverage[0].date), D);
  assert.deepEqual(h.of('futbeat_store_calendar_range').map((c) => c.body.p_snapshot.matches.length), [1, 2, 1]);
  // read-current of a date happens after that date's resolve-base and before its store.
  const names = h.names();
  for (let i = 0; i < 3; i += 1) {
    const read = names.indexOf('futbeat_read_ingest_context', i === 0 ? 0 : names.indexOf('futbeat_store_calendar_range') + 1);
    assert.ok(read > 0);
  }
  const { metadata } = await lastLedger(db);
  assert.deepEqual(Object.keys(metadata.stageMsByDate), D);
  assert.equal(await count(db, "select count(*)::int n from futbeat_private.calendar_matches where source='GOAL API'"), 4);
  assert.equal(await count(db, "select count(*)::int n from futbeat_private.calendar_coverage where provider='goal_api'"), 3);
}));

test('calendar: a date without fixtures still stores its coverage; out-of-range kickoffs go to the nearest date', () => withDb(async (db) => {
  const h = harness(db);
  const events = [fixture('c1', D[0], 12, 'L1', 'A', 'B'), fixture('c2', '2026-09-21', 1, 'L1', 'C', 'D'), { apiId: 'c3', kickoffUtc: 'bad' }];
  const { status, value } = await h.calendar(events, D);
  assert.equal(status, 200, JSON.stringify(value));
  const stores = h.of('futbeat_store_calendar_range').map((c) => [c.body.p_coverage[0].date, c.body.p_snapshot.matches.map((m) => m.provenance?.source)]);
  assert.deepEqual(stores.map(([d, m]) => [d, m.length]), [[D[0], 1], [D[1], 0], [D[2], 1]]);
  const empty = h.of('futbeat_read_ingest_context')[1].body;
  assert.deepEqual(JSON.parse(JSON.stringify(empty)), { p_competition_ids: [], p_team_ids: [], p_from: null, p_to: null });
  assert.equal(value.accepted, 2);
}));

test('calendar groups: kickoff UTC date, nearest date otherwise, first date for no kickoff', () => withDb(async (db) => {
  const h = harness(db);
  const groups = h.context.calendarDateGroups([
    { kickoffUtc: '2026-09-19T23:59:00Z' }, { kickoffUtc: '2026-09-17T23:00:00Z' }, { kickoffUtc: '2026-09-25T00:00:00Z' },
    { kickoffUtc: '' }, { kickoffUtc: '2026-09-18T00:00:00Z' },
  ], D);
  assert.deepEqual(JSON.parse(JSON.stringify([...groups].map(([d, list]) => [d, list.map((e) => e.kickoffUtc)]))), [
    [D[0], ['2026-09-17T23:00:00Z', '', '2026-09-18T00:00:00Z']],
    [D[1], ['2026-09-19T23:59:00Z']],
    [D[2], ['2026-09-25T00:00:00Z']]]);
}));

test('calendar, large batch: 3 dates x 150 fixtures, no duplicates, a re-run creates nothing new', () => withDb(async (db) => {
  const events = [];
  for (const [d, date] of D.entries()) {
    for (let i = 0; i < 150; i += 1) {
      events.push(fixture(`big-${d}-${i}`, date, i % 24, `L${i % 12}`, `T${d}-${i}`, `T${d}-${i + 150}`));
    }
  }
  const h1 = harness(db);
  const first = await h1.calendar(events, D);
  assert.equal(first.status, 200, JSON.stringify(first.value));
  assert.equal(first.value.accepted, 450);
  assert.ok(h1.of('futbeat_resolve_global_entities').every((c) => c.body.p_items.length <= 50));
  const matches = await count(db, "select count(*)::int n from futbeat_private.entities where kind='match'");
  const mappings = await count(db, 'select count(*)::int n from futbeat_private.provider_entities');
  const h2 = harness(db);
  const again = await h2.calendar(events, D);
  assert.equal(again.status, 200, JSON.stringify(again.value));
  assert.equal(await count(db, "select count(*)::int n from futbeat_private.entities where kind='match'"), matches, 'no new matches');
  assert.equal(await count(db, 'select count(*)::int n from futbeat_private.provider_entities'), mappings, 'no new mappings');
  assert.equal(await count(db, `select count(*)::int n from (select payload->>'homeTeamId', payload->>'awayTeamId', payload->>'startTime'
    from futbeat_private.entities where kind='match' group by 1,2,3 having count(*)>1) x`), 0, 'no duplicate fixtures');
  assert.equal(await count(db, "select count(*)::int n from futbeat_private.calendar_matches where source='GOAL API'"), 450);
}));

test('calendar: a failing date stops the batch; earlier dates stay stored; the ledger names the date', () => withDb(async (db) => {
  const h = harness(db, { failStoreOn: D[1] });
  const events = [fixture('f1', D[0], 12, 'L1', 'A', 'B'), fixture('f2', D[1], 12, 'L1', 'C', 'D'), fixture('f3', D[2], 12, 'L1', 'E', 'F')];
  const { status, value } = await h.calendar(events, D);
  assert.equal(status, 502);
  assert.equal(value.stage, 'store');
  assert.equal(value.failedDate, D[1]);
  assert.deepEqual(value.storedDates, [D[0]]);
  assert.equal(h.of('futbeat_store_calendar_range').length, 2, 'the third date is not attempted');
  const { status: ledgerStatus, metadata } = await lastLedger(db);
  assert.equal(ledgerStatus, 'FAILED');
  assert.equal(metadata.failedDate, D[1]);
  assert.deepEqual(metadata.storedDates, [D[0]]);
  assert.equal(typeof metadata.stageMsByDate[D[1]].store, 'number');
  assert.equal(await count(db, "select count(*)::int n from futbeat_private.calendar_coverage where provider='goal_api'"), 1);
}));

test('calendar: coverage that does not match the dates is rejected before any reservation', () => withDb(async (db) => {
  const h = harness(db);
  const { status } = await h.calendar([fixture('x1', D[0], 12, 'L1', 'A', 'B')], [D[0], D[1]], [{ date: D[0], count: 1 }, { date: D[2], count: 0 }]);
  assert.equal(status, 400);
  assert.deepEqual(h.names(), []);
}));

test('hot path unchanged: one context read for the whole window, one global store, no calendar calls, no per-date metadata', () => withDb(async (db) => {
  const h = harness(db);
  const day = (o) => { const d = new Date(); d.setUTCDate(d.getUTCDate() + o); return d.toISOString().slice(0, 10); };
  const dates = [day(-1), day(0), day(1)];
  const events = [fixture('h1', day(0), 12, 'L1', 'A', 'B'), fixture('h2', day(0), 16, 'L2', 'C', 'D')];
  const { status, value } = await h.hot(events, dates);
  assert.equal(status, 200, JSON.stringify(value));
  assert.equal(value.accepted, 2);
  assert.deepEqual(h.names().filter((n) => n !== 'futbeat_resolve_global_entities'), [
    'futbeat_reserve_provider_call', 'futbeat_read_ingest_context', 'futbeat_store_global_fixture_window', 'futbeat_complete_provider_call']);
  const { metadata } = await lastLedger(db, 'global-ingest');
  assert.equal(metadata.stageMsByDate, undefined);
  assert.deepEqual(Object.keys(metadata.stageMs).sort(),
    ['discover-matches', 'normalize', 'read-current', 'resolve-base', 'resolve-matches', 'store']);
}));
