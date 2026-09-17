import { createHash } from 'node:crypto';
import {
  RequestBudget,
  assertApiEnvelope,
  createProviderDescriptor,
} from './core/provider.mjs';

const baseUrl = 'https://v3.football.api-sports.io';

export const apiFootballDescriptor = createProviderDescriptor({
  id: 'api_football',
  source: 'API-Football',
  capabilities: [
    'fixtures',
    'liveScores',
    'events',
    'lineups',
    'statistics',
    'standings',
    'players',
    'transfers',
  ],
  developmentOnly: true,
  live: true,
});

export const apiFootballCoverage = Object.freeze({
  source: apiFootballDescriptor.source,
  partial: true,
  live: true,
  developmentOnly: true,
  description: 'Cobertura LIVE de desarrollo · sujeta a cuota y cobertura del plan',
});

function requiredString(value, label) {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`Missing ${label}`);
  return value.trim();
}

function requiredId(value, label) {
  if (!Number.isInteger(value) || value <= 0) throw new Error(`Missing ${label}`);
  return String(value);
}

function numberOrNull(value, label) {
  if (value == null) return null;
  if (!Number.isInteger(value) || value < 0) throw new Error(`Invalid ${label}`);
  return value;
}

function mapStatus(short) {
  const mapped = {
    TBD: 'DISCOVERED',
    NS: 'SCHEDULED',
    '1H': 'LIVE',
    HT: 'HALFTIME',
    '2H': 'LIVE',
    ET: 'EXTRA_TIME',
    BT: 'EXTRA_TIME',
    P: 'PENALTIES',
    LIVE: 'LIVE',
    INT: 'SUSPENDED',
    SUSP: 'SUSPENDED',
    FT: 'FINISHED_PENDING_VERIFICATION',
    AET: 'FINISHED_PENDING_VERIFICATION',
    PEN: 'FINISHED_PENDING_VERIFICATION',
    PST: 'POSTPONED',
    CANC: 'CANCELLED',
    ABD: 'ABANDONED',
    AWD: 'FINISHED_PENDING_VERIFICATION',
    WO: 'FINISHED_PENDING_VERIFICATION',
  }[short];
  if (!mapped) throw new Error(`Unsupported API-Football status: ${short}`);
  return mapped;
}

function mapEventType(type, detail) {
  if (type === 'Goal') {
    if (detail === 'Missed Penalty') return 'MISSED_PENALTY';
    return 'GOAL';
  }
  if (type === 'Card') {
    if (detail === 'Red Card' || detail === 'Second Yellow card') return 'RED_CARD';
    return 'YELLOW_CARD';
  }
  if (type === 'subst') return 'SUBSTITUTION';
  if (type === 'Var') return 'VAR';
  return 'OTHER';
}

function stableEventId(fixtureId, event) {
  const fingerprint = JSON.stringify([
    fixtureId,
    event.time?.elapsed ?? null,
    event.time?.extra ?? null,
    event.team?.id ?? null,
    event.player?.id ?? null,
    event.assist?.id ?? null,
    event.type ?? null,
    event.detail ?? null,
  ]);
  return `api_football_${createHash('sha1').update(fingerprint).digest('hex').slice(0, 20)}`;
}

export function createApiFootballProvider({
  apiKey,
  fetcher = fetch,
  budget = new RequestBudget({
    provider: 'api_football',
    dailyLimit: 100,
    perMinuteLimit: 10,
  }),
  leagueIds = [],
} = {}) {
  if (typeof apiKey !== 'string' || !apiKey.trim()) throw new Error('API-Football key is required');
  const defaultLeagueIds = [...new Set(leagueIds.map(String))];

  return Object.freeze({
    descriptor: apiFootballDescriptor,
    budget,

    async fetchLive({ leagueIds: overrideLeagueIds } = {}) {
      const ids = (overrideLeagueIds ?? defaultLeagueIds).map(String);
      const live = ids.length ? ids.join('-') : 'all';
      budget.reserve();
      const response = await fetcher(`${baseUrl}/fixtures?live=${encodeURIComponent(live)}`, {
        headers: {
          'x-apisports-key': apiKey,
          accept: 'application/json',
        },
        signal: AbortSignal.timeout(15000),
      });
      if (!response.ok) throw new Error(`API-Football HTTP ${response.status}`);
      return assertApiEnvelope(await response.json());
    },

    async fetchFixturesWindow({ from, to, timezone = 'America/Costa_Rica' }) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to)) {
        throw new Error('Fixture window requires ISO dates');
      }
      budget.reserve();
      const query = new URLSearchParams({ from, to, timezone });
      const response = await fetcher(`${baseUrl}/fixtures?${query}`, {
        headers: {
          'x-apisports-key': apiKey,
          accept: 'application/json',
        },
        signal: AbortSignal.timeout(15000),
      });
      if (!response.ok) throw new Error(`API-Football HTTP ${response.status}`);
      return assertApiEnvelope(await response.json());
    },
  });
}

