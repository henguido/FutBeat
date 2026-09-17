import test from 'node:test';
import assert from 'node:assert/strict';

import { normalize as normalizeCostaRica } from '../providers/thesportsdb.mjs';

const resolve = async (kind, externalId) => `fb_${kind}_${externalId}`;
const receivedAt = '2026-09-17T18:00:00Z';

function rawCostaRica({ directTeams = true } = {}) {
  return {
    league: {
      leagues: [{
        idLeague: '4815',
        strSport: 'Soccer',
        strLeague: 'Costa-Rica Liga FPD',
        strCountry: 'Costa Rica',
        strCurrentSeason: '2026-2027',
        strBadge: 'https://r2.thesportsdb.com/images/media/league/badge/test.png',
      }],
    },
    teams: directTeams ? {
      teams: [
        {
          idTeam: '139705',
          idLeague: '4815',
          strCountry: 'Costa Rica',
          strSport: 'Soccer',
          strTeam: 'Equipo A',
          strTeamShort: 'A',
          strBadge: 'https://r2.thesportsdb.com/images/media/team/badge/team-a.png',
        },
        {
          idTeam: '139703',
          idLeague: '4815',
          strCountry: 'Costa Rica',
          strSport: 'Soccer',
          strTeam: 'Equipo B',
          strTeamShort: 'B',
          strBadge: 'https://www.thesportsdb.com/images/media/team/badge/team-b.png',
        },
      ],
    } : undefined,
    next: {
      events: [{
        idEvent: 'test-1',
        idLeague: '4815',
        strSport: 'Soccer',
        strHomeTeam: 'Equipo A',
        strAwayTeam: 'Equipo B',
        idHomeTeam: '139705',
        idAwayTeam: '139703',
        strStatus: 'NS',
        strSeason: '2026-2027',
        strTimestamp: '2026-09-19T02:00:00',
        intHomeScore: null,
        intAwayScore: null,
        strHomeTeamBadge: 'https://r2.thesportsdb.com/images/media/team/badge/event-a.png',
        strAwayTeamBadge: 'https://r2.thesportsdb.com/images/media/team/badge/event-b.png',
      }],
    },
    past: { events: null },
    table: { table: null },
  };
}

test('TheSportsDB normalizes league and team artwork with source and rights metadata', async () => {
  const snapshot = await normalizeCostaRica(rawCostaRica(), resolve, receivedAt);
  assert.equal(snapshot.competitions[0].media.kind, 'COMPETITION_LOGO');
  assert.equal(snapshot.competitions[0].media.source, 'TheSportsDB');
  assert.equal(snapshot.competitions[0].media.verificationStatus, 'VERIFIED');
  assert.equal(snapshot.competitions[0].media.rightsStatus, 'REVIEW_REQUIRED');
  assert.equal(snapshot.competitions[0].media.usageScope, 'DEVELOPMENT_ONLY');

  const teamA = snapshot.teams.find((team) => team.id === 'fb_team_139705');
  assert.equal(teamA.media.url, 'https://r2.thesportsdb.com/images/media/team/badge/event-a.png');
  assert.equal(teamA.media.kind, 'TEAM_LOGO');
});

test('Costa Rica event observations can supply team badges when the teams endpoint is unavailable', async () => {
  const snapshot = await normalizeCostaRica(rawCostaRica({ directTeams: false }), resolve, receivedAt);
  const teamA = snapshot.teams.find((team) => team.id === 'fb_team_139705');
  const teamB = snapshot.teams.find((team) => team.id === 'fb_team_139703');
  assert.equal(teamA.media.url, 'https://r2.thesportsdb.com/images/media/team/badge/event-a.png');
  assert.equal(teamB.media.url, 'https://r2.thesportsdb.com/images/media/team/badge/event-b.png');
});

test('TheSportsDB normalization rejects artwork outside its own HTTPS hosts', async () => {
  const raw = rawCostaRica();
  raw.teams.teams[0].strBadge = 'https://example.com/fake.png';
  await assert.rejects(
    normalizeCostaRica(raw, resolve, receivedAt),
    /Untrusted TEAM_LOGO media URL/,
  );
});
