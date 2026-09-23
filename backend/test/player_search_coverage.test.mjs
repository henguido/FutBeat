import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import { normalizeGoalApiSquad } from '../providers/goal_api_players.mjs';

const photo = (name) => `https://media.goal-api.com/players/${name}.png`;

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await fn(db);
    // Local harvest/search never reserves provider work.
    assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 0);
  } finally { await db.close(); }
}

async function players(db, rows) {
  await db.query(`insert into futbeat_private.entities(id,kind,payload)
    select item->>'id','player',item from jsonb_array_elements($1::jsonb) item`, [JSON.stringify(rows)]);
}

const search = async (db, query) => (await db.query(
  'select public.futbeat_search_catalog($1,null,50) v', [query])).rows[0].v.players.map((p) => p.name);

async function match(db) {
  const rows = [
    ['fb_comp_pc', 'competition', { id: 'fb_comp_pc', name: 'League', country: 'Spain' }],
    ['fb_team_pc_home', 'team', { id: 'fb_team_pc_home', name: 'Home FC', competitionId: 'fb_comp_pc' }],
    ['fb_team_pc_away', 'team', { id: 'fb_team_pc_away', name: 'Away FC', competitionId: 'fb_comp_pc' }],
    ['fb_match_pc', 'match', { id: 'fb_match_pc', competitionId: 'fb_comp_pc', homeTeamId: 'fb_team_pc_home',
      awayTeamId: 'fb_team_pc_away', startTime: '2026-09-01T18:00:00Z', status: 'VERIFIED', events: [], statistics: [] }],
  ];
  for (const [id, kind, payload] of rows) {
    await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
  }
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match','pc-ext','fb_match_pc')");
  for (const side of ['home', 'away']) {
    await db.query("insert into futbeat_private.provider_entities values('goal_api','team',$1,$2)",
      [`pc-${side}`, `fb_team_pc_${side}`]);
  }
}

const storeDetail = (db, payload, at = '2026-09-01T20:00:00Z') => db.query(
  "select futbeat_private.store_match_detail('fb_match_pc','pc-ext',$1,$2)", [at, JSON.stringify(payload)]);

const byExt = async (db, ext) => (await db.query(`select e.id,e.payload from futbeat_private.provider_entities pe
  join futbeat_private.entities e on e.id=pe.canonical_id where pe.provider='goal_api' and pe.kind='player'
  and pe.external_id=$1`, [ext])).rows[0];

// Object-shaped lineups were never harvested before this migration.
const objectLineups = {
  lineups: {
    home: {
      startingLineups: [{ playerId: 'ext-gk', lineupPlayer: 'Portero Harvest', lineupNumber: '1',
        playerPosition: 'G', playerCountry: 'Spain', playerImage: photo('gk') }],
      substitutes: [{ playerId: 'ext-sub', lineupPlayer: 'Suplente Harvest', lineupNumber: '17', playerPosition: 'F' }],
      coach: { playerId: 'ext-coach', lineupPlayer: 'Coach Not Player' },
    },
    away: { startingLineups: [{ playerId: 'ext-away', lineupPlayer: 'Visitante Harvest', lineupNumber: '10', playerPosition: 'M' }] },
  },
};

test('"messi" without Messi returns no unrelated player such as Mestre', () => withDb(async (db) => {
  await players(db, [
    { id: 'fb_player_mestre', name: 'Mestre' },
    { id: 'fb_player_mesa', name: 'Mesa Mestre' },
  ]);
  assert.deepEqual(await search(db, 'messi'), []);
  // A real partial still works for the unrelated player itself.
  assert.deepEqual(await search(db, 'mestre'), ['Mestre', 'Mesa Mestre']);
}));

test('exact player first, then prefix, word prefix, alias, then whole-word fuzzy', () => withDb(async (db) => {
  await players(db, [
    { id: 'fb_player_lm', name: 'Lionel Messi', aliases: ['La Pulga'] },
    { id: 'fb_player_mj', name: 'Messi Junior' },
    { id: 'fb_player_alias', name: 'Otro Jugador', aliases: ['Messi'] },
    { id: 'fb_player_messias', name: 'Messias' },
  ]);
  assert.deepEqual(await search(db, 'Lionel Messi'), ['Lionel Messi']);
  assert.deepEqual(await search(db, 'messi'), ['Messi Junior', 'Messias', 'Lionel Messi', 'Otro Jugador']);
  // Typo: whole-word fuzzy match only (the alias "Messi" also qualifies).
  assert.deepEqual(await search(db, 'mesi'), ['Lionel Messi', 'Messi Junior', 'Otro Jugador']);
  assert.deepEqual(await search(db, 'lionel mesi'), ['Lionel Messi']);
}));

