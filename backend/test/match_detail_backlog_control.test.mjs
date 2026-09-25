import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// Cost-aware, section-aware match-detail planning: admission control,
// adaptive batch by provider band, per-bucket budgets, negative cache and
// usefulness metrics. Synthetic data only; no provider calls.

let seq = 0;
async function seed(db, { status = 'VERIFIED', minutes = -480 } = {}) {
  const n = ++seq;
  const ids = { comp: `fb_comp_bc${n}`, home: `fb_team_bc${n}h`, away: `fb_team_bc${n}a`, match: `fb_match_bc${n}`, ext: `bc-${n}` };
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
  'select futbeat_private.store_match_detail($1,$2,now()-make_interval(mins=>$3),$4)', [m.match, m.ext, minutesAgo, JSON.stringify(payload)]);
const plan = (db, limit = null) => db.query('select futbeat_private.plan_match_detail_coverage($1) v', [limit]).then((r) => r.rows[0].v);
const reserve = (db) => db.query("select public.futbeat_reserve_match_detail_call('test') v").then((r) => r.rows[0].v);
const complete = (db, r) => db.query("select public.futbeat_complete_provider_call($1,'SUCCEEDED',null,200,null,'{}')", [r.reservationId]);
// Worker order: reserve -> store the provider answer -> complete.
async function serve(db, payload = { lineups, statistics: [{ type: 'Shots', home: 1, away: 0 }] }) {
  const r = await reserve(db);
  if (!r.allowed) return r;
  const ext = (await db.query("select external_id e from futbeat_private.provider_entities where canonical_id=$1", [r.matchId])).rows[0].e;
  await db.query('select futbeat_private.store_match_detail($1,$2,now(),$3)', [r.matchId, ext, JSON.stringify(payload)]);
  await complete(db, r);
  return r;
}
const due = (db, m) => db.query(`select futbeat_private.match_detail_planner_due($1,futbeat_private.match_detail_bucket(
  futbeat_private.match_detail_status($1),(select (payload->>'startTime')::timestamptz from futbeat_private.entities where id=$1))) v`,
[m.match]).then((r) => r.rows[0].v);
const setPolicy = (db, patch) => db.query(`update futbeat_private.provider_quota_policy
  set freshness=freshness||$1::jsonb where provider='goal_api'`, [JSON.stringify(patch)]);
// Latest provider-reported remaining budget (simulated; no provider call).
const remaining = (db, n) => db.query(`insert into futbeat_private.provider_call_ledger
  (provider,call_kind,trigger_source,status,provider_remaining) values('goal_api','live','test','SUCCEEDED',$1)`, [n]);
const queue = (db, m, source, minutesAgo = 0) => db.query(`insert into futbeat_private.match_detail_requests
  (match_id,requested_at,expires_at,request_count,source) values($1,now()-make_interval(mins=>$3),now()+interval '10 minutes',1,$2)`,
[m.match, source, minutesAgo]);
const metric = (db, name) => db.query(`select coalesce(sum(value),0)::int n from futbeat_private.demand_metrics where metric=$1`, [name])
  .then((r) => r.rows[0].n);
const paused = (db) => db.query('select background_paused v from futbeat_private.detail_planner_state').then((r) => r.rows[0].v);

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

test('1. an empty queue admits background work', () => withDb(async (db) => {
  await remaining(db, 900);
  const m = await seed(db, { minutes: -480 });
  assert.deepEqual(await plan(db), [m.match]);
}));

test('2/20. high water stops background admission; it resumes below low water', () => withDb(async (db) => {
  await remaining(db, 900);
  await setPolicy(db, { plannerQueueHighWater: 2, plannerQueueLowWater: 1 });
  const queued = [await seed(db), await seed(db)];
  for (const m of queued) await queue(db, m, 'recent');
  const waiting = await seed(db);
  assert.deepEqual(await plan(db), []);
  assert.equal(await paused(db), true);
  await db.query('delete from futbeat_private.match_detail_requests');
  const resumed = await plan(db, 1);
  assert.equal(await paused(db), false, 'depth fell to the low water mark');
  assert.equal(resumed.length, 1);
  assert.ok([...queued, waiting].some((m) => resumed.includes(m.match)));
}));

