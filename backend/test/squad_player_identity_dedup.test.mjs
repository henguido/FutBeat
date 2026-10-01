import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import { normalizeGoalApiSquad } from '../providers/goal_api_players.mjs';

// One real person = one row in a squad. GOAL's squad answer can list the same
// person twice under two catalog ids: a complete record and a sparse twin
// whose name tokens are in another order, same shirt number. The read side
// hides that twin under a deliberately conservative rule; nothing merges
// automatically. Generic fixtures only.

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

async function storeSquad(db, teamId, rows, stamp = T1) {
  const squad = await normalized(db, teamId, rows, stamp);
  return one(db, 'select public.futbeat_store_team_squad($1,$2,$3,$4) v', [teamId, 'goal_api', stamp, JSON.stringify(squad)]);
}

const detail = (db, type, id) => one(db, 'select public.futbeat_read_entity_detail($1,$2) v', [type, id]);
const squadNames = async (db, teamId = TEAM) =>
  (await detail(db, 'team', teamId)).players.filter((p) => p.teamId === teamId).map((p) => p.name).sort();
const pidOf = (db, ext) => one(db,
  "select futbeat_private.futbeat_resolve_entity_id('player',canonical_id) v from futbeat_private.provider_entities where provider='goal_api' and kind='player' and external_id=$1", [ext]);
const memberCount = (db, teamId = TEAM) => one(db,
  'select count(*)::int v from futbeat_private.team_squad_members where team_id=$1', [teamId]);
const playerRedirects = (db) => one(db, "select count(*)::int v from futbeat_private.entity_redirects where kind='player'");
const merge = (db, alias, kept) => one(db,
  "select futbeat_private.futbeat_merge_player_identity($1,$2,'test') v", [alias, kept]);

// The real GOAL pattern: complete record + sparse reversed-name twin, same answer.
const rich = (id, name, number) => ({ id, name, number, age: 28, dateOfBirth: '1998-04-03', photo: cdn(id), matchPlayed: 14 });
const twinRows = [
  rich('full-1', 'Ana Maria Ruiz', 3),
  { id: 'sparse-1', name: 'Ruiz Ana Maria', number: 3 },
  { id: 'solo-1', name: 'Diego Solano', number: 9, photo: cdn('solo-1') },
];

test('read: the sparse reversed-name twin of a complete record is shown once', () => withDb(async (db) => {
  const result = await storeSquad(db, TEAM, twinRows);
  assert.equal(result.duplicateRows, 0);
  // Ingestion stores both provider identities; nothing merges.
  assert.equal(await memberCount(db), 3);
  assert.notEqual(await pidOf(db, 'full-1'), await pidOf(db, 'sparse-1'));
  assert.equal(await playerRedirects(db), 0);
  const team = await detail(db, 'team', TEAM);
  const squad = team.players.filter((p) => p.teamId === TEAM);
  assert.deepEqual(squad.map((p) => p.name).sort(), ['Ana Maria Ruiz', 'Diego Solano']);
  assert.equal(squad.find((p) => p.name === 'Ana Maria Ruiz').media.url, cdn('full-1'));
  assert.equal(team.coverage.squad.playerCount, 2);
  const coverage = (await db.query('select player_count,media_count from futbeat_private.team_detail_coverage where team_id=$1', [TEAM])).rows[0];
  assert.deepEqual(coverage, { player_count: 2, media_count: 2 });
}));

