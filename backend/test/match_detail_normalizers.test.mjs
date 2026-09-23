import test from 'node:test';
import assert from 'node:assert/strict';
import {
  lineupPlayerIds,
  normalizeLineupSide,
  normalizeStatistics,
} from '../../supabase/functions/_shared/match_detail.ts';

const cdn = (name) => `https://media.goal-api.com/players/${name}.png`;

test('array lineups render every type spelling the harvest accepts', () => {
  const lineups = [
    { team: 'home', type: 'starting', playerId: 'p1', lineupPlayer: 'Uno', lineupPosition: 2 },
    { team: 'home', type: 'starting_lineup', playerId: 'p2', lineupPlayer: 'Dos', lineupPosition: 1 },
    { team: 'home', type: 'Starting_Lineups', playerId: 'p3', lineupPlayer: 'Tres', lineupPosition: 3 },
    { team: 'home', type: 'sub', playerId: 'p4', lineupPlayer: 'Cuatro' },
    { team: 'home', type: 'substitutes', playerId: 'p5', lineupPlayer: 'Cinco' },
    { team: 'home', type: 'missing_players', playerId: 'p6', lineupPlayer: 'Seis' },
    { team: 'home', type: 'coach', playerId: 'c1', lineupPlayer: 'Entrenador' },
    { team: 'away', type: 'starter', playerId: 'p7', lineupPlayer: 'Siete' },
  ];
  const home = normalizeLineupSide(lineups, 'home');
  assert.deepEqual(home.starters.map((p) => p.name), ['Dos', 'Uno', 'Tres']);
  assert.deepEqual(home.substitutes.map((p) => p.name), ['Cuatro', 'Cinco']);
  assert.deepEqual(home.missing.map((p) => p.name), ['Seis']);
  assert.equal(home.coach.name, 'Entrenador');
  assert.deepEqual(normalizeLineupSide(lineups, 'away').starters.map((p) => p.name), ['Siete']);
  // Every rendered starter/substitute is also a media lookup id (coach/missing are not).
  assert.deepEqual(lineupPlayerIds({ payload: { lineups } }).sort(), ['p1', 'p2', 'p3', 'p4', 'p5', 'p7']);
});

test('object lineups: formation, canonical photo first, raw https fallback, none otherwise', () => {
  const lineups = {
    homeFormation: '4-3-3',
    home: {
      startingLineups: [
        { playerId: 'a', lineupPlayer: 'Con Canonica', playerImage: cdn('raw-a') },
        { playerId: 'b', lineupPlayer: 'Solo Raw', playerImage: cdn('raw-b') },
        { playerId: 'c', lineupPlayer: 'Sin Foto', playerImage: 'http://insecure.test/c.png' },
      ],
      substitutes: [{ playerId: 'd', lineupPlayer: 'Banca' }],
      coach: { lineupPlayer: 'DT' },
    },
  };
  const media = { a: { canonicalId: 'fb_player_a', image: cdn('canonical-a') }, b: { canonicalId: 'fb_player_b', image: null } };
  const home = normalizeLineupSide(lineups, 'home', media);
  assert.equal(home.formation, '4-3-3');
  assert.deepEqual(home.starters.map((p) => [p.canonicalId, p.image]), [
    ['fb_player_a', cdn('canonical-a')],
    ['fb_player_b', cdn('raw-b')],
    [null, null],
  ]);
  assert.equal(home.substitutes[0].image, null);
  assert.equal(home.coach.name, 'DT');
  assert.deepEqual(normalizeLineupSide(lineups, 'away').starters, []);
  assert.deepEqual(lineupPlayerIds({ payload: { lineups } }).sort(), ['a', 'b', 'c', 'd']);
});

test('statistics: full-time rows only; partial periods are never shown as totals', () => {
  const rows = [
    { type: 'Shots', home: 3, away: 2, half: '1st' },
    { type: 'Shots', home: 4, away: 2, half: '2nd' },
    { type: 'Shots', home: 7, away: 4, half: 'Full Time' },
    { type: 'Ball Possession', home: '55%', away: '45%', half: 'FT' },
  ];
  assert.deepEqual(normalizeStatistics(rows), [
    { label: 'Shots', home: 7, away: 4 },
    { label: 'Ball Possession', home: '55%', away: '45%' },
  ]);
  for (const half of ['full', 'full_time', 'fulltime', 'ALL', 'match']) {
    assert.deepEqual(normalizeStatistics([{ type: 'Corners', home: 5, away: 1, half }]),
      [{ label: 'Corners', home: 5, away: 1 }], half);
  }
  // Only halves: no whole-match statistics exist.
  assert.deepEqual(normalizeStatistics(rows.slice(0, 2)), []);
  // Unlabelled rows are whole-match rows (previous behavior).
  assert.deepEqual(normalizeStatistics([{ type: 'Fouls', home: 10, away: 12 }]),
    [{ label: 'Fouls', home: 10, away: 12 }]);
});

test('statistics object shapes: match.fullTime and team-keyed values', () => {
  assert.deepEqual(normalizeStatistics({ match: { firstHalf: [{ type: 'Shots', home: 1, away: 0 }],
    fullTime: [{ type: 'Shots', home: 6, away: 3 }] } }), [{ label: 'Shots', home: 6, away: 3 }]);
  assert.deepEqual(normalizeStatistics({ match: { firstHalf: [{ type: 'Shots', home: 1, away: 0 }] } }), []);
  assert.deepEqual(normalizeStatistics({ home: { shots: 4, possession: '60%' }, away: { shots: 2, possession: '40%' } }), [
    { label: 'shots', home: 4, away: 2 },
    { label: 'possession', home: '60%', away: '40%' },
  ]);
});

test('statistics never invent values', () => {
  for (const empty of [null, undefined, [], {}, { match: { fullTime: [] } }, 'x', 7]) {
    assert.deepEqual(normalizeStatistics(empty), [], JSON.stringify(empty));
  }
  // A row with no value on either side is dropped; one missing side shows a dash, not 0.
  assert.deepEqual(normalizeStatistics([
    { type: 'Offsides', home: null, away: '' },
    { type: 'Saves', home: 3, away: null },
  ]), [{ label: 'Saves', home: 3, away: '—' }]);
});
