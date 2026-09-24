import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// Standings identity is exactly (competition, season). Everything synthetic:
// no real competition, country, team or season is special-cased.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

// Internally consistent rows: points = 3W + D, played = W + D + L.
const rows = (prefix, points = [9, 6]) => points.map((pts, i) => ({
  overallLeaguePosition: String(i + 1), overallLeaguePlayed: String(Math.floor(pts / 3) + (pts % 3) + 1),
  overallLeagueW: String(Math.floor(pts / 3)), overallLeagueD: String(pts % 3), overallLeagueL: '1',
  overallLeagueGF: '5', overallLeagueGA: '3', overallLeaguePTS: String(pts),
  team: { id: `${prefix}-team-${i}`, name: `${prefix} Team ${i}`, country: { name: 'Nowhere' } },
}));

let seq = 0;
async function competition(db, { name = 'Shared Name League', season = '2026/2027', mapped = true } = {}) {
  const n = ++seq;
  const id = `fb_comp_st${n}`, ext = `st-league-${n}`;
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)",
    [id, JSON.stringify({ id, name, country: 'Nowhere', season })]);
  if (mapped) await db.query("insert into futbeat_private.provider_entities values('goal_api','competition',$1,$2)", [ext, id]);
  return { id, ext, n };
}
async function match(db, comp, { season, status = 'SCHEDULED', offsetHours = 24 } = {}) {
  const id = `fb_match_st${++seq}`;
  const teams = [`fb_team_st${seq}a`, `fb_team_st${seq}b`];
  for (const t of teams) await db.query("insert into futbeat_private.entities values($1,'team',$2)", [t, JSON.stringify({ id: t, name: t })]);
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [id, JSON.stringify({
    id, competitionId: comp.id, homeTeamId: teams[0], awayTeamId: teams[1], season, status,
    startTime: new Date(Date.now() + offsetHours * 3600e3).toISOString(), events: [], statistics: [] })]);
  return id;
}
const storeTable = (db, comp, season, prefix, points, at = new Date().toISOString()) => db.query(
  'select public.futbeat_store_goal_standings($1,$2,$3,$4,$5) v',
  [comp.id, comp.ext, at, season, JSON.stringify(rows(prefix, points))]);
const context = (db, m) => db.query('select public.futbeat_read_match_context($1) v', [m]).then((r) => r.rows[0].v);
const request = (db, m) => db.query('select public.futbeat_request_match_standings($1) v', [m]).then((r) => r.rows[0].v);
const points = (ctx) => ctx.standings.map((t) => t.rows.map((r) => r.points));

test('8/9/15. exact competition + season; two seasons coexist; never another season', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2025/2026' });
  await storeTable(db, comp, '2025/2026', 'old', [30, 20], '2026-05-30T00:00:00Z');
  await db.query("update futbeat_private.entities set payload=payload||'{\"season\":\"2026/2027\"}' where id=$1", [comp.id]);
  await storeTable(db, comp, '2026/2027', 'new', [3, 0]);
  const oldMatch = await match(db, comp, { season: '2025-26', status: 'VERIFIED', offsetHours: -2000 });
  const newMatch = await match(db, comp, { season: '2026/27' });
  assert.deepEqual(points(await context(db, oldMatch)), [[30, 20]]);
  assert.deepEqual(points(await context(db, newMatch)), [[3, 0]]);
  // A season nobody stored -> no table at all (not the latest one).
  const other = await match(db, comp, { season: '2024/2025', status: 'VERIFIED', offsetHours: -9000 });
  const ctx = await context(db, other);
  assert.deepEqual(ctx.standings, []);
  assert.equal(ctx.coverage.standings, 'missing');
  // No season on the match -> never guessed.
  assert.deepEqual((await context(db, await match(db, comp, { season: undefined }))).standings, []);
  // The latest-per-competition cache (profiles) still holds the newest table.
  assert.equal((await db.query('select season from futbeat_private.standings_cache where competition_id=$1', [comp.id])).rows[0].season, '2026/2027');
}));

test('10. two competitions with the same name never share standings', () => withDb(async (db) => {
  const a = await competition(db, { name: 'Twin League' });
  const b = await competition(db, { name: 'Twin League' });
  await storeTable(db, a, '2026/2027', 'a', [12, 9]);
  const mb = await match(db, b, { season: '2026/2027' });
  const ctx = await context(db, mb);
  assert.deepEqual(ctx.standings, []);
  await storeTable(db, b, '2026/2027', 'b', [7, 1]);
  assert.deepEqual(points(await context(db, mb)), [[7, 1]]);
  assert.deepEqual(points(await context(db, await match(db, a, { season: '2026/2027' }))), [[12, 9]]);
}));

test('11. fresh standings: cache hit, 0 provider calls, nothing pending', () => withDb(async (db) => {
  const comp = await competition(db);
  await storeTable(db, comp, '2026/2027', 'f', [6, 3]);
  const m = await match(db, comp, { season: '2026/2027' });
  for (let i = 0; i < 3; i++) {
    const st = await request(db, m);
    assert.deepEqual([st.standings, st.standingsPending, st.standingsStale], ['available', false, false]);
  }
  assert.equal((await db.query('select count(*)::int n from futbeat_private.standings_demands')).rows[0].n, 0);
  const res = (await db.query("select public.futbeat_reserve_standings_demand_call('test') v")).rows[0].v;
  assert.equal(res.allowed, false);
}));