test('3/4/5. user, LIVE and results are admitted while background is paused', () => withDb(async (db) => {
  await remaining(db, 900);
  await setPolicy(db, { plannerQueueHighWater: 1, plannerQueueLowWater: 0 });
  await queue(db, await seed(db), 'recent');
  const live = await seed(db, { status: 'LIVE', minutes: -30 });
  const result = await seed(db, { status: 'FINISHED_PENDING_VERIFICATION', minutes: -130 });
  const planned = await plan(db);
  assert.equal(await paused(db), true);
  assert.deepEqual(planned.sort(), [live.match, result.match].sort());
  const opened = await seed(db, { minutes: -3000 });
  await db.query('select public.futbeat_request_match_detail($1)', [opened.match]);
  const classes = [];
  for (let i = 0; i < 3; i++) classes.push((await serve(db)).quotaClass);
  assert.deepEqual(classes.sort(), ['live', 'results', 'user'].sort());
}));

test('6. a complete finished match costs nothing', () => withDb(async (db) => {
  await remaining(db, 900);
  const m = await seed(db, { minutes: -480 });
  await store(db, m, { lineups, statistics: stats }, 60);
  assert.equal(await due(db, m), false);
  assert.deepEqual(await plan(db), []);
}));

test('7/8/23. NO_DATA with provenance stops retries until its recheck; no hammering', () => withDb(async (db) => {
  await remaining(db, 900);
  const noLineup = await seed(db, { minutes: -3 * 24 * 60 });
  await store(db, noLineup, { statistics: stats }, 60);
  await store(db, noLineup, { statistics: stats }, 30);
  const cov = (await db.query(`select lineup_state,lineup_no_data_reason,lineup_empty_first_at is not null first,
    lineup_recheck_at>now()+interval '20 days' long_recheck from futbeat_private.match_detail_coverage where match_id=$1`, [noLineup.match])).rows[0];
  assert.deepEqual(cov, { lineup_state: 'NO_DATA', lineup_no_data_reason: 'empty_after_spaced_fetches', first: true, long_recheck: true });
  assert.equal(await due(db, noLineup), false);
  const noStats = await seed(db, { minutes: -3 * 24 * 60 });
  await store(db, noStats, { lineups }, 60);
  await store(db, noStats, { lineups }, 30);
  assert.equal((await db.query('select statistics_state s from futbeat_private.match_detail_coverage where match_id=$1', [noStats.match])).rows[0].s, 'NO_DATA');
  assert.equal(await due(db, noStats), false);
  assert.ok(await metric(db, 'md_no_data_transitions') >= 2);
  // Recheck due: exactly one more chance.
  await db.query("update futbeat_private.match_detail_coverage set lineup_recheck_at=now()-interval '1 minute' where match_id=$1", [noLineup.match]);
  await db.query("update futbeat_private.match_detail_cache set fetched_at=now()-interval '7 hours' where match_id=$1", [noLineup.match]);
  assert.equal(await due(db, noLineup), true);
}));

test('9/10. one missing section is eligible; two missing sections are one call', () => withDb(async (db) => {
  await remaining(db, 900);
  const one = await seed(db, { minutes: -2 * 24 * 60 });
  await store(db, one, { lineups }, 7 * 60);
  assert.equal(await due(db, one), true);
  const two = await seed(db, { minutes: -480 });
  await plan(db);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.match_detail_requests where match_id=$1', [two.match])).rows[0].n, 1);
  const reservations = [];
  for (let i = 0; i < 5; i++) {
    const r = await serve(db);
    if (!r.allowed) break;
    reservations.push(r.matchId);
  }
  assert.equal(reservations.filter((id) => id === two.match).length, 1);
}));

test('11/12. recent finished outranks history; older than the history window is user-only', () => withDb(async (db) => {
  await remaining(db, 900);
  const old = await seed(db, { minutes: -10 * 24 * 60 });
  const history = await seed(db, { minutes: -4 * 24 * 60 });
  const recent = await seed(db, { minutes: -12 * 60 });
  assert.deepEqual(await plan(db, 1), [recent.match]);
  await db.query('delete from futbeat_private.match_detail_requests');
  const all = await plan(db, 5);
  assert.ok(all.includes(history.match));
  assert.ok(!all.includes(old.match));
}));

