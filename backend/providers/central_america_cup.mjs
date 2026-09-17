const base = 'https://www.thesportsdb.com/api/v1/json/123/';
const leagueId = '4739';
const source = 'TheSportsDB';

const requestOptions = () => ({
  headers: {
    accept: 'application/json',
    'user-agent': 'FutBeat/0.1 (+https://github.com/henguido/FutBeat)',
  },
  signal: AbortSignal.timeout(15000),
});

function required(value, label) {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`Missing ${label}`);
  return value.trim();
}

function providerMedia(value, receivedAt, kind) {
  if (value == null || value === '') return null;
  const url = new URL(String(value));
  if (
    url.protocol !== 'https:' ||
    (url.hostname !== 'thesportsdb.com' && !url.hostname.endsWith('.thesportsdb.com'))
  ) {
    throw new Error(`Untrusted ${kind} media URL`);
  }
  return {
    url: url.toString(),
    kind,
    source,
    receivedAt,
    verificationStatus: 'VERIFIED',
    rightsStatus: 'REVIEW_REQUIRED',
    usageScope: 'DEVELOPMENT_ONLY',
  };
}

async function getJson(endpoint, fetcher = fetch) {
  const response = await fetcher(base + endpoint, requestOptions());
  if (!response.ok) throw new Error(`TheSportsDB HTTP ${response.status}`);
  return response.json();
}

export async function fetchCentralAmericaCup({ fetcher = fetch } = {}) {
  const [league, next, past] = await Promise.all([
    getJson(`lookupleague.php?id=${leagueId}`, fetcher),
    getJson(`eventsnextleague.php?id=${leagueId}`, fetcher),
    getJson(`eventspastleague.php?id=${leagueId}`, fetcher),
  ]);
  return { league, next, past };
}

function score(value) {
  if (value == null || value === '') return null;
  if (!/^\d+$/.test(String(value))) throw new Error('Invalid provider score');
  return Number(value);
}

function statusFor(event) {
  const value = String(event.strStatus ?? '').trim();
  if (!value || value === 'NS') return 'SCHEDULED';
  const mapped = {
    FT: 'FINISHED_PENDING_VERIFICATION',
    PST: 'POSTPONED',
    CANC: 'CANCELLED',
    SUSP: 'SUSPENDED',
    ABD: 'ABANDONED',
  }[value];
  if (!mapped) throw new Error(`Unsupported provider status: ${value}`);
  return mapped;
}

function startTimeFor(event) {
  const timestamp = required(event.strTimestamp, 'UTC timestamp');
  const withZone = /(?:Z|[+-]\d\d:\d\d)$/.test(timestamp)
    ? timestamp
    : `${timestamp}Z`;
  const parsed = new Date(withZone);
  if (!Number.isFinite(parsed.getTime())) throw new Error('Invalid timestamp');
  return parsed.toISOString();
}

export async function normalizeCentralAmericaCup(raw, resolve, receivedAt) {
  const league = raw.league?.leagues?.find((item) => String(item.idLeague) === leagueId);
  if (!league || league.strSport !== 'Soccer') throw new Error('Missing Central American Cup');

  const competitionId = await resolve('competition', leagueId);
  const competition = {
    id: competitionId,
    name: required(league.strLeague, 'competition name'),
    country: 'CONCACAF',
    season: league.strCurrentSeason ?? '',
    media: providerMedia(league.strBadge, receivedAt, 'COMPETITION_LOGO'),
  };

  const teams = new Map();
  const matches = new Map();
  const teamIdsByExternal = new Map();

  const addTeam = async (externalIdValue, nameValue, mediaValue) => {
    const externalId = required(String(externalIdValue ?? ''), 'team ID');
    const name = required(nameValue, 'team name');
    let id = teamIdsByExternal.get(externalId);
    if (!id) {
      id = await resolve('team', externalId);
      teamIdsByExternal.set(externalId, id);
    }
    const previous = teams.get(id);
    teams.set(id, {
      id,
      name: previous?.name ?? name,
      shortName: previous?.shortName ?? '',
      country: previous?.country ?? 'Centroamérica',
      competitionId,
      media: providerMedia(mediaValue, receivedAt, 'TEAM_LOGO') ?? previous?.media ?? null,
      aliases: previous?.aliases ?? [],
    });
    return id;
  };

  for (const envelope of [raw.past, raw.next]) {
    const events = envelope?.events;
    if (events != null && !Array.isArray(events)) throw new Error('Invalid events response');
    for (const event of events ?? []) {
      if (String(event.idLeague) !== leagueId || event.strSport !== 'Soccer') continue;
      const matchId = await resolve('match', required(String(event.idEvent ?? ''), 'event ID'));
      const homeTeamId = await addTeam(event.idHomeTeam, event.strHomeTeam, event.strHomeTeamBadge);
      const awayTeamId = await addTeam(event.idAwayTeam, event.strAwayTeam, event.strAwayTeamBadge);
      const status = statusFor(event);
      const home = score(event.intHomeScore);
      const away = score(event.intAwayScore);
      if ((home === null) !== (away === null)) throw new Error('Incomplete score');
      matches.set(matchId, {
        id: matchId,
        competitionId,
        season: String(event.strSeason ?? league.strCurrentSeason ?? ''),
        homeTeamId,
        awayTeamId,
        startTime: startTimeFor(event),
        status,
        score: home === null ? null : { home, away },
        minute: null,
        venue: event.strVenue ?? '',
        events: [],
        statistics: [],
        provenance: {
          source,
          externalId: String(event.idEvent),
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
    coverage: {
      source,
      partial: true,
      live: false,
      developmentOnly: true,
      description: 'Copa Centroamericana desde TheSportsDB',
    },
    competitions: [competition],
    teams: [...teams.values()],
    players: [],
    matches: [...matches.values()],
    standings: [],
    news: [],
    transfers: [],
  };
}
