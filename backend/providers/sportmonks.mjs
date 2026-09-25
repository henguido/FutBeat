import {
  RequestBudget,
  ProviderResponseError,
  createProviderDescriptor,
} from './core/provider.mjs';

// Sportmonks Football API v3 adapter (Provider Hub Phase 1A, #102).
//
// Development/integration only: nothing schedules it and the Provider Hub
// config keeps it disabled. It implements exactly three contract methods
// (fixtures by date, in-play livescores, fixture by id) and a conservative
// core-fixture normalization. Field names follow the public v3 documentation
// shapes; the event type ids and substitution player roles are UNVERIFIED
// against a captured response and must be confirmed before activation.
//
// Auth: the token travels in the Authorization header, never in the URL, so
// it cannot leak through logged URLs; errors are sanitized.

const baseUrl = 'https://api.sportmonks.com/v3/football';

export const sportmonksDescriptor = createProviderDescriptor({
  id: 'sportmonks',
  source: 'Sportmonks',
  // Only what this phase implements and normalizes.
  capabilities: ['fixtures', 'liveScores', 'events'],
  developmentOnly: true,
  live: true,
});

/** Includes this adapter knows how to normalize (allow-list). */
export const sportmonksIncludes = Object.freeze([
  'participants',
  'scores',
  'state',
  'events',
  'events.type',
  'venue',
  'league',
  'season',
  'periods',
]);
export const sportmonksDefaultIncludes = Object.freeze([
  'participants',
  'scores',
  'state',
  'events',
  'venue',
  'periods',
]);

export class SportmonksNormalizationError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = 'SportmonksNormalizationError';
    this.details = details;
  }
}

function sanitize(value, token) {
  if (typeof value !== 'string') return value;
  let result = value.slice(0, 300);
  if (token) result = result.split(token).join('[REDACTED]');
  return result;
}

function includeParam(includes) {
  const list = [...new Set(includes ?? sportmonksDefaultIncludes)];
  for (const include of list) {
    if (!sportmonksIncludes.includes(include)) throw new Error(`Unsupported Sportmonks include: ${include}`);
  }
  return list.join(';');
}

