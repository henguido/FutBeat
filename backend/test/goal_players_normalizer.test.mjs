import test from 'node:test';
import assert from 'node:assert/strict';
import {
  normalizeGoalPlayer,
  normalizeGoalPlayerProfile,
  normalizeGoalPlayerSearch,
  normalizeGoalPlayerStatistics,
} from '../../supabase/functions/_shared/goal_players.ts';

const cdn = 'https://media.goal-api.com/players/x.png';

test('player rows: only present, valid fields; identity requires provider id and name', () => {
  assert.deepEqual(normalizeGoalPlayer({ id: 7, name: ' Ana Gol ', nationality: 'Costa Rica', position: { name: 'Attacker' },
    birthDate: '2001-02-03T00:00:00Z', age: '25', height: '1,82', foot: 'Left', number: '9', photo: cdn,
    team: { id: 'goal-team-1' } }), {
    externalId: '7', name: 'Ana Gol', country: 'Costa Rica', position: 'Attacker', dateOfBirth: '2001-02-03', age: 25,
    height: 182, preferredFoot: 'left', shirtNumber: 9, photo: cdn, teamExternalId: 'goal-team-1' });
  assert.deepEqual(normalizeGoalPlayer({ player: { id: 'p', firstName: 'Ana', lastName: 'Gol' } }),
    { externalId: 'p', name: 'Ana Gol' });
  assert.deepEqual(normalizeGoalPlayer({ id: 'p', name: 'X', photo: 'https://evil.test/x.png', height: 'tall', birthDate: 'soon',
    age: -3, number: [9] }), { externalId: 'p', name: 'X' });
  assert.equal(normalizeGoalPlayer({ name: 'Sin id' }), null);
  assert.equal(normalizeGoalPlayer({ id: 'p' }), null);
});

test('search results: every envelope shape, unique by provider id, capped at 50', () => {
  const rows = [{ id: 'a', name: 'A' }, { id: 'a', name: 'A dup' }, { id: 'b', name: 'B' }, { name: 'no id' }];
  for (const payload of [{ data: rows }, { data: { players: rows } }, { data: { results: rows } }, { players: rows }]) {
    assert.deepEqual(normalizeGoalPlayerSearch(payload).map((p) => p.externalId), ['a', 'b']);
  }
  assert.equal(normalizeGoalPlayerSearch({ data: Array.from({ length: 80 }, (_, i) => ({ id: i, name: `P${i}` })) }).length, 50);
  assert.deepEqual(normalizeGoalPlayerSearch({ data: null }), []);
});

test('profile: object or first array item; nothing usable -> null', () => {
  assert.equal(normalizeGoalPlayerProfile({ data: { id: 'p', name: 'P' } }).externalId, 'p');
  assert.equal(normalizeGoalPlayerProfile({ data: [{ id: 'q', name: 'Q' }] }).externalId, 'q');
  assert.equal(normalizeGoalPlayerProfile({ data: {} }), null);
});

test('statistics: latest season; several competitions are summed without a competition label', () => {
  assert.deepEqual(normalizeGoalPlayerStatistics({ data: [
    { season: '2025', league: { name: 'Old' }, appearances: 30 },
    { season: '2026', league: { name: 'Liga' }, games: { appearences: 12, lineups: 10, minutes: 900, rating: '7.4' },
      goals: { total: 7, assists: 3 }, cards: { yellow: 2, red: 0 } },
  ] }), { season: '2026', competition: 'Liga', matchesPlayed: 12, starts: 10, minutesPlayed: 900, goals: 7, assists: 3,
    yellowCards: 2, redCards: 0, rating: 7.4 });
  assert.deepEqual(normalizeGoalPlayerStatistics({ data: [
    { season: '2026', league: { name: 'Liga' }, appearances: 10, goals: 4, rating: 7 },
    { season: '2026', league: { name: 'Copa' }, appearances: 3, goals: 1, rating: 8 },
  ] }), { season: '2026', matchesPlayed: 13, goals: 5 });
  for (const empty of [{ data: [] }, { data: {} }, { data: [{ season: '2026' }] }, {}]) {
    assert.deepEqual(normalizeGoalPlayerStatistics(empty), {});
  }
});