test('multi-word queries do not return players sharing only one word', () => withDb(async (db) => {
  await players(db, [
    { id: 'fb_player_lm', name: 'Lionel Messi' },
    { id: 'fb_player_ls', name: 'Lionel Scaloni' },
    { id: 'fb_player_kc', name: 'Kevin Chamorro' },
    { id: 'fb_player_kdb', name: 'Kevin De Bruyne' },
  ]);
  assert.deepEqual(await search(db, 'lionel messi'), ['Lionel Messi']);
  assert.deepEqual(await search(db, 'kevin chamoro'), ['Kevin Chamorro']);
}));

test('aliases and accent-insensitive names resolve to the right player', () => withDb(async (db) => {
  await players(db, [
    { id: 'fb_player_lm', name: 'Lionel Messi', aliases: ['La Pulga'] },
    { id: 'fb_player_km', name: 'Kylian Mbappé' },
    { id: 'fb_player_pulgar', name: 'Erick Pulgar' },
  ]);
  assert.deepEqual((await search(db, 'la pulga'))[0], 'Lionel Messi');
  assert.deepEqual(await search(db, 'mbappe'), ['Kylian Mbappé']);
  assert.deepEqual(await search(db, 'MBAPPÉ'), ['Kylian Mbappé']);
}));

test('lineup harvest resolves both shapes and fills team, position, number, country and photo', () => withDb(async (db) => {
  await match(db);
  await storeDetail(db, objectLineups);
  const gk = await byExt(db, 'ext-gk');
  assert.equal(gk.payload.name, 'Portero Harvest');
  assert.equal(gk.payload.teamId, 'fb_team_pc_home');
  assert.deepEqual(gk.payload.lineupOwned, ['position', 'shirtNumber', 'teamId']);
  assert.equal(gk.payload.position, 'Goalkeeper');
  assert.equal(gk.payload.shirtNumber, 1);
  assert.equal(gk.payload.country, 'Spain');
  assert.equal(gk.payload.media.url, photo('gk'));
  assert.equal((await byExt(db, 'ext-away')).payload.teamId, 'fb_team_pc_away');
  assert.equal((await byExt(db, 'ext-sub')).payload.position, 'Forward');
  assert.equal(await byExt(db, 'ext-coach'), undefined);
  // Array shape keeps working, with side-aware team assignment.
  await storeDetail(db, { lineups: [{ team: 'away', type: 'starting_lineups', playerId: 'ext-array',
    lineupPlayer: 'Array Harvest', lineupNumber: '7', playerPosition: 'D' }] }, '2026-09-01T20:05:00Z');
  const arrayPlayer = await byExt(db, 'ext-array');
  assert.equal(arrayPlayer.payload.teamId, 'fb_team_pc_away');
  assert.equal(arrayPlayer.payload.position, 'Defender');
  const metrics = (await db.query('select public.futbeat_player_catalog_metrics() v')).rows[0].v;
  assert.equal(metrics.canonical_players, 4);
  assert.equal(metrics.indexed_players, 4);
  assert.equal(metrics.mapped_players, 4);
  assert.equal(metrics.with_team, 4);
  assert.equal(metrics.with_position, 4);
  assert.equal(metrics.with_shirt_number, 4);
  assert.equal(metrics.with_photo, 1);
  // Cache keeps the richer object lineup; its 3 appearances plus none unresolved.
  assert.equal(metrics.lineup_appearances_unresolved, 0);
  assert.ok(metrics.lineup_appearances_resolved >= 1);
}));