// Reviewer probes: each pair must stay two people. The second row is always
// rich, so only the name/number/fetch rule can reject the collapse.
const probes = [
  ['subset name, same number', { name: 'Juan Perez', number: 5 }, { name: 'Juan Carlos Perez Lopez', number: 5 }],
  ['father/son suffix', { name: 'Alex Silva', number: 10 }, { name: 'Alex Silva Junior', number: 10 }],
  ['subset name, number 1', { name: 'Luis Lopez', number: 1 }, { name: 'Luis Angel Lopez', number: 1 }],
  ['identical name, one number unknown', { name: 'Jose Hernandez' }, { name: 'Jose Hernandez', number: 3 }],
  ['identical name, both numbers unknown', { name: 'Kevin Gomez' }, { name: 'Kevin Gomez' }],
  ['identical name, number 0', { name: 'Kevin Gomez', number: 0 }, { name: 'Kevin Gomez', number: 0 }],
  ['reversed name, number unknown', { name: 'Gabriel Jesus' }, { name: 'Jesus Gabriel', number: 9 }],
  ['repeated tokens', { name: 'Silva Silva', number: 4 }, { name: 'Alex Silva', number: 4 }],
  ['letters outside the fold list', { name: 'Marko Đurić', number: 5 }, { name: 'Marko Ćurić', number: 5 }],
  ['same unfoldable name', { name: 'Łukasz Nowak', number: 5 }, { name: 'Nowak Łukasz', number: 5 }],
  ['hyphenated subset', { name: 'Jean-Pierre Mendy', number: 6 }, { name: 'Pierre Mendy', number: 6 }],
  ['one token', { name: 'Neymar', number: 10 }, { name: 'Neymar', number: 10 }],
  ['different numbers', { name: 'Luis Vega', number: 6 }, { name: 'Vega Luis', number: 12 }],
];
for (const [label, sparse, full] of probes) {
  test(`read: never collapsed - ${label}`, () => withDb(async (db) => {
    await storeSquad(db, TEAM, [{ id: 'p-a', ...sparse }, { id: 'p-b', ...full, photo: cdn('p-b'), dateOfBirth: '1990-01-01' }]);
    assert.equal((await squadNames(db)).length, 2);
    assert.equal(await playerRedirects(db), 0);
  }));
}

test('read: never collapsed - two rich, two sparse, or three candidates', () => withDb(async (db) => {
  await storeSquad(db, TEAM, [
    { id: 'r-a', name: 'Pedro Mora', number: 2, photo: cdn('r-a') }, { id: 'r-b', name: 'Mora Pedro', number: 2, dateOfBirth: '1990-01-01' },
    { id: 's-a', name: 'Ivan Rojas', number: 4 }, { id: 's-b', name: 'Rojas Ivan', number: 4 },
    { id: 't-a', name: 'Mario Soto', number: 7 }, { id: 't-b', name: 'Mario Soto', number: 7 },
    { id: 't-c', name: 'Soto Mario', number: 7, photo: cdn('t-c') },
  ]);
  assert.equal((await squadNames(db)).length, 7);
}));

test('read: a stale member never pairs with a later answer', () => withDb(async (db) => {
  await storeSquad(db, TEAM, [{ id: 'old-1', name: 'Rafael Mora', number: 2 }, { id: 'fill', name: 'Filler Uno', number: 8 }], T1);
  // The next answer omits old-1 (retained) and lists a complete twin.
  await storeSquad(db, TEAM, [rich('new-1', 'Mora Rafael', 2), { id: 'fill', name: 'Filler Uno', number: 8 }], T2);
  assert.equal(await memberCount(db), 3);
  assert.deepEqual(await squadNames(db), ['Filler Uno', 'Mora Rafael', 'Rafael Mora']);
}));

test('ingestion: two rows of one canonical identity keep the established row and name', () => withDb(async (db) => {
  await storeSquad(db, TEAM, twinRows);
  const kept = await pidOf(db, 'full-1');
  await merge(db, await pidOf(db, 'sparse-1'), kept);
  // The normalizer keeps the richer of two rows of one identity, in any order.
  const squad = await normalized(db, TEAM, [...twinRows].reverse(), T2);
  assert.equal(squad.length, 2);
  assert.equal(squad.find((p) => p.id === kept).provenance.externalId, 'full-1');
  // A worker still sending both rows, sparse last: one row, established name.
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
  // Only the sparse row: the identity keeps its name and photo.
  const later = '2026-09-29T00:00:00Z';
  await one(db, 'select public.futbeat_store_team_squad($1,$2,$3,$4) v', [TEAM, 'goal_api', later,
    JSON.stringify([{ ...sparseRow, provenance: { ...sparseRow.provenance, receivedAt: later } }])]);
  payload = await one(db, 'select payload v from futbeat_private.entities where id=$1', [kept]);
  assert.equal(payload.name, 'Ana Maria Ruiz');
  assert.equal(payload.media.url, cdn('full-1'));
}));

