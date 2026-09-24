import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { openDatabase } from '../storage/database.mjs';

// Generic lineup/detail coverage planner by temporal profile. All data is
// synthetic; nothing depends on a league, team, country or date.

let seq = 0;
async function seed(db, { status = 'SCHEDULED', minutes = 0 } = {}) {
  const n = ++seq;
  const ids = { comp: `fb_comp_pl${n}`, home: `fb_team_pl${n}h`, away: `fb_team_pl${n}a`, match: `fb_match_pl${n}`, ext: `pl-${n}` };
  for (const [id, kind, payload] of [
    [ids.comp, 'competition', { id: ids.comp, name: `Comp ${n}` }],
    [ids.home, 'team', { id: ids.home, name: `H ${n}` }],
    [ids.away, 'team', { id: ids.away, name: `A ${n}` }],
    [ids.match, 'match', { id: ids.match, competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away, status,
      startTime: new Date(Date.now() + minutes * 60000).toISOString(), events: [], statistics: [] }],
  ]) await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [ids.ext, ids.match]);
  return ids;
}
const lineups = { home: { startingLineups: [{ playerId: 'x', lineupPlayer: 'Synthetic' }] } };
const stats = [{ type: 'Shots', home: 1, away: 0 }];
const store = (db, m, payload, minutesAgo = 0) => db.query(
  "select futbeat_private.store_match_detail($1,$2,now()-make_interval(mins=>$3),$4)", [m.match, m.ext, minutesAgo, JSON.stringify(payload)]);
const plan = (db, limit = null) => db.query('select futbeat_private.plan_match_detail_coverage($1) v', [limit]).then((r) => r.rows[0].v);
const reserve = (db) => db.query("select public.futbeat_reserve_match_detail_call('test') v").then((r) => r.rows[0].v);
const source = (db, m) => db.query('select source from futbeat_private.match_detail_requests where match_id=$1', [m.match])
  .then((r) => r.rows[0]?.source);
const clearQueue = (db) => db.query('delete from futbeat_private.match_detail_requests');

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

test('11/12. priority: LIVE without lineup first, then pre-match near kickoff, then recent finished', () => withDb(async (db) => {
  const recent = await seed(db, { status: 'VERIFIED', minutes: -300 });
  const pre = await seed(db, { status: 'SCHEDULED', minutes: 45 });
  const live = await seed(db, { status: 'LIVE', minutes: -30 });
  assert.deepEqual(await plan(db, 3), [live.match, pre.match, recent.match]);
  assert.deepEqual([await source(db, pre), await source(db, recent)], ['prematch', 'recent']);
  const order = [];
  for (let i = 0; i < 3; i++) {
    const r = await reserve(db);
    order.push([r.matchId, r.quotaClass]);
    await db.query("select public.futbeat_complete_provider_call($1,'SUCCEEDED',null,200,null,'{}')", [r.reservationId]);
    await store(db, { match: r.matchId, ext: r.externalMatchId }, { lineups, statistics: stats });
  }
  assert.deepEqual(order, [[live.match, 'live'], [pre.match, 'user_high'], [recent.match, 'coverage']]);
}));

test('13. far future is never polled; upcoming gets one first fetch only (no hammering)', () => withDb(async (db) => {
  const far = await seed(db, { minutes: 5 * 24 * 60 });
  const upcoming = await seed(db, { minutes: 10 * 60 });
  assert.deepEqual(await plan(db, 5), [upcoming.match]);
  await clearQueue(db);
  await store(db, upcoming, { matchStatus: 'NOT_STARTED' }, 40);
  assert.deepEqual(await plan(db, 5), [], 'already fetched once: wait for the pre-match window');
  assert.equal(await source(db, far), undefined);
}));

test('14/18. recent finished without lineup is recovered; with lineup and stats it is frozen (0 calls)', () => withDb(async (db) => {
  const m = await seed(db, { status: 'VERIFIED', minutes: -240 });
  await store(db, m, { statistics: stats }, 60);
  assert.deepEqual(await plan(db), [m.match]);
  await clearQueue(db);
  await store(db, m, { lineups, statistics: stats });
  assert.deepEqual(await plan(db), []);
  assert.equal((await reserve(db)).reason, 'no_detail_due');
}));

test('15. history: missing sections retried on the spaced cadence; opening it is handled on demand', () => withDb(async (db) => {
  const m = await seed(db, { status: 'VERIFIED', minutes: -4 * 24 * 60 });
  await store(db, m, { statistics: stats }, 7 * 60);
  assert.deepEqual(await plan(db), [m.match]);
  assert.equal(await source(db, m), 'bootstrap');
  await clearQueue(db);
  // A user opening it upgrades the same row to user priority (one row).
  await db.query('select public.futbeat_request_match_detail($1)', [m.match]);
  assert.equal(await source(db, m), 'user');
}));

