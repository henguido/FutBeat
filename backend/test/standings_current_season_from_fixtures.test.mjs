import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { worker, goalOk } from './helpers/worker_harness.mjs';

// BE-205: the current season of a competition is the most advanced season
// among its entity field and its recently started fixtures, so a stale entity
// season can no longer make a current demand "no longer current". Fixtures
// mirror the production cases (Serie A: entity 2025/2026, fixtures 2026/2027;
// Liga MX: demand closed while stale, entity current again) with synthetic
// ids/names: no real competition is special-cased. No network.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

const rows = (prefix, points, season) => points.map((pts, i) => ({
  overallLeaguePosition: String(i + 1), overallLeaguePlayed: '3',
  overallLeagueW: String(Math.floor(pts / 3)), overallLeagueD: String(pts % 3), overallLeagueL: '0',
  overallLeagueGF: '5', overallLeagueGA: '3', overallLeaguePTS: String(pts),
  team: { id: `${prefix}-team-${i}`, name: `${prefix} Team ${i}`, country: { name: 'Nowhere' } },
  ...(season ? { season } : {}),
}));

let seq = 0;
async function competition(db, { season, mapped = true } = {}) {
  const n = ++seq;
  const id = `fb_comp_cs${n}`, ext = `cs-league-${n}`;
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)",
    [id, JSON.stringify({ id, name: `Synthetic League ${n}`, country: 'Nowhere', season })]);
  if (mapped) await db.query("insert into futbeat_private.provider_entities values('goal_api','competition',$1,$2)", [ext, id]);
  return { id, ext };
}
async function match(db, comp, { season, status = 'SCHEDULED', offsetHours = 24 }) {
  const id = `fb_match_cs${++seq}`;
  const teams = [`fb_team_cs${seq}a`, `fb_team_cs${seq}b`];
  for (const t of teams) await db.query("insert into futbeat_private.entities values($1,'team',$2)", [t, JSON.stringify({ id: t, name: t })]);
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [id, JSON.stringify({
    id, competitionId: comp.id, homeTeamId: teams[0], awayTeamId: teams[1], season, status,
    startTime: new Date(Date.now() + offsetHours * 3600e3).toISOString(), events: [], statistics: [] })]);
  return id;
}
const played = async (db, comp, season, offsets) => {
  for (const h of offsets) await match(db, comp, { season, status: 'VERIFIED', offsetHours: h });
};
const seasonKey = (db, comp) => db.query('select futbeat_private.competition_season_key($1) v', [comp.id]).then((r) => r.rows[0].v);
const request = (db, m) => db.query('select public.futbeat_request_match_standings($1) v', [m]).then((r) => r.rows[0].v);
const context = (db, m) => db.query('select public.futbeat_read_match_context($1) v', [m]).then((r) => r.rows[0].v);
const reserve = (db) => db.query("select public.futbeat_reserve_standings_demand_call('test') v").then((r) => r.rows[0].v);
const demand = (db, comp, key) => db.query(`select status,last_error,next_retry_at,request_count::int n
  from futbeat_private.standings_demands where competition_id=$1 and season_key=$2`, [comp.id, key]).then((r) => r.rows[0]);
const standingsCalls = (db) => db.query("select count(*)::int n from futbeat_private.provider_call_ledger where call_kind='standings'").then((r) => r.rows[0].n);
const points = (ctx) => ctx.standings.map((t) => t.rows.map((r) => r.points));
// The exact state production showed: closed by reconcile, TTL still running.
const closedByStaleSeason = (db, comp, key, requests = 11) => db.query(`insert into futbeat_private.standings_demands(
  competition_id,season_key,external_league_id,status,request_count,queued_at,last_error,next_retry_at)
  values($1,$2,$3,'NO_DATA',$4,now()-interval '1 day','season is no longer current',now()+interval '2 days')`,
[comp.id, key, comp.ext, requests]);

