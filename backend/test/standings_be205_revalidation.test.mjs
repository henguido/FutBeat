import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { openDatabase } from '../storage/database.mjs';

// BE-205 revalidation against production state of 2026-10-31. GOAL rows carry
// no season, so every table is filed under the key at fetch time. No network.

const stored = JSON.parse(readFileSync(
  new URL('./fixtures/standings/two_phase_table_2026-10-23.json', import.meta.url), 'utf8'));

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

const rows = (prefix, points) => points.map((pts, i) => ({
  overallLeaguePosition: String(i + 1), overallLeaguePlayed: '3',
  overallLeagueW: String(Math.floor(pts / 3)), overallLeagueD: String(pts % 3), overallLeagueL: '0',
  overallLeagueGF: '5', overallLeagueGA: '3', overallLeaguePTS: String(pts),
  team: { id: `${prefix}-team-${i}`, name: `${prefix} Team ${i}`, country: { name: 'Nowhere' } },
}));

let seq = 0;
async function competition(db, season) {
  const n = ++seq;
  const id = `fb_comp_rv${n}`, ext = `rv-league-${n}`;
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)",
    [id, JSON.stringify({ id, name: `Synthetic League ${n}`, country: 'Nowhere', season })]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','competition',$1,$2)", [ext, id]);
  return { id, ext };
}
async function match(db, comp, season, offsetHours, home, away) {
  const id = `fb_match_rv${++seq}`;
  const teams = [home ?? `fb_team_rv${seq}a`, away ?? `fb_team_rv${seq}b`];
  for (const t of teams) {
    await db.query("insert into futbeat_private.entities values($1,'team',$2) on conflict do nothing", [t, JSON.stringify({ id: t, name: t })]);
  }
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [id, JSON.stringify({
    id, competitionId: comp.id, homeTeamId: teams[0], awayTeamId: teams[1], season,
    status: offsetHours < 0 ? 'VERIFIED' : 'SCHEDULED',
    startTime: new Date(Date.now() + offsetHours * 3600e3).toISOString(), events: [], statistics: [] })]);
  return id;
}
const seasonKey = (db, comp) => db.query('select futbeat_private.competition_season_key($1) v', [comp.id]).then((r) => r.rows[0].v);
const storeUnlabelled = (db, comp, prefix, points) => db.query(
  'select public.futbeat_store_goal_standings($1,$2,$3,$4,$5) v',
  [comp.id, comp.ext, new Date().toISOString(), '', JSON.stringify(rows(prefix, points))]);
const snapshots = (db, comp) => db.query(
  'select season_key from futbeat_private.standings_snapshots where competition_id=$1 order by 1', [comp.id])
  .then((r) => r.rows.map((x) => x.season_key));
const context = (db, m) => db.query('select public.futbeat_read_match_context($1) v', [m]).then((r) => r.rows[0].v);
const request = (db, m) => db.query('select public.futbeat_request_match_standings($1) v', [m]).then((r) => r.rows[0].v);

test('rolled-back entity: an unlabelled current table is filed under the current season', () => withDb(async (db) => {
  const comp = await competition(db, '2025/2026');
  const old = await match(db, comp, '2025/2026', -4000);
  await match(db, comp, '2026/2027', -48);
  await storeUnlabelled(db, comp, 'cur', [9, 6]);
  assert.deepEqual(await snapshots(db, comp), ['2026-2027']);
  // The finished season keeps no table rather than the current one.
  assert.deepEqual((await context(db, old)).standings, []);
}));

