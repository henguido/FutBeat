import test from 'node:test';
import assert from 'node:assert/strict';
import { collectGoalApiBaseIdentities, normalizeGoalApiFixtures } from '../providers/goal_api.mjs';

function fixture(overrides = {}) {
  return {
    id: 'cms_test_fixture',
    apiId: '746486',
    countryName: 'Costa Rica',
    leagueId: 'goal_league_cr',
    leagueName: 'Primera Division',
    leagueYear: '2026/2027',
    league: {
      id: 'goal_league_cr',
      name: 'Primera Division',
      logo: 'https://media.goal-api.com/badges/logo_leagues/162_primera-division.png',
    },
    kickoffUtc: '2026-09-18T01:00:00.000Z',
    matchStatus: 'SCHEDULED',
    matchPeriod: 'NOT_STARTED',
    matchElapsed: null,
    homeTeam: {
      id: 'goal_team_lda',
      name: 'Alajuelense',
      badge: 'https://media.goal-api.com/badges/100_alajuelense.jpg',
    },
    awayTeam: {
      id: 'goal_team_sap',
      name: 'Saprissa',
      badge: 'https://media.goal-api.com/badges/101_saprissa.jpg',
    },
    homeTeamScore: null,
    awayTeamScore: null,
    matchStadium: 'Estadio Alejandro Morera Soto',
    ...overrides,
  };
}

function resolver() {
  return async (kind, external, identity) => {
    if (kind === 'team' && identity.name === 'Alajuelense') {
      return 'fb_team_lda';
    }
    if (kind === 'competition' && identity.name === 'Primera Division') {
      return 'fb_comp_cr';
    }
    return `fb_${kind}_${String(external).replace(/[^a-z0-9]/gi, '_')}`;
  };
}

test('GOAL API normalization keeps global competitions and canonical identities', async () => {
  const unknown = fixture({
    id: 'cms_unknown',
    apiId: '999002',
    countryName: 'Exampleland',
    leagueId: 'goal_league_unknown',
    leagueName: 'Unknown League',
    league: {
      id: 'goal_league_unknown',
      name: 'Unknown League',
      logo: null,
    },
    homeTeam: {
      id: 'goal_team_a',
      name: 'Example FC',
      badge: null,
    },
    awayTeam: {
      id: 'goal_team_b',
      name: 'Other FC',
      badge: null,
    },
    kickoffUtc: '2026-09-18T03:00:00.000Z',
  });

  const snapshot = await normalizeGoalApiFixtures(
    [fixture(), unknown],
    resolver(),
    '2026-09-18T04:40:00Z',
  );

  assert.equal(snapshot.matches.length, 2);
  assert.equal(snapshot.matches[0].homeTeamId, 'fb_team_lda');
  assert.ok(snapshot.competitions.some((item) => item.name === 'Unknown League'));
  assert.equal(snapshot.matches[0].provenance.source, 'GOAL API');
  assert.equal(snapshot.coverage.source, 'FutBeat Global');
});

test('GOAL API normalization reuses an existing canonical fixture', async () => {
  const existing = {
    competitions: [],
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
        id: 'fb_team_sap',
        name: 'Saprissa',
        shortName: 'SAP',
        country: 'Costa Rica',
        competitionId: 'fb_comp_cr',
        aliases: [],
        media: null,
      },
    ],
    matches: [{
      id: 'fb_match_existing',
      homeTeamId: 'fb_team_lda',
      awayTeamId: 'fb_team_sap',
      startTime: '2026-09-18T01:00:00.000Z',
    }],
  };

  const resolve = async (kind, external, identity) => {
    if (kind === 'competition') return 'fb_comp_cr';
    if (kind === 'team' && identity.name === 'Alajuelense') return 'fb_team_lda';
    if (kind === 'team' && identity.name === 'Saprissa') return 'fb_team_sap';
    return `fb_${kind}_${external}`;
  };

  const snapshot = await normalizeGoalApiFixtures(
    [fixture()],
    resolve,
    '2026-09-18T04:40:00Z',
    existing,
  );

  assert.equal(snapshot.matches.length, 1);
  assert.equal(snapshot.matches[0].id, 'fb_match_existing');
});

