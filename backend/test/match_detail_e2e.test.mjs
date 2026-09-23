import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import { normalizeGoalApiSquad } from '../providers/goal_api_players.mjs';
import { lineupPlayerIds, normalizeMatchDetail } from '../../supabase/functions/_shared/match_detail.ts';

// End to end, locally: match_detail_cache -> canonical players/photos ->
// read model -> /v1/match-detail normalization. The normalized object lineup
// is pinned in a fixture that the Flutter Match Center test renders, so the
// mobile half consumes exactly what this backend half produces.

const FIXTURE = new URL('../../apps/mobile/test/fixtures/match_detail_object_lineup.json', import.meta.url);
const cdn = (name) => `https://media.goal-api.com/players/${name}.png`;

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await fn(db);
    assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 0);
  } finally { await db.close(); }
}

async function seedMatch(db) {
  const rows = [
    ['fb_comp_e2e', 'competition', { id: 'fb_comp_e2e', name: 'Liga E2E', country: 'Costa Rica' }],
    ['fb_team_e2e_home', 'team', { id: 'fb_team_e2e_home', name: 'Local E2E', competitionId: 'fb_comp_e2e' }],
    ['fb_team_e2e_away', 'team', { id: 'fb_team_e2e_away', name: 'Visita E2E', competitionId: 'fb_comp_e2e' }],
    ['fb_match_e2e', 'match', { id: 'fb_match_e2e', competitionId: 'fb_comp_e2e', homeTeamId: 'fb_team_e2e_home',
      awayTeamId: 'fb_team_e2e_away', startTime: '2026-09-01T18:00:00Z', status: 'VERIFIED', events: [], statistics: [] }],
  ];
  for (const [id, kind, payload] of rows) {
    await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
  }
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match','e2e-ext','fb_match_e2e')");
}

const store = (db, payload, at) => db.query(
  "select futbeat_private.store_match_detail('fb_match_e2e','e2e-ext',$1,$2)", [at, JSON.stringify(payload)]);

// Same RPC sequence as supabase/functions/futbeat-api (match-detail route).
async function api(db) {
  const detail = (await db.query("select public.futbeat_read_match_detail('fb_match_e2e') v")).rows[0].v;
  const ids = lineupPlayerIds(detail);
  const media = ids.length === 0 ? {} : (await db.query(
    "select public.futbeat_read_lineup_player_media('goal_api',$1) v", [ids])).rows[0].v;
  return normalizeMatchDetail(detail, [], media);
}

const objectLineups = {
  hasLineups: true,
  homeFormation: '4-4-2',
  awayFormation: '4-3-3',
  home: {
    startingLineups: [
      { playerId: 'e2e-h1', lineupPlayer: 'Portero Con Foto', lineupNumber: '1', playerPosition: 'G',
        lineupPosition: 1, playerImage: cdn('h1') },
      { playerId: 'e2e-h2', lineupPlayer: 'Defensa Sin Foto', lineupNumber: '4', playerPosition: 'D', lineupPosition: 2 },
    ],
    substitutes: [{ playerId: 'e2e-h3', lineupPlayer: 'Suplente Canonico', lineupNumber: '12', playerPosition: 'G' }],
    coach: { lineupPlayer: 'DT Local' },
  },
  away: {
    startingLineups: [{ playerId: 'e2e-a1', lineupPlayer: 'Delantero Visita', lineupNumber: '9',
      playerPosition: 'F', lineupPosition: 1, playerImage: cdn('a1') }],
    substitutes: [],
  },
};
const objectStatistics = { match: { fullTime: [
  { type: 'Ball Possession', home: '55%', away: '45%' },
  { type: 'Shots on Goal', home: 6, away: 2 },
], firstHalf: [{ type: 'Shots on Goal', home: 2, away: 1 }] } };

