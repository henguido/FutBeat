import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeEspnFixtures } from '../providers/espn.mjs';

function event(overrides = {}) {
  return {
    id: '401999001',
    date: '2026-09-18T00:30:00Z',
    season: {
      year: 2026,
      type: 91001,
      slug: '2026-concacaf-central-american-cup',
    },
    status: {
      type: {
        state: 'pre',
        completed: false,
        detail: 'Scheduled',
      },
    },
    competitions: [{
      id: '401999001',
      date: '2026-09-18T00:30:00Z',
      competitors: [
        {
          id: '1',
          homeAway: 'home',
          score: '0',
          team: {
            id: '1',
            displayName: 'Alajuelense',
            abbreviation: 'LDA',
            logo: 'https://a.espncdn.com/i/teamlogos/soccer/500/1.png',
          },
        },
        {
          id: '2',
          homeAway: 'away',
          score: '0',
          team: {
            id: '2',
            displayName: 'Marathón',
            abbreviation: 'MAR',
            logo: 'https://a.espncdn.com/i/teamlogos/soccer/500/2.png',
          },
        },
      ],
      status: {
        type: {
          state: 'pre',
          completed: false,
          detail: 'Scheduled',
        },
      },
    }],
    ...overrides,
  };
}

function resolver() {
  return async (kind, external, identity) => {
    if (kind === 'team' && (identity.name === 'Alajuelense' || identity.shortName === 'LDA')) {
      return 'fb_team_lda';
    }
    if (kind === 'competition' && identity.name === 'CONCACAF Central American Cup') {
      return 'fb_comp_cac';
    }
    return `fb_${kind}_${String(external).replace(/[^a-z0-9]/gi, '_')}`;
  };
}

test('ESPN normalization keeps an unknown competition and canonical favorite identity', async () => {
  const unknown = event({
    id: '401999002',
    date: '2026-09-18T02:00:00Z',
    season: {
      year: 2026,
      type: 99999,
      slug: '2026-completely-unknown-league',
    },
    competitions: [{
      id: '401999002',
      date: '2026-09-18T02:00:00Z',
      competitors: [
        {
          id: '300',
          homeAway: 'home',
          team: {
            id: '300',
            displayName: 'Example FC',
            abbreviation: 'EXA',
            logo: 'https://a.espncdn.com/i/teamlogos/soccer/500/300.png',
          },
        },
        {
          id: '301',
          homeAway: 'away',
          team: {
            id: '301',
            displayName: 'Another FC',
            abbreviation: 'ANO',
            logo: 'https://a.espncdn.com/i/teamlogos/soccer/500/301.png',
          },
        },
      ],
      status: { type: { state: 'pre', completed: false } },
    }],
  });

  const snapshot = await normalizeEspnFixtures(
    [event(), unknown],
    resolver(),
    '2026-09-17T23:00:00Z',
  );

  assert.equal(snapshot.matches.length, 2);
  assert.equal(snapshot.matches[0].homeTeamId, 'fb_team_lda');
  assert.ok(snapshot.competitions.some((item) => item.name === 'Completely Unknown League'));
  assert.equal(snapshot.coverage.source, 'FutBeat Global');
  assert.equal(snapshot.matches[0].provenance.source, 'ESPN');
});

test('ESPN normalization reuses an existing canonical fixture', async () => {
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
        name: 'Marathón',
        shortName: 'MAR',
        country: 'Honduras',
        competitionId: 'fb_comp_cac',
        aliases: [],
        media: null,
      },
    ],
    matches: [{
      id: 'fb_match_existing',
      homeTeamId: 'fb_team_lda',
      awayTeamId: 'fb_team_2',
      startTime: '2026-09-18T00:30:00.000Z',
    }],
  };

  const resolve = async (kind, external, identity) => {
    if (kind === 'competition') return 'fb_comp_cac';
    if (kind === 'team' && identity.shortName === 'LDA') return 'fb_team_lda';
    if (kind === 'team' && identity.shortName === 'MAR') return 'fb_team_2';
    return `fb_${kind}_${external}`;
  };

  const snapshot = await normalizeEspnFixtures(
    [event()],
    resolve,
    '2026-09-17T23:00:00Z',
    existing,
  );

  assert.equal(snapshot.matches.length, 1);
  assert.equal(snapshot.matches[0].id, 'fb_match_existing');
});

test('ESPN finished and live statuses retain real scores only after kickoff', async () => {
  const live = event({
    status: { type: { state: 'in', completed: false, detail: '2nd Half' } },
    competitions: [{
      id: '401999001',
      date: '2026-09-18T00:30:00Z',
      competitors: [
        {
          id: '1',
          homeAway: 'home',
          score: '2',
          team: {
            id: '1',
            displayName: 'Alajuelense',
            abbreviation: 'LDA',
            logo: 'https://a.espncdn.com/i/teamlogos/soccer/500/1.png',
          },
        },
        {
          id: '2',
          homeAway: 'away',
          score: '1',
          team: {
            id: '2',
            displayName: 'Marathón',
            abbreviation: 'MAR',
            logo: 'https://a.espncdn.com/i/teamlogos/soccer/500/2.png',
          },
        },
      ],
      status: {
        displayClock: "72'",
        type: { state: 'in', completed: false, detail: '2nd Half' },
      },
    }],
  });

  const snapshot = await normalizeEspnFixtures(
    [live],
    resolver(),
    '2026-09-17T23:00:00Z',
  );

  assert.equal(snapshot.matches[0].status, 'LIVE');
  assert.deepEqual(snapshot.matches[0].score, { home: 2, away: 1 });
  assert.equal(snapshot.matches[0].minute, 72);
});

test('ESPN media outside its CDN is rejected', async () => {
  const bad = event();
  bad.competitions[0].competitors[0].team.logo = 'https://example.com/fake.png';

  await assert.rejects(
    normalizeEspnFixtures([bad], resolver(), '2026-09-17T23:00:00Z'),
    /Untrusted ESPN TEAM_LOGO media URL/,
  );
});
