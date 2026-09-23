// Pure normalizers for stored GOAL match detail (lineups, statistics). Shared
// by the futbeat-api edge function and node tests; no I/O here.

export type PlayerMedia = Record<string, { canonicalId?: unknown; image?: unknown }>;

export const asRecord = (value: unknown): Record<string, unknown> =>
  value && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};

export const asList = (value: unknown): unknown[] => Array.isArray(value) ? value : [];

export const cleanText = (value: unknown) => String(value ?? '').trim();

export const safeImage = (value: unknown) => {
  const raw = cleanText(value);
  if (!raw) return null;
  try {
    const parsed = new URL(raw);
    return parsed.protocol === 'https:' ? parsed.toString() : null;
  } catch {
    return null;
  }
};

export function normalizeLineupPlayer(value: unknown, media: PlayerMedia = {}) {
  const row = asRecord(value);
  const nested = asRecord(row.player);
  const providerId =
    cleanText(row.playerId) ||
    cleanText(row.playerKey) ||
    cleanText(nested.id);
  const canonical = asRecord(media[providerId]);
  const name =
    cleanText(row.lineupPlayer) ||
    cleanText(nested.name) ||
    cleanText(row.playerName);
  if (!name) return null;
  return {
    id: providerId || null,
    canonicalId: cleanText(canonical.canonicalId) || null,
    name,
    number: cleanText(row.lineupNumber) || null,
    position: cleanText(row.playerPosition) || null,
    lineupPosition: Number.isFinite(Number(row.lineupPosition))
      ? Number(row.lineupPosition)
      : null,
    country: cleanText(row.playerCountry) || null,
    age: Number.isFinite(Number(row.playerAge)) ? Number(row.playerAge) : null,
    image: safeImage(canonical.image) ?? safeImage(row.playerImage ?? nested.image),
    rating: Number.isFinite(Number(row.playerRating ?? row.rating))
      ? Number(row.playerRating ?? row.rating)
      : null,
    captain: row.captain === true || cleanText(row.captain).toLowerCase() === 'true',
  };
}

type LineupPlayer = NonNullable<ReturnType<typeof normalizeLineupPlayer>>;

const byLineupPosition = (left: LineupPlayer, right: LineupPlayer) =>
  (left.lineupPosition ?? 999) - (right.lineupPosition ?? 999);

// Array-row lineup type -> section. Same prefixes the SQL harvest accepts
// (lineup_rows: 'start%'/'sub%'), so a harvested player is also rendered.
const lineupSection = (type: unknown) => {
  const value = cleanText(type).toLowerCase();
  if (value.startsWith('start')) return 'starters';
  if (value.startsWith('sub')) return 'substitutes';
  if (value.startsWith('missing')) return 'missing';
  if (value === 'coach') return 'coach';
  return null;
};

export function normalizeLineupSide(
  lineups: unknown,
  side: 'home' | 'away',
  media: PlayerMedia = {},
) {
  if (Array.isArray(lineups)) {
    const rows = lineups
      .map(asRecord)
      .filter((row) => cleanText(row.team).toLowerCase() === side);
    const players = (section: string) =>
      rows
        .filter((row) => lineupSection(row.type) === section)
        .map((row) => normalizeLineupPlayer(row, media))
        .filter((item): item is LineupPlayer => item !== null)
        .sort(byLineupPosition);
    return {
      formation: null,
      starters: players('starters'),
      substitutes: players('substitutes'),
      missing: players('missing'),
      coach: players('coach')[0] ?? null,
    };
  }

  const root = asRecord(lineups);
  const data = asRecord(root[side]);
  const players = (key: string) =>
    asList(data[key])
      .map((row) => normalizeLineupPlayer(row, media))
      .filter((item): item is LineupPlayer => item !== null)
      .sort(byLineupPosition);
  return {
    formation: cleanText(root[side === 'home' ? 'homeFormation' : 'awayFormation']) || null,
    starters: players('startingLineups'),
    substitutes: players('substitutes'),
    missing: players('missingPlayers'),
    coach: normalizeLineupPlayer(data.coach, media),
  };
}