test('object lineup: canonical players, canonical photo first, fallback and empty refresh', () => withDb(async (db) => {
  await seedMatch(db);
  // A squad already gave e2e-h3 a canonical photo that the lineup does not carry.
  const stamp = '2026-08-01T00:00:00Z';
  const squad = await normalizeGoalApiSquad([{ id: 'e2e-h3', name: 'Suplente Canonico', photo: cdn('squad-h3') }],
    'fb_team_e2e_home', async (kind, external, identity) => (await db.query(
      'select public.futbeat_resolve_global_entity($1,$2,$3,$4) id', ['goal_api', kind, external, identity.name])).rows[0].id, stamp);
  await db.query('select public.futbeat_store_team_squad($1,$2,$3,$4)',
    ['fb_team_e2e_home', 'goal_api', stamp, JSON.stringify(squad)]);

  await store(db, { lineups: objectLineups, statistics: objectStatistics, matchStatus: 'FINISHED' }, '2026-09-01T20:00:00Z');
  const detail = await api(db);
  const starters = detail.home.starters.map((p) => [p.name, p.image, Boolean(p.canonicalId)]);
  assert.deepEqual(starters, [
    ['Portero Con Foto', cdn('h1'), true],
    ['Defensa Sin Foto', null, true],
  ]);
  assert.deepEqual(detail.home.substitutes.map((p) => p.image), [cdn('squad-h3')]);
  assert.equal(detail.home.formation, '4-4-2');
  assert.equal(detail.away.starters[0].image, cdn('a1'));
  assert.deepEqual(detail.statistics, [
    { label: 'Ball Possession', home: '55%', away: '45%' },
    { label: 'Shots on Goal', home: 6, away: 2 },
  ]);

  // Later poorer refreshes never wipe the stored lineup or statistics.
  const at = ['2026-09-01T20:10:00Z', '2026-09-01T20:20:00Z', '2026-09-01T20:30:00Z'];
  for (const [i, poorer] of [
    { lineups: [], statistics: [] },
    { lineups: { hasLineups: false }, statistics: { match: { fullTime: [] } } },
    { lineups: { home: { startingLineups: [] } }, statistics: null },
  ].entries()) {
    await store(db, poorer, at[i]);
    const again = await api(db);
    assert.equal(again.home.starters.length, 2, JSON.stringify(poorer));
    assert.equal(again.statistics.length, 2, JSON.stringify(poorer));
  }
  // A null image in a newer lineup never erases the canonical photo.
  const noPhoto = structuredClone(objectLineups);
  delete noPhoto.home.startingLineups[0].playerImage;
  await store(db, { lineups: noPhoto }, '2026-09-01T21:00:00Z');
  assert.equal((await api(db)).home.starters[0].image, cdn('h1'));

  const actual = JSON.stringify({ matchId: detail.matchId, available: detail.available, pending: detail.pending,
    detailLevel: detail.detailLevel, home: detail.home, away: detail.away, statistics: detail.statistics,
    incidents: detail.incidents, videos: detail.videos }, function (key, value) {
    // Canonical ids are random: pin them to a stable, still-valid form.
    if (key !== 'canonicalId' || value === null) return value;
    assert.match(value, /^fb_player_[0-9a-f]{32}$/);
    return `fb_player_fixture_${this.id.replaceAll('-', '_')}`;
  }, 2) + '\n';
  if (process.env.UPDATE_FIXTURES === '1') await writeFile(FIXTURE, actual);
  assert.equal(actual, await readFile(FIXTURE, 'utf8'), 'regenerate with UPDATE_FIXTURES=1');
}));

test('array lineup produces the same rendered result as the object lineup', () => withDb(async (db) => {
  await seedMatch(db);
  const rows = [];
  for (const side of ['home', 'away']) {
    for (const [key, type] of [['startingLineups', 'starting_lineups'], ['substitutes', 'substitutes']]) {
      for (const row of objectLineups[side][key] ?? []) rows.push({ ...row, team: side, type });
    }
  }
  rows.push({ team: 'home', type: 'coach', lineupPlayer: 'DT Local' });
  await store(db, { lineups: rows, homeTeamSystem: '4-4-2', awayTeamSystem: '4-3-3' }, '2026-09-01T20:00:00Z');
  const detail = await api(db);
  const fixture = JSON.parse(await readFile(FIXTURE, 'utf8'));
  const names = (side) => detail[side].starters.map((p) => [p.name, p.image, p.number]);
  assert.deepEqual(names('home'), fixture.home.starters.map((p) => [p.name, p.image, p.number]));
  assert.deepEqual(names('away'), fixture.away.starters.map((p) => [p.name, p.image, p.number]));
  assert.equal(detail.home.formation, '4-4-2');
  assert.equal(detail.home.coach.name, 'DT Local');
  // A richer newer object lineup replaces an older, poorer array lineup.
  const richer = structuredClone(objectLineups);
  richer.home.startingLineups.push({ playerId: 'e2e-h9', lineupPlayer: 'Nuevo Titular' });
  await store(db, { lineups: richer }, '2026-09-01T20:30:00Z');
  assert.deepEqual((await api(db)).home.starters.map((p) => p.name).at(-1), 'Nuevo Titular');
}));

test('statistics in array form survive poorer refreshes; half-only data is not shown as total', () => withDb(async (db) => {
  await seedMatch(db);
  await store(db, { statistics: [
    { type: 'Corners', home: 5, away: 3, half: 'full' },
    { type: 'Corners', home: 2, away: 1, half: '1st' },
  ] }, '2026-09-01T20:00:00Z');
  assert.deepEqual((await api(db)).statistics, [{ label: 'Corners', home: 5, away: 3 }]);
  await store(db, { statistics: { match: { fullTime: [] } } }, '2026-09-01T20:05:00Z');
  assert.deepEqual((await api(db)).statistics, [{ label: 'Corners', home: 5, away: 3 }]);
  // Richer, newer data wins.
  await store(db, { statistics: [{ type: 'Corners', home: 6, away: 3, half: 'full' },
    { type: 'Fouls', home: 9, away: 11, half: 'full' }, { type: 'Corners', home: 2, away: 1, half: '1st' }] },
  '2026-09-01T20:10:00Z');
  assert.deepEqual((await api(db)).statistics, [
    { label: 'Corners', home: 6, away: 3 }, { label: 'Fouls', home: 9, away: 11 }]);
}));