for (const [label, value, historyAllowed, recentAllowed, batch] of [
  ['13. low remaining stops background', 150, false, false, 0],
  ['14. medium remaining throttles history', 500, false, true, 2],
  ['15. high remaining permits history', 900, true, true, 4],
  ['26. unknown remaining stays conservative', null, false, true, 1],
]) {
  test(label, () => withDb(async (db) => {
    if (value != null) await remaining(db, value);
    const band = (await db.query('select futbeat_private.detail_planner_band() v')).rows[0].v;
    assert.equal(band.batch, batch);
    const history = await seed(db, { minutes: -4 * 24 * 60 });
    const recent = await seed(db, { minutes: -12 * 60 });
    const planned = await plan(db);
    assert.equal(planned.includes(history.match), historyAllowed, 'history');
    assert.equal(planned.includes(recent.match), recentAllowed && batch > 0, 'recent');
  }));
}

test('16. a user open promotes the queued planner row (one row, no parallel work)', () => withDb(async (db) => {
  await remaining(db, 900);
  const m = await seed(db, { minutes: -480 });
  await plan(db);
  await db.query('select public.futbeat_request_match_detail($1)', [m.match]);
  const rows = (await db.query('select source from futbeat_private.match_detail_requests where match_id=$1', [m.match])).rows;
  assert.deepEqual(rows, [{ source: 'user' }]);
}));

test('17. stale queued rows are dropped before planning', () => withDb(async (db) => {
  await remaining(db, 900);
  const m = await seed(db, { minutes: -480 });
  await queue(db, m, 'recent');
  await store(db, m, { lineups, statistics: stats }, 5);
  await plan(db);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.match_detail_requests')).rows[0].n, 0);
  assert.equal((await db.query("select count(*)::int n from futbeat_private.match_detail_queue_log where event='dropped'")).rows[0].n, 1);
}));

test('18. an in-flight match is neither re-queued nor reserved twice', () => withDb(async (db) => {
  await remaining(db, 900);
  const m = await seed(db, { minutes: -480 });
  await plan(db);
  const r = await reserve(db);
  assert.equal(r.matchId, m.match);
  await db.query('delete from futbeat_private.match_detail_requests');
  assert.deepEqual(await plan(db), []);
  assert.equal((await reserve(db)).allowed, false);
}));

test('19. the background batch shrinks with the backlog', () => withDb(async (db) => {
  await remaining(db, 900);
  await setPolicy(db, { plannerQueueHighWater: 6, plannerQueueLowWater: 1 });
  for (let i = 0; i < 4; i++) await queue(db, await seed(db), 'recent');
  for (let i = 0; i < 5; i++) await seed(db);
  assert.equal((await plan(db)).length, 2, 'min(batch 4, high water 6 - depth 4)');
}));

test('21/22. useful coverage counts only real gains; empty answers are counted', () => withDb(async (db) => {
  const m = await seed(db, { minutes: -480 });
  await store(db, m, { lineups }, 30);
  await store(db, m, { lineups }, 20);
  await store(db, m, { lineups, statistics: stats }, 10);
  assert.equal(await metric(db, 'md_useful_unattributed'), 2);
  assert.equal(await metric(db, 'md_empty_unattributed'), 1);
  assert.equal(await metric(db, 'md_lineup_gained'), 1);
  assert.equal(await metric(db, 'md_statistics_gained'), 1);
}));

test('23b. per-match daily bound on background fetches', () => withDb(async (db) => {
  await remaining(db, 900);
  const m = await seed(db, { minutes: -480 });
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,metadata)
    select 'goal_api','match-detail','test','SUCCEEDED',jsonb_build_object('matchId',$1::text,'source','recent')
    from generate_series(1,4)`, [m.match]);
  assert.equal(await due(db, m), false);
}));

test('24. no starvation: user, LIVE and results beat an aged background backlog', () => withDb(async (db) => {
  await remaining(db, 900);
  for (let i = 0; i < 5; i++) await queue(db, await seed(db, { minutes: -4 * 24 * 60 }), 'bootstrap', 120);
  const live = await seed(db, { status: 'LIVE', minutes: -30 });
  const result = await seed(db, { status: 'FINISHED_PENDING_VERIFICATION', minutes: -130 });
  await queue(db, live, 'prefetch');
  await queue(db, result, 'recent');
  const opened = await seed(db, { minutes: -3000 });
  await db.query('select public.futbeat_request_match_detail($1)', [opened.match]);
  const first = [];
  for (let i = 0; i < 3; i++) first.push((await serve(db)).matchId);
  assert.deepEqual(first.sort(), [live.match, result.match, opened.match].sort());
  const next = await reserve(db);
  assert.equal(next.allowed, true, 'background still advances afterwards');
}));

test('25. the daily cap is preserved for everyone', () => withDb(async (db) => {
  await remaining(db, 5000);
  await db.exec(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status)
    select 'goal_api','match-detail','test','SUCCEEDED' from generate_series(1,900)`);
  const m = await seed(db, { minutes: -480 });
  await db.query('select public.futbeat_request_match_detail($1)', [m.match]);
  assert.equal((await reserve(db)).reason, 'kind_daily_cap');
}));

