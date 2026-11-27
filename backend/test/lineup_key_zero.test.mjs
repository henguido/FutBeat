// K0: GOAL sends playerKey "0" for lineup players it has no key for. It names nobody, so it is never an identity:
// no media lookup, no canonical player, no dedup key (prod 2026-11-27: 352 rows / 304 matches in 45 days all mapped
// to one crosswalk entity).
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  providerPlayerId as lineupKey,
  lineupPlayerIds,
  lineupPlayerIdsBySection,
  normalizeLineupPlayer,
} from '../../supabase/functions/_shared/match_detail.ts';

const detail = (lineups) => ({ payload: { lineups } });
const rows = [
  { team: 'home', type: 'starting_lineups', lineupPlayer: 'Real Uno', playerKey: '140886920' },
  { team: 'home', type: 'starting_lineups', lineupPlayer: 'Sin Clave A', playerKey: '0' },
  { team: 'away', type: 'starting_lineups', lineupPlayer: 'Sin Clave B', playerKey: '0' },
  { team: 'away', type: 'substitutes', lineupPlayer: 'Sin Clave C', playerId: '00' },
  { team: 'away', type: 'substitutes', lineupPlayer: 'Real Dos', playerId: '2797666696' },
];

test('lineupKey: 0/00 are no key; real keys and ids untouched', () => {
  assert.equal(lineupKey('0'), '');
  assert.equal(lineupKey(' 00 '), '');
  assert.equal(lineupKey(0), '');
  assert.equal(lineupKey('140886920'), '140886920');
  assert.equal(lineupKey('10'), '10');
  assert.equal(lineupKey('cmwrbbetct7hbod083klt3s3i'), 'cmwrbbetct7hbod083klt3s3i');
  assert.equal(lineupKey(null), '');
});

test('key 0 never reaches the media lookup', () => {
  assert.deepEqual(lineupPlayerIds(detail(rows)), ['140886920', '2797666696']);
  const { starters, substitutes } = lineupPlayerIdsBySection(detail(rows));
  assert.deepEqual([...starters], ['140886920']);
  assert.deepEqual([...substitutes], ['2797666696']);
});

test('key 0 player keeps its name but gets no id and no canonical player', () => {
  const media = { '0': { canonicalId: 'fb_player_wrong', image: 'https://media.goal-api.com/x.jpg' },
    '140886920': { canonicalId: 'fb_player_ok', image: null } };
  const zero = normalizeLineupPlayer(rows[1], media);
  assert.equal(zero.name, 'Sin Clave A');
  assert.equal(zero.id, null);
  assert.equal(zero.canonicalId, null, 'never the key-0 crosswalk player');
  const real = normalizeLineupPlayer(rows[0], media);
  assert.equal(real.id, '140886920');
  assert.equal(real.canonicalId, 'fb_player_ok');
});