test('12. stale standings: cached table shown while one revalidation is queued', () => withDb(async (db) => {
  const comp = await competition(db);
  await storeTable(db, comp, '2026/2027', 's', [6, 3], new Date(Date.now() - 8 * 3600e3).toISOString());
  const m = await match(db, comp, { season: '2026/2027' });
  const st = await request(db, m);
  assert.deepEqual([st.standings, st.standingsStale, st.standingsPending], ['available', true, true]);
  const ctx = await context(db, m);
  assert.deepEqual(points(ctx), [[6, 3]]);
  assert.equal(ctx.coverage.standingsPending, true);
}));

test('13/14. missing standings: one demand for many users; worker reserve serves the exact identity', () => withDb(async (db) => {
  const comp = await competition(db);
  const matches = [];
  for (let i = 0; i < 4; i++) matches.push(await match(db, comp, { season: '2026/2027' }));
  const results = [];
  for (let i = 0; i < 100; i++) results.push(await request(db, matches[i % 4]));
  assert.ok(results.every((r) => r.standings === 'pending' && r.standingsPending));
  assert.deepEqual((await db.query('select season_key,request_count::int n from futbeat_private.standings_demands')).rows,
    [{ season_key: '2026-2027', n: 100 }]);
  const reservations = [];
  for (let i = 0; i < 20; i++) reservations.push((await db.query("select public.futbeat_reserve_standings_demand_call('test') v")).rows[0].v);
  const allowed = reservations.filter((r) => r.allowed);
  assert.equal(allowed.length, 1);
  assert.deepEqual([allowed[0].competitionId, allowed[0].seasonKey, allowed[0].source, allowed[0].class],
    [comp.id, '2026-2027', 'user', 'user_high']);
  // Worker stores and completes: the demand is answered, the table appears.
  await storeTable(db, comp, '2026/2027', 'w', [4, 1]);
  assert.equal((await db.query('select public.futbeat_complete_standings_call($1,true,200,500) v', [allowed[0].reservationId])).rows[0].v.status, 'AVAILABLE');
  const ctx = await context(db, matches[0]);
  assert.deepEqual([points(ctx), ctx.coverage.standings, ctx.coverage.standingsPending], [[[4, 1]], 'available', false]);
}));

test('provider answers another season or nothing: negative cache, no loop', () => withDb(async (db) => {
  const comp = await competition(db);
  const m = await match(db, comp, { season: '2026/2027' });
  await request(db, m);
  const res = (await db.query("select public.futbeat_reserve_standings_demand_call('test') v")).rows[0].v;
  assert.equal((await db.query('select public.futbeat_complete_standings_call($1,true,200,null) v', [res.reservationId])).rows[0].v.status, 'NO_DATA');
  const st = await request(db, m);
  assert.deepEqual([st.standings, st.standingsPending], ['unavailable', false]);
  assert.equal((await db.query("select public.futbeat_reserve_standings_demand_call('test') v")).rows[0].v.allowed, false);
}));

test('past season without archive is never fetched as if it were current', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2026/2027' });
  const m = await match(db, comp, { season: '2024/2025', status: 'VERIFIED', offsetHours: -9000 });
  const st = await request(db, m);
  assert.deepEqual([st.standings, st.standingsPending], ['missing', false]);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.standings_demands')).rows[0].n, 0);
}));

