// GOAL player contract: endpoint paths + pure normalizers (no I/O). This is
// the ONLY place that knows the GOAL player endpoints and response shapes;
// the worker imports both from here. The shapes are not pinned by a captured
// sample yet (UNVERIFIED): readers are tolerant and only emit fields that are
// actually present and valid; the database stores nothing else. After the
// first real response is captured, adjust GOAL_PLAYER_ENDPOINTS and the
// readers below and pin the sample as a fixture.

/** Paths relative to https://api.goal-api.com/v1 (the worker adds base + auth). */
export const GOAL_PLAYER_ENDPOINTS = {
  search: (query: string) => `/players/search?q=${encodeURIComponent(query)}`,
  profile: (externalId: string) => `/players/${encodeURIComponent(externalId)}`,
  statistics: (externalId: string) => `/players/${encodeURIComponent(externalId)}/statistics`,
};

type Json = Record<string, unknown>;

const text = (value: unknown) =>
  typeof value === 'string' || typeof value === 'number' ? String(value).trim() : '';

const record = (value: unknown): Json =>
  value && typeof value === 'object' && !Array.isArray(value) ? value as Json : {};

const first = (...values: unknown[]) => {
  for (const value of values) {
    const result = text(value);
    if (result) return result;
  }
  return '';
};

const count = (...values: unknown[]) => {
  for (const value of values) {
    if (value == null || value === '' || typeof value === 'object') continue;
    const number = Number(value);
    if (Number.isInteger(number) && number >= 0) return number;
  }
  return null;
};

const decimal = (value: unknown) => {
  if (value == null || value === '' || typeof value === 'object') return null;
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? Math.round(number * 100) / 100 : null;
};

function heightCm(value: unknown) {
  const raw = text(value).toLowerCase().replace(',', '.');
  const match = raw.match(/^(\d+(?:\.\d+)?)\s*(cm|m)?$/);
  if (!match) return null;
  const number = Number(match[1]);
  const cm = match[2] === 'm' || number < 3 ? Math.round(number * 100) : Math.round(number);
  return cm >= 140 && cm <= 230 ? cm : null;
}

function foot(value: unknown) {
  const raw = text(value).toLowerCase();
  if (['right', 'r', 'derecho', 'diestro'].includes(raw)) return 'right';
  if (['left', 'l', 'izquierdo', 'zurdo'].includes(raw)) return 'left';
  if (['both', 'ambos', 'ambidextrous'].includes(raw)) return 'both';
  return null;
}

function isoDate(value: unknown) {
  const raw = text(value);
  return /^\d{4}-\d{2}-\d{2}/.test(raw) && Number.isFinite(Date.parse(raw)) ? raw.slice(0, 10) : null;
}

function photo(value: unknown) {
  try {
    const url = new URL(text(value));
    return url.protocol === 'https:' && url.hostname === 'media.goal-api.com' && !url.username &&
        !url.password && !url.port
      ? url.toString()
      : null;
  } catch {
    return null;
  }
}

const compact = (value: Json) =>
  Object.fromEntries(Object.entries(value).filter(([, item]) => item !== null && item !== ''));

/** One GOAL player row -> fields the catalog understands, or null without identity. */
export function normalizeGoalPlayer(value: unknown): Json | null {
  const row = record(value);
  const player = Object.keys(record(row.player)).length > 0 ? record(row.player) : row;
  const team = record(player.team ?? row.team ?? player.currentTeam ?? row.currentTeam);
  const externalId = first(player.id, player.apiId, player.playerId, row.playerId, row.id);
  const composed = [first(player.firstName), first(player.lastName)].filter(Boolean).join(' ');
  const name = first(player.name, player.playerName, player.fullName, row.playerName, composed);
  if (!externalId || !name) return null;
  const position = record(player.position);
  return compact({
    externalId,
    name,
    shortName: first(player.shortName, player.displayName) || null,
    country: first(player.nationality, player.countryName, record(player.country).name, player.country) || null,
    position: first(position.name, player.positionName, player.position) || null,
    dateOfBirth: isoDate(player.dateOfBirth ?? player.birthDate ?? player.birthdate ?? player.birthday),
    age: count(player.age),
    height: heightCm(player.height),
    preferredFoot: foot(player.preferredFoot ?? player.foot),
    shirtNumber: count(player.shirtNumber, player.number, player.jerseyNumber),
    photo: photo(player.photo ?? player.photoUrl ?? player.image ?? player.avatar),
    teamExternalId: first(team.id, team.apiId, player.teamId, row.teamId) || null,
  });
}

