const base = 'https://www.thesportsdb.com/api/v1/json/123/';
const requestOptions = () => ({
  headers: { accept: 'application/json', 'user-agent': 'FutBeat/0.1 (+https://github.com/henguido/FutBeat)' },
  signal: AbortSignal.timeout(15000),
});
export const source = 'TheSportsDB';
export const coverage = {
  source, partial: true, live: false, developmentOnly: true,
  description: 'Cobertura parcial de Costa Rica · sin seguimiento en vivo',
};

const itemKeys = { league: 'leagues', next: 'events', past: 'events', teams: 'teams', table: 'table' };
const temporaryStatus = (httpStatus, error) =>
  error?.name === 'TimeoutError' || error?.name === 'AbortError' || httpStatus === 408 || httpStatus === 429 || httpStatus >= 500;
const safeError = (error) => error?.name === 'TimeoutError' || error?.name === 'AbortError' ? 'timeout' : 'network_error';

export class CountryFetchError extends Error {
  constructor(message, diagnostics) {
    super(message);
    this.name = 'CountryFetchError';
    this.diagnostics = diagnostics;
  }
}

async function fetchEndpoint(name, endpoint, fetcher, now) {
  const started = now();
  try {
    const response = await fetcher(base + endpoint, requestOptions());
    if (!response.ok) return { ok: false, diagnostic: {
      name, endpoint, durationMs: Math.max(0, Math.round(now() - started)), httpStatus: response.status,
      status: temporaryStatus(response.status) ? 'temporarily_unavailable' : 'unavailable',
      error: `http_${response.status}`, itemCount: null,
    } };
    let body;
    try { body = await response.json(); } catch {
      return { ok: false, invalid: true, diagnostic: {
        name, endpoint, durationMs: Math.max(0, Math.round(now() - started)), httpStatus: response.status, status: 'unavailable',
        error: 'invalid_json', itemCount: null,
      } };
    }
    const items = body?.[itemKeys[name]];
    return { ok: true, body, diagnostic: {
      name, endpoint, durationMs: Math.max(0, Math.round(now() - started)), httpStatus: response.status, status: 'available',
      error: null, itemCount: Array.isArray(items) ? items.length : 0,
    } };
  } catch (error) {
    return { ok: false, diagnostic: {
      name, endpoint, durationMs: Math.max(0, Math.round(now() - started)), httpStatus: null,
      status: temporaryStatus(0, error) ? 'temporarily_unavailable' : 'unavailable',
      error: safeError(error), itemCount: null,
    } };
  }
}

function rejectFetch(message, diagnostics) {
  throw new CountryFetchError(message, diagnostics);
}

// Five shared requests per explicit country import. No per-user calls or retries.
export async function fetchCostaRica({ fetcher = fetch, now = () => performance.now() } = {}) {
  const diagnostics = {};
  const leagueEndpoint = 'lookupleague.php?id=4815';
  const league = await fetchEndpoint('league', leagueEndpoint, fetcher, now);
  diagnostics.league = league.diagnostic;
  if (!league.ok) rejectFetch(`TheSportsDB league ${league.diagnostic.error}`, diagnostics);
  if (!Array.isArray(league.body?.leagues)) {
    diagnostics.league = { ...diagnostics.league, status: 'unavailable', error: 'invalid_response' };
    rejectFetch('TheSportsDB league invalid_response', diagnostics);
  }
  const result = { league: league.body };
  const season = result.league.leagues.find((item) => item.idLeague === '4815')?.strCurrentSeason;
  const requests = [
    ['next', 'eventsnextleague.php?id=4815'],
    ['past', 'eventspastleague.php?id=4815'],
    ['teams', 'lookup_all_teams.php?id=4815'],
    ['table', `lookuptable.php?l=4815${season ? `&s=${encodeURIComponent(season)}` : ''}`],
  ];
  const settled = await Promise.allSettled(requests.map(([name, endpoint]) => fetchEndpoint(name, endpoint, fetcher, now)));
  for (let index = 0; index < requests.length; index++) {
    const [name, endpoint] = requests[index];
    const entry = settled[index].status === 'fulfilled' ? settled[index].value : {
      ok: false, diagnostic: { name, endpoint, durationMs: 0, httpStatus: null, status: 'unavailable', error: 'internal_error', itemCount: null },
    };
    diagnostics[name] = entry.diagnostic;
    if (entry.invalid) rejectFetch(`TheSportsDB ${name} invalid_json`, diagnostics);
    if (entry.ok) result[name] = entry.body;
  }
  if (!result.teams) rejectFetch(`TheSportsDB teams ${diagnostics.teams.error}`, diagnostics);
  result._fetch = { endpoints: diagnostics };
  return result;
}

function required(value, label) {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`Missing ${label}`);
  return value;
}
function score(value) {
  if (value == null || value === '') return null;
  if (!/^\d+$/.test(String(value))) throw new Error('Invalid provider score');
  return Number(value);
}

