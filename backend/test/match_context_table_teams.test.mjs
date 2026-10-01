import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// QA (Match Center Tabla): a 20-team league table must reach the app with the
// team entity of every row, even when only the match's two teams appear in
// stored matches, and a league table stored together with labelled stage
// groups keeps its overall rows unlabelled (grouped=true,
// groupsResolved=true). Everything synthetic; no provider call.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

const row = (i, extra = {}) => ({
  overallLeaguePosition: String(i + 1), overallLeaguePlayed: '5', overallLeagueW: '1',
  overallLeagueD: '1', overallLeagueL: '3', overallLeagueGF: '2', overallLeagueGA: '3',
  overallLeaguePTS: String(40 - i),
  team: { id: `mct-team-${i}`, name: `Equipo Sintético ${i}`, country: { name: 'Nowhere' } },
  ...extra,
});

async function setup(db, rows) {
  const id = 'fb_comp_mct', ext = 'mct-league';
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)",
    [id, JSON.stringify({ id, name: 'Liga Sintética', country: 'Nowhere', season: '2026' })]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','competition',$1,$2)", [ext, id]);
  await db.query('select public.futbeat_store_goal_standings($1,$2,$3,$4,$5)',
    [id, ext, new Date().toISOString(), '2026', JSON.stringify(rows)]);
  const team = async (external) => (await db.query(
    "select canonical_id from futbeat_private.provider_entities where provider='goal_api' and kind='team' and external_id=$1",
    [external])).rows[0].canonical_id;
  const [home, away] = [await team('mct-team-0'), await team('mct-team-1')];
  const match = 'fb_match_mct';
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [match, JSON.stringify({
    id: match, competitionId: id, homeTeamId: home, awayTeamId: away, season: '2026', status: 'SCHEDULED',
    startTime: new Date(Date.now() + 86400e3).toISOString(), events: [], statistics: [] })]);
  await db.query('select public.futbeat_request_match_standings($1)', [match]);
  return (await db.query('select public.futbeat_read_match_context($1) v', [match])).rows[0].v;
}

test('match context carries the team of every table row', () => withDb(async (db) => {
  const ctx = await setup(db, Array.from({ length: 20 }, (_, i) => row(i)));
  const [table] = ctx.standings;
  assert.equal(table.rows.length, 20);
  const ids = new Set(ctx.teams.map((t) => t.id));
  assert.deepEqual(table.rows.filter((r) => !ids.has(r.teamId)), []);
}));

test('overall table plus labelled stage groups: overall rows stay unlabelled', () => withDb(async (db) => {
  const rows = Array.from({ length: 20 }, (_, i) => row(i));
  for (let i = 0; i < 8; i++) {
    rows.push(row(i, { overallLeaguePosition: String((i % 4) + 1), group: i < 4 ? 'Grupo A' : 'Grupo B' }));
  }
  const ctx = await setup(db, rows);
  const [table] = ctx.standings;
  assert.deepEqual([table.grouped, table.groupsResolved, table.rows.length], [true, true, 28]);
  assert.equal(table.rows.filter((r) => r.group === undefined).length, 20);
  const ids = new Set(ctx.teams.map((t) => t.id));
  assert.equal(table.rows.every((r) => ids.has(r.teamId)), true);
}));
