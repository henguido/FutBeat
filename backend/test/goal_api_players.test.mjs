import test from 'node:test';
import assert from 'node:assert/strict';
import {
  collectGoalApiPlayerIdentities,
  normalizeGoalApiSquad,
} from '../providers/goal_api_players.mjs';

test('GOAL API squad normalizer accepts wrapped and nested player payloads', async () => {
  const payload = {
    success: true,
    data: {
      players: [
        {
          player: {
            id: 'p1',
            name: 'Ana Gol',
            nationality: 'Costa Rica',
            position: { name: 'Forward' },
            photo: 'https://media.goal-api.com/players/p1.png',
            age: '24',
            birthdate: '2002-05-14',
            matchPlayed: '18',
            goals: '7',
            assists: '4',
            yellowCards: '2',
            redCards: '0',
            rating: '7.4',
            injured: '0',
          },
          number: 9,
        },
        {
          id: 'p2',
          firstName: 'Luis',
          lastName: 'Mora',
          countryName: 'Costa Rica',
          positionName: 'Goalkeeper',
          shirtNumber: 1,
        },
      ],
    },
  };

  assert.deepEqual(
    collectGoalApiPlayerIdentities(payload).map((x) => x.external),
    ['p1', 'p2'],
  );

  const players = await normalizeGoalApiSquad(
    payload,
    'fb_team_test',
    async (_, external) => 'fb_player_' + external,
    '2026-09-18T13:30:00.000Z',
  );

  assert.equal(players.length, 2);
  assert.equal(players[0].teamId, 'fb_team_test');
  assert.equal(players[0].position, 'Forward');
  assert.equal(players[0].media.kind, 'PLAYER_PHOTO');
  assert.equal(players[0].age, 24);
  assert.equal(players[0].dateOfBirth, '2002-05-14');
  assert.equal(players[0].matchesPlayed, 18);
  assert.equal(players[0].goals, 7);
  assert.equal(players[0].assists, 4);
  assert.equal(players[0].yellowCards, 2);
  assert.equal(players[0].redCards, 0);
  assert.equal(players[0].rating, 7.4);
  assert.equal(players[0].injured, false);
  assert.equal(players[1].name, 'Luis Mora');
  assert.equal(players[1].shirtNumber, 1);
});

test('GOAL API squad normalizer drops untrusted photos and malformed players', async () => {
  const payload = {
    data: [
      {
        apiId: 'p3',
        playerName: 'Player Three',
        image: 'https://example.com/not-trusted.png',
      },
      { name: 'No id' },
    ],
  };

  const players = await normalizeGoalApiSquad(
    payload,
    'fb_team_test',
    async (_, external) => 'fb_player_' + external,
    '2026-09-18T13:30:00.000Z',
  );

  assert.equal(players.length, 1);
  assert.equal(players[0].media, null);
  assert.equal(players[0].provenance.externalId, 'p3');
});