test('stale entity with an old table: opening a match asks for the current season once', () => withDb(async (db) => {
  const comp = await competition(db, '2025/2026');
  const m = await match(db, comp, '2026/2027', 24);
  await match(db, comp, '2026/2027', -48);
  await storeUnlabelled(db, comp, 'cur', [9, 6]);
  await db.query(`update futbeat_private.standings_snapshots set fetched_at=now()-interval '28 days'
    where competition_id=$1`, [comp.id]);
  await db.query(`insert into futbeat_private.standings_demands(competition_id,season_key,external_league_id,status)
    values($1,'2026-2027',$2,'AVAILABLE')`, [comp.id, comp.ext]);
  const state = await request(db, m);
  assert.equal(state.standingsPending, true);
  assert.equal((await db.query(`select status from futbeat_private.standings_demands where competition_id=$1`, [comp.id])).rows[0].status, 'QUEUED');
  assert.equal((await request(db, m)).standingsPending, true);
  const n = (await db.query("select count(*)::int n from futbeat_private.provider_call_ledger")).rows[0].n;
  assert.equal(n, 0);
}));

test('a stray calendar-year fixture never outranks the split season ending that year', () => withDb(async (db) => {
  const comp = await competition(db, '2025/2026');
  for (const h of [-24, -96, -200, -300]) await match(db, comp, '2025/2026', h);
  await match(db, comp, '2026', -30);
  assert.equal(await seasonKey(db, comp), '2025-2026');
  // Nor does an entity rolled onto that stray.
  await db.query("update futbeat_private.entities set payload=payload||'{\"season\":\"2026\"}' where id=$1", [comp.id]);
  assert.equal(await seasonKey(db, comp), '2025-2026');
}));

test('a league that really moved to calendar years is not a stray', () => withDb(async (db) => {
  const comp = await competition(db, '2025/2026');
  for (const h of [-3000, -3100]) await match(db, comp, '2025/2026', h);
  await match(db, comp, '2026', -30);
  assert.equal(await seasonKey(db, comp), '2026');
}));

const storeRaw = async (db, comp, payload, at) => {
  await db.query(`insert into futbeat_private.standings_cache(competition_id,provider,external_league_id,season,table_payload,fetched_at)
    values($1,'goal_api','l1','',$2,$3)`, [comp.id, JSON.stringify({ ...payload, competitionId: comp.id }), at]);
  return (await db.query('select table_payload p from futbeat_private.standings_cache where competition_id=$1', [comp.id])).rows[0].p;
};
const group = (payload, label) => [...new Set(payload.rows.filter((r) => r.group === label).map((r) => r.teamId))];
// One round of matches among `teams`; odd leftovers play an outside team.
async function round(db, comp, teams, hours) {
  for (let i = 0; i < teams.length; i += 2) {
    await match(db, comp, '2026/2027', hours, teams[i], teams[i + 1]);
  }
}

test('stored Apertura + Clausura table, stage names no group: the phase being played', () => withDb(async (db) => {
  const comp = await competition(db, '2026/2027');
  const table = stored.table_payload;
  await round(db, comp, group(table, 'Apertura'), -72);
  const payload = await storeRaw(db, comp, table, new Date().toISOString());
  assert.equal(payload.currentGroup, 'Apertura');
}));

test('same teams in both phases, parallel groups or an overall table: no team-set hint', () => withDb(async (db) => {
  const table = stored.table_payload;
  const same = await competition(db, '2026/2027');
  const teams = group(table, 'Apertura');
  await round(db, same, teams, -72);
  const twin = { ...table, rows: teams.flatMap((teamId, i) => ['Apertura', 'Clausura'].map((g) => ({ teamId, group: g, position: i + 1, played: 3 }))) };
  assert.equal((await storeRaw(db, same, twin, new Date().toISOString())).currentGroup, undefined);

  const parallel = await competition(db, '2026/2027');
  await round(db, parallel, [...group(table, 'Apertura'), ...group(table, 'Clausura')], -72);
  assert.equal((await storeRaw(db, parallel, table, new Date().toISOString())).currentGroup, undefined);

  const overall = await competition(db, '2026/2027');
  await round(db, overall, group(table, 'Apertura'), -72);
  const annual = { ...table, rows: [...table.rows, { teamId: 'fb_team_x', position: 1, played: 3 }, { teamId: 'fb_team_y', position: 2, played: 3 }] };
  assert.equal((await storeRaw(db, overall, annual, new Date().toISOString())).currentGroup, undefined);
}));