export async function normalizeApiFootballFixtures(raw, resolve, receivedAt) {
  assertApiEnvelope(raw);
  if (typeof resolve !== 'function') throw new Error('Provider resolver is required');
  if (!Number.isFinite(Date.parse(receivedAt))) throw new Error('Invalid receivedAt');

  const competitions = new Map();
  const teams = new Map();
  const players = new Map();
  const matches = new Map();

  for (const item of raw.response) {
    const fixtureId = requiredId(item.fixture?.id, 'fixture ID');
    const competitionExternalId = requiredId(item.league?.id, 'league ID');
    const competitionId = await resolve('competition', competitionExternalId);
    competitions.set(competitionId, {
      id: competitionId,
      name: requiredString(item.league?.name, 'league name'),
      country: requiredString(item.league?.country ?? 'Unknown', 'league country'),
      season: String(item.league?.season ?? ''),
      media: null,
    });

    const teamIds = {};
    for (const side of ['home', 'away']) {
      const externalId = requiredId(item.teams?.[side]?.id, `${side} team ID`);
      const canonicalId = await resolve('team', externalId);
      teamIds[side] = canonicalId;
      teams.set(canonicalId, {
        id: canonicalId,
        name: requiredString(item.teams?.[side]?.name, `${side} team name`),
        country: requiredString(item.league?.country ?? 'Unknown', 'team country'),
        competitionId,
        media: null,
        aliases: [],
      });
    }
    if (teamIds.home === teamIds.away) throw new Error('Home and away team cannot be the same');

    const events = [];
    for (const event of (item.events ?? [])) {
      const externalTeamId = event.team?.id;
      const teamId = String(externalTeamId) === String(item.teams.home.id)
        ? teamIds.home
        : String(externalTeamId) === String(item.teams.away.id)
          ? teamIds.away
          : null;
      if (!teamId) throw new Error('Event references unknown team');

      let playerId;
      if (Number.isInteger(event.player?.id) && event.player.id > 0) {
        playerId = await resolve('player', String(event.player.id));
        players.set(playerId, {
          id: playerId,
          name: requiredString(event.player.name, 'event player name'),
          teamId,
          position: '',
          country: '',
          media: null,
        });
      }

      const normalizedEvent = {
        id: stableEventId(fixtureId, event),
        minute: Number.isInteger(event.time?.elapsed) ? event.time.elapsed : 0,
        type: mapEventType(event.type, event.detail),
        teamId,
      };
      if (playerId) normalizedEvent.playerId = playerId;
      if (event.detail) normalizedEvent.detail = String(event.detail);
      if (event.comments) normalizedEvent.comments = String(event.comments);
      events.push(normalizedEvent);
    }

    const home = numberOrNull(item.goals?.home, 'home score');
    const away = numberOrNull(item.goals?.away, 'away score');
    if ((home === null) !== (away === null)) throw new Error('Incomplete score');

    const matchId = await resolve('match', fixtureId);
    const timestamp = requiredString(item.fixture?.date, 'fixture date');
    const startTime = new Date(timestamp).toISOString();
    if (!Number.isFinite(Date.parse(startTime))) throw new Error('Invalid fixture date');
    matches.set(matchId, {
      id: matchId,
      competitionId,
      season: String(item.league?.season ?? ''),
      homeTeamId: teamIds.home,
      awayTeamId: teamIds.away,
      startTime,
      status: mapStatus(item.fixture?.status?.short),
      score: home === null ? null : { home, away },
      minute: Number.isInteger(item.fixture?.status?.elapsed)
        ? item.fixture.status.elapsed
        : null,
      venue: item.fixture?.venue?.name ?? '',
      events,
      statistics: [],
      provenance: {
        source: apiFootballDescriptor.source,
        externalId: fixtureId,
        receivedAt,
        verificationStatus: 'PROVISIONAL',
      },
    });
  }

  return {
    schemaVersion: 1,
    demo: false,
    updatedAt: receivedAt,
    coverage: apiFootballCoverage,
    competitions: [...competitions.values()],
    teams: [...teams.values()],
    players: [...players.values()],
    matches: [...matches.values()],
    standings: [],
    news: [],
    transfers: [],
  };
}

export const normalizeApiFootballLive = normalizeApiFootballFixtures;