export function createSportmonksProvider({
  token,
  fetcher = fetch,
  budget,
  timeoutMs = 15000,
  clock = () => new Date(),
} = {}) {
  if (typeof token !== 'string' || !token.trim()) throw new Error('Sportmonks token is required');
  // No invented contractual limit: a caller must inject the budget it owns.
  if (!(budget instanceof RequestBudget)) throw new Error('Sportmonks request budget is required');
  if (!Number.isInteger(timeoutMs) || timeoutMs <= 0) throw new Error('Invalid Sportmonks timeout');

  const request = async (endpoint, path, includes) => {
    const query = new URLSearchParams();
    const include = includeParam(includes);
    if (include) query.set('include', include);
    const url = `${baseUrl}${path}${query.size ? `?${query}` : ''}`;
    budget.reserve();
    const started = performance.now();
    let response;
    try {
      response = await fetcher(url, {
        headers: { Authorization: token, accept: 'application/json' },
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (error) {
      throw new ProviderResponseError('Sportmonks network error', {
        endpoint,
        httpStatus: null,
        durationMs: Math.round(performance.now() - started),
        providerErrors: error?.name === 'TimeoutError' ? 'timeout' : 'network_error',
      });
    }
    const durationMs = Math.round(performance.now() - started);
    let body = null;
    try {
      body = await response.json();
    } catch {
      body = null;
    }
    if (!response.ok) {
      throw new ProviderResponseError(`Sportmonks HTTP ${response.status}`, {
        endpoint,
        httpStatus: response.status,
        durationMs,
        providerErrors: sanitize(body?.message, token) ?? null,
      });
    }
    const data = body?.data;
    const valid = endpoint === 'fixture'
      ? data && typeof data === 'object' && !Array.isArray(data)
      : Array.isArray(data);
    if (!valid) {
      throw new ProviderResponseError('Sportmonks response payload missing', {
        endpoint, httpStatus: response.status, durationMs,
      });
    }
    return {
      data,
      receivedAt: clock().toISOString(),
      rateLimit: body?.rate_limit && typeof body.rate_limit === 'object'
        ? {
            remaining: Number.isInteger(body.rate_limit.remaining) ? body.rate_limit.remaining : null,
            resetsInSeconds: Number.isInteger(body.rate_limit.resets_in_seconds)
              ? body.rate_limit.resets_in_seconds
              : null,
          }
        : null,
      durationMs,
    };
  };

  return Object.freeze({
    descriptor: sportmonksDescriptor,
    budget,

    /** GET /fixtures/date/{YYYY-MM-DD}. Validated before spending quota. */
    async fetchFixturesByDate({ date, includes } = {}) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(String(date ?? ''))) throw new Error('Fixture date requires an ISO date');
      return request('fixtures_by_date', `/fixtures/date/${date}`, includes);
    },

    /** GET /livescores/inplay. */
    async fetchLivescores({ includes } = {}) {
      return request('livescores_inplay', '/livescores/inplay', includes);
    },

    /** GET /fixtures/{id}. */
    async fetchFixture({ id, includes } = {}) {
      if (!/^\d+$/.test(String(id ?? ''))) throw new Error('Fixture id must be numeric');
      return request('fixture', `/fixtures/${id}`, includes);
    },
  });
}

// ---------------------------------------------------------------------------
// Normalization (core fixture identity only).
// ---------------------------------------------------------------------------

/** Sportmonks state developer_name -> FutBeat status; null = not recognized. */
export function mapSportmonksState(developerName) {
  return {
    TBA: 'DISCOVERED',
    NS: 'SCHEDULED',
    DELAYED: 'SCHEDULED',
    INPLAY_1ST_HALF: 'LIVE',
    INPLAY_2ND_HALF: 'LIVE',
    HT: 'HALFTIME',
    BREAK: 'EXTRA_TIME',
    INPLAY_ET: 'EXTRA_TIME',
    EXTRA_TIME_BREAK: 'EXTRA_TIME',
    INPLAY_PENALTIES: 'PENALTIES',
    PEN_BREAK: 'PENALTIES',
    FT: 'FINISHED_PENDING_VERIFICATION',
    AET: 'FINISHED_PENDING_VERIFICATION',
    FT_PEN: 'FINISHED_PENDING_VERIFICATION',
    AWARDED: 'FINISHED_PENDING_VERIFICATION',
    WO: 'FINISHED_PENDING_VERIFICATION',
    POSTPONED: 'POSTPONED',
    SUSPENDED: 'SUSPENDED',
    INTERRUPTED: 'SUSPENDED',
    ABANDONED: 'ABANDONED',
    CANCELLED: 'CANCELLED',
  }[String(developerName ?? '')] ?? null;
}

// Event types: by the included type's developer_name when present, else by
// type_id (UNVERIFIED ids, confirm before activation).
const eventTypeByName = Object.freeze({
  GOAL: 'GOAL',
  OWNGOAL: 'GOAL',
  PENALTY: 'GOAL',
  MISSED_PENALTY: 'MISSED_PENALTY',
  SUBSTITUTION: 'SUBSTITUTION',
  YELLOWCARD: 'YELLOW_CARD',
  REDCARD: 'RED_CARD',
  YELLOWREDCARD: 'RED_CARD',
  VAR: 'VAR',
  VAR_CARD: 'VAR',
});
const eventTypeById = Object.freeze({
  14: 'GOAL',
  15: 'GOAL',
  16: 'GOAL',
  17: 'MISSED_PENALTY',
  18: 'SUBSTITUTION',
  19: 'YELLOW_CARD',
  20: 'RED_CARD',
  21: 'RED_CARD',
});

function eventType(event) {
  const name = event?.type?.developer_name;
  if (typeof name === 'string' && eventTypeByName[name]) return eventTypeByName[name];
  return eventTypeById[event?.type_id] ?? 'OTHER';
}

function idString(value) {
  return Number.isInteger(value) && value > 0 ? String(value) : null;
}

function goals(value) {
  return Number.isInteger(value) && value >= 0 ? value : null;
}

function parseResult(value) {
  const match = /^\s*(\d+)\s*-\s*(\d+)\s*$/.exec(String(value ?? ''));
  return match ? { home: Number(match[1]), away: Number(match[2]) } : null;
}

function startTimeOf(fixture) {
  if (Number.isInteger(fixture.starting_at_timestamp)) {
    return new Date(fixture.starting_at_timestamp * 1000).toISOString();
  }
  const text = String(fixture.starting_at ?? '');
  const parsed = Date.parse(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}(:\d{2})?$/.test(text) ? `${text.replace(' ', 'T')}Z` : '');
  if (!Number.isFinite(parsed)) throw new SportmonksNormalizationError('Invalid Sportmonks kickoff', { fixtureId: fixture.id });
  return new Date(parsed).toISOString();
}

/**
 * One fixture -> provider-neutral concepts Provider Hub can compare.
 * `resolve(kind, externalId)` is the STRICT canonical resolver (returns a
 * canonical id or null = unmapped; it never creates or name-matches).
 */
