import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { worker, goalOk } from './helpers/worker_harness.mjs';
import { normalizeMatchDetail } from '../../supabase/functions/_shared/match_detail.ts';

// Issue #101: historical Match Center is cache-first and partial-first.
// `available` = displayable; `hydrationNeeded` = registering demand would
// still help. Settled history is frozen; >90 days never calls the provider.
// Everything synthetic (ids, names, dates relative to now). No network.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

let seq = 0;
async function seed(db, { days = 10, status = 'FINISHED_PENDING_VERIFICATION', events = [], mapped = true } = {}) {
  const n = ++seq;
  const ids = { comp: `fb_comp_hm${n}`, home: `fb_team_hm${n}h`, away: `fb_team_hm${n}a`, match: `fb_match_hm${n}`, ext: `hm-${n}` };
  const start = new Date(Date.now() - days * 24 * 3600e3).toISOString();
  for (const [id, kind, payload] of [
    [ids.comp, 'competition', { id: ids.comp, name: `Comp ${n}` }],
    [ids.home, 'team', { id: ids.home, name: `Home ${n}` }],
    [ids.away, 'team', { id: ids.away, name: `Away ${n}` }],
    [ids.match, 'match', { id: ids.match, competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away,
      startTime: start, status, score: { home: 2, away: 1 }, events, statistics: [] }],
  ]) await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
  if (mapped) await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [ids.ext, ids.match]);
  return ids;
}

const lineups = { home: { startingLineups: [{ playerId: 'hm-p1', lineupPlayer: 'Player One' }] } };
const statistics = [{ type: 'Shots on Goal', home: 3, away: 1 }];
const goalEvents = [{ type: 'goal', time: '10', homeScorer: 'Scorer A', score: '1 - 0' },
  { type: 'goal', time: '55', awayScorer: 'Scorer B', score: '1 - 1' }];
const store = (db, m, payload, minutesAgo = 0) => db.query(
  "select futbeat_private.store_match_detail($1,$2,now()-make_interval(mins=>$3),$4)",
  [m.match, m.ext, minutesAgo, JSON.stringify(payload)]);
const observe = (db, m, raw = { matchStadium: 'Observed Stadium', events: goalEvents }) => db.query(
  `insert into futbeat_private.provider_observations(provider,external_match_id,canonical_match_id,received_at,status,
    home_score,away_score,events,payload_hash,raw_payload)
   values('goal_api',$1,$2,now()-interval '9 days','FINISHED_PENDING_VERIFICATION',2,1,'[]',md5($1)||md5($2),$3)`,
  [m.ext, m.match, JSON.stringify(raw)]);