test('Serie A shape: stale entity 2025/2026, fixtures 2026/2027 -> current 2026-2027, closed demand reopens, table shown', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2025/2026' });
  await played(db, comp, '2025/2026', [-4000, -3900, -3800]); // last season, within 180 days
  await played(db, comp, '2026/2027', [-1500, -700, -200, -30]);
  const m = await match(db, comp, { season: '2026/2027', offsetHours: 2 });
  assert.equal(await seasonKey(db, comp), '2026-2027');
  await closedByStaleSeason(db, comp, '2026-2027');

  // Opening the match requeues it before the stale TTL (no 'unavailable').
  const st = await request(db, m);
  assert.deepEqual([st.standings, st.standingsPending], ['pending', true]);
  const d = await demand(db, comp, '2026-2027');
  assert.deepEqual([d.status, d.next_retry_at, d.n], ['QUEUED', null, 12]);

  // The worker fetches the exact season (GOAL rows without a season label are
  // archived under the derived current season, a fixture of it has started).
  const w = worker(db, () => goalOk(rows('sa', [9, 6])));
  assert.equal((await w.run()).standings.demand, 'AVAILABLE');
  const ctx = await context(db, m);
  assert.deepEqual(points(ctx), [[9, 6]]);
  assert.equal(ctx.coverage.standings, 'available');
  assert.equal((await demand(db, comp, '2026-2027')).status, 'AVAILABLE');
  // The previous season's matches never get the new table.
  const old = await match(db, comp, { season: '2025/2026', status: 'VERIFIED', offsetHours: -3700 });
  assert.deepEqual((await context(db, old)).standings, []);
}));

test('reconcile reopens a demand closed by a stale season without anyone reopening the match', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2025/2026' });
  await played(db, comp, '2026/2027', [-300, -50]);
  await closedByStaleSeason(db, comp, '2026-2027');
  const r = await reserve(db);
  assert.equal(r.reconciled.reopened, 1);
  assert.deepEqual([r.allowed, r.seasonKey, r.competitionId], [true, '2026-2027', comp.id]);
  // Idempotent: nothing left to reopen.
  await db.query("update futbeat_private.provider_call_ledger set status='SUCCEEDED',completed_at=now() where call_kind='standings'");
  assert.equal((await reserve(db)).reconciled.reopened, 0);
}));

test('Liga MX shape: demand closed while the entity was stale, entity current again -> reopened and served', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2026/2027' });
  await played(db, comp, '2025/2026', [-3000]);
  await played(db, comp, '2026/2027', [-900, -100]);
  const m = await match(db, comp, { season: '2026/2027', offsetHours: 30 });
  await closedByStaleSeason(db, comp, '2026-2027', 4);
  assert.equal((await request(db, m)).standings, 'pending');
  const w = worker(db, () => goalOk(rows('mx', [7, 4], '2026/2027')));
  assert.equal((await w.run()).standings.demand, 'AVAILABLE');
  assert.deepEqual(points(await context(db, m)), [[7, 4]]);
}));

test('Apertura/Clausura labels: the phase being played is current, phases never share a table', () => withDb(async (db) => {
  const comp = await competition(db, { season: 'Clausura 2026' });
  await played(db, comp, 'Clausura 2026', [-3500, -3400]);
  await played(db, comp, 'Apertura 2026', [-500, -20]);
  assert.equal(await seasonKey(db, comp), 'apertura 2026');
  const clausura = await match(db, comp, { season: 'Clausura 2026', status: 'VERIFIED', offsetHours: -3300 });
  const apertura = await match(db, comp, { season: 'Apertura 2026', offsetHours: 20 });
  await db.query(`insert into futbeat_private.standings_snapshots(competition_id,season_key,season,table_payload,fetched_at)
    values($1,'clausura 2026','Clausura 2026','{"rows":[{"teamId":"x","points":30}]}',now())`, [comp.id]);
  assert.deepEqual((await context(db, apertura)).standings, []);
  assert.equal((await request(db, apertura)).standings, 'pending');
  // The finished phase is not fetchable (no demand, no call).
  const st = await request(db, clausura);
  assert.equal(st.standings, 'available');
  assert.equal(await demand(db, comp, 'clausura 2026'), undefined);
}));

test('calendar-year seasons: stale entity 2025, fixtures 2026 -> 2026', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2025' });
  await played(db, comp, '2025', [-3000]);
  await played(db, comp, '2026', [-400, -60]);
  assert.equal(await seasonKey(db, comp), '2026');
}));

test('entity ahead of its fixtures (new season announced, opener not played) still wins', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2026/2027' });
  await played(db, comp, '2025/2026', [-1200, -1000]);
  await match(db, comp, { season: '2026/2027', offsetHours: 100 });
  assert.equal(await seasonKey(db, comp), '2026-2027');
  // No fixtures at all: the entity field, as before.
  assert.equal(await seasonKey(db, await competition(db, { season: '2024/2025' })), '2024-2025');
}));

