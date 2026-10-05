import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// 20261005030000: a stage that GOAL sends as one label with repeated
// positions (several groups) is split by real fixtures, only when the split
// is unambiguous; otherwise the table stays exactly as stored (fail-closed).

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const comp = 'fb_competition_sub';
let seq = 0;
async function seedTeams(db, n) {
  await db.query("insert into futbeat_private.entities values($1,'competition',$2) on conflict do nothing",
    [comp, JSON.stringify({ id: comp, name: 'Nations' })]);
  const ids = [];
  for (let i = 0; i < n; i++) {
    const id = `fb_team_sub_${++seq}`;
    await db.query("insert into futbeat_private.entities values($1,'team',$2)", [id, JSON.stringify({ id, name: `T${seq}` })]);
    ids.push(id);
  }
  return ids;
}
async function fixture(db, home, away, daysAgo = 10) {
  const id = `fb_match_sub_${++seq}`;
  const start = new Date(Date.now() - daysAgo * 864e5).toISOString();
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [id, JSON.stringify({
    id, competitionId: comp, homeTeamId: home, awayTeamId: away, startTime: start, status: 'VERIFIED',
    score: { home: 1, away: 0 }, events: [], statistics: [] })]);
}
const row = (teamId, position, group = 'League A') => ({ teamId, position, group, played: 2, won: 1, drawn: 0, lost: 1, gf: 2, ga: 2, points: 3 });
async function store(db, rows) {
  const table = { competitionId: comp, season: '', provisional: false, source: 'GOAL API', grouped: false,
    groupsResolved: false, rows };
  await db.query(`insert into futbeat_private.standings_cache(competition_id,provider,external_league_id,season,table_payload,fetched_at)
    values($1,'goal_api','ext-sub','',$2,now())
    on conflict(competition_id) do update set table_payload=excluded.table_payload,fetched_at=excluded.fetched_at`,
  [comp, JSON.stringify(table)]);
  return (await db.query('select table_payload t from futbeat_private.standings_cache where competition_id=$1', [comp])).rows[0].t;
}
// Two groups of four (round robin inside each group only).
async function twoGroups(db) {
  const [a1, a2, a3, a4, b1, b2, b3, b4] = await seedTeams(db, 8);
  for (const g of [[a1, a2, a3, a4], [b1, b2, b3, b4]]) {
    for (let i = 0; i < g.length; i++) for (let j = i + 1; j < g.length; j++) await fixture(db, g[i], g[j]);
  }
  return { a: [a1, a2, a3, a4], b: [b1, b2, b3, b4] };
}

test('one label holding two groups is split by fixtures into two resolved sub-groups', () => withDb(async (db) => {
  const { a, b } = await twoGroups(db);
  // Provider order interleaves the groups by position.
  const t = await store(db, [row(a[0], 1), row(b[0], 1), row(a[1], 2), row(b[1], 2), row(a[2], 3), row(b[2], 3), row(a[3], 4), row(b[3], 4)]);
  assert.equal(t.groupsResolved, true, JSON.stringify(t));
  assert.equal(t.subgroupsFromFixtures, true);
  const sub = Object.fromEntries(t.rows.map((r) => [r.teamId, r.subgroup]));
  assert.deepEqual(new Set(a.map((id) => sub[id])), new Set([1]));
  assert.deepEqual(new Set(b.map((id) => sub[id])), new Set([2]));
  assert.ok(t.rows.every((r) => r.group === 'League A'), 'the provider label is kept, never invented');
  assert.equal(t.rows.length, 8, 'no row added or dropped');
}));

test('a fixture joining the groups (knockout / interzonal) keeps the table unresolved', () => withDb(async (db) => {
  const { a, b } = await twoGroups(db);
  await fixture(db, a[0], b[0], 2);
  const t = await store(db, [row(a[0], 1), row(b[0], 1), row(a[1], 2), row(b[1], 2), row(a[2], 3), row(b[2], 3), row(a[3], 4), row(b[3], 4)]);
  assert.equal(t.groupsResolved, false);
  assert.ok(t.rows.every((r) => r.subgroup === undefined));
}));

