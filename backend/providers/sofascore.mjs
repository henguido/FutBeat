import { validateSnapshot } from './core/snapshot.mjs';

const clean = (value) => String(value ?? '').trim();
const providerId = (value) => {
  const id = clean(value);
  if (!/^\d+$/.test(id)) throw new Error('Invalid SofaScore id');
  return id;
};
const media = (url, kind, receivedAt) => ({
  url, kind, source: 'SofaScore', receivedAt,
  verificationStatus: 'VERIFIED',
  rightsStatus: 'REVIEW_REQUIRED',
  usageScope: 'DEVELOPMENT_ONLY',
});
const status = (event) => {
  const type = clean(event?.status?.type).toLowerCase();
  const description = clean(event?.status?.description).toLowerCase();
  if (type === 'inprogress') {
    if (description.includes('half') || description.includes('interval')) return 'HALFTIME';
    return 'LIVE';
  }
  if (type === 'finished') return 'VERIFIED';
  if (type === 'postponed') return 'POSTPONED';
  if (type === 'suspended') return 'SUSPENDED';
  if (type === 'canceled' || type === 'cancelled') return 'CANCELLED';
  return 'SCHEDULED';
};
const fixtureKey = (home, away, start) =>
  `${home}|${away}|${Math.floor(Date.parse(start) / 300000)}`;

export function createSofaScoreProvider({ fetchImpl = fetch, baseUrl = 'https://api.sofascore.com/api/v1' } = {}) {
  return {
    async fetchDate(date) {
      const response = await fetchImpl(`${baseUrl}/sport/football/scheduled-events/${date}`, {
        headers: {
          accept: 'application/json,text/plain,*/*',
          origin: 'https://www.sofascore.com',
          referer: 'https://www.sofascore.com/',
          'user-agent': 'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 Chrome/140.0 Mobile Safari/537.36',
        },
        signal: AbortSignal.timeout(15000),
      });
      if (!response.ok) throw new Error(`SofaScore HTTP ${response.status}`);
      const body = await response.json();
      if (!Array.isArray(body?.events)) throw new Error('Invalid SofaScore response');
      return body;
    },
  };
}

export async function normalizeSofaScoreFixtures(rawEvents, resolve, receivedAt, existing = null) {
  const competitions = new Map();
  const teams = new Map();
  const matches = new Map();
  const existingFixtures = new Map();

  if (existing) {
    for (const match of existing.matches ?? []) {
      existingFixtures.set(fixtureKey(match.homeTeamId, match.awayTeamId, match.startTime), match.id);
    }
  }

  for (const event of rawEvents) {
    const tournament = event?.tournament;
    const unique = tournament?.uniqueTournament ?? tournament;
    const home = event?.homeTeam;
    const away = event?.awayTeam;
    if (!unique || !home || !away || !Number.isFinite(event?.startTimestamp)) continue;

    const competitionExternal = providerId(unique.id);
    const competitionName = clean(unique.name || tournament.name);
    const country = clean(tournament?.category?.name);
    if (!competitionName) continue;

    const competitionId = await resolve('competition', competitionExternal, {
      name: competitionName,
      country,
      shortName: '',
    });
    competitions.set(competitionId, {
      id: competitionId,
      name: competitionName,
      country,
      season: '',
      media: media(
        `https://img.sofascore.com/api/v1/unique-tournament/${competitionExternal}/image`,
        'COMPETITION_LOGO',
        receivedAt,
      ),
    });

    const normalizeTeam = async (team) => {
      const external = providerId(team.id);
      const name = clean(team.name);
      const shortName = clean(team.nameCode || team.shortName);
      const teamCountry = clean(team?.country?.name) || country;
      const id = await resolve('team', external, { name, country: teamCountry, shortName });
      if (!teams.has(id)) {
        const previous = existing?.teams?.find?.((item) => item.id === id);
        teams.set(id, previous ? {
          ...previous,
          media: previous.media ?? media(
            `https://img.sofascore.com/api/v1/team/${external}/image`,
            'TEAM_LOGO',
            receivedAt,
          ),
        } : {
          id,
          name,
          shortName,
          competitionId,
          country: teamCountry,
          aliases: [],
          media: media(
            `https://img.sofascore.com/api/v1/team/${external}/image`,
            'TEAM_LOGO',
            receivedAt,
          ),
        });
      }
      return id;
    };

    const homeId = await normalizeTeam(home);
    const awayId = await normalizeTeam(away);
    const startTime = new Date(event.startTimestamp * 1000).toISOString();
    const key = fixtureKey(homeId, awayId, startTime);
    const matchExternal = providerId(event.id);
    const matchId = existingFixtures.get(key) ??
      await resolve('match', matchExternal, { name: '', country: '', shortName: '' });

    const homeScore = event?.homeScore?.current;
    const awayScore = event?.awayScore?.current;
    const score = Number.isInteger(homeScore) && Number.isInteger(awayScore)
      ? { home: homeScore, away: awayScore }
      : null;

    matches.set(matchId, {
      id: matchId,
      competitionId,
      season: '',
      homeTeamId: homeId,
      awayTeamId: awayId,
      startTime,
      status: status(event),
      score,
      minute: null,
      venue: clean(event?.venue?.stadium?.name || event?.venue?.name),
      events: [],
      statistics: [],
      provenance: {
        source: 'SofaScore',
        externalId: matchExternal,
        receivedAt,
        verificationStatus: 'PROVISIONAL',
      },
    });
  }

  return validateSnapshot({
    schemaVersion: 1,
    demo: false,
    updatedAt: receivedAt,
    coverage: {
      source: 'FutBeat Global',
      partial: true,
      live: false,
      developmentOnly: true,
      description: 'Calendario global centralizado por fecha',
      sources: ['SofaScore'],
    },
    competitions: [...competitions.values()],
    teams: [...teams.values()],
    players: [],
    matches: [...matches.values()],
    standings: [],
  });
}
