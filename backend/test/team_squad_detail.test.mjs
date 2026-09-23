import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { normalizeGoalApiSquad } from '../providers/goal_api_players.mjs';

// Team Profile "Plantilla" data path: team_squad_members -> player entities ->
// futbeat_read_entity_detail('team'). No provider calls, no invented squad.

const cdn = (name) => `https://media.goal-api.com/players/${name}.png`;
const stamp = '2026-09-01T00:00:00Z';
const positions = ['Goalkeeper', 'Defender', 'Midfielder', 'Attacker'];

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities values
      ('fb_team_sq','team','{"id":"fb_team_sq","name":"Club Plantilla"}'),
      ('fb_team_empty','team','{"id":"fb_team_empty","name":"Club Sin Plantilla"}')`);
    await fn(db);
    assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 0);
  } finally { await db.close(); }
}

async function storeSquad(db, teamId, rows) {
  const squad = await normalizeGoalApiSquad(rows, teamId, async (kind, external, identity) => (await db.query(
    'select public.futbeat_resolve_global_entity($1,$2,$3,$4) id', ['goal_api', kind, external, identity.name])).rows[0].id, stamp);
  await db.query('select public.futbeat_store_team_squad($1,$2,$3,$4)', [teamId, 'goal_api', stamp, JSON.stringify(squad)]);
}

const teamDetail = async (db, id) => (await db.query("select public.futbeat_read_entity_detail('team',$1) v", [id])).rows[0].v;

test('a 40-player squad reaches the team detail complete, with mixed photos and real facts only', () => withDb(async (db) => {
  const rows = Array.from({ length: 40 }, (_, i) => ({
    id: `sq-${i + 1}`, name: `Jugador ${i + 1}`, number: i + 1, position: positions[i % 4],
    nationality: i % 3 === 0 ? 'Costa Rica' : undefined, ...(i % 2 === 0 ? { photo: cdn(`sq-${i + 1}`) } : {}),
  }));
  await storeSquad(db, 'fb_team_sq', rows);
  const detail = await teamDetail(db, 'fb_team_sq');
  const squad = detail.players.filter((p) => p.teamId === 'fb_team_sq');
  assert.equal(squad.length, 40);
  assert.equal(squad.filter((p) => p.media?.verificationStatus === 'VERIFIED').length, 20);
  assert.deepEqual(new Set(squad.map((p) => p.position)), new Set(positions));
  assert.deepEqual(squad.map((p) => p.shirtNumber).sort((a, b) => a - b), Array.from({ length: 40 }, (_, i) => i + 1));
  // Nationality only where the provider gave one; never a placeholder.
  assert.equal(squad.filter((p) => p.country === 'Costa Rica').length, 14);
  // (identity creation stores "" for unknown; the app treats blank as missing)
  assert.equal(squad.filter((p) => (p.country ?? '') !== '' && p.country !== 'Costa Rica').length, 0);
}));

test('a team without a stored squad returns no players (nothing invented)', () => withDb(async (db) => {
  await storeSquad(db, 'fb_team_sq', [{ id: 'sq-1', name: 'Otro Club' }]);
  const detail = await teamDetail(db, 'fb_team_empty');
  assert.equal(detail.players.filter((p) => p.teamId === 'fb_team_empty').length, 0);
}));

test('a player moved to another squad leaves the previous Plantilla', () => withDb(async (db) => {
  await storeSquad(db, 'fb_team_sq', [{ id: 'mv-1', name: 'Viajero', number: 7 }, { id: 'st-1', name: 'Fijo', number: 1 }]);
  await db.query(`insert into futbeat_private.entities values
    ('fb_team_new','team','{"id":"fb_team_new","name":"Club Nuevo"}')`);
  await storeSquad(db, 'fb_team_new', [{ id: 'mv-1', name: 'Viajero', number: 11 }]);
  const old = (await teamDetail(db, 'fb_team_sq')).players.filter((p) => p.teamId === 'fb_team_sq');
  assert.deepEqual(old.map((p) => p.name), ['Fijo']);
  const moved = (await teamDetail(db, 'fb_team_new')).players.find((p) => p.name === 'Viajero');
  assert.equal(moved.shirtNumber, 11);
}));
