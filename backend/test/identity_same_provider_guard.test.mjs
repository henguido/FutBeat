import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// 20261005020000: two ids of the SAME provider are never merged by name
// alone (production: Andorra's national side, named "Andorra CF" by GOAL, was
// mapped onto the Spanish club "Andorra CF"; 65 same-name merges in total).

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const resolve = (db, provider, kind, external, name, country = '') => db.query(
  'select futbeat_private.futbeat_resolve_global_entity($1,$2,$3,$4,$5,$6) v',
  [provider, kind, external, name, country, ''],
).then((r) => r.rows[0].v);

test('a club and a national side with the same provider name stay two teams', () => withDb(async (db) => {
  const club = await resolve(db, 'goal_api', 'team', 'club-ext', 'Andorra CF');
  const national = await resolve(db, 'goal_api', 'team', 'national-ext', 'Andorra CF');
  assert.notEqual(national, club);
  // Each id keeps resolving to its own canonical (idempotent).
  assert.equal(await resolve(db, 'goal_api', 'team', 'club-ext', 'Andorra CF'), club);
  assert.equal(await resolve(db, 'goal_api', 'team', 'national-ext', 'Andorra CF'), national);
}));

test('same-named clubs of different countries (same provider, no country) are never merged', () => withDb(async (db) => {
  const ids = new Set();
  for (const ext of ['nacional-uy', 'nacional-py', 'nacional-pt']) ids.add(await resolve(db, 'goal_api', 'team', ext, 'Nacional'));
  assert.equal(ids.size, 3);
}));

test('a redirected alias holding the other id also blocks the name merge', () => withDb(async (db) => {
  const alias = await resolve(db, 'goal_api', 'team', 'old-ext', 'River Plate');
  await db.query("insert into futbeat_private.entities values('fb_team_target','team',$1)", [JSON.stringify({ id: 'fb_team_target', name: 'River Plate', country: '' })]);
  await db.query("select futbeat_private.futbeat_register_entity_redirect('team',$1,'fb_team_target','test')", [alias]);
  assert.notEqual(await resolve(db, 'goal_api', 'team', 'new-ext', 'River Plate'), 'fb_team_target');
}));

test('a corroborating country still lets a re-issued id of the same provider merge', () => withDb(async (db) => {
  const first = await resolve(db, 'goal_api', 'team', 'ext-a', 'Herediano', 'Costa Rica');
  assert.equal(await resolve(db, 'goal_api', 'team', 'ext-b', 'Herediano', 'Costa Rica'), first);
}));

test('cross-provider name matching is unchanged', () => withDb(async (db) => {
  const goal = await resolve(db, 'goal_api', 'team', 'goal-1', 'Saprissa');
  assert.equal(await resolve(db, 'sofascore', 'team', 'sofa-1', 'Saprissa'), goal);
}));

test('competitions follow the same rule (two same-named leagues of one provider stay apart)', () => withDb(async (db) => {
  const a = await resolve(db, 'goal_api', 'competition', 'league-a', 'Primera Division');
  const b = await resolve(db, 'goal_api', 'competition', 'league-b', 'Primera Division');
  assert.notEqual(a, b);
}));