test('quota: standings demand is user_high; coverage refresh stops earlier; LIVE keeps its floor', () => withDb(async (db) => {
  const comp = await competition(db);
  const m = await match(db, comp, { season: '2026/2027' });
  await request(db, m);
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,provider_remaining)
    values('goal_api','live-goal','test',now(),now(),'SUCCEEDED',200)`);
  assert.equal((await db.query("select public.futbeat_reserve_standings_demand_call('test') v")).rows[0].v.allowed, true);
  const coverage = (await db.query("select futbeat_private.quota_decision('goal_api','standings','coverage') v")).rows[0].v;
  assert.equal(coverage.allowed, false);
  await db.query("update futbeat_private.provider_call_ledger set provider_remaining=120");
  assert.equal((await db.query("select futbeat_private.quota_decision('goal_api','standings','user_high') v")).rows[0].v.allowed, false);
  assert.equal((await db.query("select futbeat_private.quota_decision('goal_api','match-detail','live') v")).rows[0].v.allowed, true);
}));

test('season normalization is format-only (no guessing between different seasons)', () => withDb(async (db) => {
  const norm = async (v) => (await db.query('select futbeat_private.normalize_season($1) v', [v])).rows[0].v;
  assert.equal(await norm('2026/2027'), '2026-2027');
  assert.equal(await norm('2026-27'), '2026-2027');
  assert.equal(await norm(' 2026 / 27 '), '2026-2027');
  assert.equal(await norm('1999/00'), '1999-2000');
  assert.equal(await norm('2026'), '2026');
  assert.notEqual(await norm('2026'), await norm('2026/2027'));
  assert.equal(await norm(''), '');
}));

test('security: standings demand/reserve/complete are service-only; helpers private', () => withDb(async (db) => {
  const can = async (role, fn) => (await db.query("select has_function_privilege($1,$2,'EXECUTE') ok", [role, fn])).rows[0].ok;
  for (const role of ['anon', 'authenticated']) {
    for (const fn of ['public.futbeat_request_match_standings(text)', 'public.futbeat_reserve_standings_demand_call(text)',
      'public.futbeat_complete_standings_call(bigint,boolean,integer,integer)', 'public.futbeat_read_match_context(text)']) {
      assert.equal(await can(role, fn), false, `${role} ${fn}`);
    }
  }
  for (const role of ['anon', 'authenticated', 'service_role']) {
    assert.equal(await can(role, 'futbeat_private.match_standings_state(text)'), false);
  }
  assert.equal(await can('service_role', 'public.futbeat_read_match_context(text)'), true);
}));

test('worker demand lane: GOAL table for the exact season lands in Match Center; empty answer is negative-cached', async () => {
  const { worker, goalOk } = await import('./helpers/worker_harness.mjs');
  await withDb(async (db) => {
    const comp = await competition(db);
    const m = await match(db, comp, { season: '2026/2027' });
    assert.equal((await request(db, m)).standings, 'pending');
    const goal = worker(db, (url) => {
      assert.equal(url.pathname, `/v1/standings/${comp.ext}`);
      return goalOk(rows('wk', [10, 4]).map((row) => ({ ...row, season: '2026/2027' })));
    });
    const run = await goal.run();
    assert.deepEqual([run.standings.status, run.standings.demand], ['ok', 'AVAILABLE']);
    const ctx = await context(db, m);
    assert.deepEqual([points(ctx), ctx.coverage.standings, ctx.coverage.standingsPending], [[[10, 4]], 'available', false]);
    await goal.run();
    assert.equal(goal.goalCalls().length, 1, 'fresh table: no second call');

    const empty = await competition(db);
    const m2 = await match(db, empty, { season: '2026/2027' });
    await request(db, m2);
    const goal2 = worker(db, () => goalOk([]));
    assert.equal((await goal2.run()).standings.demand, 'NO_DATA');
    assert.equal((await request(db, m2)).standings, 'unavailable');
    await goal2.run();
    assert.equal(goal2.goalCalls().length, 1, 'negative cache: no retry loop');
  });
});

test('review: an unlabeled table at a season rollover is never filed as the new season', () => withDb(async (db) => {
  // Competition already says the new season, no new-season match has started:
  // an unlabeled table can only be last season's final table.
  const comp = await competition(db, { season: '2026/2027' });
  const m = await match(db, comp, { season: '2026/2027', offsetHours: 48 });
  await storeTable(db, comp, '', 'prev', [50, 40]);
  assert.deepEqual((await context(db, m)).standings, []);
  // Once the new season has started, an unlabeled table is the current one.
  await match(db, comp, { season: '2026/2027', status: 'VERIFIED', offsetHours: -24 });
  await storeTable(db, comp, '', 'cur', [3, 0]);
  assert.deepEqual(points(await context(db, m)), [[3, 0]]);
}));

test('review: match without season or competition never throws on open', () => withDb(async (db) => {
  const comp = await competition(db);
  const m = await match(db, comp, { season: undefined });
  const st = await request(db, m);
  assert.deepEqual([st.standings, st.standingsPending], ['missing', false]);
}));

test('review: the legacy workflow reservation never serves user demands (coverage only)', () => withDb(async (db) => {
  const comp = await competition(db);
  const m = await match(db, comp, { season: '2026/2027' });
  await request(db, m);
  const plan = (await db.query("select public.futbeat_reserve_goal_standings_call('github-actions') v")).rows[0].v;
  assert.notEqual(plan.source, 'user');
  const demand = (await db.query('select status,lease_until from futbeat_private.standings_demands')).rows[0];
  assert.deepEqual(demand, { status: 'QUEUED', lease_until: null });
  assert.equal((await db.query("select public.futbeat_reserve_standings_demand_call('t') v")).rows[0].v.source, 'user');
}));

test('review: a season mismatch is visible (metric + reason), not silently empty', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2026' });
  const m = await match(db, comp, { season: '2026' });
  await request(db, m);
  const res = (await db.query("select public.futbeat_reserve_standings_demand_call('t') v")).rows[0].v;
  await storeTable(db, comp, '2026/2027', 'x', [3, 0]);
  assert.equal((await db.query('select public.futbeat_complete_standings_call($1,true,200,null) v', [res.reservationId])).rows[0].v.status, 'NO_DATA');
  const row = (await db.query('select last_error from futbeat_private.standings_demands')).rows[0];
  assert.match(row.last_error, /2026-2027/);
  assert.equal((await db.query("select coalesce(sum(value),0)::int n from futbeat_private.demand_metrics where metric='standings_season_mismatch'")).rows[0].n, 1);
}));