export async function normalize(raw, resolve, receivedAt) {
  const league = raw.league?.leagues?.find((l) => l.idLeague === '4815');
  if (!league || league.strSport !== 'Soccer') throw new Error('Missing Costa Rica league');
  const competitionId = await resolve('competition', '4815');
  const competition = { id: competitionId, name: required(league.strLeague, 'league name'), country: 'Costa Rica', season: league.strCurrentSeason ?? '', media: null };
  const teams = new Map(), matches = new Map();
  const providerTeamIds = new Set();
  if (!Array.isArray(raw.teams?.teams) || raw.teams.teams.length === 0) throw new Error('Missing valid teams response');
  for (const team of raw.teams.teams) {
    if (team.strSport !== 'Soccer') continue;
    if (team.idLeague !== '4815' || team.strCountry !== 'Costa Rica') throw new Error('Unexpected team competition/country');
    providerTeamIds.add(required(team.idTeam, 'team ID'));
    const teamId = await resolve('team', required(team.idTeam, 'team ID'));
    teams.set(teamId, {
      id: teamId, name: required(team.strTeam, 'team name'),
      shortName: team.strTeamShort ?? '', country: 'Costa Rica',
      competitionId, media: null, aliases: [],
    });
  }
  if (teams.size === 0) throw new Error('No valid soccer teams');
  for (const envelope of [raw.past, raw.next].filter(Boolean)) {
    if (!envelope || !Object.hasOwn(envelope, 'events') || (envelope.events !== null && !Array.isArray(envelope.events))) throw new Error('Invalid events response');
    for (const event of envelope.events ?? []) {
      if (event.idLeague !== '4815' || event.strSport !== 'Soccer') throw new Error('Unexpected competition');
      const id = await resolve('match', required(event.idEvent, 'event ID'));
      const teamIds = [];
      for (const side of ['Home', 'Away']) {
        const externalTeamId = required(event[`id${side}Team`], 'team ID');
        providerTeamIds.add(externalTeamId);
        const teamId = await resolve('team', externalTeamId);
        teamIds.push(teamId);
        teams.set(teamId, { ...teams.get(teamId), id: teamId, name: required(event[`str${side}Team`], 'team name'), country: 'Costa Rica', competitionId, media: null, aliases: teams.get(teamId)?.aliases ?? [] });
      }
      const status = { NS: 'SCHEDULED', FT: 'FINISHED_PENDING_VERIFICATION', PST: 'POSTPONED', CANC: 'CANCELLED', SUSP: 'SUSPENDED', ABD: 'ABANDONED' }[event.strStatus];
      if (!status) throw new Error(`Unsupported provider status: ${event.strStatus}`);
      const timestamp = required(event.strTimestamp, 'UTC timestamp');
      if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:Z|[+-]\d\d:\d\d)?$/.test(timestamp)) throw new Error('Invalid timestamp');
      const startTime = new Date(/(?:Z|[+-]\d\d:\d\d)$/.test(timestamp) ? timestamp : `${timestamp}Z`).toISOString();
      const home = score(event.intHomeScore), away = score(event.intAwayScore);
      if ((home === null) !== (away === null) || (status === 'FINISHED_PENDING_VERIFICATION' && home === null)) throw new Error('Incomplete score');
      const match = { id, competitionId, season: required(event.strSeason, 'season'), homeTeamId: teamIds[0], awayTeamId: teamIds[1], startTime, status,
        score: home === null ? null : { home, away }, minute: null, venue: event.strVenue ?? '', events: [], statistics: [],
        provenance: { source, externalId: event.idEvent, receivedAt, verificationStatus: 'PROVISIONAL' } };
      if (matches.has(id) && JSON.stringify(matches.get(id)) !== JSON.stringify(match)) throw new Error('Conflicting provider observations');
      matches.set(id, match);
    }
  }
  const table = raw.table?.table;
  if (raw.table && !Object.hasOwn(raw.table, 'table')) throw new Error('Invalid table response');
  if (table !== null && table !== undefined && !Array.isArray(table)) throw new Error('Invalid table response');
  const rows = [];
  for (const item of table ?? []) {
    const externalTeamId = required(item.idTeam, 'table team ID');
    if (!providerTeamIds.has(externalTeamId)) continue;
    const teamId = await resolve('team', externalTeamId);
    if (!teams.has(teamId)) continue;
    const integer = (value, label) => {
      if (!/^\d+$/.test(String(value ?? ''))) throw new Error(`Invalid table ${label}`);
      return Number(value);
    };
    rows.push({
      teamId, played: integer(item.intPlayed, 'played'), won: integer(item.intWin, 'won'),
      drawn: integer(item.intDraw, 'drawn'), lost: integer(item.intLoss, 'lost'),
      gf: integer(item.intGoalsFor, 'goals for'), ga: integer(item.intGoalsAgainst, 'goals against'),
      points: integer(item.intPoints, 'points'),
    });
  }
  const endpoint = raw._fetch?.endpoints ?? {};
  const capability = (key) => ({
    status: endpoint[key]?.status ?? 'unavailable',
    itemCount: endpoint[key]?.itemCount ?? null,
    stale: false,
  });
  const capabilities = {
    teams: capability('teams'), upcomingFixtures: capability('next'),
    pastResults: capability('past'), standings: capability('table'),
  };
  const dynamicCoverage = {
    ...coverage,
    partial: Object.values(capabilities).some((item) => item.status !== 'available'),
    capabilities,
  };
  return {
    schemaVersion: 1, demo: false, updatedAt: receivedAt, coverage: dynamicCoverage,
    competitions: [competition], teams: [...teams.values()], matches: [...matches.values()],
    players: [], standings: rows.length ? [{ competitionId, season: competition.season, provisional: true, rows }] : [],
    news: [], transfers: [],
  };
}
