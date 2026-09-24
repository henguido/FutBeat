import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// Generic Match Center completeness: a cached detail is not automatically a
// complete detail. Names/ids are synthetic; nothing here is league-specific.

let seq = 0;
async function seedMatch(db, { status = 'VERIFIED', startOffsetMinutes = -180 } = {}) {
  const n = ++seq;
  const ids = { comp: `fb_comp_cp${n}`, home: `fb_team_cp${n}h`, away: `fb_team_cp${n}a`, match: `fb_match_cp${n}` };
  const start = new Date(Date.now() + startOffsetMinutes * 60000).toISOString();
  for (const [id, kind, payload] of [
    [ids.comp, 'competition', { id: ids.comp, name: `Competition ${n}` }],
    [ids.home, 'team', { id: ids.home, name: `Home ${n}` }],
    [ids.away, 'team', { id: ids.away, name: `Away ${n}` }],
    [ids.match, 'match', { id: ids.match, competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away,
      startTime: start, status, events: [], statistics: [] }],
  ]) await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [`cp-${n}`, ids.match]);
  return { ...ids, external: `cp-${n}` };
}

const lineups = { home: { startingLineups: [{ playerId: 'x1', lineupPlayer: 'Player One' }] } };
const statistics = [{ type: 'Shots', home: 3, away: 1 }];
const store = (db, m, payload, minutesAgo = 0) => db.query(
  "select futbeat_private.store_match_detail($1,$2,now()-make_interval(mins=>$3),$4)",
  [m.match, m.external, minutesAgo, JSON.stringify(payload)]);
const open = (db, m) => db.query('select public.futbeat_request_match_detail($1) v', [m.match]).then((r) => r.rows[0].v);
const read = (db, m) => db.query('select public.futbeat_read_match_detail($1) v', [m.match]).then((r) => r.rows[0].v);
const reserve = (db) => db.query("select public.futbeat_reserve_match_detail_call('test') v").then((r) => r.rows[0].v);
const needs = (db, m) => db.query('select futbeat_private.match_detail_needs_fetch($1) v', [m.match]).then((r) => r.rows[0].v);
const calls = (db) => db.query("select count(*)::int n from futbeat_private.provider_call_ledger where call_kind='match-detail'")
  .then((r) => r.rows[0].n);
const age = (db, m, minutes) => db.query(
  "update futbeat_private.match_detail_cache set fetched_at=now()-make_interval(mins=>$2) where match_id=$1", [m.match, minutes]);

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

test('1. no detail: opening requests it and the client sees detail pending', () => withDb(async (db) => {
  const m = await seedMatch(db);
  const detail = await open(db, m);
  assert.deepEqual([detail.coverage.detail, detail.pending], ['pending', true]);
  assert.equal((await reserve(db)).matchId, m.match);
}));

test('2/3. finished match with events but no lineup: incomplete, re-requested (not treated as complete)', () => withDb(async (db) => {
  const m = await seedMatch(db, { status: 'VERIFIED', startOffsetMinutes: -3000 });
  await store(db, m, { events: [{ type: 'goal', time: '10' }], statistics });
  await age(db, m, 7 * 60);
  assert.equal(await needs(db, m), true, 'VERIFIED match missing lineup is due again');
  const detail = await open(db, m);
  assert.deepEqual([detail.coverage.lineup, detail.coverage.statistics, detail.pending], ['pending', 'available', true]);
  assert.equal((await reserve(db)).matchId, m.match);
}));

test('4. lineup present, statistics missing: statistics incomplete', () => withDb(async (db) => {
  const m = await seedMatch(db, { status: 'VERIFIED', startOffsetMinutes: -120 });
  await store(db, m, { lineups });
  await age(db, m, 20);
  const detail = await open(db, m);
  assert.deepEqual([detail.coverage.lineup, detail.coverage.statistics], ['available', 'pending']);
}));

test('5. complete fresh detail: 0 provider calls, nothing pending', () => withDb(async (db) => {
  const m = await seedMatch(db, { status: 'VERIFIED', startOffsetMinutes: -3000 });
  await store(db, m, { lineups, statistics }, 60);
  for (let i = 0; i < 5; i++) {
    const detail = await open(db, m);
    assert.deepEqual([detail.pending, detail.coverage.lineup, detail.coverage.statistics, detail.coverage.stale],
      [false, 'available', 'available', false]);
  }
  assert.equal((await reserve(db)).reason, 'no_detail_due');
  assert.equal(await calls(db), 0);
}));

test('6. 100 opens of the same incomplete match -> one reservation', () => withDb(async (db) => {
  const m = await seedMatch(db, { status: 'VERIFIED', startOffsetMinutes: -3000 });
  await store(db, m, { lineups }, 7 * 60);
  await Promise.all(Array.from({ length: 100 }, () => open(db, m)));
  const results = await Promise.all(Array.from({ length: 50 }, () => reserve(db)));
  assert.equal(results.filter((r) => r.allowed).length, 1);
  assert.equal(await calls(db), 1);
}));

