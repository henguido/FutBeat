import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { normalizeGoalApiSquad } from '../providers/goal_api_players.mjs';

// BE10 P0.3 / BE11 A2: GOAL can list one person under two catalog ids in ONE
// squad answer, both with a birth date (so the old sparse-twin rule never
// fires). Migration 20261107180000 hides the less complete id in the squad
// only: nothing is merged or deleted, both identities keep their own
// detail/stats, and a player that a user follows is never hidden.
// Patterns taken from production (2026-11-07), generic names.

const cdn = (name) => `https://media.goal-api.com/players/${name}.png`;
const T1 = '2026-11-01T00:00:00Z';
const TEAM = 'fb_team_dobtwins';

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities values
      ('${TEAM}','team','{"id":"${TEAM}","name":"Club Uno"}')`);
    await db.query("insert into futbeat_private.provider_entities values('goal_api','team','goal-team-dobtwins',$1)", [TEAM]);
    await fn(db);
    assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 0);
  } finally { await db.close(); }
}

const one = async (db, sql, params = []) => (await db.query(sql, params)).rows[0]?.v;

async function storeSquad(db, rows, stamp = T1) {
  const squad = await normalizeGoalApiSquad(rows, TEAM, async (kind, external, identity) => one(db,
    'select public.futbeat_resolve_global_entity($1,$2,$3,$4) v', ['goal_api', kind, external, identity.name]), stamp);
  return one(db, 'select public.futbeat_store_team_squad($1,$2,$3,$4) v', [TEAM, 'goal_api', stamp, JSON.stringify(squad)]);
}

const squad = async (db) => (await one(db, 'select public.futbeat_read_entity_detail($1,$2) v', ['team', TEAM]))
  .players.filter((p) => p.teamId === TEAM);
const pidOf = (db, ext) => one(db,
  "select canonical_id v from futbeat_private.provider_entities where provider='goal_api' and kind='player' and external_id=$1", [ext]);
const integrity = (db) => one(db, `select md5(string_agg(x,'|' order by x)) v from (
  select 'e'||id||payload::text x from futbeat_private.entities where kind='player'
  union all select 'p'||external_id||canonical_id from futbeat_private.provider_entities where kind='player'
  union all select 'f'||user_id||entity_id from futbeat_private.push_follows
  union all select 'r'||alias_id from futbeat_private.entity_redirects
  union all select 'm'||team_id||player_id from futbeat_private.team_squad_members) s`);
const follow = (db, pid, user = '00000000-0000-0000-0000-0000000000a1') => db.query(
  "insert into futbeat_private.push_follows(user_id,entity_type,entity_id) values($1,'player',$2)", [user, pid]);
const refresh = (db) => one(db, 'select futbeat_private.refresh_team_squad_twins($1) v', [TEAM]);

const dob = (id, name, extra = {}) => ({ id, name, age: 23, dateOfBirth: '2003-01-05', ...extra });

test('same name + same birth date in one squad: the photo id is shown once, nothing merged', () => withDb(async (db) => {
  await storeSquad(db, [
    dob('ext-photo', 'Ahmed Mahmoud', { number: 31, photo: cdn('ext-photo'), matchPlayed: 1 }),
    dob('ext-plain', 'Ahmed Mahmoud', { number: 31, matchPlayed: 5 }),
    { id: 'ext-solo', name: 'Diego Solano', number: 9, photo: cdn('ext-solo') },
  ]);
  const shown = await squad(db);
  assert.deepEqual(shown.map((p) => p.name).sort(), ['Ahmed Mahmoud', 'Diego Solano']);
  assert.equal(shown.find((p) => p.name === 'Ahmed Mahmoud').media.url, cdn('ext-photo'));
  // Hidden id stays a separate, readable identity with its own stats.
  const hidden = await pidOf(db, 'ext-plain');
  assert.notEqual(hidden, await pidOf(db, 'ext-photo'));
  assert.equal(await one(db, "select (payload->>'matchesPlayed')::int v from futbeat_private.entities where id=$1", [hidden]), 5);
  assert.ok(await one(db, 'select public.futbeat_read_entity_detail($1,$2) v', ['player', hidden]), 'hidden id still has a detail');
  assert.equal(await one(db, "select count(*)::int v from futbeat_private.entity_redirects where kind='player'"), 0);
  const coverage = (await db.query('select player_count from futbeat_private.team_detail_coverage where team_id=$1', [TEAM])).rows[0];
  assert.deepEqual(coverage, { player_count: 2 });
}));

test('equal richness: the id with more matches is the one shown', () => withDb(async (db) => {
  await storeSquad(db, [
    dob('ext-a', 'Emerson Bravo', { number: 25, matchPlayed: 1 }),
    dob('ext-b', 'Emerson Bravo', { number: 25, matchPlayed: 13 }),
  ]);
  const shown = await squad(db);
  assert.equal(shown.length, 1);
  assert.equal(shown[0].id, await pidOf(db, 'ext-b'));
}));

test('never hidden: 3 equal ids, different birth date, followed alias (before and after the store)', () => withDb(async (db) => {
  await storeSquad(db, [
    dob('ext-t1', 'Luis Gomez'), dob('ext-t2', 'Luis Gomez'), dob('ext-t3', 'Luis Gomez'),
    dob('ext-d1', 'Carlos Diaz'), dob('ext-d2', 'Carlos Diaz', { dateOfBirth: '2001-02-02' }),
    dob('ext-f1', 'Pedro Leon', { matchPlayed: 9 }), dob('ext-f2', 'Pedro Leon'),
  ]);
  assert.equal((await squad(db)).length, 6, 'only the Pedro Leon pair collapses');
  const before = await integrity(db);
  await follow(db, await pidOf(db, 'ext-f2'));
  assert.equal((await squad(db)).length, 7, 'a followed player is shown at once (live read)');
  assert.equal(await refresh(db), 0, 'and is not stored as a twin on the next refresh');
  assert.notEqual(await integrity(db), before);
}));

test('coexists with the old sparse-twin rule; refresh never touches identities or follows', () => withDb(async (db) => {
  await storeSquad(db, [
    { id: 'ext-full', name: 'Jose Estrada', number: 198, age: 19, dateOfBirth: '2007-05-31', matchPlayed: 0 },
    { id: 'ext-sparse', name: 'Estrada Jose', number: 198 },
    { id: 'ext-dup', name: 'Jose Estrada', number: 250, age: 19, dateOfBirth: '2007-05-31' },
  ]);
  const shown = await squad(db);
  assert.equal(shown.length, 1);
  assert.equal(shown[0].id, await pidOf(db, 'ext-full'));
  const before = await integrity(db);
  assert.equal(await refresh(db), 2);
  assert.equal(await integrity(db), before);
}));