const open = (db, m) => db.query('select public.futbeat_request_match_detail($1) v', [m.match]).then((r) => r.rows[0].v);
const read = (db, m) => db.query('select public.futbeat_read_match_detail($1) v', [m.match]).then((r) => r.rows[0].v);
const reserve = (db) => db.query("select public.futbeat_reserve_match_detail_call('test') v").then((r) => r.rows[0].v);
const calls = (db) => db.query("select count(*)::int n from futbeat_private.provider_call_ledger where call_kind='match-detail'").then((r) => r.rows[0].n);
const requests = (db, m) => db.query('select request_count::int n,source from futbeat_private.match_detail_requests where match_id=$1', [m.match]).then((r) => r.rows);
const remaining = (db, value = 900) => db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,provider_remaining)
  values('goal_api','global-ingest','test',now(),now(),'SUCCEEDED',$1)`, [value]);
const metric = (db, name) => db.query("select coalesce(sum(value),0)::int n from futbeat_private.demand_metrics where metric=$1", [name]).then((r) => r.rows[0].n);
const detailGoal = (m, payload) => (url) => (url.pathname === `/v1/fixtures/${m.ext}`
  ? goalOk({ id: m.ext, ...payload }) : goalOk([]));
const detailCalls = (w) => w.goalCalls().filter((u) => /\/fixtures\/hm-/.test(u)).length;

test('1/6. historical full cached: immediate answer, no demand row, 0 provider calls (frozen)', () => withDb(async (db) => {
  const m = await seed(db, { days: 12 });
  await store(db, m, { lineups, statistics, events: goalEvents }, 60 * 24 * 5);
  for (let i = 0; i < 5; i++) {
    const d = await open(db, m);
    assert.deepEqual([d.available, d.detailLevel, d.pending, d.hydrationNeeded], [true, 'full', false, false]);
  }
  assert.deepEqual(await requests(db, m), []);
  assert.equal((await reserve(db)).allowed, false);
  assert.equal(await calls(db), 0);
  assert.equal(await metric(db, 'md_history_open_warm'), 5);
}));

test('2/4/15. partial provider observation: displayable now, hydration requested once (not complete)', () => withDb(async (db) => {
  const m = await seed(db, { days: 9 });
  await observe(db, m);
  const before = await read(db, m);
  assert.deepEqual([before.available, before.detailLevel, before.coverage.detail, before.hydrationNeeded],
    [true, 'live', 'missing', true], 'displayable is not complete');
  const d = await open(db, m);
  assert.deepEqual([d.available, d.pending, d.hydrationNeeded, d.coverage.detail], [true, true, false, 'pending']);
  assert.equal(normalizeMatchDetail(d).stadium, 'Observed Stadium', 'persisted metadata shown immediately');
  assert.deepEqual(await requests(db, m), [{ n: 1, source: 'user' }]);
  assert.equal(await calls(db), 0, 'the RPC never waits for or calls the provider');
  assert.equal(await metric(db, 'md_history_open_partial'), 1);
}));

test('3. 100 users open the same partial historical match: one demand, one provider call', () => withDb(async (db) => {
  await remaining(db);
  const m = await seed(db, { days: 9 });
  await observe(db, m);
  for (let i = 0; i < 100; i++) await open(db, m);
  assert.deepEqual(await requests(db, m), [{ n: 100, source: 'user' }]);
  const w = worker(db, detailGoal(m, { lineups, statistics, events: goalEvents }));
  await w.run();
  await w.run();
  assert.equal(detailCalls(w), 1);
  assert.equal(await calls(db), 1);
}));

test('4/5. completely uncached: pending at once; after the provider fetch the next read is full', () => withDb(async (db) => {
  await remaining(db);
  const m = await seed(db, { days: 5 });
  const d = await open(db, m);
  assert.deepEqual([d.available, d.pending, d.coverage.detail], [false, true, 'pending']);
  assert.equal(await calls(db), 0);
  assert.equal(await metric(db, 'md_history_open_cold'), 1);
  const w = worker(db, detailGoal(m, { lineups, statistics, events: goalEvents }));
  await w.run();
  const after = await read(db, m);
  assert.deepEqual([after.detailLevel, after.coverage.lineup, after.coverage.statistics, after.pending, after.hydrationNeeded],
    ['full', 'available', 'available', false, false]);
  // Reopen: cache hit, no provider call.
  await open(db, m);
  assert.equal(detailCalls(w), 1);
  assert.equal((await reserve(db)).allowed, false);
}));

test('7. missing lineup + statistics available: lineup hydrates, statistics shown', () => withDb(async (db) => {
  const m = await seed(db, { days: 10 });
  await store(db, m, { statistics }, 60 * 7);
  const d = await open(db, m);
  assert.deepEqual([d.coverage.lineup, d.coverage.statistics, d.pending], ['pending', 'available', true]);
  assert.equal(normalizeMatchDetail(d).statistics.length > 0, true);
}));

test('8. lineup available + statistics missing: statistics hydrate, lineup shown', () => withDb(async (db) => {
  const m = await seed(db, { days: 10 });
  await store(db, m, { lineups }, 60 * 7);
  const d = await open(db, m);
  assert.deepEqual([d.coverage.lineup, d.coverage.statistics, d.pending], ['available', 'pending', true]);
}));

test('9. both sections NO_DATA: frozen, no retry loop', () => withDb(async (db) => {
  const m = await seed(db, { days: 20 });
  await store(db, m, { events: goalEvents }, 180);
  await store(db, m, { events: goalEvents }, 0);
  const cov = (await db.query('select lineup_state,statistics_state from futbeat_private.match_detail_coverage where match_id=$1', [m.match])).rows[0];
  assert.deepEqual(cov, { lineup_state: 'NO_DATA', statistics_state: 'NO_DATA' });
  await db.query("update futbeat_private.match_detail_cache set fetched_at=now()-interval '3 days' where match_id=$1", [m.match]);
  for (let i = 0; i < 5; i++) {
    const d = await open(db, m);
    assert.deepEqual([d.coverage.lineup, d.coverage.statistics, d.pending, d.hydrationNeeded], ['unavailable', 'unavailable', false, false]);
  }
  assert.deepEqual(await requests(db, m), []);
  assert.equal(await calls(db), 0);
}));

test('10. transient fetch failure: backoff, persisted partial data stays', () => withDb(async (db) => {
  await remaining(db);
  const m = await seed(db, { days: 9 });
  await observe(db, m);
  await open(db, m);
  const r = await reserve(db);
  assert.equal(r.matchId, m.match);
  await db.query("select public.futbeat_complete_provider_call($1,'FAILED',null,500,'GOAL_DETAIL_FAILED','{}')", [r.reservationId]);
  const d = await open(db, m);
  assert.deepEqual([d.available, d.detailLevel, d.pending, d.hydrationNeeded], [true, 'live', false, false]);
  assert.ok(d.coverage.retryAt, 'backoff reported');
  assert.equal(normalizeMatchDetail(d).stadium, 'Observed Stadium');
  assert.equal((await reserve(db)).allowed, false, 'no retry loop during backoff');
}));

for (const [label, days] of [['11. 7-30 days', 15], ['12. 30-90 days', 60]]) {
  test(`${label}: on demand as user class (no planner, no user_high), one fetch`, () => withDb(async (db) => {
    await remaining(db);
    const m = await seed(db, { days });
    const d = await open(db, m);
    assert.deepEqual([d.pending, d.coverage.detail], [true, 'pending']);
    const r = await reserve(db);
    assert.deepEqual([r.allowed, r.matchId, r.quotaClass], [true, m.match, 'user']);
    // The background planner never adds this history by itself.
    assert.equal((await db.query("select count(*)::int n from futbeat_private.match_detail_requests where source<>'user'")).rows[0].n, 0);
  }));
}

test('13. >90 days: persisted data, stable empty sections, no demand, no provider call', () => withDb(async (db) => {
  const m = await seed(db, { days: 100, events: [{ type: 'GOAL', minute: 10 }] });
  await observe(db, m);
  const d = await open(db, m);
  assert.deepEqual([d.available, d.pending, d.hydrationNeeded, d.coverage.lineup, d.coverage.statistics],
    [true, false, false, 'missing', 'missing']);
  assert.deepEqual(await requests(db, m), []);
  assert.equal(await calls(db), 0);
  assert.equal(await metric(db, 'md_history_open_out_of_horizon'), 1);
  const w = worker(db, () => { throw new Error('GOAL must not be called'); });
  await w.run();
  assert.equal(detailCalls(w), 0);
}));

test('14. canonical events without any detail: the timeline data stays in the match context', () => withDb(async (db) => {
  const m = await seed(db, { days: 100, events: [{ id: 'e1', type: 'GOAL', minute: 10, side: 'home' }] });
  const d = await open(db, m);
  assert.deepEqual([d.available, d.pending], [false, false]);
  const ctx = (await db.query('select public.futbeat_read_match_context($1) v', [m.match])).rows[0].v;
  const match = ctx.matches.find((x) => x.id === m.match);
  assert.equal(match.events.length, 1);
  assert.deepEqual(match.score, { home: 2, away: 1 });
}));

test('16. full hydration replaces the partial observation: incidents are not duplicated', () => withDb(async (db) => {
  await remaining(db);
  const m = await seed(db, { days: 9 });
  await observe(db, m);
  assert.equal(normalizeMatchDetail(await open(db, m)).incidents.length, 2);
  const w = worker(db, detailGoal(m, { lineups, statistics, events: goalEvents }));
  await w.run();
  const full = normalizeMatchDetail(await read(db, m));
  assert.equal(full.detailLevel, 'full');
  assert.equal(full.incidents.length, goalEvents.length);
}));

test('FPV finals: clock cadence only inside the results window, then frozen', () => withDb(async (db) => {
  const needs = async (m) => (await db.query('select futbeat_private.match_detail_needs_fetch($1) v', [m.match])).rows[0].v;
  const recent = await seed(db, { days: 0.1 });
  await store(db, recent, { lineups, statistics }, 40);
  assert.equal(await needs(recent), true, 'results window keeps its cadence');
  const old = await seed(db, { days: 3 });
  await store(db, old, { lineups, statistics }, 60 * 24);
  assert.equal(await needs(old), false, 'settled history is frozen');
}));

test('diagnostics: warm/cold/partial opens, hydration seconds and coverage by age (service only)', () => withDb(async (db) => {
  await remaining(db);
  const warm = await seed(db, { days: 2 });
  await store(db, warm, { lineups, statistics }, 60 * 24);
  const partial = await seed(db, { days: 9 });
  await observe(db, partial);
  await seed(db, { days: 40 });
  await seed(db, { days: 120 });
  await open(db, warm);
  await open(db, partial);
  const w = worker(db, detailGoal(partial, { lineups, statistics }));
  await w.run();
  const x = (await db.query('select public.futbeat_historical_match_center_metrics() v')).rows[0].v;
  assert.equal(x.historyOpensToday.warm, 1);
  assert.equal(x.historyOpensToday.partial, 1);
  assert.equal(x.coverageByAge['1-3d'].settled, 1);
  assert.equal(x.coverageByAge['7-30d'].withDetail, 1);
  assert.equal(x.coverageByAge['30-90d'].withDetail, 0);
  assert.equal(x.coverageByAge['>90d'].matches, 1);
  assert.equal(x.hydrationSecondsToday.history.calls, 1);
  const can = async (role) => (await db.query("select has_function_privilege($1,'public.futbeat_historical_match_center_metrics()','EXECUTE') ok", [role])).rows[0].ok;
  assert.equal(await can('anon'), false);
  assert.equal(await can('authenticated'), false);
  assert.equal(await can('service_role'), true);
}));

// Reproducible local benchmark (PGlite, relative numbers only; generous
// bounds so CI is not flaky). Production reference: reads 9-18 ms.
test('benchmark: warm read, cold persisted-only read, request/enqueue, simulated provider completion', () => withDb(async (db) => {
  await remaining(db);
  const warm = await seed(db, { days: 12 });
  await store(db, warm, { lineups, statistics, events: goalEvents }, 60 * 24);
  const cold = await seed(db, { days: 12 });
  await observe(db, cold);
  const time = async (fn, n = 20) => {
    const samples = [];
    for (let i = 0; i < n; i++) { const t = performance.now(); await fn(i); samples.push(performance.now() - t); }
    samples.sort((a, b) => a - b);
    return { median: +samples[Math.floor(n / 2)].toFixed(2), p95: +samples[Math.floor(n * 0.95) - 1].toFixed(2) };
  };
  const report = {
    warmRead: await time(() => read(db, warm)),
    warmOpen: await time(() => open(db, warm)),
    coldPersistedRead: await time(() => read(db, cold)),
    requestEnqueue: await time(() => open(db, cold)),
  };
  const t = performance.now();
  const w = worker(db, detailGoal(cold, { lineups, statistics, events: goalEvents }));
  await w.run();
  report.simulatedProviderCompletionMs = +(performance.now() - t).toFixed(2);
  console.log('historical Match Center benchmark (ms)', JSON.stringify(report));
  for (const key of ['warmRead', 'warmOpen', 'coldPersistedRead', 'requestEnqueue']) {
    assert.ok(report[key].median < 1500, `${key} ${report[key].median} ms`);
  }
  assert.equal((await read(db, cold)).detailLevel, 'full');
}));

test('available / hydrationNeeded / pending are distinct (DB and normalized API)', () => withDb(async (db) => {
  await remaining(db);
  const m = await seed(db, { days: 9 });
  await observe(db, m);
  const states = (d) => [d.available, d.hydrationNeeded, d.pending];
  // Before any demand: displayable, demand would help, nothing awaited.
  assert.deepEqual(states(await read(db, m)), [true, true, false]);
  // Request-aware open: demand exists -> not needed any more, but awaited.
  const opened = await open(db, m);
  assert.deepEqual(states(opened), [true, false, true]);
  assert.deepEqual(states(normalizeMatchDetail(opened)), [true, false, true], 'API keeps both');
  assert.deepEqual(states(await read(db, m)), [true, false, true]);
  // Reserved (in flight): still awaited, still not needed.
  const r = await reserve(db);
  assert.equal(r.matchId, m.match);
  assert.deepEqual(states(await read(db, m)), [true, false, true]);
  // Stored: complete.
  await store(db, m, { lineups, statistics, events: goalEvents });
  await db.query("select public.futbeat_complete_provider_call($1,'SUCCEEDED',null,200,null,'{}')", [r.reservationId]);
  assert.deepEqual(states(await read(db, m)), [true, false, false]);
}));

test('an expired demand / finished backoff says hydrationNeeded again and a reopen re-enqueues once', () => withDb(async (db) => {
  await remaining(db);
  const m = await seed(db, { days: 9 });
  await observe(db, m);
  await open(db, m);
  const r = await reserve(db);
  await db.query("select public.futbeat_complete_provider_call($1,'FAILED',null,500,'X','{}')", [r.reservationId]);
  assert.deepEqual([(await read(db, m)).hydrationNeeded, (await read(db, m)).pending], [false, false], 'backoff');
  // Backoff over and the user demand expired.
  await db.query("update futbeat_private.match_detail_coverage set next_retry_at=now()-interval '1 second' where match_id=$1", [m.match]);
  await db.query("update futbeat_private.match_detail_requests set expires_at=now()-interval '1 second' where match_id=$1", [m.match]);
  const again = await read(db, m);
  assert.deepEqual([again.hydrationNeeded, again.pending], [true, false]);
  const reopened = await open(db, m);
  assert.deepEqual([reopened.hydrationNeeded, reopened.pending], [false, true]);
  await open(db, m); // a second open is deduplicated
  assert.equal((await db.query('select count(*)::int n from futbeat_private.match_detail_requests where match_id=$1 and expires_at>now()', [m.match])).rows[0].n, 1);
  assert.equal((await reserve(db)).matchId, m.match);
  assert.equal(await calls(db), 2);
}));

test('FPV boundary: inside resultsWindowHours = results class; just outside = user class', () => withDb(async (db) => {
  await remaining(db);
  const windowHours = Number((await db.query(
    "select futbeat_private.quota_setting('goal_api','resultsWindowHours',4) v")).rows[0].v);
  const classOf = async (minutesAgo) => {
    await db.query("delete from futbeat_private.match_detail_requests where true");
    await db.query("delete from futbeat_private.provider_call_ledger where call_kind='match-detail'");
    const m = await seed(db, { days: minutesAgo / (24 * 60) });
    await open(db, m);
    const src = (await requests(db, m))[0]?.source;
    const r = await reserve(db);
    assert.equal(r.matchId, m.match);
    return { source: src, quotaClass: r.quotaClass, bucket: r.bucket };
  };
  const inside = await classOf(windowHours * 60 - 5);
  assert.deepEqual(inside, { source: 'user', quotaClass: 'results', bucket: 'results' }, 'recent result keeps its protected class');
  const outside = await classOf(windowHours * 60 + 5);
  assert.equal(outside.source, 'user');
  assert.equal(outside.quotaClass, 'user', 'history never borrows the results floor');
  assert.notEqual(outside.bucket, 'results');
  const old = await classOf(30 * 24 * 60);
  assert.deepEqual([old.source, old.quotaClass], ['user', 'user']);
}));

// Final post-match capture (#115 review): a cache taken before
// kickoff + finalFetchAfterMinutes is not frozen until one capture after it.
const finalAfter = (db) => db.query("select futbeat_private.quota_setting('goal_api','finalFetchAfterMinutes',120)::int v")
  .then((r) => r.rows[0].v);
const needsFetch = (db, m) => db.query('select futbeat_private.match_detail_needs_fetch($1) v', [m.match]).then((r) => r.rows[0].v);
// Cache fetched `minutesAfterKickoff` after the kickoff of a match `days` ago.
const storeAtKickoffPlus = async (db, m, days, minutesAfterKickoff, payload) =>
  store(db, m, payload, Math.round(days * 24 * 60) - minutesAfterKickoff);

test('A. settled but pre-final cache: one user final capture, then frozen', () => withDb(async (db) => {
  await remaining(db);
  const fa = await finalAfter(db);
  const m = await seed(db, { days: 10 });
  await storeAtKickoffPlus(db, m, 10, fa - 30, { lineups, statistics, events: goalEvents });
  const cov = (await db.query('select lineup_state,statistics_state from futbeat_private.match_detail_coverage where match_id=$1', [m.match])).rows[0];
  assert.deepEqual(cov, { lineup_state: 'AVAILABLE', statistics_state: 'AVAILABLE' });
  assert.equal(await needsFetch(db, m), true);
  const before = await read(db, m);
  assert.deepEqual([before.hydrationNeeded, before.pending, before.coverage.stale], [true, false, true]);
  await open(db, m);
  await open(db, m);
  assert.deepEqual(await requests(db, m), [{ n: 2, source: 'user' }], 'one deduplicated demand');
  const r = await reserve(db);
  assert.deepEqual([r.matchId, (await db.query("select metadata->>'source' s from futbeat_private.provider_call_ledger where id=$1", [r.reservationId])).rows[0].s, r.quotaClass],
    [m.match, 'user', 'user']);
  await store(db, m, { lineups, statistics, events: goalEvents });
  await db.query("select public.futbeat_complete_provider_call($1,'SUCCEEDED',null,200,null,'{}')", [r.reservationId]);
  assert.equal(await needsFetch(db, m), false);
  const after = await open(db, m);
  assert.deepEqual([after.hydrationNeeded, after.pending, after.coverage.stale], [false, false, false]);
  assert.equal((await reserve(db)).allowed, false);
  assert.equal(await calls(db), 1);
}));

test('B. settled post-final cache: frozen at once, not stale, no demand', () => withDb(async (db) => {
  const fa = await finalAfter(db);
  const m = await seed(db, { days: 10 });
  await storeAtKickoffPlus(db, m, 10, fa + 30, { lineups, statistics, events: goalEvents });
  assert.equal(await needsFetch(db, m), false);
  const d = await open(db, m);
  assert.deepEqual([d.hydrationNeeded, d.pending, d.coverage.stale], [false, false, false]);
  assert.deepEqual(await requests(db, m), []);
  assert.equal(await calls(db), 0);
}));

test('C. pre-final cache with empty events: one final capture allowed, then frozen even if still empty', () => withDb(async (db) => {
  await remaining(db);
  const fa = await finalAfter(db);
  const m = await seed(db, { days: 10 });
  await storeAtKickoffPlus(db, m, 10, fa - 30, { lineups, statistics });
  assert.equal(await needsFetch(db, m), true);
  await open(db, m);
  const w = worker(db, detailGoal(m, { lineups, statistics }));
  await w.run();
  assert.equal(detailCalls(w), 1);
  assert.equal(await needsFetch(db, m), false, 'no events retry loop');
  await open(db, m);
  await w.run();
  assert.equal(detailCalls(w), 1);
  assert.equal(normalizeMatchDetail(await read(db, m)).incidents.length, 0);
}));

test('D. >90 days with a pre-final cache: hydrationNeeded=false, no demand, no provider call', () => withDb(async (db) => {
  const fa = await finalAfter(db);
  const m = await seed(db, { days: 100 });
  await storeAtKickoffPlus(db, m, 100, fa - 30, { lineups, statistics });
  const d = await open(db, m);
  assert.deepEqual([d.available, d.hydrationNeeded, d.pending], [true, false, false]);
  assert.deepEqual(await requests(db, m), []);
  assert.equal(await calls(db), 0);
}));

test('E. recent FPV inside resultsWindowHours: results bucket and class, unaffected by the final rule', () => withDb(async (db) => {
  await remaining(db);
  const fa = await finalAfter(db);
  const windowHours = Number((await db.query("select futbeat_private.quota_setting('goal_api','resultsWindowHours',4) v")).rows[0].v);
  const days = (windowHours * 60 - 20) / (24 * 60);
  const m = await seed(db, { days });
  await storeAtKickoffPlus(db, m, days, fa - 30, { lineups, statistics });
  assert.equal(await needsFetch(db, m), true);
  await open(db, m);
  const r = await reserve(db);
  assert.deepEqual([r.matchId, r.quotaClass, r.bucket], [m.match, 'results', 'results']);
}));
