import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// BE-239: GOAL 835432 was mapped to an entity with an empty payload, so the linker
// called it linked and the match stayed without teams or calendar row.

const kickoff = new Date(Date.now() - 3600000).toISOString();
async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const insert = (db, id, kind, payload) => db.query('insert into futbeat_private.entities(id,kind,payload) values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
const mapId = (db, kind, ext, id) => db.query("insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) values('goal_api',$1,$2,$3)", [kind, ext, id]);
async function seed(db, { teams = true, comp = true } = {}) {
  await insert(db, 'fb_team_r', 'team', { id: 'fb_team_r', name: 'MB Rouisset' });
  await insert(db, 'fb_team_b', 'team', { id: 'fb_team_b', name: 'Ben Aknoun' });
  await insert(db, 'fb_competition_l', 'competition', { id: 'fb_competition_l', name: 'Ligue 1' });
  await insert(db, 'fb_match_empty', 'match', { id: 'fb_match_empty', name: '', country: '', shortName: '' });
  await mapId(db, 'match', 'x835', 'fb_match_empty');
  if (teams) { await mapId(db, 'team', 'tr', 'fb_team_r'); await mapId(db, 'team', 'tb', 'fb_team_b'); }
  if (comp) await mapId(db, 'competition', 'cl', 'fb_competition_l');
}
const fixture = { apiId: 'x835', kickoffUtc: kickoff, matchStatus: 'LIVE', leagueId: 'cl', leagueYear: '2026',
  homeTeam: { id: 'tr', name: 'Rouisset' }, awayTeam: { id: 'tb', name: 'Ben Aknoun' } };
const link = (db, f = fixture) => db.query('select public.futbeat_link_goal_live_matches($1) v', [JSON.stringify([f])]).then((r) => r.rows[0].v);
const entity = (db, id = 'fb_match_empty') => db.query('select payload p from futbeat_private.entities where id=$1', [id]).then((r) => r.rows[0].p);
const calendar = (db) => db.query("select count(*)::int n from futbeat_private.calendar_matches where match_id='fb_match_empty'").then((r) => r.rows[0].n);

test('a mapped empty match gets its teams, competition and calendar row', () => withDb(async (db) => {
  await seed(db);
  const r = await link(db);
  assert.equal(r.alreadyLinked, 1);
  const p = await entity(db);
  assert.equal(p.homeTeamId, 'fb_team_r');
  assert.equal(p.awayTeamId, 'fb_team_b');
  assert.equal(p.competitionId, 'fb_competition_l');
  assert.equal(p.status, 'SCHEDULED');
  assert.equal(p.name, undefined);
  assert.equal(await calendar(db), 1);
}));

test('hydrating twice changes nothing the second time', () => withDb(async (db) => {
  await seed(db);
  await link(db);
  const first = await entity(db);
  await link(db);
  assert.deepEqual(await entity(db), first);
  assert.equal(await calendar(db), 1);
}));

test('an unmapped team keeps the entity empty, whatever the names say', () => withDb(async (db) => {
  await seed(db, { teams: false });
  await link(db);
  assert.equal((await entity(db)).homeTeamId, undefined);
}));

test('an unmapped competition keeps the entity empty', () => withDb(async (db) => {
  await seed(db, { comp: false });
  await link(db);
  assert.equal((await entity(db)).homeTeamId, undefined);
}));

test('a real match of the same teams is never doubled', () => withDb(async (db) => {
  await seed(db);
  await insert(db, 'fb_match_real', 'match', { id: 'fb_match_real', competitionId: 'fb_competition_l', homeTeamId: 'fb_team_r', awayTeamId: 'fb_team_b',
    status: 'SCHEDULED', startTime: kickoff, events: [], statistics: [] });
  await link(db);
  assert.equal((await entity(db)).homeTeamId, undefined);
  const { rows } = await db.query("select canonical_id c from futbeat_private.provider_entities where provider='goal_api' and kind='match' and external_id='x835'");
  assert.equal(rows[0].c, 'fb_match_empty');
}));

test('a match with real data is left alone', () => withDb(async (db) => {
  await seed(db);
  await insert(db, 'fb_match_full', 'match', { id: 'fb_match_full', competitionId: 'fb_competition_l', homeTeamId: 'fb_team_b', awayTeamId: 'fb_team_r',
    status: 'SCHEDULED', startTime: kickoff, events: [], statistics: [] });
  await mapId(db, 'match', 'x900', 'fb_match_full');
  const before = await entity(db, 'fb_match_full');
  await link(db, { ...fixture, apiId: 'x900' });
  assert.deepEqual(await entity(db, 'fb_match_full'), before);
}));