test('7. provider has no lineup: after repeated empty answers it is unavailable and polling stops', () => withDb(async (db) => {
  const m = await seedMatch(db, { status: 'VERIFIED', startOffsetMinutes: -3000 });
  await store(db, m, { statistics }, 8 * 60);
  await store(db, m, { statistics, events: [] }, 7 * 60);
  const detail = await open(db, m);
  assert.deepEqual([detail.coverage.lineup, detail.coverage.statistics, detail.pending], ['unavailable', 'available', false]);
  assert.equal(await needs(db, m), false);
  assert.equal((await reserve(db)).reason, 'no_detail_due');
  // A later answer with a lineup still upgrades it (the section is never locked).
  await store(db, m, { lineups });
  assert.equal((await read(db, m)).coverage.lineup, 'available');
}));

test('failed fetch backs off exponentially instead of looping', () => withDb(async (db) => {
  const m = await seedMatch(db);
  await open(db, m);
  const first = await reserve(db);
  await db.query("select public.futbeat_complete_provider_call($1,'FAILED',null,500,'X','{}')", [first.reservationId]);
  assert.equal(await needs(db, m), false);
  assert.equal((await reserve(db)).reason, 'no_detail_due');
  const detail = await read(db, m);
  assert.equal(detail.pending, false, 'no false "searching" during backoff');
  assert.ok(detail.coverage.retryAt);
  await db.query("update futbeat_private.match_detail_coverage set next_retry_at=now()-interval '1 second'");
  const second = await reserve(db);
  await db.query("select public.futbeat_complete_provider_call($1,'FAILED',null,500,'X','{}')", [second.reservationId]);
  const backoff = (await db.query('select failure_count,next_retry_at>now()+interval \'3 minutes\' longer from futbeat_private.match_detail_coverage')).rows[0];
  assert.deepEqual(backoff, { failure_count: 2, longer: true });
}));

test('sections that cannot exist yet are not demanded (upcoming match without lineup)', () => withDb(async (db) => {
  const m = await seedMatch(db, { status: 'SCHEDULED', startOffsetMinutes: 600 });
  await store(db, m, { matchStatus: 'NOT_STARTED' }, 5);
  assert.equal(await needs(db, m), false);
  const detail = await open(db, m);
  assert.deepEqual([detail.coverage.lineup, detail.coverage.statistics, detail.pending], ['missing', 'missing', false]);
}));

test('live match refreshes an incomplete section on the live cadence only', () => withDb(async (db) => {
  const m = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -30 });
  await store(db, m, { lineups }, 2);
  assert.equal(await needs(db, m), false, 'fresh live detail');
  await age(db, m, 6);
  assert.equal(await needs(db, m), true);
}));

test('completeness helpers are private', () => withDb(async (db) => {
  for (const role of ['anon', 'authenticated', 'service_role']) {
    for (const fn of ['futbeat_private.match_detail_needs_fetch(text)', 'futbeat_private.match_detail_completeness(text)']) {
      assert.equal((await db.query("select has_function_privilege($1,$2,'EXECUTE') ok", [role, fn])).rows[0].ok, false);
    }
  }
  assert.equal((await db.query("select has_table_privilege('anon','futbeat_private.match_detail_coverage','SELECT') ok")).rows[0].ok, false);
}));

test('worker: an incomplete stored detail is completed on open and lineup players get canonical ids', async () => {
  const { worker, goalOk } = await import('./helpers/worker_harness.mjs');
  await withDb(async (db) => {
    const m = await seedMatch(db, { status: 'VERIFIED', startOffsetMinutes: -3000 });
    await store(db, m, { events: [], statistics }, 7 * 60);
    assert.equal((await open(db, m)).coverage.lineup, 'pending');
    const goal = worker(db, (url) => {
      assert.equal(url.pathname, `/v1/fixtures/${m.external}`);
      return goalOk({ matchStatus: 'FINISHED', statistics, lineups: {
        home: { startingLineups: [{ playerId: 'wk-1', lineupPlayer: 'Synthetic Starter' }],
          substitutes: [{ playerId: 'wk-2', lineupPlayer: 'Synthetic Sub' }] } } });
    });
    await goal.run();
    const detail = await read(db, m);
    assert.deepEqual([detail.coverage.lineup, detail.pending], ['available', false]);
    const ids = (await db.query(`select external_id,canonical_id from futbeat_private.provider_entities
      where provider='goal_api' and kind='player' and external_id in ('wk-1','wk-2') order by external_id`)).rows;
    assert.equal(ids.length, 2);
    assert.ok(ids.every((r) => r.canonical_id.startsWith('fb_player_')));
    await goal.run();
    assert.equal(goal.goalCalls().length, 1, 'complete now: no further fetch');
  });
});