export async function normalizeSportmonksFixture(fixture, { resolve, receivedAt }) {
  if (typeof resolve !== 'function') throw new Error('Provider resolver is required');
  if (!Number.isFinite(Date.parse(receivedAt))) throw new Error('Invalid receivedAt');
  const externalMatchId = idString(fixture?.id);
  if (!externalMatchId) throw new SportmonksNormalizationError('Missing Sportmonks fixture id');
  const developerName = fixture.state?.developer_name ?? fixture.state?.short_name ?? null;
  const status = mapSportmonksState(developerName);
  if (!status) {
    throw new SportmonksNormalizationError(`Unsupported Sportmonks state: ${developerName ?? 'none'}`, {
      fixtureId: externalMatchId,
    });
  }

  const participants = Array.isArray(fixture.participants) ? fixture.participants : [];
  const side = (location) => participants.filter((p) => p?.meta?.location === location);
  const [home] = side('home');
  const [away] = side('away');
  if (side('home').length !== 1 || side('away').length !== 1 || !idString(home?.id) || !idString(away?.id)
    || home.id === away.id) {
    throw new SportmonksNormalizationError('Sportmonks fixture needs exactly one home and one away participant', {
      fixtureId: externalMatchId,
    });
  }
  const sideOf = (participantId) => (participantId === home.id ? 'home' : participantId === away.id ? 'away' : null);

  // Current score only when both sides report it.
  let score = null;
  const current = (Array.isArray(fixture.scores) ? fixture.scores : []).filter((s) => s?.description === 'CURRENT');
  const currentGoals = (location) => goals(current.find((s) => s?.score?.participant === location)?.score?.goals);
  if (currentGoals('home') !== null && currentGoals('away') !== null) {
    score = { home: currentGoals('home'), away: currentGoals('away') };
  }

  const ticking = (Array.isArray(fixture.periods) ? fixture.periods : []).find((p) => p?.ticking === true);
  const minute = Number.isInteger(ticking?.minutes) && ticking.minutes >= 0 ? ticking.minutes : null;

  const events = [];
  const seenEvents = new Set();
  for (const event of Array.isArray(fixture.events) ? fixture.events : []) {
    const eventId = idString(event?.id);
    if (!eventId || seenEvents.has(eventId)) continue; // no duplicate inside one payload
    seenEvents.add(eventId);
    const eventSide = sideOf(event.participant_id);
    events.push({
      provenance: { provider: 'sportmonks', eventId },
      type: eventType(event),
      minute: Number.isInteger(event.minute) ? event.minute : null,
      extraMinute: Number.isInteger(event.extra_minute) ? event.extra_minute : null,
      side: eventSide,
      teamExternalId: eventSide ? String(event.participant_id) : null,
      playerExternalId: idString(event.player_id),
      relatedPlayerExternalId: idString(event.related_player_id),
      scoreAfter: parseResult(event.result),
    });
  }

  const competitionExternalId = idString(fixture.league_id);
  const homeExternalId = String(home.id);
  const awayExternalId = String(away.id);
  return {
    provider: 'sportmonks',
    externalMatchId,
    competitionExternalId,
    seasonExternalId: idString(fixture.season_id),
    stageExternalId: idString(fixture.stage_id),
    roundExternalId: idString(fixture.round_id),
    startTime: startTimeOf(fixture),
    status,
    providerState: developerName,
    minute,
    score,
    home: { externalId: homeExternalId, name: String(home.name ?? ''), shortCode: home.short_code ?? null },
    away: { externalId: awayExternalId, name: String(away.name ?? ''), shortCode: away.short_code ?? null },
    venue: idString(fixture.venue?.id) || fixture.venue?.name
      ? { externalId: idString(fixture.venue?.id), name: String(fixture.venue?.name ?? '') }
      : null,
    canonical: {
      matchId: await resolve('match', externalMatchId),
      competitionId: competitionExternalId ? await resolve('competition', competitionExternalId) : null,
      homeTeamId: await resolve('team', homeExternalId),
      awayTeamId: await resolve('team', awayExternalId),
    },
    events,
    receivedAt,
  };
}

/** A batch: duplicate fixture ids are kept once; bad fixtures are reported, not guessed. */
export async function normalizeSportmonksFixtures(data, options) {
  if (!Array.isArray(data)) throw new SportmonksNormalizationError('Sportmonks fixtures must be an array');
  const fixtures = [];
  const rejected = [];
  const seen = new Set();
  for (const fixture of data) {
    const id = idString(fixture?.id);
    if (id && seen.has(id)) continue;
    if (id) seen.add(id);
    try {
      fixtures.push(await normalizeSportmonksFixture(fixture, options));
    } catch (error) {
      if (!(error instanceof SportmonksNormalizationError)) throw error;
      rejected.push({ externalMatchId: id, reason: error.message });
    }
  }
  return { fixtures, rejected };
}
