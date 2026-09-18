const PRIMARY_BASE = 'https://api.sofascore.com/api/v1';
const FALLBACK_BASE = 'https://www.sofascore.com/api/v1';
const SOURCE = 'SofaScore';

export const sofaScoreCoverage = Object.freeze({
  source: 'FutBeat Global',
  partial: true,
  live: false,
  developmentOnly: true,
  description: 'Calendario global cacheado por FutBeat; favoritos solo cambian el orden.',
  sources: [SOURCE],
});

const browserHeaders = Object.freeze({
  accept: 'application/json,text/plain,*/*',
  origin: 'https://www.sofascore.com',
  referer: 'https://www.sofascore.com/',
  'user-agent':
    'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/140.0 Mobile Safari/537.36',
});

function validDate(value) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(value ?? ''));
}

function requiredId(value, label) {
  const text = String(value ?? '').trim();
  if (!/^\d+$/.test(text)) throw new Error(`Invalid ${label}`);
  return text;
}

function requiredName(value, label) {
  const text = String(value ?? '').trim();
  if (!text) throw new Error(`Missing ${label}`);
  return text;
}

function object(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
}

function media(url, receivedAt, kind) {
  if (typeof url !== 'string' || !url.startsWith('https://img.sofascore.com/')) return null;
  return {
    url,
    kind,
    source: SOURCE,
    receivedAt,
    verificationStatus: 'VERIFIED',
    rightsStatus: 'REVIEW_REQUIRED',
    usageScope: 'DEVELOPMENT_ONLY',
  };
}

function score(value) {
  const current = object(value)?.current;
  return Number.isFinite(current) ? Number(current) : null;
}

function mapStatus(event) {
  const status = object(event.status);
  const type = String(status?.type ?? '').toLowerCase();
  const description = String(status?.description ?? '').toLowerCase();

  if (type === 'inprogress') {
    if (description.includes('half') || description.includes('interval')) return 'HALFTIME';
    return 'LIVE';
  }
  if (type === 'finished') return 'FINISHED_PENDING_VERIFICATION';
  if (type === 'postponed') return 'POSTPONED';
  if (type === 'canceled' || type === 'cancelled') return 'CANCELLED';
  if (type === 'suspended') return 'SUSPENDED';
  return 'SCHEDULED';
}

function venue(event) {
  const direct = object(event.venue);
  const stadium = object(direct?.stadium);
  return String(stadium?.name ?? direct?.name ?? '');
}

async function fetchDate(baseUrl, date, fetcher) {
  const response = await fetcher(
    `${baseUrl}/sport/football/scheduled-events/${date}`,
    { headers: browserHeaders, signal: AbortSignal.timeout(15000) },
  );
  if (!response.ok) throw new Error(`SofaScore HTTP ${response.status}`);
  const body = await response.json();
  if (!body || !Array.isArray(body.events)) throw new Error('Invalid SofaScore schedule');
  return body.events;
}

export async function fetchSofaScoreSchedule({
  dates,
  fetcher = fetch,
  primaryBase = PRIMARY_BASE,
  fallbackBase = FALLBACK_BASE,
} = {}) {
  if (!Array.isArray(dates) || dates.length === 0 || dates.some((date) => !validDate(date))) {
    throw new Error('Invalid schedule dates');
  }

  const days = [];
  for (const date of dates) {
    let events;
    let endpoint = primaryBase;
    try {
      events = await fetchDate(primaryBase, date, fetcher);
    } catch (primaryError) {
      endpoint = fallbackBase;
      try {
        events = await fetchDate(fallbackBase, date, fetcher);
      } catch (fallbackError) {
        const error = new Error(`Global schedule unavailable for ${date}`);
        error.cause = { primaryError, fallbackError };
        throw error;
      }
    }
    days.push({ date, endpoint, events });
  }
  return {
    provider: SOURCE,
    days,
    results: days.reduce((total, day) => total + day.events.length, 0),
  };
}

