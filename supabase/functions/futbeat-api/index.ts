import { withSupabase } from 'npm:@supabase/server';

const jsonHeaders = {
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'public, max-age=30, stale-while-revalidate=60',
};

const reply = (status: number, data: unknown) =>
  new Response(JSON.stringify(data), { status, headers: jsonHeaders });

const replyNoStore = (status: number, data: unknown) =>
  new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
    },
  });

const validDate = (value: string | null) =>
  value !== null && /^\d{4}-\d{2}-\d{2}$/.test(value);

const validEntityType = (value: string | null) =>
  value !== null && ['team', 'player', 'competition'].includes(value);

const validEntityId = (value: string | null) =>
  value !== null && /^fb_[A-Za-z0-9_-]{3,120}$/.test(value);

const asRecord = (value: unknown): Record<string, unknown> =>
  value && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};

const asList = (value: unknown): unknown[] => Array.isArray(value) ? value : [];

const cleanText = (value: unknown) => String(value ?? '').trim();

const safeImage = (value: unknown) => {
  const raw = cleanText(value);
  if (!raw) return null;
  try {
    const parsed = new URL(raw);
    return parsed.protocol === 'https:' ? parsed.toString() : null;
  } catch {
    return null;
  }
};

const minuteValue = (value: unknown) => {
  const match = cleanText(value).match(/\d+/);
  return match ? Number(match[0]) : null;
};

function normalizeLineupPlayer(value: unknown) {
  const row = asRecord(value);
  const nested = asRecord(row.player);
  const name =
    cleanText(row.lineupPlayer) ||
    cleanText(nested.name) ||
    cleanText(row.playerName);
  if (!name) return null;
  return {
    id: cleanText(row.playerId) || cleanText(nested.id) || null,
    name,
    number: cleanText(row.lineupNumber) || null,
    position: cleanText(row.playerPosition) || null,
    lineupPosition: Number.isFinite(Number(row.lineupPosition))
      ? Number(row.lineupPosition)
      : null,
    country: cleanText(row.playerCountry) || null,
    age: Number.isFinite(Number(row.playerAge)) ? Number(row.playerAge) : null,
    image: safeImage(row.playerImage ?? nested.image),
  };
}

function normalizeLineupSide(lineups: Record<string, unknown>, side: 'home' | 'away') {
  const data = asRecord(lineups[side]);
  const players = (key: string) =>
    asList(data[key])
      .map(normalizeLineupPlayer)
      .filter((item): item is NonNullable<ReturnType<typeof normalizeLineupPlayer>> => item !== null)
      .sort((left, right) =>
        (left.lineupPosition ?? 999) - (right.lineupPosition ?? 999)
      );
  return {
    formation: cleanText(lineups[side === 'home' ? 'homeFormation' : 'awayFormation']) || null,
    starters: players('startingLineups'),
    substitutes: players('substitutes'),
    missing: players('missingPlayers'),
  };
}

function normalizeMatchDetail(raw: unknown) {
  const envelope = asRecord(raw);
  const payload = asRecord(envelope.payload);
  const lineups = asRecord(payload.lineups);
  const statistics = asRecord(payload.statistics);
  const matchStats = asRecord(statistics.match);
  const fullTime = asList(matchStats.fullTime)
    .map(asRecord)
    .filter((row) => cleanText(row.type))
    .map((row) => ({
      label: cleanText(row.type),
      home: row.home ?? '—',
      away: row.away ?? '—',
    }));

  const incidents = [
    ...asList(payload.cards).map((value) => {
      const row = asRecord(value);
      const card = cleanText(row.card);
      return {
        type: card.toLowerCase().includes('red') ? 'RED_CARD' : 'YELLOW_CARD',
        minute: minuteValue(row.time),
        label: card || 'Tarjeta',
        detail:
          cleanText(row.homeFault) ||
          cleanText(row.awayFault) ||
          cleanText(row.info) ||
          null,
      };
    }),
    ...asList(payload.substitutions).map((value) => {
      const row = asRecord(value);
      return {
        type: 'SUBSTITUTION',
        minute: minuteValue(row.time),
        label: 'Sustitución',
        detail: cleanText(row.substitution) || null,
        team: cleanText(row.team) || null,
      };
    }),
  ].sort((a, b) => (a.minute ?? 999) - (b.minute ?? 999));

  const home = normalizeLineupSide(lineups, 'home');
  const away = normalizeLineupSide(lineups, 'away');
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
  };
}

export default {
  fetch: withSupabase({ auth: 'none' }, async (request, ctx) => {
    if (request.method !== 'GET') {
      return reply(405, { error: 'Method not allowed' });
    }

    const requestUrl = new URL(request.url);
    const path = requestUrl.pathname;

    if (path.endsWith('/futbeat-api/v1/snapshot')) {
      const { data: snapshot, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_read_snapshot',
      );
      if (
        error ||
        !snapshot ||
        snapshot.schemaVersion !== 1 ||
        snapshot.demo !== false
      ) {
        return reply(503, { error: 'Datos temporalmente no disponibles' });
      }

      return reply(200, snapshot);
    }

    if (path.endsWith('/futbeat-api/v1/entity')) {
      const type = requestUrl.searchParams.get('type');
      const id = requestUrl.searchParams.get('id');

      if (!validEntityType(type) || !validEntityId(id)) {
        return reply(400, { error: 'Entidad inválida' });
      }

      const { data: snapshot, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_read_entity_detail',
        {
          p_type: type,
          p_id: id,
        },
      );

      if (error) {
        return reply(503, { error: 'Datos temporalmente no disponibles' });
      }
      if (!snapshot) {
        return reply(404, { error: 'Entidad no encontrada' });
      }
      if (snapshot.schemaVersion !== 1 || snapshot.demo !== false) {
        return reply(503, { error: 'Datos temporalmente no disponibles' });
      }

      return reply(200, snapshot);
    }

    if (path.endsWith('/futbeat-api/v1/match-detail')) {
      const id = requestUrl.searchParams.get('id');
      if (!validEntityId(id) || !id?.startsWith('fb_match_')) {
        return replyNoStore(400, { error: 'Partido inválido' });
      }

      const { data: detail, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_request_match_detail',
        { p_match_id: id },
      );

      if (error) {
        const message = String(error.message ?? '');
        if (message.includes('Unknown canonical match')) {
          return replyNoStore(404, { error: 'Partido no encontrado' });
        }
        return replyNoStore(503, { error: 'Detalle temporalmente no disponible' });
      }

      if (!detail) {
        return replyNoStore(404, { error: 'Partido no encontrado' });
      }

      return replyNoStore(200, normalizeMatchDetail(detail));
    }

    if (path.endsWith('/futbeat-api/v1/calendar')) {
      const date = requestUrl.searchParams.get('date');
      const timezone =
        requestUrl.searchParams.get('timezone') ?? 'America/Costa_Rica';

      if (!validDate(date) || timezone.length < 1 || timezone.length > 80) {
        return reply(400, { error: 'Fecha o zona horaria inválida' });
      }

      const { data: snapshot, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_read_calendar_range',
        {
          p_from_date: date,
          p_to_date: date,
          p_timezone: timezone,
        },
      );

      if (
        error ||
        !snapshot ||
        snapshot.schemaVersion !== 1 ||
        snapshot.demo !== false
      ) {
        return reply(503, { error: 'Datos temporalmente no disponibles' });
      }

      return reply(200, snapshot);
    }

    return reply(404, { error: 'Not found' });
  }),
};