test('GOAL API live lifecycle retains score and parsed minute', async () => {
  const live = fixture({
    matchStatus: 'LIVE',
    matchPeriod: 'SECOND_HALF',
    matchElapsed: 72,
    homeTeamScore: '2',
    awayTeamScore: '1',
  });

  const snapshot = await normalizeGoalApiFixtures(
    [live],
    resolver(),
    '2026-09-18T04:40:00Z',
  );

  assert.equal(snapshot.matches[0].status, 'LIVE');
  assert.deepEqual(snapshot.matches[0].score, { home: 2, away: 1 });
  assert.equal(snapshot.matches[0].minute, 72);
});

test('GOAL API final lifecycle maps extra time and penalties to verified', async () => {
  for (const matchStatus of ['FINISHED', 'AFTER_ET', 'AFTER_PEN', 'AWARDED']) {
    const snapshot = await normalizeGoalApiFixtures(
      [fixture({
        matchStatus,
        matchPeriod: 'FINISHED',
        homeTeamScore: '1',
        awayTeamScore: '0',
      })],
      resolver(),
      '2026-09-18T04:40:00Z',
    );

    assert.equal(snapshot.matches[0].status, 'VERIFIED');
    // AFTER_PEN: the running total carries the shoot-out winner's bonus, so
    // without FtScore the result is unknown (status is still final).
    assert.deepEqual(snapshot.matches[0].score, matchStatus === 'AFTER_PEN' ? null : { home: 1, away: 0 });
  }
  // AFTER_PEN with FT + ET: the +1 bonus for the shoot-out winner is dropped.
  const snapshot = await normalizeGoalApiFixtures(
    [fixture({
      matchStatus: 'AFTER_PEN', matchPeriod: 'FINISHED',
      homeTeamScore: '1', awayTeamScore: '0', homeTeamFtScore: '0', awayTeamFtScore: '0',
      homeTeamExtraScore: '0', awayTeamExtraScore: '0', homeTeamPenaltyScore: '4', awayTeamPenaltyScore: '3',
    })],
    resolver(),
    '2026-09-18T04:40:00Z',
  );
  assert.equal(snapshot.matches[0].status, 'VERIFIED');
  assert.deepEqual(snapshot.matches[0].score, { home: 0, away: 0 });
});

test('GOAL API calendar never verifies a fixture before its UTC kickoff', async () => {
  const receivedAt = '2026-09-18T04:40:00.000Z';
  const snapshot = await normalizeGoalApiFixtures(
    [fixture({
      kickoffUtc: '2026-09-19T01:00:00.000Z',
      matchStatus: 'FINISHED',
      matchPeriod: 'FINISHED',
      homeTeamScore: '2',
      awayTeamScore: '1',
    })],
    resolver(),
    receivedAt,
  );

  assert.equal(snapshot.matches[0].status, 'SCHEDULED');
  assert.equal(snapshot.matches[0].score, null);
});

test('GOAL API terminal chronology rejects absent or invalid receivedAt before snapshot creation', async () => {
  const raw = fixture({
    matchStatus: 'FINISHED',
    matchPeriod: 'FINISHED',
    homeTeamScore: '2',
    awayTeamScore: '1',
  });

  for (const receivedAt of [undefined, null, '', 'not-an-instant']) {
    await assert.rejects(
      normalizeGoalApiFixtures([raw], resolver(), receivedAt),
      /Invalid receivedAt/,
    );
  }
});

test('GOAL API terminal chronology accepts kickoff equality and historical imports', async () => {
  const raw = fixture({
    matchStatus: 'FINISHED',
    matchPeriod: 'FINISHED',
    homeTeamScore: '2',
    awayTeamScore: '1',
  });

  for (const receivedAt of [raw.kickoffUtc, '2030-01-01T00:00:00.000Z']) {
    const snapshot = await normalizeGoalApiFixtures([raw], resolver(), receivedAt);
    assert.equal(snapshot.matches[0].status, 'VERIFIED');
    assert.deepEqual(snapshot.matches[0].score, { home: 2, away: 1 });
  }
});