export async function normalizeSofaScoreSchedule(
  raw,
  { resolveEntity, resolveMatch },
  receivedAt,
) {
  if (!raw || !Array.isArray(raw.days)) throw new Error('Invalid SofaScore raw payload');
  if (typeof resolveEntity !== 'function' || typeof resolveMatch !== 'function') {
    throw new Error('Global resolvers are required');
  }
  if (!Number.isFinite(Date.parse(receivedAt))) throw new Error('Invalid receivedAt');

  const competitions = new Map();
  const teams = new Map();
  const matches = new Map();

  for (const day of raw.days) {
    if (!validDate(day.date) || !Array.isArray(day.events)) throw new Error('Invalid SofaScore day');

    for (const event of day.events) {
      const eventId = requiredId(event.id, 'event ID');
      const tournament = object(event.tournament);
      const uniqueTournament = object(tournament?.uniqueTournament);
      const competitionSource = uniqueTournament ?? tournament;
      const home = object(event.homeTeam);
      const away = object(event.awayTeam);
      if (!tournament || !competitionSource || !home || !away) continue;

      const timestamp = event.startTimestamp;
      if (!Number.isFinite(timestamp)) continue;
      const startTime = new Date(Number(timestamp) * 1000).toISOString();

      const competitionExternal = requiredId(competitionSource.id, 'competition ID');
      const competitionName = requiredName(
        competitionSource.name ?? tournament.name,
        'competition name',
      );
      const category = object(tournament.category);
      const competitionCountry = String(category?.name ?? '');
      const competitionId = await resolveEntity('competition', competitionExternal, {
        name: competitionName,
        country: competitionCountry,
        shortName: '',
      });

      competitions.set(competitionId, {
        id: competitionId,
        name: competitionName,
        country: competitionCountry,
        season: '',
        media: uniqueTournament
          ? media(
              `https://img.sofascore.com/api/v1/unique-tournament/${competitionExternal}/image`,
              receivedAt,
              'COMPETITION_LOGO',
            )
          : null,
      });

      const teamIds = {};
      for (const [side, team] of [['home', home], ['away', away]]) {
        const externalId = requiredId(team.id, `${side} team ID`);
        const name = requiredName(team.name, `${side} team name`);
        const teamCountry = String(object(team.country)?.name ?? competitionCountry);
        const shortName = String(team.nameCode ?? team.shortName ?? '').trim();
        const canonicalId = await resolveEntity('team', externalId, {
          name,
          country: teamCountry,
          shortName,
        });
        teamIds[side] = canonicalId;
        teams.set(canonicalId, {
          id: canonicalId,
          name,
          shortName,
          country: teamCountry,
          competitionId,
          aliases: [],
          media: media(
            `https://img.sofascore.com/api/v1/team/${externalId}/image`,
            receivedAt,
            'TEAM_LOGO',
          ),
        });
      }
      if (teamIds.home === teamIds.away) throw new Error('Home and away team cannot be the same');

      const homeScore = score(event.homeScore);
      const awayScore = score(event.awayScore);
      if ((homeScore === null) !== (awayScore === null)) {
        throw new Error('Incomplete SofaScore score');
      }

      const matchId = await resolveMatch(eventId, {
        homeTeamId: teamIds.home,
        awayTeamId: teamIds.away,
        startTime,
      });

      matches.set(matchId, {
        id: matchId,
        competitionId,
        season: '',
        homeTeamId: teamIds.home,
        awayTeamId: teamIds.away,
        startTime,
        status: mapStatus(event),
        score: homeScore === null ? null : { home: homeScore, away: awayScore },
        minute: null,
        venue: venue(event),
        events: [],
        statistics: [],
        provenance: {
          source: SOURCE,
          externalId: eventId,
          receivedAt,
          verificationStatus: 'PROVISIONAL',
        },
      });
    }
  }

  return {
    schemaVersion: 1,
    demo: false,
    updatedAt: receivedAt,
    coverage: sofaScoreCoverage,
    competitions: [...competitions.values()],
    teams: [...teams.values()],
    players: [],
    matches: [...matches.values()],
    standings: [],
    news: [],
    transfers: [],
  };
}