export function lineupPlayerIds(raw: unknown) {
  const payload = asRecord(asRecord(raw).payload);
  const lineups = payload.lineups;
  const ids = new Set<string>();
  const add = (value: unknown) => {
    const row = asRecord(value);
    const nested = asRecord(row.player);
    const id = cleanText(row.playerId) || cleanText(row.playerKey) || cleanText(nested.id);
    if (id) ids.add(id);
  };
  if (Array.isArray(lineups)) {
    lineups.map(asRecord)
      .filter((row) => {
        const section = lineupSection(row.type);
        return section === 'starters' || section === 'substitutes';
      })
      .forEach(add);
  } else {
    const root = asRecord(lineups);
    for (const side of ['home', 'away']) {
      const team = asRecord(root[side]);
      [...asList(team.startingLineups), ...asList(team.substitutes)].forEach(add);
    }
  }
  return [...ids].slice(0, 100);
}

// Whole-match period labels. Anything else labelled (1st, 2nd, firstHalf...)
// is a partial period and must never be shown as the match total.
const FULL_PERIODS = new Set(['full', 'fulltime', 'ft', 'all', 'match', 'total']);
const periodKey = (value: unknown) =>
  cleanText(value).toLowerCase().replace(/[\s_-]+/g, '');

const present = (value: unknown) =>
  value !== null && value !== undefined && cleanText(value) !== '';

type StatRow = { label: string; home: unknown; away: unknown };

function statRows(rows: Record<string, unknown>[]): StatRow[] {
  const byType = new Map<string, StatRow>();
  for (const row of rows) {
    const label = cleanText(row.type ?? row.label ?? row.name);
    // A row with no value on either side carries no statistic.
    if (!label || (!present(row.home) && !present(row.away))) continue;
    byType.set(label.toLowerCase(), {
      label,
      home: present(row.home) ? row.home : '—',
      away: present(row.away) ? row.away : '—',
    });
  }
  return [...byType.values()];
}

/**
 * Full-match statistics only. Supported stored shapes:
 * - [{type, home, away, half?}] (full-time rows win; unlabelled rows are
 *   treated as full match; partial periods alone yield no statistics);
 * - {match: {fullTime: [...]}} (also full/all/total keys);
 * - {home: {shots: 4}, away: {shots: 2}} keyed by team.
 * Missing data yields [], never invented values.
 */
export function normalizeStatistics(value: unknown): StatRow[] {
  if (Array.isArray(value)) {
    const rows = value.map(asRecord);
    const full = rows.filter((row) => FULL_PERIODS.has(periodKey(row.half)));
    if (full.length > 0) return statRows(full);
    return statRows(rows.filter((row) => periodKey(row.half) === ''));
  }

  const statistics = asRecord(value);
  const matchStats = asRecord(statistics.match);
  for (const [key, rows] of Object.entries(matchStats)) {
    if (FULL_PERIODS.has(periodKey(key)) && Array.isArray(rows)) {
      return statRows(rows.map(asRecord));
    }
  }

  const home = asRecord(statistics.home);
  const away = asRecord(statistics.away);
  const labels = [...new Set([...Object.keys(home), ...Object.keys(away)])];
  const scalar = (item: unknown) =>
    item === null || item === undefined || ['string', 'number'].includes(typeof item);
  return statRows(
    labels
      .filter((label) => scalar(home[label]) && scalar(away[label]))
      .map((label) => ({ type: label, home: home[label], away: away[label] })),
  );
}

const minuteParts = (value: unknown) => {
  const match = cleanText(value).match(/(\d+)(?:\s*\+\s*(\d+))?/);
  return {
    minute: match ? Number(match[1]) : null,
    extraMinute: match?.[2] ? Number(match[2]) : null,
  };
};

const minuteValue = (value: unknown) => minuteParts(value).minute;
const extraMinuteValue = (value: unknown) => minuteParts(value).extraMinute;