test('merge tool: audit, facts, birth-date conflict, cycle, idempotence', () => withDb(async (db) => {
  await db.query(`insert into futbeat_private.entities values
    ('fb_player_keep','player','{"id":"fb_player_keep","name":"Ana Ruiz","teamId":"${TEAM}","country":""}'),
    ('fb_player_alias','player','{"id":"fb_player_alias","name":"Ruiz Ana","country":"Costa Rica","dateOfBirth":"1998-04-03","shirtNumber":3}'),
    ('fb_player_dob_a','player','{"id":"fb_player_dob_a","name":"Leo Paz","dateOfBirth":"1990-01-01"}'),
    ('fb_player_dob_b','player','{"id":"fb_player_dob_b","name":"Paz Leo","dateOfBirth":"1995-05-05"}')`);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','player','ext-alias','fb_player_alias')");
  const user = '00000000-0000-4000-8000-000000000001';
  await db.query("insert into futbeat_private.push_follows values($1,'player','fb_player_alias',now())", [user]);
  assert.equal((await merge(db, 'fb_player_alias', 'fb_player_keep')).status, 'merged');
  const kept = await one(db, "select payload v from futbeat_private.entities where id='fb_player_keep'");
  assert.equal(kept.name, 'Ana Ruiz');
  assert.equal(kept.country, 'Costa Rica');
  assert.equal(kept.dateOfBirth, '1998-04-03');
  assert.equal(kept.shirtNumber, 3);
  assert.deepEqual(kept.aliases, ['Ruiz Ana']);
  assert.equal(await pidOf(db, 'ext-alias'), 'fb_player_keep');
  assert.equal(await one(db, 'select entity_id v from futbeat_private.push_follows where user_id=$1', [user]), 'fb_player_keep');
  const audit = (await db.query('select * from futbeat_private.player_identity_merges')).rows[0];
  assert.equal(audit.alias_id, 'fb_player_alias');
  assert.deepEqual(audit.moved_provider_ids, ['ext-alias']);
  assert.equal(audit.canonical_payload_before.country, '');
  assert.equal(audit.moved_follows[0].keptHadFollow, false);
  assert.equal((await merge(db, 'fb_player_alias', 'fb_player_keep')).status, 'already_merged');
  await assert.rejects(merge(db, 'fb_player_keep', 'fb_player_alias'), /cycle/);
  await assert.rejects(merge(db, 'fb_player_dob_b', 'fb_player_dob_a'), /conflicting birth dates/);
}));

test('merge tool: only the kept player\'s current team gains the membership', () => withDb(async (db) => {
  // The sparse id was in the old club's earlier answer; the new club lists both.
  await storeSquad(db, 'fb_team_other', [{ id: 'sparse-1', name: 'Ruiz Ana Maria', number: 3 }, { id: 'o2', name: 'Otro Uno', number: 8 }], T1);
  await storeSquad(db, TEAM, twinRows, T2);
  const kept = await pidOf(db, 'full-1');
  await merge(db, await pidOf(db, 'sparse-1'), kept);
  assert.deepEqual(await squadNames(db, 'fb_team_other'), ['Otro Uno']);
  assert.deepEqual(await squadNames(db), ['Ana Maria Ruiz', 'Diego Solano']);
}));

test('snapshots ship only the player redirects their players need', () => withDb(async (db) => {
  await storeSquad(db, TEAM, twinRows);
  await storeSquad(db, 'fb_team_other', [{ id: 'other-1', name: 'Otro Jugador', number: 1 }]);
  const alias = await pidOf(db, 'sparse-1');
  const kept = await pidOf(db, 'full-1');
  await merge(db, alias, kept);
  assert.deepEqual((await detail(db, 'team', TEAM)).entityRedirects, { [alias]: kept });
  assert.deepEqual((await detail(db, 'team', 'fb_team_other')).entityRedirects, {});
  const profile = await detail(db, 'player', alias);
  assert.equal(profile.players[0].id, kept);
  // Search for the variant name finds the one identity, once.
  const search = await one(db, "select public.futbeat_search_catalog('ruiz',null,50) v");
  assert.deepEqual(search.players.filter((p) => /ruiz/i.test(p.name)).map((p) => p.id), [kept]);
}));

test('lineup bridge ignores a merged alias as a second candidate', () => withDb(async (db) => {
  await storeSquad(db, TEAM, [rich('full-x', 'Lucas Pereira', 8), { id: 'sparse-x', name: 'Lucas Pereira', number: 8 }]);
  const kept = await pidOf(db, 'full-x');
  assert.equal(await one(db,
    "select futbeat_private.bridge_player_identity('99887766','Lucas Pereira','goal-team-dedup') v"), null);
  await merge(db, await pidOf(db, 'sparse-x'), kept);
  assert.equal(await one(db,
    "select futbeat_private.bridge_player_identity('99887766','Lucas Pereira','goal-team-dedup') v"), kept);
}));