test('no stored detail: empty lineups and statistics, never invented', () => withDb(async (db) => {
  await seedMatch(db);
  const detail = await api(db);
  assert.deepEqual([detail.home.starters, detail.away.starters, detail.statistics], [[], [], []]);
  assert.equal(detail.available, false);
}));

async function squadAt(db, teamId, row, stamp) {
  const squad = await normalizeGoalApiSquad([row], teamId, async (kind, external, identity) => (await db.query(
    'select public.futbeat_resolve_global_entity($1,$2,$3,$4) id', ['goal_api', kind, external, identity.name])).rows[0].id, stamp);
  await db.query('select public.futbeat_store_team_squad($1,$2,$3,$4)', [teamId, 'goal_api', stamp, JSON.stringify(squad)]);
}
const mover = async (db) => (await db.query(`select e.payload from futbeat_private.provider_entities pe
  join futbeat_private.entities e on e.id=pe.canonical_id where pe.kind='player' and pe.external_id='e2e-mover'`)).rows[0].payload;

test('a club move drops the previous club number, position, season numbers and injury', () => withDb(async (db) => {
  await seedMatch(db);
  await squadAt(db, 'fb_team_e2e_home', { id: 'e2e-mover', name: 'Mover', number: 4, position: 'Defender',
    goals: 2, assists: 1, matchPlayed: 20, rating: '7.1', injured: true, age: 27, photo: cdn('mover') }, '2026-08-01T00:00:00Z');
  await squadAt(db, 'fb_team_e2e_away', { id: 'e2e-mover', name: 'Mover', age: 27 }, '2026-09-01T00:00:00Z');
  const moved = await mover(db);
  assert.equal(moved.teamId, 'fb_team_e2e_away');
  for (const key of ['shirtNumber', 'position', 'goals', 'assists', 'matchesPlayed', 'rating', 'injured']) {
    assert.equal(moved[key], undefined, key);
  }
  // Identity-level facts and the photo stay.
  assert.equal(moved.age, 27);
  assert.equal(moved.media.url, cdn('mover'));
  // The new club's own values apply when supplied.
  await squadAt(db, 'fb_team_e2e_away', { id: 'e2e-mover', name: 'Mover', number: 10, position: 'Midfielder', goals: 1 },
    '2026-09-10T00:00:00Z');
  const refreshed = await mover(db);
  assert.deepEqual([refreshed.shirtNumber, refreshed.position, refreshed.goals], [10, 'Midfielder', 1]);
}));

test('same-club squad refreshes keep previous values (unchanged behavior)', () => withDb(async (db) => {
  await seedMatch(db);
  await squadAt(db, 'fb_team_e2e_home', { id: 'e2e-mover', name: 'Mover', number: 4, position: 'Defender', goals: 2 },
    '2026-08-01T00:00:00Z');
  await squadAt(db, 'fb_team_e2e_home', { id: 'e2e-mover', name: 'Mover' }, '2026-09-01T00:00:00Z');
  const same = await mover(db);
  assert.deepEqual([same.teamId, same.shirtNumber, same.position, same.goals], ['fb_team_e2e_home', 4, 'Defender', 2]);
  // An older observation of another club never moves or strips anything.
  await squadAt(db, 'fb_team_e2e_away', { id: 'e2e-mover', name: 'Mover' }, '2026-07-01T00:00:00Z');
  const stale = await mover(db);
  assert.deepEqual([stale.teamId, stale.shirtNumber], ['fb_team_e2e_home', 4]);
}));

test('new helpers stay private and the squad wrapper keeps its grants', () => withDb(async (db) => {
  const can = async (role, fn) => (await db.query("select has_function_privilege($1,$2,'EXECUTE') ok", [role, fn])).rows[0].ok;
  for (const role of ['anon', 'authenticated', 'service_role']) {
    assert.equal(await can(role, 'futbeat_private.detail_statistics_count(jsonb)'), false, role);
    assert.equal(await can(role, 'futbeat_private.store_team_squad_before_club_move(text,text,timestamptz,jsonb)'), false, role);
  }
  for (const role of ['anon', 'authenticated']) {
    assert.equal(await can(role, 'futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb)'), false, role);
  }
  assert.equal(await can('service_role', 'futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb)'), true);
}));
