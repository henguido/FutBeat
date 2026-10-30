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