test('squad data stays authoritative over lineup metadata', () => withDb(async (db) => {
  await match(db);
  const stamp = '2026-09-02T00:00:00Z';
  const squad = await normalizeGoalApiSquad([{ id: 'ext-gk', name: 'Portero Harvest', position: 'Goalkeeper',
    number: 13, photo: photo('squad') }], 'fb_team_pc_away', async (kind, external, identity) =>
    (await db.query('select public.futbeat_resolve_global_entity($1,$2,$3,$4) id',
      ['goal_api', kind, external, identity.name])).rows[0].id, stamp);
  await db.query('select public.futbeat_store_team_squad($1,$2,$3,$4)',
    ['fb_team_pc_away', 'goal_api', stamp, JSON.stringify(squad)]);
  await storeDetail(db, objectLineups, '2026-09-03T00:00:00Z');
  const gk = await byExt(db, 'ext-gk');
  assert.equal(gk.payload.teamId, 'fb_team_pc_away');
  assert.equal(gk.payload.lineupOwned, undefined);
  assert.equal(gk.payload.position, 'Goalkeeper');
  assert.equal(gk.payload.shirtNumber, 13);
  // Squad player is findable immediately.
  assert.deepEqual(await search(db, 'portero harvest'), ['Portero Harvest']);
}));

test('identity is provider-ID based, idempotent and never merges by name', () => withDb(async (db) => {
  await match(db);
  await storeDetail(db, objectLineups);
  const first = await byExt(db, 'ext-gk');
  const count = async () => (await db.query("select count(*)::int n from futbeat_private.entities where kind='player'")).rows[0].n;
  const before = await count();
  const changed = (await db.query("select futbeat_private.harvest_lineup_players('fb_match_pc',$1,'2026-09-01T20:00:00Z') n",
    [JSON.stringify(objectLineups)])).rows[0].n;
  assert.equal(changed, 0);
  assert.equal(await count(), before);
  assert.equal((await byExt(db, 'ext-gk')).id, first.id);
  // Same name, different provider ID: a different person, never merged.
  await storeDetail(db, { lineups: [{ team: 'home', type: 'starting_lineups', playerId: 'ext-homonym',
    lineupPlayer: 'Portero Harvest' }] }, '2026-09-01T20:10:00Z');
  assert.notEqual((await byExt(db, 'ext-homonym')).id, first.id);
  assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_entities where kind='player' and external_id='ext-gk'")).rows[0].n, 1);
}));

test('a valid existing photo is never lost', () => withDb(async (db) => {
  await match(db);
  await storeDetail(db, objectLineups);
  const original = (await byExt(db, 'ext-gk')).payload.media;
  for (const image of [null, 'http://media.goal-api.com/x.png', 'https://evil.test/x.png']) {
    const lineup = structuredClone(objectLineups);
    lineup.lineups.home.startingLineups[0].playerImage = image;
    await db.query("select futbeat_private.harvest_lineup_players('fb_match_pc',$1,'2026-09-05T00:00:00Z')",
      [JSON.stringify(lineup)]);
    assert.deepEqual((await byExt(db, 'ext-gk')).payload.media, original, String(image));
  }
  // An older lineup cannot replace a newer verified photo.
  const older = structuredClone(objectLineups);
  older.lineups.home.startingLineups[0].playerImage = photo('older');
  await db.query("select futbeat_private.harvest_lineup_players('fb_match_pc',$1,'2020-01-01T00:00:00Z')",
    [JSON.stringify(older)]);
  assert.equal((await byExt(db, 'ext-gk')).payload.media.url, photo('gk'));
}));

test('a newly harvested player appears in search', () => withDb(async (db) => {
  await match(db);
  assert.deepEqual(await search(db, 'visitante harvest'), []);
  await storeDetail(db, objectLineups);
  const found = (await db.query("select public.futbeat_search_catalog('visitante harvest',null,50) v")).rows[0].v.players;
  assert.equal(found.length, 1);
  assert.equal(found[0].teamId, 'fb_team_pc_away');
}));

test('helpers stay private and metrics are service-only', () => withDb(async (db) => {
  for (const role of ['anon', 'authenticated', 'service_role']) {
    for (const fn of ['futbeat_private.search_fold(text)', 'futbeat_private.lineup_rows(jsonb)',
      'futbeat_private.harvest_lineup_players(text,jsonb,timestamptz)']) {
      assert.equal((await db.query("select has_function_privilege($1,$2,'EXECUTE') ok", [role, fn])).rows[0].ok, false, `${role} ${fn}`);
    }
  }
  for (const role of ['anon', 'authenticated']) {
    assert.equal((await db.query("select has_function_privilege($1,'public.futbeat_player_catalog_metrics()','EXECUTE') ok", [role])).rows[0].ok, false);
  }
  assert.equal((await db.query("select has_function_privilege('service_role','public.futbeat_player_catalog_metrics()','EXECUTE') ok")).rows[0].ok, true);
}));

