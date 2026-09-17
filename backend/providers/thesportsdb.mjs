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
const normalized = (value) => String(value ?? '').trim().toLocaleLowerCase('en-US');
const isCostaRicaTeam = (team) => {
  if (!team || team.strSport !== 'Soccer') return false;
  if (team.idLeague != null && String(team.idLeague) !== '4815') return false;
  if (team.strCountry && normalized(team.strCountry) !== 'costa rica') return false;
  return true;
};

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

function teamSearchEndpoint(league) {
  const leagueName = String(league?.strLeague ?? '').trim().replace(/\s+/g, '_');
  if (!leagueName) return null;
  return `search_all_teams.php?l=${encodeURIComponent(leagueName)}&s=Soccer&c=${encodeURIComponent('Costa Rica')}`;
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
  const leagueRecord = league.body.leagues.find((item) => item.idLeague === '4815');
  if (!leagueRecord || leagueRecord.strSport !== 'Soccer' ||
      (leagueRecord.strCountry && normalized(leagueRecord.strCountry) !== 'costa rica')) {
    diagnostics.league = { ...diagnostics.league, status: 'unavailable', error: 'provider_scope_mismatch' };
    rejectFetch('TheSportsDB league provider_scope_mismatch', diagnostics);
  }

  const result = { league: league.body };
  const season = leagueRecord.strCurrentSeason;
  const teamsEndpoint = teamSearchEndpoint(leagueRecord);
  if (!teamsEndpoint) {
    diagnostics.teams = { name: 'teams', endpoint: null, durationMs: 0, httpStatus: null, status: 'unavailable', error: 'missing_league_name', itemCount: null };
  }
  const requests = [
    ['next', 'eventsnextleague.php?id=4815'],
    ['past', 'eventspastleague.php?id=4815'],
    ...(teamsEndpoint ? [['teams', teamsEndpoint]] : []),
    ['table', `lookuptable.php?l=4815${season ? `&s=${encodeURIComponent(season)}` : ''}`],
  ];
  const settled = await Promise.allSettled(requests.map(([name, endpoint]) => fetchEndpoint(name, endpoint, fetcher, now)));
  for (let index = 0; index < requests.length; index++) {
    const [name, endpoint] = requests[index];
    const entry = settled[index].status === 'fulfilled' ? settled[index].value : {
      ok: false, diagnostic: { name, endpoint, durationMs: 0, httpStatus: null, status: 'unavailable', error: 'internal_error', itemCount: null },
    };
    diagnostics[name] = entry.diagnostic;
    if (entry.invalid) {
      if (name === 'teams') {
        diagnostics.teams = { ...entry.diagnostic, status: 'unavailable', error: 'invalid_json' };
        continue;
      }
      rejectFetch(`TheSportsDB ${name} invalid_json`, diagnostics);
    }
    if (!entry.ok) continue;

    if (name === 'teams') {
      const items = entry.body?.teams;
      if (items !== null && items !== undefined && !Array.isArray(items)) {
        diagnostics.teams = { ...entry.diagnostic, status: 'unavailable', error: 'invalid_response' };
        continue;
      }
      if (!Array.isArray(items) || items.length === 0) {
        diagnostics.teams = { ...entry.diagnostic, status: 'unavailable', error: 'empty_response', itemCount: 0 };
        continue;
      }
      const outOfScope = items.filter((team) => !isCostaRicaTeam(team));
      if (outOfScope.length > 0) {
        diagnostics.teams = {
          ...entry.diagnostic, status: 'unavailable', error: 'provider_scope_mismatch',
          scopeMismatchCount: outOfScope.length, source: 'search_all_teams',
        };
        continue;
      }
      diagnostics.teams = { ...entry.diagnostic, source: 'search_all_teams' };
    }
    result[name] = entry.body;
  }
  if (!diagnostics.teams) diagnostics.teams = {
    name: 'teams', endpoint: teamsEndpoint, durationMs: 0, httpStatus: null,
    status: 'unavailable', error: 'not_requested', itemCount: null,
  };
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
  if (!league || league.strSport !== 'Soccer' || (league.strCountry && normalized(league.strCountry) !== 'costa rica')) {
    throw new Error('Missing Costa Rica league');
  }
  const competitionId = await resolve('competition', '4815');
  const competition = { id: competitionId, name: required(league.strLeague, 'league name'), country: 'Costa Rica', season: league.strCurrentSeason ?? '', media: null };
  const teams = new Map(), matches = new Map(), teamIdsByExternal = new Map();
  const directTeams = Array.isArray(raw.teams?.teams) ? raw.teams.teams : [];

  const addTeam = async (externalIdValue, nameValue, { shortName = '', preferName = false } = {}) => {
    const externalId = required(externalIdValue, 'team ID');
    const name = required(nameValue, 'team name');
    let teamId = teamIdsByExternal.get(externalId);
    if (!teamId) {
      teamId = await resolve('team', externalId);
      teamIdsByExternal.set(externalId, teamId);
    }
    const existing = teams.get(teamId);
    const aliases = new Set(existing?.aliases ?? []);
    let selectedName = existing?.name ?? name;
    if (existing?.name && existing.name !== name) {
      if (preferName) {
        aliases.add(existing.name);
        selectedName = name;
      } else {
        aliases.add(name);
      }
    }
    teams.set(teamId, {
      ...existing, id: teamId, name: selectedName,
      shortName: preferName ? (shortName || existing?.shortName || '') : (existing?.shortName || shortName || ''),
      country: 'Costa Rica', competitionId, media: null, aliases: [...aliases],
    });
    return teamId;
  };

  for (const team of directTeams) {
    if (!isCostaRicaTeam(team)) throw new Error('Unexpected team competition/country');
    await addTeam(team.idTeam, team.strTeam, { shortName: team.strTeamShort ?? '', preferName: true });
  }

  for (const envelope of [raw.past, raw.next].filter(Boolean)) {
    if (!Object.hasOwn(envelope, 'events') || (envelope.events !== null && !Array.isArray(envelope.events))) throw new Error('Invalid events response');
    for (const event of envelope.events ?? []) {
      if (event.idLeague !== '4815' || event.strSport !== 'Soccer') throw new Error('Unexpected competition');
      const id = await resolve('match', required(event.idEvent, 'event ID'));
      const homeTeamId = await addTeam(event.idHomeTeam, event.strHomeTeam);
      const awayTeamId = await addTeam(event.idAwayTeam, event.strAwayTeam);
      const status = { NS: 'SCHEDULED', FT: 'FINISHED_PENDING_VERIFICATION', PST: 'POSTPONED', CANC: 'CANCELLED', SUSP: 'SUSPENDED', ABD: 'ABANDONED' }[event.strStatus];
      if (!status) throw new Error(`Unsupported provider status: ${event.strStatus}`);
      const timestamp = required(event.strTimestamp, 'UTC timestamp');
      if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:Z|[+-]\d\d:\d\d)?$/.test(timestamp)) throw new Error('Invalid timestamp');
      const startTime = new Date(/(?:Z|[+-]\d\d:\d\d)$/.test(timestamp) ? timestamp : `${timestamp}Z`).toISOString();
      const home = score(event.intHomeScore), away = score(event.intAwayScore);
      if ((home === null) !== (away === null) || (status === 'FINISHED_PENDING_VERIFICATION' && home === null)) throw new Error('Incomplete score');
      const match = { id, competitionId, season: required(event.strSeason, 'season'), homeTeamId, awayTeamId, startTime, status,
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
    let teamId = teamIdsByExternal.get(externalTeamId);
    if (!teamId && typeof item.strTeam === 'string' && item.strTeam.trim()) {
      teamId = await addTeam(externalTeamId, item.strTeam);
    }
    if (!teamId || !teams.has(teamId)) continue;
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

  if (teams.size === 0) throw new Error('No valid Costa Rica teams from provider observations');

  const endpoint = raw._fetch?.endpoints ?? {};
  const inferredStatus = (key, value) => endpoint[key]?.status ?? (value !== undefined ? 'available' : 'unavailable');
  const capability = (key, value) => ({
    status: inferredStatus(key, value),
    itemCount: endpoint[key]?.itemCount ?? (Array.isArray(value) ? value.length : null),
    stale: false,
  });
  const teamsSource = directTeams.length > 0 ? 'provider' : 'derived';
  const teamsCapability = {
    status: 'available', itemCount: teams.size, stale: false, source: teamsSource,
    providerStatus: endpoint.teams?.status ?? (directTeams.length > 0 ? 'available' : 'unavailable'),
    providerError: endpoint.teams?.error ?? null,
  };
  const capabilities = {
    teams: teamsCapability,
    upcomingFixtures: capability('next', raw.next?.events),
    pastResults: capability('past', raw.past?.events),
    standings: capability('table', raw.table?.table),
  };
  const dynamicCoverage = {
    ...coverage,
    partial: teamsSource === 'derived' || Object.entries(capabilities).some(([key, item]) => key !== 'teams' && item.status !== 'available'),
    capabilities,
  };
  return {
    schemaVersion: 1, demo: false, updatedAt: receivedAt, coverage: dynamicCoverage,
    competitions: [competition], teams: [...teams.values()], matches: [...matches.values()],
    players: [], standings: rows.length ? [{ competitionId, season: competition.season, provisional: true, rows }] : [],
    news: [], transfers: [],
  };
}