test('entity_redirects keeps exactly one kind check', () => withDb(async (db) => {
  assert.equal(await one(db, `select count(*)::int v from pg_constraint
    where conrelid='futbeat_private.entity_redirects'::regclass and contype='c'
      and pg_get_constraintdef(oid) ~ '\\mkind\\M'`), 1);
  await assert.rejects(db.query(
    "insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values('fb_team_other','fb_team_dedup','match','x')"));
}));

test('manual merge script: dry-run lists exactly the hidden twins, apply merges them', () => withDb(async (db) => {
  await storeSquad(db, TEAM, [...twinRows, { id: 'p-a', name: 'Juan Perez', number: 5 },
    rich('p-b', 'Juan Carlos Perez Lopez', 5)]);
  const script = await readFile(new URL('../../supabase/manual/2026-10-01_squad_player_identity_merge.sql', import.meta.url), 'utf8');
  const dryRun = script.slice(script.indexOf('-- [dry-run]'), script.indexOf('-- [apply]'));
  const apply = script.slice(script.indexOf('-- [apply]'));
  const rows = (await db.query(dryRun)).rows;
  assert.equal(rows.length, 1);
  assert.equal(Number(rows[0].candidate_count), 1);
  assert.equal(rows[0].kept_name, 'Ana Maria Ruiz');
  await assert.rejects(db.exec(apply.replace('__EXPECTED_COUNT__', '2')), /expected 2/);
  assert.equal(await playerRedirects(db), 0);
  await db.exec(apply.replace('__EXPECTED_COUNT__', '1'));
  assert.equal(await playerRedirects(db), 1);
  assert.equal(await pidOf(db, 'sparse-1'), await pidOf(db, 'full-1'));
  assert.notEqual(await pidOf(db, 'p-a'), await pidOf(db, 'p-b'));
  assert.equal((await db.query(dryRun)).rows.length, 0);
}));

test('read-side dedup stays cheap on a large accumulated squad', () => withDb(async (db) => {
  const N = 150;
  await db.query(`insert into futbeat_private.entities select 'fb_player_perf_'||g,'player',
    jsonb_build_object('id','fb_player_perf_'||g,'name','Nombre'||(g%50)||' Apellido'||(g%37)||' X',
      'shirtNumber',(g%40)+1,'teamId','${TEAM}') from generate_series(1,${N}) g`);
  await db.query(`insert into futbeat_private.team_squad_members(team_id,player_id,provider,updated_at)
    select '${TEAM}','fb_player_perf_'||g,'goal_api',now() from generate_series(1,${N}) g`);
  // One twin pair among them, found when the answer is stored.
  await db.query(`update futbeat_private.entities set payload=payload||jsonb_build_object('name','Twin Uno','shirtNumber',99)
    where id='fb_player_perf_1'`);
  await db.query(`update futbeat_private.entities set payload=payload||jsonb_build_object('name','Uno Twin','shirtNumber',99,
    'dateOfBirth','1990-01-01') where id='fb_player_perf_2'`);
  const t0 = performance.now();
  assert.equal(await one(db, 'select futbeat_private.refresh_team_squad_twins($1) v', [TEAM]), 1);
  const refresh = performance.now() - t0;
  const time = async (sql) => {
    await db.query(sql, [TEAM]);
    const t = performance.now();
    for (let i = 0; i < 5; i += 1) await db.query(sql, [TEAM]);
    return (performance.now() - t) / 5;
  };
  const withDedup = await time("select public.futbeat_read_entity_detail('team',$1)");
  const base = await time("select futbeat_private.read_entity_detail_before_squad_dedup('team',$1)");
  const ids = await time('select count(*) from futbeat_private.team_squad_player_ids($1)');
  const state = await time('select futbeat_private.team_squad_state($1)');
  console.log(`squad dedup N=${N}: store-time refresh ${refresh.toFixed(1)}ms; read: detail ${withDedup.toFixed(1)}ms,`
    + ` base ${base.toFixed(1)}ms, ids ${ids.toFixed(1)}ms, state ${state.toFixed(1)}ms`);
  assert.equal(await one(db, 'select count(*)::int v from futbeat_private.team_squad_player_ids($1)', [TEAM]), N - 1);
  // Generous bound for slow CI; measured locally in the report.
  assert.ok(ids + state < 100, `squad ids+state took ${ids + state}ms`);
}));