test('a component with a shared or missing position keeps the whole table unresolved', () => withDb(async (db) => {
  const { a, b } = await twoGroups(db);
  const t = await store(db, [row(a[0], 1), row(b[0], 1), row(a[1], 1), row(b[1], 2), row(a[2], 3), row(b[2], 3), row(a[3], 4), row(b[3], 4)]);
  assert.equal(t.groupsResolved, false);
}));

test('a team without fixtures in the window keeps the table unresolved (no guess)', () => withDb(async (db) => {
  const { a, b } = await twoGroups(db);
  const [lonely] = await seedTeams(db, 1);
  const t = await store(db, [row(a[0], 1), row(b[0], 1), row(lonely, 1), row(a[1], 2), row(b[1], 2), row(a[2], 3), row(b[2], 3), row(a[3], 4), row(b[3], 4)]);
  assert.equal(t.groupsResolved, false);
}));

test('fixtures older than the window do not connect anything', () => withDb(async (db) => {
  const { a, b } = await twoGroups(db);
  await fixture(db, a[0], b[0], 400); // last edition, other groups
  const t = await store(db, [row(a[0], 1), row(b[0], 1), row(a[1], 2), row(b[1], 2), row(a[2], 3), row(b[2], 3), row(a[3], 4), row(b[3], 4)]);
  assert.equal(t.groupsResolved, true);
}));

test('an already resolved single table is stored untouched', () => withDb(async (db) => {
  const ids = await seedTeams(db, 3);
  const rows = ids.map((id, i) => row(id, i + 1, undefined));
  const table = { competitionId: comp, season: '', provisional: false, source: 'GOAL API', grouped: false, groupsResolved: true, rows };
  await db.query(`insert into futbeat_private.standings_cache(competition_id,provider,external_league_id,season,table_payload,fetched_at)
    values($1,'goal_api','ext-sub','',$2,now())`, [comp, JSON.stringify(table)]);
  const t = (await db.query('select table_payload t from futbeat_private.standings_cache where competition_id=$1', [comp])).rows[0].t;
  assert.equal(t.subgroupsFromFixtures, undefined);
  assert.ok(t.rows.every((r) => r.subgroup === undefined));
}));

test('live overlay re-ranks inside the sub-group only and keeps `subgroup`', () => withDb(async (db) => {
  const { a, b } = await twoGroups(db);
  const rows = [row(a[0], 1), row(b[0], 1), row(a[1], 2), row(b[1], 2), row(a[2], 3), row(b[2], 3), row(a[3], 4), row(b[3], 4)];
  const table = { competitionId: comp, season: '', provisional: false, source: 'GOAL API', grouped: false, groupsResolved: false, rows };
  await db.query(`insert into futbeat_private.standings_cache(competition_id,provider,external_league_id,season,table_payload,fetched_at)
    values($1,'goal_api','ext-sub','',$2,now()-interval '3 hours')`, [comp, JSON.stringify(table)]);
  const stored = (await db.query('select table_payload t,fetched_at f from futbeat_private.standings_cache where competition_id=$1', [comp])).rows[0];
  assert.equal(stored.t.groupsResolved, true);
  // Group B's last team wins big after the table was fetched.
  await db.query("insert into futbeat_private.entities values('fb_match_sub_live','match',$1)", [JSON.stringify({
    id: 'fb_match_sub_live', competitionId: comp, homeTeamId: b[3], awayTeamId: b[0],
    startTime: new Date(Date.now() - 2 * 3600e3).toISOString(), status: 'VERIFIED', score: { home: 5, away: 0 },
    provenance: { receivedAt: new Date().toISOString() }, events: [], statistics: [] })]);
  const out = (await db.query('select futbeat_private.futbeat_apply_provisional_standings($1,$2) v', [JSON.stringify(stored.t), stored.f])).rows[0].v;
  assert.equal(out.provisional, true);
  const byTeam = Object.fromEntries(out.rows.map((r) => [r.teamId, r]));
  for (const id of a) assert.equal(byTeam[id].subgroup, 1);
  for (const id of b) assert.equal(byTeam[id].subgroup, 2);
  assert.deepEqual(a.map((id) => byTeam[id].position), [1, 2, 3, 4], 'group A untouched');
  assert.equal(byTeam[b[3]].position, 1, 'the winner leads ITS group, not all of League A');
  const positions = out.rows.filter((r) => r.subgroup === 2).map((r) => r.position).sort();
  assert.deepEqual(positions, [1, 2, 3, 4]);
}));
