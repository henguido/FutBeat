import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import { normalizeGoalApiSquad } from '../providers/goal_api_players.mjs';

// One real person = one player identity. GOAL's squad answer can list the
// same person twice under two catalog ids (a complete record and a sparse one
// with the name reversed or shortened, same shirt number). Generic fixtures.

const cdn = (name) => `https://media.goal-api.com/players/${name}.png`;
const T1 = '2026-09-20T00:00:00Z';
const T2 = '2026-09-28T00:00:00Z';
const TEAM = 'fb_team_dedup';

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities values
      ('${TEAM}','team','{"id":"${TEAM}","name":"Club Uno"}'),
      ('fb_team_other','team','{"id":"fb_team_other","name":"Club Dos"}')`);
    await db.query("insert into futbeat_private.provider_entities values('goal_api','team','goal-team-dedup',$1)", [TEAM]);
    await fn(db);
    assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 0);
  } finally { await db.close(); }
}

const one = async (db, sql, params = []) => (await db.query(sql, params)).rows[0]?.v;

async function normalized(db, teamId, rows, stamp) {
  return normalizeGoalApiSquad(rows, teamId, async (kind, external, identity) => one(db,
    'select public.futbeat_resolve_global_entity($1,$2,$3,$4) v', ['goal_api', kind, external, identity.name]), stamp);
}

// The squad path as deployed (worker -> public wrapper).
async function storeSquad(db, teamId, rows, stamp = T1) {
  const squad = await normalized(db, teamId, rows, stamp);
  return one(db, 'select public.futbeat_store_team_squad($1,$2,$3,$4) v', [teamId, 'goal_api', stamp, JSON.stringify(squad)]);
}

// How production stored squads before this fix: every provider id its own member.
async function storeSquadPreFix(db, teamId, rows, stamp = T1) {
  const squad = await normalized(db, teamId, rows, stamp);
  await db.query('select futbeat_private.store_team_squad_before_identity_dedup($1,$2,$3,$4)',
    [teamId, 'goal_api', stamp, JSON.stringify(squad)]);
}

const detail = (db, type, id) => one(db, 'select public.futbeat_read_entity_detail($1,$2) v', [type, id]);
const squadNames = async (db, teamId = TEAM) =>
  (await detail(db, 'team', teamId)).players.filter((p) => p.teamId === teamId).map((p) => p.name).sort();
const pidOf = (db, ext) => one(db,
  "select futbeat_private.futbeat_resolve_entity_id('player',canonical_id) v from futbeat_private.provider_entities where provider='goal_api' and kind='player' and external_id=$1", [ext]);
const memberCount = (db, teamId = TEAM) => one(db,
  'select count(*)::int v from futbeat_private.team_squad_members where team_id=$1', [teamId]);

// A complete record and its sparse twin (reversed / shortened name, same number).
const twinRows = [
  { id: 'full-1', name: 'Ana Maria Ruiz', number: 3, age: 28, dateOfBirth: '1998-04-03', photo: cdn('full-1'), matchPlayed: 14 },
  { id: 'sparse-1', name: 'Ruiz Ana Maria', number: 3 },
  { id: 'full-2', name: 'Carlos Eduardo Brenes Mora', number: 4, age: 31, photo: cdn('full-2') },
  { id: 'sparse-2', name: 'Brenes Mora', number: 4 },
  { id: 'solo-1', name: 'Diego Solano', number: 9, photo: cdn('solo-1') },
];

test('read: a stored duplicate is shown once, the richer identity with its photo', () => withDb(async (db) => {
  await storeSquadPreFix(db, TEAM, twinRows);
  assert.equal(await memberCount(db), 5);
  const team = await detail(db, 'team', TEAM);
  const squad = team.players.filter((p) => p.teamId === TEAM);
  assert.deepEqual(squad.map((p) => p.name).sort(), ['Ana Maria Ruiz', 'Carlos Eduardo Brenes Mora', 'Diego Solano']);
  assert.ok(squad.every((p) => p.media?.verificationStatus === 'VERIFIED'));
  assert.equal(team.coverage.squad.playerCount, 3);
  // Read only: nothing was merged or deleted.
  assert.equal(await memberCount(db), 5);
  assert.equal(await one(db, "select count(*)::int v from futbeat_private.entity_redirects where kind='player'"), 0);
}));

test('read: different people are never collapsed', () => withDb(async (db) => {
  await storeSquadPreFix(db, TEAM, [
    // Same name, two different known numbers: two people.
    { id: 'tw-a', name: 'Luis Vega', number: 6 }, { id: 'tw-b', name: 'Luis Vega', number: 12 },
    // Same number, unrelated names.
    { id: 'n-a', name: 'Pedro Alfaro', number: 16 }, { id: 'n-b', name: 'Jose Prieto', number: 16 },
    // One token is not enough evidence.
    { id: 'mono-a', name: 'Neymar', number: 10 }, { id: 'mono-b', name: 'Neymar', number: 10 },
    // Initials without a number: not identical full names.
    { id: 'ini-a', name: 'K. Gonzalez' }, { id: 'ini-b', name: 'Gonzalez K.', number: 38 },
    // Ambiguous: one numberless "Mario Soto" next to two numbered ones.
    { id: 'amb-0', name: 'Mario Soto' }, { id: 'amb-1', name: 'Mario Soto', number: 5 },
    { id: 'amb-2', name: 'Soto Mario', number: 7 },
  ]);
  assert.equal((await squadNames(db)).length, 11);
}));

test('read: identical full names with an unknown number are one person', () => withDb(async (db) => {
  await storeSquadPreFix(db, TEAM, [
    { id: 'u-a', name: 'Marcos Mina', number: 14, photo: cdn('u-a') }, { id: 'u-b', name: 'Mina Marcos' },
    { id: 'u-c', name: 'Gabriel Jesus', position: 'Attacker' }, { id: 'u-d', name: 'Jesús Gabriel', number: 0 },
  ]);
  assert.deepEqual(await squadNames(db), ['Gabriel Jesus', 'Marcos Mina']);
}));

test('ingestion: one squad answer listing a person twice stores one identity and merges the other', () => withDb(async (db) => {
  const result = await storeSquad(db, TEAM, twinRows);
  assert.equal(result.duplicateRows, 2);
  assert.equal(result.identitiesMerged, 2);
  assert.equal(await memberCount(db), 3);
  assert.deepEqual(await squadNames(db), ['Ana Maria Ruiz', 'Carlos Eduardo Brenes Mora', 'Diego Solano']);

  // Every provider id of the person resolves to the one kept identity.
  const kept = await pidOf(db, 'full-1');
  assert.equal(await pidOf(db, 'sparse-1'), kept);
  const keptPayload = await one(db, 'select payload v from futbeat_private.entities where id=$1', [kept]);
  assert.equal(keptPayload.name, 'Ana Maria Ruiz');
  assert.equal(keptPayload.provenance.externalId, 'full-1');
  assert.deepEqual(keptPayload.aliases, ['Ruiz Ana Maria']);

  // The alias entity row stays (old links) and redirects to the kept player.
  const alias = await one(db,
    "select alias_id v from futbeat_private.entity_redirects where kind='player' and canonical_id=$1", [kept]);
  assert.ok(alias);
  assert.equal(await one(db, "select count(*)::int v from futbeat_private.entities where id=$1 and kind='player'", [alias]), 1);
  const profile = await detail(db, 'player', alias);
  assert.equal(profile.players[0].id, kept);
  assert.equal(profile.players[0].media.url, cdn('full-1'));
  assert.equal(profile.entityRedirects[alias], kept);
  assert.equal((await detail(db, 'team', TEAM)).entityRedirects[alias], kept);

  // Search for the variant name finds the one identity, once.
  const search = await one(db, "select public.futbeat_search_catalog('ruiz',null,50) v");
  const hits = search.players.filter((p) => p.name === 'Ana Maria Ruiz' || p.name === 'Ruiz Ana Maria');
  assert.deepEqual(hits.map((p) => p.id), [kept]);

  // The next fetch (both ids again) is stable: same identity, same name, no new merge.
  // The normalizer already keeps the richer of two rows of one identity.
  const reversed = [...twinRows].reverse();
  const squad = await normalized(db, TEAM, reversed, T2);
  assert.equal(squad.length, 3);
  assert.equal(squad.find((p) => p.id === kept).provenance.externalId, 'full-1');
  const again = await storeSquad(db, TEAM, reversed, T2);
  assert.equal(again.identitiesMerged, 0);
  assert.equal(await memberCount(db), 3);
  const after = await one(db, 'select payload v from futbeat_private.entities where id=$1', [kept]);
  assert.equal(after.name, 'Ana Maria Ruiz');
  assert.equal(after.provenance.externalId, 'full-1');
  assert.equal(after.media.url, cdn('full-1'));
  assert.equal(after.dateOfBirth, '1998-04-03');
  const coverage = (await db.query('select player_count,media_count from futbeat_private.team_detail_coverage where team_id=$1', [TEAM])).rows[0];
  assert.deepEqual(coverage, { player_count: 3, media_count: 3 });
}));

test('ingestion: rows of one merged identity keep the established row and name, in any order', () => withDb(async (db) => {
  await storeSquad(db, TEAM, twinRows);
  const kept = await pidOf(db, 'full-1');
  // A worker that still sends both rows (same canonical id), sparse row last.
  const rows = await normalized(db, TEAM, twinRows, T2);
  const sparseRow = { ...rows.find((p) => p.id === kept), name: 'Ruiz Ana Maria', media: null, age: null,
    dateOfBirth: null, matchesPlayed: null, provenance: { source: 'GOAL API', externalId: 'sparse-1', receivedAt: T2,
      verificationStatus: 'PROVISIONAL', mediaSource: 'squad', mediaStatus: 'NO_PHOTO' } };
  const result = await one(db, 'select public.futbeat_store_team_squad($1,$2,$3,$4) v',
    [TEAM, 'goal_api', T2, JSON.stringify([...rows, sparseRow])]);
  assert.equal(result.duplicateRows, 1);
  let payload = await one(db, 'select payload v from futbeat_private.entities where id=$1', [kept]);
  assert.equal(payload.name, 'Ana Maria Ruiz');
  assert.equal(payload.provenance.externalId, 'full-1');
  // Only the sparse row this time: the identity keeps its name.
  await one(db, 'select public.futbeat_store_team_squad($1,$2,$3,$4) v',
    [TEAM, 'goal_api', '2026-09-29T00:00:00Z', JSON.stringify([{ ...sparseRow,
      provenance: { ...sparseRow.provenance, receivedAt: '2026-09-29T00:00:00Z' } }])]);
  payload = await one(db, 'select payload v from futbeat_private.entities where id=$1', [kept]);
  assert.equal(payload.name, 'Ana Maria Ruiz');
  assert.equal(payload.media.url, cdn('full-1'));
  assert.deepEqual(await squadNames(db), ['Ana Maria Ruiz', 'Carlos Eduardo Brenes Mora', 'Diego Solano']);
}));

test('ingestion: duplicates stored before the fix merge on the next refresh', () => withDb(async (db) => {
  await storeSquadPreFix(db, TEAM, twinRows);
  const sparse = await pidOf(db, 'sparse-1');
  const full = await pidOf(db, 'full-1');
  assert.notEqual(sparse, full);
  // A user followed the sparse identity and is browsing it.
  const user = '00000000-0000-4000-8000-000000000001';
  await db.query("insert into futbeat_private.push_follows values($1,'player',$2,now())", [user, sparse]);
  await db.query("insert into futbeat_private.temporary_interests values($1,'player',$2,now(),now()+interval '30 minutes')", [user, sparse]);

  const result = await storeSquad(db, TEAM, twinRows, T2);
  assert.equal(result.identitiesMerged, 2);
  assert.equal(await pidOf(db, 'sparse-1'), full);
  assert.equal(await memberCount(db), 3);
  assert.equal(await one(db, "select count(*)::int v from futbeat_private.team_squad_members where player_id=$1", [sparse]), 0);
  assert.equal(await one(db, "select entity_id v from futbeat_private.push_follows where user_id=$1", [user]), full);
  assert.equal(await one(db, "select entity_id v from futbeat_private.temporary_interests where user_id=$1", [user]), full);
}));

test('ingestion: two people with one name and different numbers stay two identities', () => withDb(async (db) => {
  const result = await storeSquad(db, TEAM, [
    { id: 'tw-a', name: 'Luis Vega', number: 6 }, { id: 'tw-b', name: 'Luis Vega', number: 12 },
    { id: 'n-a', name: 'Pedro Alfaro', number: 16 }, { id: 'n-b', name: 'Jose Prieto', number: 16 },
  ]);
  assert.equal(result.identitiesMerged, 0);
  assert.equal(result.duplicateRows, 0);
  assert.equal(await memberCount(db), 4);
  assert.notEqual(await pidOf(db, 'tw-a'), await pidOf(db, 'tw-b'));
}));

test('merge: fills only missing facts, refuses cycles, is idempotent', () => withDb(async (db) => {
  await db.query(`insert into futbeat_private.entities values
    ('fb_player_keep','player','{"id":"fb_player_keep","name":"Ana Ruiz","teamId":"${TEAM}","country":""}'),
    ('fb_player_alias','player','{"id":"fb_player_alias","name":"Ruiz Ana","country":"Costa Rica","dateOfBirth":"1998-04-03","shirtNumber":3}')`);
  const merge = (a, c) => one(db, "select futbeat_private.futbeat_merge_player_identity($1,$2,'test') v", [a, c]);
  assert.equal((await merge('fb_player_alias', 'fb_player_keep')).status, 'merged');
  const kept = await one(db, "select payload v from futbeat_private.entities where id='fb_player_keep'");
  assert.equal(kept.name, 'Ana Ruiz');
  assert.equal(kept.country, 'Costa Rica');
  assert.equal(kept.dateOfBirth, '1998-04-03');
  assert.equal(kept.shirtNumber, 3);
  assert.deepEqual(kept.aliases, ['Ruiz Ana']);
  assert.equal((await merge('fb_player_alias', 'fb_player_keep')).status, 'already_merged');
  await assert.rejects(merge('fb_player_keep', 'fb_player_alias'), /cycle/);
  // Team merges keep working with the widened kind check.
  await assert.rejects(db.query(
    "insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values('fb_team_other','${TEAM}','match','x')"));
}));

test('snapshots ship only the player redirects their players need', () => withDb(async (db) => {
  await storeSquad(db, TEAM, twinRows);
  await storeSquad(db, 'fb_team_other', [{ id: 'other-1', name: 'Otro Jugador', number: 1 }]);
  const own = await detail(db, 'team', TEAM);
  const other = await detail(db, 'team', 'fb_team_other');
  assert.equal(Object.keys(own.entityRedirects).length, 2);
  assert.deepEqual(other.entityRedirects, {});
}));

test('lineup bridge ignores a merged alias as a second candidate', () => withDb(async (db) => {
  await storeSquad(db, TEAM, [
    { id: 'full-x', name: 'Lucas Pereira', number: 8, photo: cdn('full-x') },
    { id: 'sparse-x', name: 'Lucas Pereira', number: 8 },
  ]);
  const kept = await pidOf(db, 'full-x');
  assert.equal(await one(db,
    "select futbeat_private.bridge_player_identity('99887766','Lucas Pereira','goal-team-dedup') v"), kept);
}));

test('manual merge script: dry-run lists the stored duplicates, apply merges exactly them', () => withDb(async (db) => {
  await storeSquadPreFix(db, TEAM, twinRows);
  // Same person in two different fetches is not same-fetch evidence: excluded.
  await storeSquadPreFix(db, 'fb_team_other', [{ id: 'late-a', name: 'Rafael Mora', number: 2 }], T1);
  await db.query("update futbeat_private.team_squad_members set updated_at=updated_at-interval '1 day' where team_id='fb_team_other'");
  await storeSquadPreFix(db, 'fb_team_other', [{ id: 'late-b', name: 'Mora Rafael', number: 2 }], T2);
  const script = await readFile(new URL('../../supabase/manual/2026-10-01_squad_player_identity_merge.sql', import.meta.url), 'utf8');
  const dryRun = script.slice(script.indexOf('-- [dry-run]'), script.indexOf('-- [apply]'));
  const apply = script.slice(script.indexOf('-- [apply]'));
  const rows = (await db.query(dryRun)).rows;
  assert.equal(rows.length, 2);
  assert.equal(Number(rows[0].candidate_count), 2);
  await assert.rejects(db.exec(apply.replace('__EXPECTED_COUNT__', '3')), /expected 3/);
  assert.equal(await one(db, "select count(*)::int v from futbeat_private.entity_redirects where kind='player'"), 0);
  await db.exec(apply.replace('__EXPECTED_COUNT__', '2'));
  assert.equal(await one(db, "select count(*)::int v from futbeat_private.entity_redirects where kind='player'"), 2);
  assert.equal(await pidOf(db, 'sparse-1'), await pidOf(db, 'full-1'));
  assert.equal(await memberCount(db), 3);
  assert.equal((await db.query(dryRun)).rows.length, 0);
}));