test('teams and competitions keep exactly the previous results and order', () => withDb(async (db) => {
  const teams = [['Real Madrid', []], ['Real Sociedad', []], ['Madrid FC', ['Real']], ['Atlético Madrid', []],
    ['Manchester United', ['Red Devils']], ['Reading', []], ['Rea FC', []], ['LD Alajuelense', ['LDA', 'Liga']],
    ['Unión Española', []]];
  await db.query(`insert into futbeat_private.entities select 'fb_team_r'||i,'team',
    jsonb_build_object('id','fb_team_r'||i,'name',t->>0,'aliases',t->1)
    from jsonb_array_elements($1::jsonb) with ordinality x(t,i)`, [JSON.stringify(teams)]);
  await db.query(`insert into futbeat_private.entities values
    ('fb_comp_r1','competition','{"id":"fb_comp_r1","name":"LaLiga","aliases":["Liga Española"]}'),
    ('fb_comp_r2','competition','{"id":"fb_comp_r2","name":"Liga Promerica"}')`);
  // Players must not leak into team/competition ranking either.
  await players(db, [{ id: 'fb_player_real', name: 'Real Player' }]);
  const queries = ['real', 'madrid', 'rea', 'liga', 'atletico', 'unión', 're', 'manchestr'];
  const run = async () => {
    const out = {};
    for (const q of queries) {
      const v = (await db.query('select public.futbeat_search_catalog($1,null,50) v', [q])).rows[0].v;
      out[q] = { teams: v.teams, competitions: v.competitions };
    }
    return out;
  };
  const current = await run();
  const previous = await readFile(new URL('../../supabase/migrations/20260922002909_calendar_cache_explore.sql', import.meta.url), 'utf8');
  await db.exec(previous.slice(previous.indexOf('create or replace function public.futbeat_search_catalog'),
    previous.indexOf('revoke all on function futbeat_private.index_entity_search()')));
  const before = await run();
  for (const q of queries) assert.deepEqual(current[q], before[q], q);
  assert.equal(current.real.teams[0].name, 'Madrid FC');
  assert.deepEqual(current.liga.competitions.map((c) => c.name), ['LaLiga', 'Liga Promerica']);
  // Team/competition index terms are unchanged: no folded variants added.
  assert.equal((await db.query(`select count(*)::int n from futbeat_private.entity_search_index
    where kind<>'player' and term='union espanola'`)).rows[0].n, 0);
}));

async function twoClubs(db) {
  await match(db);
  await db.query(`insert into futbeat_private.entities values('fb_match_pc2','match',
    '{"id":"fb_match_pc2","homeTeamId":"fb_team_pc_away","awayTeamId":"fb_team_pc_home","startTime":"2026-09-10T18:00:00Z"}')`);
}
const moverLineup = (number, position) => JSON.stringify({ lineups: { home: { startingLineups: [
  { playerId: 'ext-mover', lineupPlayer: 'Mover', ...(number ? { lineupNumber: number } : {}),
    ...(position ? { playerPosition: position } : {}) }] } } });
const harvest = async (db, matchId, payload, at) => (await db.query(
  'select futbeat_private.harvest_lineup_players($1,$2,$3) n', [matchId, payload, at])).rows[0].n;
const mover = async (db) => {
  const { payload } = await byExt(db, 'ext-mover');
  return { teamId: payload.teamId, shirtNumber: payload.shirtNumber, position: payload.position };
};
const CLUB_B = { teamId: 'fb_team_pc_away', shirtNumber: 10, position: 'Midfielder' };

test('a newer lineup moves team, shirt number and position together', () => withDb(async (db) => {
  await twoClubs(db);
  await harvest(db, 'fb_match_pc', moverLineup('7', 'D'), '2026-09-01T20:00:00Z');
  assert.deepEqual(await mover(db), { teamId: 'fb_team_pc_home', shirtNumber: 7, position: 'Defender' });
  await harvest(db, 'fb_match_pc2', moverLineup('10', 'M'), '2026-09-10T20:00:00Z');
  assert.deepEqual(await mover(db), CLUB_B);
  // Idempotent: replaying both lineups changes nothing.
  assert.equal(await harvest(db, 'fb_match_pc', moverLineup('7', 'D'), '2026-09-01T20:00:00Z'), 0);
  assert.equal(await harvest(db, 'fb_match_pc2', moverLineup('10', 'M'), '2026-09-10T20:00:00Z'), 0);
  assert.deepEqual(await mover(db), CLUB_B);
}));

