import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { normalizeGoalApiSquad } from '../providers/goal_api_players.mjs';

// QA81 (#222) / #217: a player listed by a club squad AND by a national-team
// squad is one person with two memberships. Storing one squad must never
// erase the other membership, record a club<->national "transfer" or flip
// the player's club. The profile lists the matches of every membership.
// Generic fixtures only; no provider is called.

const T1 = '2026-10-10T00:00:00Z';
const T2 = '2026-10-12T00:00:00Z';
const T3 = '2026-10-14T00:00:00Z';
const CLUB = 'fb_team_club_a';
const CLUB_B = 'fb_team_club_b';
const NATIONAL = 'fb_team_nat_cr';
const NATIONAL_U23 = 'fb_team_nat_cr_u23';

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities values
      ('fb_comp_league','competition','{"id":"fb_comp_league","name":"Liga Ejemplo","country":"Costa Rica"}'),
      ('fb_comp_intl','competition','{"id":"fb_comp_intl","name":"Copa Internacional"}'),
      ('${CLUB}','team','{"id":"${CLUB}","name":"Club Sport Ejemplo","competitionId":"fb_comp_league"}'),
      ('${CLUB_B}','team','{"id":"${CLUB_B}","name":"Deportivo Otro","competitionId":"fb_comp_league"}'),
      ('fb_team_rival','team','{"id":"fb_team_rival","name":"Rival FC","competitionId":"fb_comp_league"}'),
      ('${NATIONAL}','team','{"id":"${NATIONAL}","name":"Costa Rica","competitionId":"fb_comp_intl"}'),
      ('${NATIONAL_U23}','team','{"id":"${NATIONAL_U23}","name":"Costa Rica U23","competitionId":"fb_comp_intl"}'),
      ('fb_team_nat_pa','team','{"id":"fb_team_nat_pa","name":"Panama","competitionId":"fb_comp_intl"}')`);
    for (const [ext, id] of [['club-a', CLUB], ['club-b', CLUB_B], ['nat-cr', NATIONAL], ['nat-cr-u23', NATIONAL_U23]]) {
      await db.query("insert into futbeat_private.provider_entities values('goal_api','team',$1,$2)", [ext, id]);
    }
    await fn(db);
    assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 0);
  } finally { await db.close(); }
}

const one = async (db, sql, params = []) => (await db.query(sql, params)).rows[0]?.v;

async function storeSquad(db, teamId, rows, stamp) {
  const squad = await normalizeGoalApiSquad(rows, teamId, async (kind, external, identity) => one(db,
    'select public.futbeat_resolve_global_entity($1,$2,$3,$4) v', ['goal_api', kind, external, identity.name]), stamp);
  return one(db, 'select public.futbeat_store_team_squad($1,$2,$3,$4) v', [teamId, 'goal_api', stamp, JSON.stringify(squad)]);
}

const pidOf = (db, ext) => one(db,
  "select futbeat_private.futbeat_resolve_entity_id('player',canonical_id) v from futbeat_private.provider_entities where provider='goal_api' and kind='player' and external_id=$1", [ext]);
const payloadOf = (db, id) => one(db, 'select payload v from futbeat_private.entities where id=$1', [id]);
const teamsOf = async (db, playerId) => (await db.query(
  'select team_id from futbeat_private.team_squad_members where player_id=$1 order by team_id', [playerId])).rows.map((r) => r.team_id);
const transfers = async (db) => (await db.query(
  'select player_id,from_team_id,to_team_id from futbeat_private.transfer_events order by id')).rows;
const detail = (db, type, id) => one(db, 'select public.futbeat_read_entity_detail($1,$2) v', [type, id]);

async function addMatch(db, id, home, away, competitionId, start, events = []) {
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [id, JSON.stringify({
    id, competitionId, homeTeamId: home, awayTeamId: away, startTime: start, status: 'FINISHED',
    homeScore: 1, awayScore: 0, events,
  })]);
  await db.query("insert into futbeat_private.calendar_matches values($1,$2,'test',$2) on conflict(match_id) do nothing", [id, start]);
}

const acuna = { id: 'p-acuna', name: 'Sebastian Ejemplo', number: 10, age: 25, dateOfBirth: '2001-01-01', matchPlayed: 12 };
const mate = { id: 'p-mate', name: 'Otro Jugador', number: 4 };

test('club then national squad: two memberships, no transfer, club stays primary', () => withDb(async (db) => {
  await storeSquad(db, CLUB, [acuna, mate], T1);
  await storeSquad(db, NATIONAL, [{ ...acuna, number: 17 }], T2);
  const pid = await pidOf(db, 'p-acuna');
  assert.deepEqual(await teamsOf(db, pid), [CLUB, NATIONAL].sort());
  assert.deepEqual(await transfers(db), []);
  const payload = await payloadOf(db, pid);
  assert.equal(payload.teamId, CLUB);
  assert.equal(payload.nationalTeamId, NATIONAL);
  // Club context survives the national call-up (shirt number, season numbers).
  assert.equal(payload.shirtNumber, 10);
  assert.equal(payload.matchesPlayed, 12);
  // Coverage counts include the restored club membership.
  const cov = (await db.query('select player_count from futbeat_private.team_detail_coverage where team_id=$1', [CLUB])).rows[0];
  assert.equal(cov.player_count, 2);
}));

test('national then club squad: club becomes primary, national kept', () => withDb(async (db) => {
  await storeSquad(db, NATIONAL, [acuna], T1);
  await storeSquad(db, CLUB, [acuna], T2);
  const pid = await pidOf(db, 'p-acuna');
  assert.deepEqual(await teamsOf(db, pid), [CLUB, NATIONAL].sort());
  assert.deepEqual(await transfers(db), []);
  const payload = await payloadOf(db, pid);
  assert.equal(payload.teamId, CLUB);
  assert.equal(payload.nationalTeamId, NATIONAL);
}));

test('repeated refreshes do not ping-pong the club', () => withDb(async (db) => {
  await storeSquad(db, CLUB, [acuna], T1);
  await storeSquad(db, NATIONAL, [acuna], T2);
  await storeSquad(db, CLUB, [acuna], T3);
  await storeSquad(db, NATIONAL, [acuna], '2026-10-16T00:00:00Z');
  const pid = await pidOf(db, 'p-acuna');
  assert.equal((await payloadOf(db, pid)).teamId, CLUB);
  assert.deepEqual(await teamsOf(db, pid), [CLUB, NATIONAL].sort());
  assert.deepEqual(await transfers(db), []);
}));

test('club to club is still a transfer; the national membership survives it', () => withDb(async (db) => {
  await storeSquad(db, CLUB, [acuna], T1);
  await storeSquad(db, NATIONAL, [acuna], T2);
  await storeSquad(db, CLUB_B, [acuna], T3);
  const pid = await pidOf(db, 'p-acuna');
  assert.deepEqual(await teamsOf(db, pid), [CLUB_B, NATIONAL].sort());
  assert.deepEqual(await transfers(db), [{ player_id: pid, from_team_id: CLUB, to_team_id: CLUB_B }]);
  const payload = await payloadOf(db, pid);
  assert.equal(payload.teamId, CLUB_B);
  assert.equal(payload.nationalTeamId, NATIONAL);
}));

test('senior and youth national teams are both kept, never a transfer', () => withDb(async (db) => {
  await storeSquad(db, CLUB, [acuna], T1);
  await storeSquad(db, NATIONAL_U23, [acuna], T2);
  await storeSquad(db, NATIONAL, [acuna], T3);
  const pid = await pidOf(db, 'p-acuna');
  assert.deepEqual(await teamsOf(db, pid), [CLUB, NATIONAL, NATIONAL_U23].sort());
  assert.deepEqual(await transfers(db), []);
  assert.equal((await payloadOf(db, pid)).teamId, CLUB);
}));

test('homonyms: same name, different provider ids stay two people', () => withDb(async (db) => {
  await storeSquad(db, CLUB, [acuna], T1);
  await storeSquad(db, NATIONAL, [{ ...acuna, id: 'p-acuna-homonym', dateOfBirth: '1990-05-05' }], T2);
  const a = await pidOf(db, 'p-acuna');
  const b = await pidOf(db, 'p-acuna-homonym');
  assert.notEqual(a, b);
  assert.deepEqual(await teamsOf(db, a), [CLUB]);
  assert.deepEqual(await teamsOf(db, b), [NATIONAL]);
  assert.equal((await payloadOf(db, a)).nationalTeamId, undefined);
  assert.equal(await one(db, "select count(*)::int v from futbeat_private.entity_redirects where kind='player'"), 0);
}));

test('profile: matches of club and national team, plus own-event matches', () => withDb(async (db) => {
  await storeSquad(db, CLUB, [acuna], T1);
  await storeSquad(db, NATIONAL, [acuna], T2);
  const pid = await pidOf(db, 'p-acuna');
  await addMatch(db, 'fb_match_club', CLUB, 'fb_team_rival', 'fb_comp_league', '2026-10-18T22:00:00Z');
  await addMatch(db, 'fb_match_nat', NATIONAL, 'fb_team_nat_pa', 'fb_comp_intl', '2026-10-10T02:00:00Z');
  await addMatch(db, 'fb_match_unrelated', CLUB_B, 'fb_team_rival', 'fb_comp_league', '2026-10-17T22:00:00Z');
  const profile = await detail(db, 'player', pid);
  assert.deepEqual(profile.matches.map((m) => m.id).sort(), ['fb_match_club', 'fb_match_nat']);
  assert.deepEqual(profile.players[0].teamIds, [CLUB, NATIONAL]);
  assert.ok(profile.teams.some((t) => t.id === NATIONAL));
  assert.ok(profile.competitions.some((c) => c.id === 'fb_comp_intl'));
}));

test('profile: a match where the player has a canonical event is listed even without membership', () => withDb(async (db) => {
  await storeSquad(db, NATIONAL, [acuna], T1);
  const pid = await pidOf(db, 'p-acuna');
  // Pre-fix data: the club membership was already erased in production.
  await addMatch(db, 'fb_match_goal', CLUB, 'fb_team_rival', 'fb_comp_league', '2026-10-18T22:00:00Z');
  await db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,first_seen_at)
    values('fb_event_g1','fb_match_goal','goal_api','GOAL',$1,now())`, [JSON.stringify({ playerId: pid, teamId: CLUB, minute: 30 })]);
  const profile = await detail(db, 'player', pid);
  assert.ok(profile.matches.some((m) => m.id === 'fb_match_goal'));
  assert.ok(profile.players[0].teamIds.includes(NATIONAL));
}));
