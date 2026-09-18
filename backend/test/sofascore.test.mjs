import test from 'node:test';
import assert from 'node:assert/strict';

import {
  fetchSofaScoreSchedule,
  normalizeSofaScoreSchedule,
} from '../providers/sofascore.mjs';

const event = ({
  id = 9001,
  tournamentId = 4739,
  tournament = 'CONCACAF Central American Cup',
  category = 'North & Central America',
  homeId = 1,
  home = 'LD Alajuelense',
  homeCode = 'LDA',
  awayId = 2,
  away = 'Marathón',
  awayCode = 'MAR',
  start = '2026-09-18T00:30:00Z',
} = {}) => ({
  id,
  startTimestamp: Math.floor(Date.parse(start) / 1000),
  status: { type: 'notstarted', description: 'Not started' },
  tournament: {
    id: tournamentId + 100000,
    name: tournament,
    category: { name: category },
    uniqueTournament: { id: tournamentId, name: tournament },
  },
  homeTeam: {
    id: homeId,
    name: home,
    nameCode: homeCode,
    country: { name: homeCode === 'LDA' ? 'Costa Rica' : category },
  },
  awayTeam: {
    id: awayId,
    name: away,
    nameCode: awayCode,
    country: { name: awayCode === 'MAR' ? 'Honduras' : category },
  },
});

test('fetchSofaScoreSchedule falls back host-by-host and keeps every event', async () => {
  const calls = [];
  const fetcher = async (url) => {
    calls.push(url);
    if (url.startsWith('https://primary.example')) {
      return new Response('blocked', { status: 403 });
    }
    return Response.json({
      events: [
        event(),
        event({
          id: 9002,
          tournamentId: 999999,
          tournament: 'Completely Unknown League',
          category: 'Exampleland',
          homeId: 300,
          home: 'Example FC',
          homeCode: 'EXA',
          awayId: 301,
          away: 'Another FC',
          awayCode: 'ANO',
          start: '2026-09-18T02:00:00Z',
        }),
      ],
    });
  };

  const raw = await fetchSofaScoreSchedule({
    dates: ['2026-09-17'],
    fetcher,
    primaryBase: 'https://primary.example/api/v1',
    fallbackBase: 'https://fallback.example/api/v1',
  });

  assert.equal(raw.results, 2);
  assert.equal(raw.days[0].events.length, 2);
  assert.equal(calls.length, 2);
  assert.match(calls[1], /fallback\.example/);
});

test('global normalizer accepts unknown competitions and reuses canonical team identity', async () => {
  const entityCalls = [];
  const matchCalls = [];

  const snapshot = await normalizeSofaScoreSchedule(
    {
      provider: 'SofaScore',
      days: [{
        date: '2026-09-17',
        endpoint: 'https://api.sofascore.com/api/v1',
        events: [
          event(),
          event({
            id: 9002,
            tournamentId: 999999,
            tournament: 'Completely Unknown League',
            category: 'Exampleland',
            homeId: 300,
            home: 'Example FC',
            homeCode: 'EXA',
            awayId: 301,
            away: 'Another FC',
            awayCode: 'ANO',
            start: '2026-09-18T02:00:00Z',
          }),
        ],
      }],
    },
    {
      resolveEntity: async (kind, externalId, identity) => {
        entityCalls.push({ kind, externalId, identity });
        if (kind === 'team' && identity.shortName === 'LDA') return 'fb_team_lda';
        return `fb_${kind}_sofa_${externalId}`;
      },
      resolveMatch: async (externalId, identity) => {
        matchCalls.push({ externalId, identity });
        return `fb_match_sofa_${externalId}`;
      },
    },
    '2026-09-17T23:00:00Z',
  );

  assert.equal(snapshot.demo, false);
  assert.equal(snapshot.matches.length, 2);
  assert.ok(snapshot.competitions.some((item) => item.name === 'Completely Unknown League'));

  const ldaMatch = snapshot.matches.find((item) => item.homeTeamId === 'fb_team_lda');
  assert.ok(ldaMatch);
  assert.equal(ldaMatch.provenance.source, 'SofaScore');

  const ldaResolve = entityCalls.find(
    (item) => item.kind === 'team' && item.identity.shortName === 'LDA',
  );
  assert.equal(ldaResolve.identity.country, 'Costa Rica');

  assert.equal(matchCalls[0].identity.homeTeamId, 'fb_team_lda');
  assert.match(
    snapshot.teams.find((item) => item.id === 'fb_team_lda').media.url,
    /img\.sofascore\.com\/api\/v1\/team\/1\/image/,
  );
});

test('global normalizer maps finished games without claiming final verification', async () => {
  const finished = event();
  finished.status = { type: 'finished', description: 'Ended' };
  finished.homeScore = { current: 2 };
  finished.awayScore = { current: 1 };

  const snapshot = await normalizeSofaScoreSchedule(
    {
      provider: 'SofaScore',
      days: [{ date: '2026-09-17', events: [finished] }],
    },
    {
      resolveEntity: async (kind, externalId) => `fb_${kind}_${externalId}`,
      resolveMatch: async (externalId) => `fb_match_${externalId}`,
    },
    '2026-09-17T23:00:00Z',
  );

  assert.equal(snapshot.matches[0].status, 'FINISHED_PENDING_VERIFICATION');
  assert.deepEqual(snapshot.matches[0].score, { home: 2, away: 1 });
  assert.equal(snapshot.matches[0].provenance.verificationStatus, 'PROVISIONAL');
});