test('a replayed fixture of an older season never rolls the current season back', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2026/2027' });
  await played(db, comp, '2026/2027', [-500, -100]);
  await played(db, comp, '2025/2026', [-1]); // postponed fixture played late
  assert.equal(await seasonKey(db, comp), '2026-2027');
}));

test('regression: a truly finished season is still closed and never reopened', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2026/2027' });
  await played(db, comp, '2025/2026', [-3000, -2900]);
  await played(db, comp, '2026/2027', [-600, -40]);
  const old = await match(db, comp, { season: '2025/2026', status: 'VERIFIED', offsetHours: -2800 });
  await db.query(`insert into futbeat_private.standings_demands(competition_id,season_key,external_league_id,queued_at)
    values($1,'2025-2026',$2,now()-interval '5 days')`, [comp.id, comp.ext]);
  const r = await reserve(db);
  assert.deepEqual([r.allowed, r.reconciled.closed, r.reconciled.reopened], [false, 1, 0]);
  const d = await demand(db, comp, '2025-2026');
  assert.deepEqual([d.status, d.last_error], ['NO_DATA', 'season is no longer current']);
  // Not reopened by later reconciles nor by opening its match.
  assert.equal((await reserve(db)).reconciled.reopened, 0);
  const st = await request(db, old);
  assert.deepEqual([st.standings, st.standingsPending], ['unavailable', false]);
  assert.equal((await demand(db, comp, '2025-2026')).status, 'NO_DATA');
  assert.equal(await standingsCalls(db), 0);
}));

test('a season with current fixtures is never closed as "no longer current"', () => withDb(async (db) => {
  // Opener in two days, entity still on the old season, no new fixture started.
  const comp = await competition(db, { season: '2025/2026' });
  await played(db, comp, '2025/2026', [-1500]);
  await match(db, comp, { season: '2026/2027', offsetHours: 48 });
  assert.equal(await seasonKey(db, comp), '2025-2026');
  await db.query(`insert into futbeat_private.standings_demands(competition_id,season_key,external_league_id,queued_at)
    values($1,'2026-2027',$2,now()-interval '1 hour')`, [comp.id, comp.ext]);
  const r = await reserve(db);
  assert.equal(r.reconciled.closed, 0);
  assert.equal((await demand(db, comp, '2026-2027')).status, 'QUEUED');
  assert.equal(await standingsCalls(db), 0);
  // Once the opener has kicked off the season is current and the demand is served.
  await played(db, comp, '2026/2027', [-1]);
  const served = await reserve(db);
  assert.deepEqual([served.allowed, served.seasonKey], [true, '2026-2027']);
}));

test('a fixture labelled with a season that starts after it was played never becomes current', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2026' });
  await played(db, comp, '2026', [-2000]);
  const year = new Date().getUTCFullYear();
  await played(db, comp, String(year + 4), [-100]);
  assert.equal(await seasonKey(db, comp), '2026');
}));