test('reverse order: the newest lineup still wins and old values never mix in', () => withDb(async (db) => {
  await twoClubs(db);
  await harvest(db, 'fb_match_pc2', moverLineup('10', 'M'), '2026-09-10T20:00:00Z');
  await harvest(db, 'fb_match_pc', moverLineup('7', 'D'), '2026-09-01T20:00:00Z');
  assert.deepEqual(await mover(db), CLUB_B);
}));

test('moving club without a published number drops the old club number', () => withDb(async (db) => {
  await twoClubs(db);
  await harvest(db, 'fb_match_pc', moverLineup('7', 'D'), '2026-09-01T20:00:00Z');
  await harvest(db, 'fb_match_pc2', moverLineup(null, null), '2026-09-10T20:00:00Z');
  assert.deepEqual(await mover(db), { teamId: 'fb_team_pc_away', shirtNumber: undefined, position: undefined });
}));

test('squad present: no lineup changes team, number or position', () => withDb(async (db) => {
  await twoClubs(db);
  const stamp = '2026-09-02T00:00:00Z';
  const squad = await normalizeGoalApiSquad([{ id: 'ext-mover', name: 'Mover', position: 'Goalkeeper', number: 13 }],
    'fb_team_pc_home', async (kind, external, identity) =>
      (await db.query('select public.futbeat_resolve_global_entity($1,$2,$3,$4) id',
        ['goal_api', kind, external, identity.name])).rows[0].id, stamp);
  await db.query('select public.futbeat_store_team_squad($1,$2,$3,$4)',
    ['fb_team_pc_home', 'goal_api', stamp, JSON.stringify(squad)]);
  const before = (await byExt(db, 'ext-mover')).payload;
  await harvest(db, 'fb_match_pc2', moverLineup('10', 'M'), '2026-09-10T20:00:00Z');
  const after = (await byExt(db, 'ext-mover')).payload;
  assert.deepEqual({ teamId: after.teamId, shirtNumber: after.shirtNumber, position: after.position },
    { teamId: 'fb_team_pc_home', shirtNumber: 13, position: before.position });
  assert.equal(after.lineupOwned, undefined);
}));

async function squadFor(db, teamId, row, stamp) {
  const squad = await normalizeGoalApiSquad([row], teamId, async (kind, external, identity) =>
    (await db.query('select public.futbeat_resolve_global_entity($1,$2,$3,$4) id',
      ['goal_api', kind, external, identity.name])).rows[0].id, stamp);
  await db.query('select public.futbeat_store_team_squad($1,$2,$3,$4)', [teamId, 'goal_api', stamp, JSON.stringify(squad)]);
}
const club = async (db) => {
  const { payload } = await byExt(db, 'ext-mover');
  return { teamId: payload.teamId, shirtNumber: payload.shirtNumber, position: payload.position,
    lineupOwned: payload.lineupOwned, lineupSeenAt: payload.lineupSeenAt };
};

test('A: lineup A #7 DEF then empty squad B leaves B without the old number/position', () => withDb(async (db) => {
  await twoClubs(db);
  await harvest(db, 'fb_match_pc', moverLineup('7', 'D'), '2026-09-01T20:00:00Z');
  await squadFor(db, 'fb_team_pc_away', { id: 'ext-mover', name: 'Mover' }, '2026-09-05T00:00:00Z');
  assert.deepEqual(await club(db), { teamId: 'fb_team_pc_away', shirtNumber: undefined, position: undefined,
    lineupOwned: undefined, lineupSeenAt: undefined });
  // The squad now owns the club facts: later lineups cannot change them.
  await harvest(db, 'fb_match_pc', moverLineup('7', 'D'), '2026-09-20T20:00:00Z');
  assert.equal((await club(db)).teamId, 'fb_team_pc_away');
}));