test('planner pacing: the worker entry plans at most once per interval', () => withDb(async (db) => {
  await remaining(db, 900);
  await seed(db, { minutes: -480 });
  await seed(db, { minutes: -490 });
  const first = (await db.query('select futbeat_private.enqueue_stale_interested_match_detail() v')).rows[0].v;
  assert.ok(first);
  await db.query('delete from futbeat_private.match_detail_requests');
  assert.equal((await db.query('select futbeat_private.enqueue_stale_interested_match_detail() v')).rows[0].v, null);
}));

test('audit answers where calls went and what the queue holds', () => withDb(async (db) => {
  await remaining(db, 900);
  const m = await seed(db, { minutes: -480 });
  await plan(db);
  await serve(db, { lineups });
  await queue(db, await seed(db, { minutes: -480 }), 'recent');
  const meta = (await db.query("select metadata from futbeat_private.provider_call_ledger where call_kind='match-detail'")).rows[0].metadata;
  assert.equal(meta.bucket, 'recent', 'completion keeps reservation attribution');
  assert.equal(meta.source, 'recent');
  const audit = (await db.query('select public.futbeat_match_detail_backlog_audit() v')).rows[0].v;
  assert.equal(audit.callsToday.total, 1);
  assert.deepEqual(audit.callsToday.byBucket, { recent: 1 });
  assert.equal(audit.queue.depth, 1);
  assert.equal(audit.queue.eligible, 1);
  assert.equal(audit.outcomesToday.metrics.md_useful_recent, 1);
  assert.equal(Number(audit.outcomesToday.usefulCoveragePerCall), 1);
  for (const role of ['anon', 'authenticated']) {
    assert.equal((await db.query("select has_function_privilege($1,'public.futbeat_match_detail_backlog_audit()','EXECUTE') ok", [role])).rows[0].ok, false);
  }
}));

test('low budget: background work stops above the user floor; user opens are still served', () => withDb(async (db) => {
  await remaining(db, 350);
  const live = await seed(db, { status: 'LIVE', minutes: -30 });
  const result = await seed(db, { status: 'FINISHED_PENDING_VERIFICATION', minutes: -130 });
  await seed(db, { minutes: 45, status: 'SCHEDULED' });
  assert.deepEqual(await plan(db), [result.match], 'only result verification below plannerMinRemaining');
  const history = await seed(db, { minutes: -3000 });
  await db.query('select public.futbeat_request_match_detail($1)', [history.match]);
  const served = [(await serve(db)).matchId, (await serve(db)).matchId];
  assert.deepEqual(served, [result.match, history.match], 'results first, then the user open (its own slice)');
  await db.query('select public.futbeat_request_match_detail($1)', [live.match]);
  const r = await reserve(db);
  assert.equal(r.allowed, true);
  assert.equal(r.quotaClass, 'live');
}));

test('I1. an older NO_DATA row without a recheck time is never queued (no frozen queue)', () => withDb(async (db) => {
  await remaining(db, 900);
  const ms = [];
  for (let i = 0; i < 5; i++) {
    const m = await seed(db, { minutes: -4 * 24 * 60 });
    await store(db, m, { lineups }, 60 * 24);
    // State written before this migration: NO_DATA with no recheck columns.
    await db.query(`update futbeat_private.match_detail_coverage set statistics_state='NO_DATA',statistics_recheck_at=null
      where match_id=$1`, [m.match]);
    ms.push(m);
  }
  assert.equal(await due(db, ms[0]), false);
  assert.deepEqual(await plan(db), []);
  assert.equal(await paused(db), false);
}));

