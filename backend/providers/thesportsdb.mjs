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

// Five shared requests per explicit country import. No per-user calls or retries.
export async function fetchCostaRica({ fetcher = fetch } = {}) {
  const leagueResponse = await fetcher(base + 'lookupleague.php?id=4815', requestOptions());
  if (!leagueResponse.ok) throw new Error(`TheSportsDB HTTP ${leagueResponse.status}; importación cancelada`);
  const result = { league: await leagueResponse.json() };
  const season = result.league?.leagues?.find((item) => item.idLeague === '4815')?.strCurrentSeason;
  for (const [key, endpoint] of [
    ['next', 'eventsnextleague.php?id=4815'],
    ['past', 'eventspastleague.php?id=4815'],
    ['teams', 'lookup_all_teams.php?id=4815'],
    ['table', `lookuptable.php?l=4815${season ? `&s=${encodeURIComponent(season)}` : ''}`],
  ]) {
    const response = await fetcher(base + endpoint, requestOptions());
    if (!response.ok) throw new Error(`TheSportsDB HTTP ${response.status}; importación cancelada`);
    result[key] = await response.json();
  }
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
  if (raw.teams?.teams !== null && !Array.isArray(raw.teams?.teams)) throw new Error('Invalid teams response');
  for (const team of raw.teams?.teams ?? []) {
    if (team.strSport !== 'Soccer') continue;
    const teamId = await resolve('team', required(team.idTeam, 'team ID'));
    teams.set(teamId, {
      id: teamId, name: required(team.strTeam, 'team name'),
      shortName: team.strTeamShort ?? '', country: 'Costa Rica',
      competitionId, media: null, aliases: [],
    });
  }
  for (const envelope of [raw.past, raw.next]) {
    if (!envelope || !Object.hasOwn(envelope, 'events') || (envelope.events !== null && !Array.isArray(envelope.events))) throw new Error('Invalid events response');
    for (const event of envelope.events ?? []) {
      if (event.idLeague !== '4815' || event.strSport !== 'Soccer') throw new Error('Unexpected competition');
      const id = await resolve('match', required(event.idEvent, 'event ID'));
      const teamIds = [];
      for (const side of ['Home', 'Away']) {
        const teamId = await resolve('team', required(event[`id${side}Team`], 'team ID'));
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
  if (table !== null && table !== undefined && !Array.isArray(table)) throw new Error('Invalid table response');
  const rows = [];
  for (const item of table ?? []) {
    const teamId = await resolve('team', required(item.idTeam, 'table team ID'));
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
  return {
    schemaVersion: 1, demo: false, updatedAt: receivedAt, coverage,
    competitions: [competition], teams: [...teams.values()], matches: [...matches.values()],
    players: [], standings: rows.length ? [{ competitionId, season: competition.season, provisional: true, rows }] : [],
    news: [], transfers: [],
  };
}
