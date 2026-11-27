import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import { normalizeGoalApiSquad } from '../providers/goal_api_players.mjs';

// PRODUCTION line of squad twins, exactly as rebuilt from the migrations (FB-09 v2, 20261127040600, plus the
// production team_squad_hidden_twins recorded in 20261127040700). Main's BE10 P0.3 line is NOT applied here;
// it has its own tests (squad_player_identity_dedup / squad_twins_same_birth_date) on an undeployed fixture.
// Cases mirror the FB-09 kit (recovery-03/fb-play-17/fb09/kit-r3/t_fb09.sh, 20/20 on the production export).
// Display only: nothing is ever merged or redirected. Generic fixtures, except the ZED FC names from the kit.
const cdn = (name) => `https://media.goal-api.com/players/${name}.png`;
const T1 = '2026-11-20T00:00:00Z';
const TEAM = 'fb_team_twins_v2';

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await db.query(`insert into futbeat_private.entities values ('${TEAM}','team','{"id":"${TEAM}","name":"Club V2"}')`);
    await db.query("insert into futbeat_private.provider_entities values('goal_api','team','goal-team-v2',$1)", [TEAM]);
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
const squadNames = async (db) =>
  (await one(db, 'select public.futbeat_read_entity_detail($1,$2) v', ['team', TEAM])).players
    .filter((p) => p.teamId === TEAM).map((p) => p.name).sort();
const pidOf = (db, ext) => one(db,
  "select futbeat_private.futbeat_resolve_entity_id('player',canonical_id) v from futbeat_private.provider_entities where provider='goal_api' and kind='player' and external_id=$1", [ext]);
const redirects = (db) => one(db, "select count(*)::int v from futbeat_private.entity_redirects where kind='player'");
const pair = (sparse, full, extra = {}) => [{ id: 'p-a', ...sparse }, { id: 'p-b', ...full, photo: cdn('p-b'), dateOfBirth: '1997-09-25', ...extra }];

test('production v2: the rebuilt functions are the production ones', () => withDb(async (db) => {
  const md5 = (sig) => one(db, 'select md5(pg_get_functiondef($1::regprocedure)) v', [sig]);
  const src = (sig) => one(db, "select md5(replace(prosrc,chr(13),'')) v from pg_proc where oid=$1::regprocedure", [sig]);
  assert.equal(await md5('futbeat_private.team_squad_twin_aliases(text)'), '2ef0e7d73f9700877ca20193d7f0dfa3');
  assert.equal(await md5('futbeat_private.squad_names_compatible(text,text)'), '8481ac2bba93b2a76dc8c0380c49d16a');
  assert.equal(await src('futbeat_private.team_squad_hidden_twins(text)'), '6ebd8dca53bb117fa83abddca2de8aa4');
  assert.equal(await src('futbeat_private.player_identity_richness(jsonb)'), 'df79415008fabd4dd68eff48b579ad99');
  // owner-only, as in production (postgres=X/postgres)
  for (const sig of ['futbeat_private.team_squad_twin_aliases(text)', 'futbeat_private.team_squad_hidden_twins(text)',
    'futbeat_private.squad_names_compatible(text,text)', 'futbeat_private.squad_fold_name(text)']) {
    for (const role of ['anon', 'authenticated']) {
      assert.equal(await one(db, 'select has_function_privilege($1,$2,\'execute\') v', [role, sig]), false, `${role} ${sig}`);
    }
  }
}));

test('production v2: ZED FC "A. Messi" #14 is shown once as "Messi" (kit case)', () => withDb(async (db) => {
  await storeSquad(db, pair({ name: 'A. Messi', number: 14 }, { name: 'Messi', number: 14 }));
  assert.deepEqual(await squadNames(db), ['Messi']);
  assert.equal(await redirects(db), 0);
}));

test('production v2: the v1 pair (same tokens, other order) is still one person', () => withDb(async (db) => {
  await storeSquad(db, pair({ name: 'Rafael Mora', number: 2 }, { name: 'Mora Rafael', number: 2 }));
  assert.deepEqual(await squadNames(db), ['Mora Rafael']);
}));

test('production v2: two different known birth dates are never one person', () => withDb(async (db) => {
  await storeSquad(db, [{ id: 'p-a', name: 'A. Messi', number: 14, dateOfBirth: '2001-02-03' },
    { id: 'p-b', name: 'Messi', number: 14, photo: cdn('p-b'), dateOfBirth: '1997-09-25' }]);
  assert.equal((await squadNames(db)).length, 2);
}));

test('production v2: three members on one shirt are never paired', () => withDb(async (db) => {
  await storeSquad(db, [{ id: 'p-a', name: 'A. Messi', number: 14 }, { id: 'p-b', name: 'Messi', number: 14, photo: cdn('p-b') },
    { id: 'p-c', name: 'L. Messi', number: 14 }]);
  assert.equal((await squadNames(db)).length, 3);
}));

test('production v2: a followed alias is never hidden', () => withDb(async (db) => {
  const rows = pair({ name: 'A. Messi', number: 14 }, { name: 'Messi', number: 14 });
  await storeSquad(db, rows);
  const user = '00000000-0000-4000-8000-0000000000f7';
  await db.query("insert into futbeat_private.push_follows values($1,'player',$2,now())", [user, await pidOf(db, 'p-a')]);
  await storeSquad(db, rows, '2026-11-21T00:00:00Z');
  assert.equal((await squadNames(db)).length, 2);
}));

test('production v2: the manual merge script never merges a pair hidden only by name', () => withDb(async (db) => {
  await storeSquad(db, [{ id: 'p-a', name: 'A. Messi', number: 14 }, { id: 'p-b', name: 'Messi', number: 14, photo: cdn('p-b'), dateOfBirth: '1997-09-25' },
    { id: 'v-a', name: 'Rafael Mora', number: 2 }, { id: 'v-b', name: 'Mora Rafael', number: 2, photo: cdn('v-b'), dateOfBirth: '1990-01-01' }]);
  assert.deepEqual(await squadNames(db), ['Messi', 'Mora Rafael']);
  const script = await readFile(new URL('../../supabase/manual/2026-10-01_squad_player_identity_merge.sql', import.meta.url), 'utf8');
  const rows = (await db.query(script.slice(script.indexOf('-- [dry-run]'), script.indexOf('-- [apply]')))).rows;
  assert.deepEqual(rows.map((r) => r.alias_name), ['Rafael Mora'], 'only v1 evidence is a merge candidate');
  assert.equal(await redirects(db), 0);
}));

// Known production v2 results that look ambiguous. NOT asserted either way: changing them is an owner decision
// (proposal recovery-03/fb-play-17/fb09/v21-proposal; measured impact on 2,335 production pairs: 0, 0 and 1).
test.todo('production v2 open question: "Alex Silva" vs "Alex Silva Junior" #10 (trailing generational suffix)');
test.todo('production v2 open question: "Silva Silva" vs "Alex Silva" #4 (repeated token)');
test.todo('production v2 open question: "Pierre Mendy" vs "Jean-Pierre Mendy" #6 (partial compound given name)');
