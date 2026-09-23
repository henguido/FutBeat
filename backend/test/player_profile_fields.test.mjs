import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { normalizeGoalApiSquad } from '../providers/goal_api_players.mjs';

// Player profile data path: GOAL squad row -> mapper -> stored player ->
// futbeat_read_entity_detail. Keys must match what the mobile Player Profile
// reads (player_profile.dart playerFacts/playerSeason), and missing provider
// fields must stay absent (never null/0 placeholders).

const cdn = (name) => `https://media.goal-api.com/players/${name}.png`;
const stamp = '2026-09-01T00:00:00Z';
const resolveLocal = () => { let n = 0; return async () => `fb_player_mapped_${++n}`; };

test('mapper keeps optional profile facts only when the provider sends them', async () => {
  const [rich, sparse] = await normalizeGoalApiSquad([
    { id: '1', name: 'Rico', height: '1,82 m', foot: 'Left', minutes: '900', starts: 10, number: '9',
      position: { name: 'Attacker' }, nationality: 'Costa Rica', birthDate: '2000-02-01', age: 26,
      matchPlayed: 12, goals: 7, assists: 3, yellowCards: 2, redCards: 0, rating: '7.40', injured: 'no' },
    { id: '2', name: 'Escaso', height: 'tall', foot: 'weird', minutes: [90], starts: { total: 3 } },
  ], 'fb_team_mapped', resolveLocal(), stamp);
  assert.deepEqual(
    { height: rich.height, preferredFoot: rich.preferredFoot, minutesPlayed: rich.minutesPlayed, starts: rich.starts,
      shirtNumber: rich.shirtNumber, position: rich.position, country: rich.country, dateOfBirth: rich.dateOfBirth,
      matchesPlayed: rich.matchesPlayed, rating: rich.rating, injured: rich.injured, redCards: rich.redCards },
    { height: 182, preferredFoot: 'left', minutesPlayed: 900, starts: 10, shirtNumber: 9, position: 'Attacker',
      country: 'Costa Rica', dateOfBirth: '2000-02-01', matchesPlayed: 12, rating: 7.4, injured: false, redCards: 0 });
  for (const key of ['height', 'preferredFoot', 'minutesPlayed', 'starts', 'shirtNumber', 'age', 'goals']) {
    assert.equal(sparse[key], null, key);
  }
});

test('height parsing accepts common formats and rejects implausible values', async () => {
  const heights = ['182', 182, '182 cm', '1.82', '1.82 m', '1,82', '99', '300', '6ft', ''];
  const rows = heights.map((height, i) => ({ id: String(i), name: `P${i}`, height }));
  const players = await normalizeGoalApiSquad(rows, 'fb_team_mapped', resolveLocal(), stamp);
  assert.deepEqual(players.map((p) => p.height), [182, 182, 182, 182, 182, 182, null, null, null, null]);
});

test('stored squad facts reach entity detail with the keys the mobile profile reads', async () => {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities values
      ('fb_team_pf','team','{"id":"fb_team_pf","name":"Club Perfil"}')`);
    const squad = await normalizeGoalApiSquad([
      { id: 'pf-1', name: 'Jugador Completo', number: 10, position: 'Midfielder', nationality: 'Costa Rica',
        birthDate: '1999-05-14', age: 27, height: 178, foot: 'right', minutes: 1500, starts: 17,
        matchPlayed: 20, goals: 5, assists: 8, yellowCards: 3, redCards: 1, rating: 7.1, injured: true, photo: cdn('pf1') },
      { id: 'pf-2', name: 'Jugador Minimo' },
    ], 'fb_team_pf', async (kind, external, identity) => (await db.query(
      'select public.futbeat_resolve_global_entity($1,$2,$3,$4) id', ['goal_api', kind, external, identity.name])).rows[0].id, stamp);
    await db.query('select public.futbeat_store_team_squad($1,$2,$3,$4)', ['fb_team_pf', 'goal_api', stamp, JSON.stringify(squad)]);

    const full = squad[0].id;
    const detail = (await db.query("select public.futbeat_read_entity_detail('player',$1) v", [full])).rows[0].v;
    const player = detail.players.find((p) => p.id === full);
    const read = ['shirtNumber', 'position', 'country', 'dateOfBirth', 'age', 'height', 'preferredFoot', 'minutesPlayed',
      'starts', 'matchesPlayed', 'goals', 'assists', 'yellowCards', 'redCards', 'rating', 'injured', 'teamId'];
    assert.deepEqual(Object.fromEntries(read.map((k) => [k, player[k]])), {
      shirtNumber: 10, position: 'Midfielder', country: 'Costa Rica', dateOfBirth: '1999-05-14', age: 27,
      height: 178, preferredFoot: 'right', minutesPlayed: 1500, starts: 17, matchesPlayed: 20, goals: 5, assists: 8,
      yellowCards: 3, redCards: 1, rating: 7.1, injured: true, teamId: 'fb_team_pf' });
    assert.equal(player.media.url, cdn('pf1'));
    assert.ok(detail.teams.some((t) => t.id === 'fb_team_pf'), 'current team travels with the player');

    // Missing provider facts are absent, not null or zero.
    const minimal = (await db.query("select public.futbeat_read_entity_detail('player',$1) v", [squad[1].id]))
      .rows[0].v.players.find((p) => p.id === squad[1].id);
    for (const key of ['shirtNumber', 'position', 'height', 'preferredFoot', 'goals', 'rating', 'injured', 'media']) {
      assert.equal(key in minimal, false, key);
    }
  } finally { await db.close(); }
});