test('16/17. empty pre-match lineup is retried later; empty history becomes NO_DATA and stops', () => withDb(async (db) => {
  const pre = await seed(db, { minutes: 30 });
  await store(db, pre, { matchStatus: 'NOT_STARTED' }, 20);
  assert.deepEqual(await plan(db), [pre.match], 'pre-match lineup may still appear');
  await clearQueue(db);
  const old = await seed(db, { status: 'VERIFIED', minutes: -5 * 24 * 60 });
  await store(db, old, { statistics: stats }, 8 * 60);
  await store(db, old, { statistics: stats }, 7 * 60);
  assert.equal((await db.query('select lineup_state from futbeat_private.match_detail_coverage where match_id=$1', [old.match])).rows[0].lineup_state, 'NO_DATA');
  assert.ok(!(await plan(db, 10)).includes(old.match));
}));

test('19. a stored lineup persists; later empty answers never erase it', () => withDb(async (db) => {
  const m = await seed(db, { status: 'LIVE', minutes: -20 });
  await store(db, m, { lineups }, 10);
  await store(db, m, { lineups: [] }, 0);
  assert.equal((await db.query('select public.futbeat_read_match_detail($1) v', [m.match])).rows[0].v.coverage.lineup, 'available');
}));

test('20. repeated planner runs and many users produce one row and one recovery per match', () => withDb(async (db) => {
  const m = await seed(db, { status: 'LIVE', minutes: -20 });
  for (let i = 0; i < 5; i++) await plan(db);
  for (let i = 0; i < 20; i++) await db.query('select public.futbeat_request_match_detail($1)', [m.match]);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.match_detail_requests')).rows[0].n, 1);
  const results = [];
  for (let i = 0; i < 10; i++) results.push(await reserve(db));
  assert.equal(results.filter((r) => r.allowed).length, 1);
}));

test('queue never blocks: an open user request and a backoff head do not stop other matches', () => withDb(async (db) => {
  const userOpened = await seed(db, { status: 'VERIFIED', minutes: -3000 });
  await db.query('select public.futbeat_request_match_detail($1)', [userOpened.match]);
  const inBackoff = await seed(db, { status: 'LIVE', minutes: -10 });
  await db.query(`insert into futbeat_private.match_detail_coverage(match_id,failure_count,next_retry_at)
    values($1,3,now()+interval '1 hour')`, [inBackoff.match]);
  const live = await seed(db, { status: 'LIVE', minutes: -30 });
  assert.deepEqual(await plan(db), [live.match]);
}));

test('bulk live/results payload with a lineup is promoted to the stored detail (0 extra calls)', () => withDb(async (db) => {
  const m = await seed(db, { status: 'LIVE', minutes: -25 });
  const observe = async (raw, hashChar) => db.query('select public.futbeat_record_live_batch($1,$2,$3)', ['goal_api',
    new Date().toISOString(), JSON.stringify([{ externalMatchId: m.ext, status: 'LIVE', minute: 25, score: { home: 0, away: 0 },
      events: [], payloadHash: createHash('sha256').update(hashChar).digest('hex'), rawPayload: raw }])]);
  await observe({ matchStatus: 'LIVE' }, 'a');
  assert.equal((await db.query('select count(*)::int n from futbeat_private.match_detail_cache')).rows[0].n, 0);
  await observe({ matchStatus: 'LIVE', lineups }, 'b');
  const detail = (await db.query('select public.futbeat_read_match_detail($1) v', [m.match])).rows[0].v;
  assert.equal(detail.coverage.lineup, 'available');
  assert.equal((await db.query("select coalesce(sum(value),0)::int n from futbeat_private.demand_metrics where metric='lineups_from_bulk'")).rows[0].n, 1);
  assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_call_ledger where call_kind='match-detail'")).rows[0].n, 0);
}));

