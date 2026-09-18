import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createSofaScoreProvider,
  normalizeSofaScoreFixtures,
} from '../providers/sofascore.mjs';

const resolver = () => {
  const map = new Map([
    ['team:1', 'fb_team_lda'],
    ['competition:10', 'fb_comp_cac'],
  ]);
  return async (kind, external, identity) => {
    const key = `${kind}:${external}`;
    if (map.has(key)) return map.get(key);
    if (kind === 'team' && identity.shortName === 'LDA') return 'fb_team_lda';
    return `fb_${kind}_${external}`;
  };
};

const event = (overrides = {}) => ({
  id: 9001,
  startTimestamp: Date.parse('2026-09-18T00:30:00Z') / 1000,
  status: { type: 'notstarted', description: 'Not started' },
  tournament: {
    id: 10010,
    name: 'Central American Cup',
    category: { name: 'CONCACAF' },
    uniqueTournament: { id: 10, name: 'Central American Cup' },
  },
  homeTeam: { id: 1, name: 'LD Alajuelense', nameCode: 'LDA', country: { name: 'Costa Rica' } },
  awayTeam: { id: 2, name: 'Marathon', nameCode: 'MAR', country: { name: 'Honduras' } },
  ...overrides,
});

test('SofaScore provider requests an unfiltered football date', async () => {
  const calls = [];
  const provider = createSofaScoreProvider({
    baseUrl: 'https://example.test/api/v1',
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      return Response.json({ events: [] });
    },
  });
  const body = await provider.fetchDate('2026-09-17');
  assert.deepEqual(body.events, []);
  assert.equal(calls.length, 1);
  assert.equal(
    calls[0].url,
    'https://example.test/api/v1/sport/football/scheduled-events/2026-09-17',
  );
  assert.match(calls[0].options.headers['user-agent'], /Android/);
});

test('global normalization keeps unknown competitions and canonical favorite identity', async () => {
  const unknown = event({
    id: 9002,
    tournament: {
      id: 19999,
      name: 'Unknown League',
      category: { name: 'Exampleland' },
      uniqueTournament: { id: 9999, name: 'Unknown League' },
    },
    homeTeam: { id: 3, name: 'Example FC', nameCode: 'EXA' },
    awayTeam: { id: 4, name: 'Other FC', nameCode: 'OTH' },
    startTimestamp: Date.parse('2026-09-18T02:00:00Z') / 1000,
  });

  const snapshot = await normalizeSofaScoreFixtures(
    [event(), unknown],
    resolver(),
    '2026-09-17T23:00:00Z',
  );

  assert.equal(snapshot.matches.length, 2);
  assert.ok(snapshot.competitions.some((item) => item.name === 'Unknown League'));
  assert.equal(snapshot.matches[0].homeTeamId, 'fb_team_lda');
  assert.equal(snapshot.coverage.source, 'FutBeat Global');
});

test('global normalization reuses an existing canonical match instead of duplicating it', async () => {
  const existing = {
    teams: [
      {
        id: 'fb_team_lda',
        name: 'Alajuelense',
        shortName: 'LDA',
        country: 'Costa Rica',
        competitionId: 'fb_comp_cr',
        aliases: [],
        media: null,
      },
      {
        id: 'fb_team_2',
        name: 'Marathon',
        shortName: 'MAR',
        country: 'Honduras',
        competitionId: 'fb_comp_cac',
        aliases: [],
        media: null,
      },
    ],
    matches: [
      {
        id: 'fb_match_existing',
        homeTeamId: 'fb_team_lda',
        awayTeamId: 'fb_team_2',
        startTime: '2026-09-18T00:30:00.000Z',
      },
    ],
  };

  const customResolve = async (kind, external, identity) => {
    if (kind === 'competition') return 'fb_comp_cac';
    if (kind === 'team' && identity.shortName === 'LDA') return 'fb_team_lda';
    if (kind === 'team' && identity.shortName === 'MAR') return 'fb_team_2';
    return `fb_${kind}_${external}`;
  };

  const snapshot = await normalizeSofaScoreFixtures(
    [event()],
    customResolve,
    '2026-09-17T23:00:00Z',
    existing,
  );

  assert.equal(snapshot.matches.length, 1);
  assert.equal(snapshot.matches[0].id, 'fb_match_existing');
});