export function normalizeMatchDetail(
  raw: unknown,
  rawVideos: unknown = [],
  media: PlayerMedia = {},
) {
  const envelope = asRecord(raw);
  const videos = asList(rawVideos)
    .map(asRecord)
    .filter((row) => {
      const videoId = cleanText(row.videoId);
      const url = cleanText(row.url);
      return /^[A-Za-z0-9_-]{11}$/.test(videoId) &&
        url === `https://www.youtube.com/watch?v=${videoId}` &&
        cleanText(row.verificationStatus) === 'VERIFIED_CHANNEL';
    })
    .map((row) => ({
      videoId: cleanText(row.videoId),
      title: cleanText(row.title),
      url: cleanText(row.url),
      channelId: cleanText(row.channelId),
      channelName: cleanText(row.channelName),
      publishedAt: row.publishedAt ?? null,
      source: cleanText(row.source) || 'YouTube · canal oficial',
      verificationStatus: 'VERIFIED_CHANNEL',
    }));
  const payload = asRecord(envelope.payload);
  const lineups = payload.lineups;
  const fullTime = normalizeStatistics(payload.statistics);

  const incidents = [
    ...asList(payload.events).map((value) => {
      const row = asRecord(value);
      const providerType = cleanText(row.type).toUpperCase();
      const type = providerType.includes('MISSED') &&
          providerType.includes('PENAL')
        ? 'MISSED_PENALTY'
        : providerType.includes('VAR')
        ? 'VAR'
        : providerType.includes('GOAL')
        ? 'GOAL'
        : 'OTHER';
      const scorer =
        cleanText(row.homeScorer) ||
        cleanText(row.awayScorer) ||
        cleanText(row.player);
      const assist =
        cleanText(row.homeAssist) ||
        cleanText(row.awayAssist) ||
        cleanText(row.assist);
      const score = cleanText(row.score);
      const side = cleanText(row.homeScorer) || cleanText(row.homeAssist)
        ? 'home'
        : cleanText(row.awayScorer) || cleanText(row.awayAssist)
        ? 'away'
        : null;
      return {
        type,
        minute: minuteValue(row.time),
        extraMinute: extraMinuteValue(row.time),
        label: type === 'GOAL'
          ? 'Gol'
          : type === 'VAR'
          ? 'VAR'
          : type === 'MISSED_PENALTY'
          ? 'Penal fallado'
          : providerType || 'Evento',
        detail: [
          scorer,
          assist ? `Asistencia: ${assist}` : '',
          score,
          cleanText(row.info),
        ].filter((part) => part.length > 0).join(' · ') || null,
        playerId: cleanText(row.homeScorerId) || cleanText(row.awayScorerId) || null,
        assistPlayerId: cleanText(row.homeAssistId) || cleanText(row.awayAssistId) || null,
        side,
      };
    }),
    ...asList(payload.cards).map((value) => {
      const row = asRecord(value);
      const card = cleanText(row.card);
      return {
        type: card.toLowerCase().includes('red') ? 'RED_CARD' : 'YELLOW_CARD',
        minute: minuteValue(row.time),
        extraMinute: extraMinuteValue(row.time),
        label: card || 'Tarjeta',
        detail:
          cleanText(row.homeFault) ||
          cleanText(row.awayFault) ||
          cleanText(row.info) ||
          null,
        playerId: cleanText(row.homePlayerId) || cleanText(row.awayPlayerId) || null,
        side: cleanText(row.homeFault)
          ? 'home'
          : cleanText(row.awayFault)
          ? 'away'
          : null,
      };
    }),
    ...asList(payload.substitutions).map((value) => {
      const row = asRecord(value);
      const playerIds = cleanText(row.substitutionPlayerId)
        .split('|')
        .map((part) => part.trim())
        .filter(Boolean);
      return {
        type: 'SUBSTITUTION',
        minute: minuteValue(row.time),
        extraMinute: extraMinuteValue(row.time),
        label: 'Sustitución',
        detail: cleanText(row.substitution) || null,
        team: cleanText(row.team) || null,
        outPlayerId: playerIds[0] || null,
        inPlayerId: playerIds[1] || null,
      };
    }),
  ].sort((a, b) => (a.minute ?? 999) - (b.minute ?? 999));

  const home = normalizeLineupSide(lineups, 'home', media);
  const away = normalizeLineupSide(lineups, 'away', media);
  if (!home.formation) home.formation = cleanText(payload.homeTeamSystem) || null;
  if (!away.formation) away.formation = cleanText(payload.awayTeamSystem) || null;

  return {
    matchId: cleanText(envelope.matchId),
    available: envelope.available === true,
    pending:
      envelope.requestedAt != null &&
      cleanText(envelope.detailLevel) !== 'full',
    detailLevel: cleanText(envelope.detailLevel) || 'none',
    fetchedAt: envelope.fetchedAt ?? null,
    provider: envelope.provider ?? null,
    referee: cleanText(payload.matchReferee) || null,
    stadium: cleanText(payload.matchStadium) || null,
    round: cleanText(payload.matchRound) || null,
    home,
    away,
    statistics: fullTime,
    incidents,
    videos,
  };
}