test('GOAL API corrected future kickoff cannot leak any terminal status as VERIFIED', async () => {
  for (const matchStatus of ['FINISHED', 'AFTER_ET', 'AFTER_PEN', 'AWARDED']) {
    const snapshot = await normalizeGoalApiFixtures(
      [fixture({
        kickoffUtc: '2026-09-20T01:00:00.000Z',
        matchStatus,
        matchPeriod: 'FINISHED',
        homeTeamScore: '2',
        awayTeamScore: '1',
      })],
      resolver(),
      '2026-09-18T04:40:00.000Z',
    );

    assert.equal(snapshot.matches[0].status, 'SCHEDULED');
    assert.equal(snapshot.matches[0].score, null);
  }
});

test('GOAL API terminal chronology compares instants, not local calendar dates', async () => {
  const raw = fixture({
    kickoffUtc: '2026-09-18T23:30:00-06:00',
    matchStatus: 'FINISHED',
    matchPeriod: 'FINISHED',
    homeTeamScore: '2',
    awayTeamScore: '1',
  });
  const before = await normalizeGoalApiFixtures(
    [raw], resolver(), '2026-09-19T05:29:59.000Z',
  );
  const after = await normalizeGoalApiFixtures(
    [raw], resolver(), '2026-09-19T05:30:01.000Z',
  );

  assert.equal(before.matches[0].status, 'SCHEDULED');
  assert.equal(before.matches[0].score, null);
  assert.equal(after.matches[0].status, 'VERIFIED');
  assert.deepEqual(after.matches[0].score, { home: 2, away: 1 });
});

test('GOAL API keeps postponed, cancelled, suspended and abandoned explicit', async () => {
  for (const matchStatus of ['POSTPONED', 'CANCELLED', 'SUSPENDED', 'ABANDONED']) {
    const snapshot = await normalizeGoalApiFixtures(
      [fixture({ matchStatus })], resolver(), '2026-09-18T04:40:00Z',
    );
    assert.equal(snapshot.matches[0].status, matchStatus);
    assert.equal(snapshot.matches[0].score, null);
  }
});

test('GOAL API media outside its delivery host is rejected', async () => {
  const bad = fixture({
    homeTeam: {
      id: 'goal_team_lda',
      name: 'Alajuelense',
      badge: 'https://example.com/fake.png',
    },
  });

  await assert.rejects(
    normalizeGoalApiFixtures([bad], resolver(), '2026-09-18T04:40:00Z'),
    /Untrusted GOAL API TEAM_LOGO media URL/,
  );
});

test('GOAL API fixtures without an unambiguous kickoff are skipped', async () => {
  const snapshot = await normalizeGoalApiFixtures(
    [fixture({ kickoffUtc: null })],
    resolver(),
    '2026-09-18T04:40:00Z',
  );

  assert.equal(snapshot.matches.length, 0);
});


test('GOAL API base identity collection deduplicates competitions and teams', () => {
  const second = fixture({
    id: 'cms_second',
    apiId: '746487',
    kickoffUtc: '2026-09-18T02:00:00.000Z',
    awayTeam: {
      id: 'goal_team_csh',
      name: 'Herediano',
      badge: null,
    },
  });

  const identities = collectGoalApiBaseIdentities([
    fixture(),
    second,
    fixture({ kickoffUtc: null }),
  ]);

  const keys = identities.map((item) => `${item.kind}:${item.external}`).sort();
  assert.deepEqual(keys, [
    'competition:goal_league_cr',
    'team:goal_team_csh',
    'team:goal_team_lda',
    'team:goal_team_sap',
  ]);
  assert.equal(
    identities.find((item) => item.kind === 'competition')?.country,
    'Costa Rica',
  );
});

