import test from 'node:test';
import assert from 'node:assert/strict';
import {
  lineupPlayerIds,
  normalizeMatchDetail,
  normalizePeriodScores,
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

test('lineupPlayerIdsBySection splits starters/substitutes for both raw shapes', async () => {
  const { lineupPlayerIdsBySection } = await import('../../supabase/functions/_shared/match_detail.ts');
  const arrayLineups = [
    { team: 'home', type: 'starting', playerId: 'p1' },
    { team: 'home', type: 'sub', playerId: 'p2' },
    { team: 'away', type: 'starting', playerId: 'p3' },
  ];
  assert.deepEqual(lineupPlayerIdsBySection({ payload: { lineups: arrayLineups } }), {
    starters: ['p1', 'p3'], substitutes: ['p2'],
  });
  const objectLineups = {
    home: { startingLineups: [{ playerId: 'a' }], substitutes: [{ playerId: 'b' }] },
    away: { startingLineups: [{ playerId: 'c' }], substitutes: [] },
  };
  assert.deepEqual(lineupPlayerIdsBySection({ payload: { lineups: objectLineups } }), {
    starters: ['a', 'c'], substitutes: ['b'],
  });
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

const score = (home, away) => ({ home, away });
const periods = (fixture) => normalizePeriodScores(fixture);

test('period scores: finished matches expose only complete, coherent stored halves', () => {
  const finished = {
    matchStatus: 'FINISHED',
    homeTeamScore: '0', awayTeamScore: '0', // GOAL may reset the running total.
    homeTeamHalftimeScore: '1', awayTeamHalftimeScore: '0',
    homeTeamFtScore: '2', awayTeamFtScore: '1',
  };
  const expected = { halfTime: score(1, 0), fullTime: score(2, 1) };
  assert.deepEqual(periods(finished), expected);
  assert.deepEqual(normalizeMatchDetail({ payload: finished }).periodScores, expected);
  assert.deepEqual(periods({ ...finished, homeTeamHalftimeScore: null }),
    { fullTime: score(2, 1) });
  assert.deepEqual(periods({ ...finished, homeTeamFtScore: null,
    homeTeamScore: '2', awayTeamScore: '1' }),
    {});
  assert.deepEqual(periods({ ...finished, homeTeamHalftimeScore: '3' }),
    {});
  assert.deepEqual(periods({ ...finished, awayTeamFtScore: 'x',
    homeTeamScore: '2', awayTeamScore: '1' }),
    {});
  assert.deepEqual(periods({ ...finished, homeTeamFtScore: '-1',
    homeTeamScore: '2', awayTeamScore: '1' }),
    {});
  assert.deepEqual(periods({ ...finished, homeTeamFtScore: '2.5',
    homeTeamScore: '2', awayTeamScore: '1' }),
    {});
});

test('period scores: extra time and penalties stay separate from final match score', () => {
  const extra = {
    matchStatus: 'AFTER_ET',
    homeTeamScore: '2', awayTeamScore: '1',
    homeTeamHalftimeScore: '1', awayTeamHalftimeScore: '0',
    homeTeamFtScore: '1', awayTeamFtScore: '1',
    homeTeamExtraScore: '1', awayTeamExtraScore: '0',
  };
  assert.deepEqual(periods(extra), {
    halfTime: score(1, 0), fullTime: score(1, 1), extraTime: score(1, 0),
  });
  const afterPen = {
    ...extra, matchStatus: 'AFTER_PEN',
    homeTeamScore: '3', awayTeamScore: '1', // Shoot-out bonus for winner.
    homeTeamPenaltyScore: '4', awayTeamPenaltyScore: '3',
  };
  assert.deepEqual(periods(afterPen), {
    halfTime: score(1, 0), fullTime: score(1, 1),
    extraTime: score(1, 0), penalties: score(4, 3),
  }); // Non-tied match total can still have a two-legged aggregate shoot-out.
  assert.deepEqual(periods({ ...afterPen, homeTeamExtraScore: '0',
    homeTeamScore: '2' }), {
    halfTime: score(1, 0), fullTime: score(1, 1),
    extraTime: score(0, 0), penalties: score(4, 3),
  }); // Ordinary tied match with the shoot-out bonus.
  assert.deepEqual(periods({ ...afterPen, homeTeamScore: '0', awayTeamScore: '0' }),
    periods(afterPen)); // GOAL's post-match reset is also coherent.
  assert.deepEqual(periods({ ...afterPen, homeTeamPenaltyScore: '3', awayTeamPenaltyScore: '3',
    homeTeamScore: '2', awayTeamScore: '1' }), {
    halfTime: score(1, 0), fullTime: score(1, 1), extraTime: score(1, 0),
  });
  assert.deepEqual(periods({ ...afterPen, homeTeamPenaltyScore: null,
    homeTeamScore: '2', awayTeamScore: '1' }), {
    halfTime: score(1, 0), fullTime: score(1, 1), extraTime: score(1, 0),
  });
});

test('period scores: absent, nonterminal, awarded and incoherent answers fail closed', () => {
  const fixture = {
    homeTeamScore: '2', awayTeamScore: '1',
    homeTeamHalftimeScore: '1', awayTeamHalftimeScore: '0',
    homeTeamFtScore: '2', awayTeamFtScore: '1',
    homeTeamExtraScore: '0', awayTeamExtraScore: '0',
    homeTeamPenaltyScore: '4', awayTeamPenaltyScore: '3',
  };
  for (const status of [null, 'SCHEDULED', 'LIVE', 'HALF_TIME', 'AWARDED', 'ABANDONED']) {
    assert.deepEqual(periods({ ...fixture, matchStatus: status }), {}, String(status));
  }
  assert.deepEqual(periods({ matchStatus: 'FINISHED' }), {});
  assert.deepEqual(periods({ ...fixture, matchStatus: 'FINISHED', homeTeamScore: '3' }), {});
  assert.deepEqual(periods({ ...fixture, matchStatus: 'AFTER_ET', awayTeamExtraScore: null }), {});
  assert.deepEqual(periods({ ...fixture, matchStatus: 'AFTER_PEN', homeTeamPenaltyScore: '4',
    awayTeamPenaltyScore: null, homeTeamScore: '3' }), {});
  assert.deepEqual(periods({ ...fixture, matchStatus: 'AFTER_PEN', homeTeamScore: '3',
    awayTeamPenaltyScore: '5' }), {}); // Bonus assigned to shoot-out loser.
  assert.deepEqual(periods({ ...fixture, matchStatus: 'FINISHED', homeTeamHalftimeScore: '999' }),
    {});
});