function rows(payload: unknown): unknown[] {
  const root = record(payload);
  const data = root.data;
  if (Array.isArray(data)) return data;
  const inner = record(data);
  for (const key of ['players', 'results', 'items']) {
    if (Array.isArray(inner[key])) return inner[key] as unknown[];
    if (Array.isArray(root[key])) return root[key] as unknown[];
  }
  return Array.isArray(payload) ? payload : [];
}

/** Search results: unique players by provider id, capped at 50. */
export function normalizeGoalPlayerSearch(payload: unknown) {
  const players = new Map<string, Json>();
  for (const row of rows(payload)) {
    const player = normalizeGoalPlayer(row);
    if (player && !players.has(String(player.externalId))) players.set(String(player.externalId), player);
    if (players.size >= 50) break;
  }
  return [...players.values()];
}

/** Profile: the player object, or null when the provider returned nothing usable. */
export function normalizeGoalPlayerProfile(payload: unknown) {
  const data = record(payload).data;
  return normalizeGoalPlayer(Array.isArray(data) ? data[0] : data);
}

type Season = { season: string; competition: string; stats: Json };

function seasonEntry(value: unknown): Season | null {
  const row = record(value);
  const games = record(row.games);
  const cards = record(row.cards);
  const goalsObject = record(row.goals);
  const stats = compact({
    matchesPlayed: count(row.matchesPlayed, row.matchPlayed, row.appearances, row.appearences, games.appearences,
      games.appearances),
    starts: count(row.starts, row.lineups, row.gamesStarted, games.lineups),
    minutesPlayed: count(row.minutesPlayed, row.minutes, games.minutes),
    goals: count(typeof row.goals === 'object' ? goalsObject.total : row.goals),
    assists: count(row.assists, goalsObject.assists),
    yellowCards: count(row.yellowCards, row.yellow, cards.yellow),
    redCards: count(row.redCards, row.red, cards.red),
    rating: decimal(row.rating ?? games.rating),
  });
  if (!Object.values(stats).some((item) => typeof item === 'number')) return null;
  return {
    season: first(row.season, record(row.league).season, row.seasonName),
    competition: first(record(row.league).name, record(row.competition).name, row.competitionName, row.league),
    stats,
  };
}

/**
 * Current-season statistics. With several competitions in the latest season
 * the counts are added up and labelled without a single competition name;
 * rating is kept only when one entry provides it. Empty -> {}.
 */
export function normalizeGoalPlayerStatistics(payload: unknown): Json {
  const data = record(payload).data;
  const source = Array.isArray(data)
    ? data
    : Array.isArray(record(data).statistics) ? record(data).statistics as unknown[]
    : Array.isArray(record(data).seasons) ? record(data).seasons as unknown[]
    : [data];
  const entries = source.map(seasonEntry).filter((item): item is Season => item !== null);
  if (entries.length === 0) return {};
  const latest = entries.map((item) => item.season).filter(Boolean).sort().at(-1) ?? '';
  const current = entries.filter((item) => item.season === latest);
  if (current.length === 1) {
    return compact({ season: latest || null, competition: current[0].competition || null, ...current[0].stats });
  }
  const summed: Json = {};
  for (const key of ['matchesPlayed', 'starts', 'minutesPlayed', 'goals', 'assists', 'yellowCards', 'redCards']) {
    const values = current.map((item) => item.stats[key]).filter((item) => typeof item === 'number') as number[];
    if (values.length > 0) summed[key] = values.reduce((a, b) => a + b, 0);
  }
  return compact({ season: latest || null, ...summed });
}