test('GOAL API badge replaces an empty or url-less stored media, never a usable one', async () => {
  const kept = { url: 'https://media.goal-api.com/badges/old_saprissa.jpg', kind: 'TEAM_LOGO', verificationStatus: 'VERIFIED',
    source: 'GOAL API', rightsStatus: 'REVIEW_REQUIRED', usageScope: 'DEVELOPMENT_ONLY', receivedAt: '2026-09-01T00:00:00Z' };
  const existing = {
    competitions: [{ id: 'fb_comp_cr', name: 'Primera', country: 'Costa Rica', season: '', media: {} }],
    teams: [
      { id: 'fb_team_lda', name: 'Alajuelense', shortName: '', country: '', competitionId: 'fb_comp_cr', aliases: [], media: {} },
      { id: 'fb_team_sap', name: 'Saprissa', shortName: '', country: '', competitionId: 'fb_comp_cr', aliases: [], media: kept },
    ],
    matches: [],
  };
  const resolve = async (kind, external, identity) => {
    if (kind === 'competition') return 'fb_comp_cr';
    if (kind === 'team' && identity.name === 'Alajuelense') return 'fb_team_lda';
    if (kind === 'team' && identity.name === 'Saprissa') return 'fb_team_sap';
    return `fb_${kind}_${external}`;
  };
  const snapshot = await normalizeGoalApiFixtures([fixture()], resolve, '2026-09-18T04:40:00Z', existing);
  const team = (id) => snapshot.teams.find((item) => item.id === id);
  assert.equal(team('fb_team_lda').media.url, 'https://media.goal-api.com/badges/100_alajuelense.jpg');
  assert.equal(team('fb_team_lda').media.verificationStatus, 'VERIFIED');
  assert.deepEqual(team('fb_team_sap').media, kept);
  assert.equal(snapshot.competitions[0].media.url, 'https://media.goal-api.com/badges/logo_leagues/162_primera-division.png');
});

// BE11-A3: the compact calendar read (`existing` in calendar mode) carries only
// {url, verificationStatus}; writing it back dropped source/rightsStatus.
test('GOAL API badge upgrades compact (lossy) stored media; lossy media survives without a badge', async () => {
  const lossy = (url) => ({ url, verificationStatus: 'VERIFIED' });
  const existing = {
    competitions: [{ id: 'fb_comp_cr', name: 'Primera', country: 'Costa Rica', season: '',
      media: lossy('https://media.goal-api.com/badges/logo_leagues/162_primera-division.png') }],
    teams: [
      { id: 'fb_team_lda', name: 'Alajuelense', shortName: '', competitionId: 'fb_comp_cr',
        media: lossy('https://media.goal-api.com/badges/100_alajuelense.jpg') },
      { id: 'fb_team_sap', name: 'Saprissa', shortName: '', competitionId: 'fb_comp_cr',
        media: lossy('https://media.goal-api.com/badges/old_saprissa.jpg') },
    ],
    matches: [],
  };
  const resolve = async (kind, external, identity) => {
    if (kind === 'competition') return 'fb_comp_cr';
    if (kind === 'team' && identity.name === 'Alajuelense') return 'fb_team_lda';
    if (kind === 'team' && identity.name === 'Saprissa') return 'fb_team_sap';
    return `fb_${kind}_${external}`;
  };
  const raw = fixture();
  delete raw.awayTeam.badge;
  delete raw.teamAwayBadge;
  const snapshot = await normalizeGoalApiFixtures([raw], resolve, '2026-09-18T04:40:00Z', existing);
  const team = (id) => snapshot.teams.find((item) => item.id === id);
  // Fresh badge -> complete GOAL media (provenance and rights restored).
  assert.equal(team('fb_team_lda').media.source, 'GOAL API');
  assert.equal(team('fb_team_lda').media.rightsStatus, 'REVIEW_REQUIRED');
  assert.equal(team('fb_team_lda').media.usageScope, 'DEVELOPMENT_ONLY');
  assert.equal(snapshot.competitions[0].media.source, 'GOAL API');
  // No badge in this fixture -> the lossy but displayable media is kept.
  assert.deepEqual(team('fb_team_sap').media, lossy('https://media.goal-api.com/badges/old_saprissa.jpg'));
});