test('unknown remaining: background history cannot take the blind budget; LIVE can', () => withDb(async (db) => {
  const decide = async (cls) => (await db.query("select futbeat_private.quota_decision('goal_api','match-detail',$1) v", [cls])).rows[0].v;
  await db.exec(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status)
    select 'goal_api','match-detail','test','FAILED' from generate_series(1,150)`);
  assert.equal((await decide('bootstrap')).allowed, false);
  assert.equal((await decide('live')).allowed, true);
}));

test('lineup coverage metrics report the gaps generically', () => withDb(async (db) => {
  await seed(db, { status: 'LIVE', minutes: -30 });
  const withLineup = await seed(db, { status: 'VERIFIED', minutes: -200 });
  await store(db, withLineup, { lineups, statistics: stats });
  await seed(db, { minutes: 120 });
  const metrics = (await db.query('select public.futbeat_lineup_coverage_metrics() v')).rows[0].v;
  assert.deepEqual([metrics.mapped, metrics.withDetail, metrics.withLineup, metrics.liveWithoutLineup,
    metrics.upcoming24hWithoutLineup], [3, 1, 1, 1, 1]);
  for (const role of ['anon', 'authenticated']) {
    assert.equal((await db.query("select has_function_privilege($1,'public.futbeat_lineup_coverage_metrics()','EXECUTE') ok", [role])).rows[0].ok, false);
  }
}));

test('a LIVE status long past kickoff is not live evidence (no endless live-class polling)', () => withDb(async (db) => {
  const m = await seed(db, { status: 'LIVE', minutes: -3 * 24 * 60 });
  await store(db, m, { lineups, statistics: stats }, 10);
  assert.deepEqual(await plan(db, 5), []);
  const fresh = await seed(db, { status: 'LIVE', minutes: -40 });
  await store(db, fresh, { lineups, statistics: stats }, 10);
  assert.deepEqual(await plan(db, 5), [fresh.match], 'a real live match keeps the live cadence');
  assert.equal((await reserve(db)).quotaClass, 'live');
}));

test('no status after kickoff: fetched only while sections are unknown, then settles to NO_DATA', () => withDb(async (db) => {
  const m = await seed(db, { status: 'SCHEDULED', minutes: -5 * 60 });
  await store(db, m, { lineups }, 40);
  // Lineup known, statistics unknown: spaced retries, then two misses settle it.
  assert.deepEqual(await plan(db), [m.match]);
  await clearQueue(db);
  await store(db, m, { lineups }, 20);
  await store(db, m, { lineups }, 0);
  const cov = (await db.query('select statistics_state from futbeat_private.match_detail_coverage where match_id=$1', [m.match])).rows[0];
  assert.equal(cov.statistics_state, 'NO_DATA');
  assert.deepEqual(await plan(db), []);
  // Before kickoff, a known lineup is not refetched on a clock.
  const pre = await seed(db, { minutes: 60 });
  await store(db, pre, { lineups }, 40);
  assert.ok(!(await plan(db, 5)).includes(pre.match));
}));

test('a re-planned expired request keeps its source and quota class', () => withDb(async (db) => {
  const pre = await seed(db, { minutes: 45 });
  await plan(db);
  await db.query("update futbeat_private.match_detail_requests set expires_at=now()-interval '1 second'");
  await plan(db);
  assert.equal(await source(db, pre), 'prematch');
  assert.equal((await reserve(db)).quotaClass, 'user_high');
}));

test('background planning stops at its share of the daily cap; LIVE and user opens keep the rest', () => withDb(async (db) => {
  // Known, abundant provider budget: only the background share applies.
  await db.exec(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,provider_remaining)
    select 'goal_api','match-detail','test','SUCCEEDED',50000 from generate_series(1,540)`);
  const recent = await seed(db, { status: 'VERIFIED', minutes: -300 });
  const live = await seed(db, { status: 'LIVE', minutes: -30 });
  assert.deepEqual(await plan(db, 5), [live.match], 'only LIVE is planned');
  await db.query("insert into futbeat_private.match_detail_requests(match_id,requested_at,expires_at,request_count,source) values($1,now(),now()+interval '10 minutes',1,'recent')", [recent.match]);
  const first = await reserve(db);
  assert.equal(first.matchId, live.match);
  await db.query("select public.futbeat_complete_provider_call($1,'SUCCEEDED',null,200,null,'{}')", [first.reservationId]);
  await store(db, live, { lineups, statistics: stats });
  // The background request is never selected once the share is used...
  assert.equal((await reserve(db)).reason, 'no_detail_due');
  // ...so an open pre-match planner request cannot block a user open.
  const pre = await seed(db, { minutes: 45 });
  await db.query("insert into futbeat_private.match_detail_requests(match_id,requested_at,expires_at,request_count,source) values($1,now(),now()+interval '10 minutes',1,'prematch')", [pre.match]);
  await db.query('select public.futbeat_request_match_detail($1)', [recent.match]);
  const user = await reserve(db);
  assert.equal(user.allowed, true, 'a user open is not background');
  assert.equal(user.matchId, recent.match);
}));

test('planner LIVE work leaves a reserve of the daily cap for user opens and results', () => withDb(async (db) => {
  await db.exec(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,provider_remaining)
    select 'goal_api','match-detail','test','SUCCEEDED',50000 from generate_series(1,770)`);
  const live = await seed(db, { status: 'LIVE', minutes: -30 });
  const opened = await seed(db, { status: 'LIVE', minutes: -50 });
  assert.deepEqual(await plan(db, 5), [], 'planner LIVE stops at the user reserve');
  await db.query("insert into futbeat_private.match_detail_requests(match_id,requested_at,expires_at,request_count,source) values($1,now(),now()+interval '10 minutes',1,'prefetch')", [live.match]);
  await db.query('select public.futbeat_request_match_detail($1)', [opened.match]);
  const r = await reserve(db);
  assert.equal(r.matchId, opened.match);
  assert.equal(r.quotaClass, 'live');
}));