test('I2. LIVE attempts never block the post-match fetch nor result verification', () => withDb(async (db) => {
  await remaining(db, 900);
  const m = await seed(db, { status: 'FINISHED_PENDING_VERIFICATION', minutes: -150 });
  await store(db, m, {}, 60);
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,metadata)
    select 'goal_api','match-detail','test','SUCCEEDED',jsonb_build_object('matchId',$1::text,'source','prefetch','bucket','live')
    from generate_series(1,6)`, [m.match]);
  assert.equal(await due(db, m), true, 'results keep their own cadence');
  await db.query(`update futbeat_private.entities set payload=payload||'{"status":"VERIFIED"}' where id=$1`, [m.match]);
  await db.query(`update futbeat_private.match_detail_cache set fetched_at=now()-interval '140 minutes' where match_id=$1`, [m.match]);
  assert.equal(await due(db, m), true, 'post-match fetch is a separate phase');
}));

test('I3. settled matches never crowd the candidate limit', () => withDb(async (db) => {
  await remaining(db, 900);
  for (let i = 0; i < 405; i++) {
    const m = await seed(db, { minutes: -300 - (i % 60) });
    await store(db, m, { lineups, statistics: stats }, 0);
  }
  const upcoming = await seed(db, { status: 'SCHEDULED', minutes: 600 });
  assert.deepEqual(await plan(db), [upcoming.match]);
}));

test('M6. a completion without matchId never erases the reservation attribution', () => withDb(async (db) => {
  await remaining(db, 900);
  const m = await seed(db, { minutes: -480 });
  await plan(db);
  const r = await reserve(db);
  await db.query(`select public.futbeat_complete_provider_call($1,'FAILED',null,500,'X',jsonb_build_object('matchId',null))`, [r.reservationId]);
  const meta = (await db.query('select metadata from futbeat_private.provider_call_ledger where id=$1', [r.reservationId])).rows[0].metadata;
  assert.equal(meta.matchId, m.match);
  assert.equal(meta.bucket, 'recent');
}));

test('C-1. pending-verification finals (GOAL never verifies) are not refetched every 30 minutes forever', () => withDb(async (db) => {
  await remaining(db, 900);
  // Old final: finished rules (complete -> 0 calls), not the results cadence.
  const old = await seed(db, { status: 'FINISHED_PENDING_VERIFICATION', minutes: -2 * 24 * 60 });
  await store(db, old, { lineups, statistics: stats }, 60 * 30);
  assert.equal((await db.query("select futbeat_private.match_detail_bucket('FINISHED_PENDING_VERIFICATION',now()-interval '2 days') b")).rows[0].b, 'history');
  assert.equal(await due(db, old), false);
  // Fresh final: results window, capped at plannerMaxResultFetches.
  const fresh = await seed(db, { status: 'FINISHED_PENDING_VERIFICATION', minutes: -130 });
  await store(db, fresh, { lineups, statistics: stats }, 40);
  assert.equal(await due(db, fresh), true);
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,metadata)
    select 'goal_api','match-detail','test','SUCCEEDED',jsonb_build_object('matchId',$1::text,'source','recent','bucket','results')
    from generate_series(1,2)`, [fresh.match]);
  assert.equal(await due(db, fresh), false, 'results phase capped');
  // Planner FPV rows outside the window are background work (shares apply).
  const mid = await seed(db, { status: 'FINISHED_PENDING_VERIFICATION', minutes: -12 * 60 });
  await plan(db);
  const r = await reserve(db);
  assert.equal(r.matchId, mid.match);
  assert.equal(r.quotaClass, 'coverage');
  // Boundary: the results window ends resultsWindowHours after kickoff.
  const bucketAt = async (h) => (await db.query(
    "select futbeat_private.match_detail_bucket('FINISHED_PENDING_VERIFICATION',now()-make_interval(mins=>$1::int)) b", [h])).rows[0].b;
  assert.equal(await bucketAt(4 * 60 - 1), 'results');
  assert.equal(await bucketAt(4 * 60 + 1), 'recent_hot');
  // A LIVE match stays LIVE; a user open of an old final keeps its user path.
  assert.equal((await db.query("select futbeat_private.match_detail_bucket('LIVE',now()-interval '30 minutes') b")).rows[0].b, 'live');
  await db.query('select public.futbeat_request_match_detail($1)', [old.match]);
  assert.equal((await db.query('select source from futbeat_private.match_detail_requests where match_id=$1', [old.match])).rows[0].source, 'user');
}));