test('A: lineup A #7 DEF then squad B #10 MID becomes B/#10/MID', () => withDb(async (db) => {
  await twoClubs(db);
  await harvest(db, 'fb_match_pc', moverLineup('7', 'D'), '2026-09-01T20:00:00Z');
  await squadFor(db, 'fb_team_pc_away', { id: 'ext-mover', name: 'Mover', number: 10, position: 'Midfielder' },
    '2026-09-05T00:00:00Z');
  assert.deepEqual(await club(db), { teamId: 'fb_team_pc_away', shirtNumber: 10, position: 'Midfielder',
    lineupOwned: undefined, lineupSeenAt: undefined });
}));

test('A: same-club empty squad keeps the compatible lineup values and takes ownership', () => withDb(async (db) => {
  await twoClubs(db);
  await harvest(db, 'fb_match_pc', moverLineup('7', 'D'), '2026-09-01T20:00:00Z');
  await squadFor(db, 'fb_team_pc_home', { id: 'ext-mover', name: 'Mover' }, '2026-09-05T00:00:00Z');
  // Documented rule: values from a lineup of the SAME club describe this club,
  // so they are kept (no mixing) and the squad becomes their owner.
  assert.deepEqual(await club(db), { teamId: 'fb_team_pc_home', shirtNumber: 7, position: 'Defender',
    lineupOwned: undefined, lineupSeenAt: undefined });
}));

test('B: a newer row without club context never blocks an older row with context', () => withDb(async (db) => {
  await twoClubs(db);
  // T2: array row with no team side (and the legacy context-free wrapper).
  await harvest(db, 'fb_match_pc', JSON.stringify({ lineups: [{ type: 'starting_lineups', playerId: 'ext-mover',
    lineupPlayer: 'Mover', lineupNumber: '9', playerPosition: 'F', playerCountry: 'Chile' }] }), '2026-09-10T20:00:00Z');
  await db.query("select futbeat_private.harvest_lineup_media($1,'2026-09-11T20:00:00Z')", [JSON.stringify({
    lineups: [{ type: 'starting', playerId: 'ext-mover', lineupPlayer: 'Mover', lineupNumber: '9' }] })]);
  let state = await club(db);
  assert.deepEqual([state.teamId, state.shirtNumber, state.position, state.lineupSeenAt], [undefined, undefined, undefined, undefined]);
  assert.equal((await byExt(db, 'ext-mover')).payload.country, 'Chile');
  // T1 (older) with a real club context still assigns the club block.
  await harvest(db, 'fb_match_pc', moverLineup('7', 'D'), '2026-09-01T20:00:00Z');
  state = await club(db);
  assert.deepEqual([state.teamId, state.shirtNumber, state.position], ['fb_team_pc_home', 7, 'Defender']);
}));

test('UTC: lineupSeenAt is deterministic and idempotent across session time zones', () => withDb(async (db) => {
  await twoClubs(db);
  await db.exec("set timezone='America/Costa_Rica'");
  await harvest(db, 'fb_match_pc', moverLineup('7', 'D'), '2026-09-01T20:00:00Z');
  const costaRica = await club(db);
  assert.equal(costaRica.lineupSeenAt, '2026-09-01T20:00:00.000000Z');
  await db.exec("set timezone='Asia/Tokyo'");
  assert.equal(await harvest(db, 'fb_match_pc', moverLineup('7', 'D'), '2026-09-01T20:00:00Z'), 0);
  assert.deepEqual(await club(db), costaRica);
  await db.exec("set timezone='UTC'");
  assert.equal(await harvest(db, 'fb_match_pc', moverLineup('7', 'D'), '2026-09-01T20:00:00Z'), 0);
}));

test('squad wrapper keeps grants: inner writer internal, wrapper service-only', () => withDb(async (db) => {
  const can = async (role, fn) => (await db.query("select has_function_privilege($1,$2,'EXECUTE') ok", [role, fn])).rows[0].ok;
  const inner = 'futbeat_private.store_team_squad_before_lineup_owner(text,text,timestamptz,jsonb)';
  const wrapper = 'futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb)';
  for (const role of ['anon', 'authenticated', 'service_role']) assert.equal(await can(role, inner), false, role);
  for (const role of ['anon', 'authenticated']) assert.equal(await can(role, wrapper), false, role);
  assert.equal(await can('service_role', wrapper), true);
  assert.equal(await can('service_role', 'public.futbeat_store_team_squad(text,text,timestamptz,jsonb)'), true);
}));