// Night 230: gaps around the reopened demand. A reopen happens at most once
// per closure, every later outcome carries another last_error, so quota stays
// bounded. standingsCalls counts the ledger, goalCalls the provider.
const complete = (db, id, ok, status) => db.query('select public.futbeat_complete_standings_call($1,$2,$3,null) v', [id, ok, status]).then((r) => r.rows[0].v);
const setRemaining = (db, value) => db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,provider_remaining)
  values('goal_api','global-ingest','test',now(),now(),'SUCCEEDED',$1)`, [value]);
const notFound = () => new Response(JSON.stringify({ success: false, error: { code: 'STANDINGS_NOT_FOUND' } }),
  { status: 404, headers: { 'x-ratelimit-remaining': '700', 'content-type': 'application/json' } });
const staleCup = async (db) => {
  const comp = await competition(db, { season: '2025/2026' });
  await played(db, comp, '2026/2027', [-300, -50]);
  const m = await match(db, comp, { season: '2026/2027', offsetHours: 30 });
  await closedByStaleSeason(db, comp, '2026-2027');
  return { comp, m };
};

test('cup without a table: a reopened demand answered 404 stays empty, no error, one call, no second reopen', () => withDb(async (db) => {
  const { comp, m } = await staleCup(db);
  const w = worker(db, notFound);
  await w.run();
  await w.run();
  await w.run();
  assert.equal(w.goalCalls().length, 1);
  const d = await demand(db, comp, '2026-2027');
  assert.equal(d.status, 'NO_DATA');
  assert.notEqual(d.last_error, 'season is no longer current');
  assert.equal((await reserve(db)).reconciled.reopened, 0);
  assert.deepEqual([(await request(db, m)).standings, (await request(db, m)).standingsPending], ['unavailable', false]);
  const ctx = await context(db, m);
  assert.deepEqual([ctx.standings, ctx.coverage.standings], [[], 'unavailable']);
}));

test('a provider table of another season after a reopen: negative cache, never filed under the demanded season', () => withDb(async (db) => {
  const { comp, m } = await staleCup(db);
  const w = worker(db, () => goalOk(rows('old', [9, 6], '2025/2026')));
  assert.equal((await w.run()).standings.demand, 'NO_DATA');
  await w.run();
  assert.equal(w.goalCalls().length, 1);
  assert.deepEqual((await context(db, m)).standings, []);
  assert.equal((await reserve(db)).reconciled.reopened, 0);
}));

test('transient failures after a reopen honour standingsMaxAutoRetries and are not reopened', () => withDb(async (db) => {
  await db.query(`update futbeat_private.provider_quota_policy
    set freshness=freshness||'{"standingsMaxAutoRetries":2}' where provider='goal_api'`);
  const { comp } = await staleCup(db);
  for (const expected of ['QUEUED', 'FETCH_FAILED']) {
    const r = await reserve(db);
    assert.equal(r.allowed, true);
    assert.equal((await complete(db, r.reservationId, false, 500)).status, expected);
    await db.query("update futbeat_private.standings_demands set next_retry_at=now()-interval '1 second' where status='QUEUED'");
  }
  const after = await reserve(db);
  assert.deepEqual([after.allowed, after.reconciled.reopened], [false, 0]);
  assert.equal((await demand(db, comp, '2026-2027')).status, 'FETCH_FAILED');
  assert.equal(await standingsCalls(db), 2);
}));

test('a reopen spends no quota by itself: without quota the demand waits and nothing is reserved', () => withDb(async (db) => {
  const { comp } = await staleCup(db);
  await setRemaining(db, 0);
  const r = await reserve(db);
  assert.deepEqual([r.allowed, r.reconciled.reopened], [false, 1]);
  assert.equal(await standingsCalls(db), 0);
  assert.equal((await demand(db, comp, '2026-2027')).status, 'QUEUED');
}));

test('season roll-over: the old table stays with its season, the new one needs its own table', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2025/2026' });
  await played(db, comp, '2025/2026', [-2000, -1900]);
  const old = await match(db, comp, { season: '2025/2026', status: 'VERIFIED', offsetHours: -1800 });
  const next = await match(db, comp, { season: '2026/2027', offsetHours: 48 });
  // Opener not played: the new season is not fetchable yet.
  assert.deepEqual([await seasonKey(db, comp), (await request(db, next)).standings], ['2025-2026', 'missing']);
  await db.query(`insert into futbeat_private.standings_snapshots(competition_id,season_key,season,table_payload,fetched_at)
    values($1,'2025-2026','2025/2026','{"rows":[{"teamId":"x","points":80}]}',now())`, [comp.id]);
  await played(db, comp, '2026/2027', [-1]);
  assert.equal(await seasonKey(db, comp), '2026-2027');
  assert.equal((await request(db, next)).standings, 'pending');
  // GOAL still serves last season's final table: not the new season's.
  const final = worker(db, () => goalOk(rows('fin', [90, 70], '2025/2026')));
  assert.equal((await final.run()).standings.demand, 'NO_DATA');
  assert.deepEqual((await context(db, next)).standings, []);
  assert.equal((await context(db, old)).standings.length, 1);
  // After the negative cache the new table arrives; both seasons coexist.
  await db.query("update futbeat_private.standings_demands set next_retry_at=now()-interval '1 second'");
  assert.equal((await request(db, next)).standings, 'pending');
  const fresh = worker(db, () => goalOk(rows('new', [3, 1], '2026/2027')));
  assert.equal((await fresh.run()).standings.demand, 'AVAILABLE');
  assert.deepEqual(points(await context(db, next)), [[3, 1]]);
  assert.deepEqual(points(await context(db, old)), [[90, 70]]);
}));

test('future-start season: an unlabelled table is never filed before the opener, one call, stays empty', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2026/2027' });
  await played(db, comp, '2025/2026', [-2000]);
  const m = await match(db, comp, { season: '2026/2027', offsetHours: 100 });
  assert.equal((await request(db, m)).standings, 'pending');
  const w = worker(db, () => goalOk(rows('fut', [9, 6])));
  assert.equal((await w.run()).standings.demand, 'NO_DATA');
  await w.run();
  assert.equal(w.goalCalls().length, 1);
  assert.deepEqual((await context(db, m)).standings, []);
}));

test('group stage with a stale entity: every group stays in the exact season, no other season sees them', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2025/2026' });
  await played(db, comp, '2026/2027', [-100, -20]);
  const m = await match(db, comp, { season: '2026/2027', offsetHours: 20 });
  const old = await match(db, comp, { season: '2025/2026', status: 'VERIFIED', offsetHours: -3000 });
  const row = (group, points) => ({ teamId: `${group}-1`, position: 1, group, played: 3, won: 1, drawn: 0, lost: 2, gf: 2, ga: 2, points });
  await db.query(`insert into futbeat_private.standings_cache(competition_id,provider,external_league_id,season,table_payload,fetched_at)
    values($1,'goal_api',$2,'2026/2027',$3,now())`, [comp.id, comp.ext, JSON.stringify({
    competitionId: comp.id, season: '2026/2027', grouped: true, groupsResolved: true, rows: [row('A', 7), row('B', 5)] })]);
  const ctx = await context(db, m);
  assert.deepEqual(ctx.standings[0].rows.map((r) => [r.group, r.points]), [['A', 7], ['B', 5]]);
  assert.deepEqual((await context(db, old)).standings, []);
}));

test('friendlies without a provider league: empty, no demand, no call, whatever the fixture labels say', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2025', mapped: false });
  await played(db, comp, '2025', [-3000]);
  await played(db, comp, '2026/2027', [-100]);
  const m = await match(db, comp, { season: '2026/2027', offsetHours: 10 });
  assert.equal(await seasonKey(db, comp), '2026-2027');
  assert.deepEqual([(await request(db, m)).standings, (await request(db, m)).standingsPending], ['missing', false]);
  assert.equal(await demand(db, comp, '2026-2027'), undefined);
  assert.deepEqual((await context(db, m)).standings, []);
  assert.equal(await standingsCalls(db), 0);
}));

test('a postponed Apertura game played after the Clausura opener does not close the Clausura demand', () => withDb(async (db) => {
  const comp = await competition(db, { season: 'Apertura 2026' });
  await played(db, comp, 'Apertura 2026', [-2000]);
  await played(db, comp, 'Clausura 2026', [-100]);
  await match(db, comp, { season: 'Clausura 2026', offsetHours: 48 });
  assert.equal(await seasonKey(db, comp), 'clausura 2026');
  await db.query(`insert into futbeat_private.standings_demands(competition_id,season_key,external_league_id,queued_at)
    values($1,'clausura 2026',$2,now())`, [comp.id, comp.ext]);
  await played(db, comp, 'Apertura 2026', [-5]);
  assert.equal(await seasonKey(db, comp), 'apertura 2026');
  const held = await reserve(db);
  assert.deepEqual([held.allowed, held.reconciled.closed], [false, 0]);
  assert.equal(await standingsCalls(db), 0);
  assert.equal((await demand(db, comp, 'clausura 2026')).status, 'QUEUED');
  await played(db, comp, 'Clausura 2026', [-1]);
  const served = await reserve(db);
  assert.deepEqual([served.allowed, served.seasonKey], [true, 'clausura 2026']);
}));

test('same flip with no Clausura fixture stored ahead: closed without a call, reopened at the next game', () => withDb(async (db) => {
  const comp = await competition(db, { season: 'Apertura 2026' });
  await played(db, comp, 'Clausura 2026', [-100]);
  await db.query(`insert into futbeat_private.standings_demands(competition_id,season_key,external_league_id,queued_at)
    values($1,'clausura 2026',$2,now())`, [comp.id, comp.ext]);
  await played(db, comp, 'Apertura 2026', [-5]);
  assert.equal((await reserve(db)).reconciled.closed, 1);
  await played(db, comp, 'Clausura 2026', [-1]);
  const again = await reserve(db);
  assert.deepEqual([again.reconciled.reopened, again.allowed, again.seasonKey], [1, true, 'clausura 2026']);
  assert.equal(await standingsCalls(db), 1);
}));

test('public shape: opening a match returns exactly the same keys', () => withDb(async (db) => {
  const { m } = await staleCup(db);
  assert.deepEqual(Object.keys(await request(db, m)).sort(),
    ['competitionId', 'demandRetryAt', 'seasonKey', 'standings', 'standingsPending', 'standingsStale']);
}));
