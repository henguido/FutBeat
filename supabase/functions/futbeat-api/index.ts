import { withSupabase } from 'npm:@supabase/server';
import { calendarCacheControl } from '../_shared/calendar_cache.ts';
import {
  asRecord,
  lineupPlayerIds,
  normalizeMatchDetail,
  type PlayerMedia,
} from '../_shared/match_detail.ts';

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

      // Opening a player records a deduplicated hydration demand (server-side
      // only). A failure here never blocks the cached profile.
      let enrichmentPending = false;
      if (type === 'player') {
        const { data: demand, error: demandError } = await ctx.supabaseAdmin.rpc(
          'futbeat_request_player_profile',
          { p_player_id: id },
        );
        if (demandError) {
          console.warn('player profile demand unavailable');
        } else {
          enrichmentPending = asRecord(demand).enrichmentPending === true;
        }
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

      if (enrichmentPending) {
        // Partial profile now; the app refreshes once enrichment lands.
        snapshot.coverage = { ...asRecord(snapshot.coverage), enrichmentPending: true };
        return replyNoStore(200, snapshot);
      }
      return reply(200, snapshot);
    }

    if (path.endsWith('/futbeat-api/v1/explore')) {
      const { data: snapshot, error } = await ctx.supabaseAdmin.rpc('futbeat_read_explore');
      if (error || !snapshot || snapshot.schemaVersion !== 1 || snapshot.demo !== false) {
        return reply(503, { error: 'Sugerencias temporalmente no disponibles' });
      }
      return replyNoStore(200, snapshot);
    }

    if (path.endsWith('/futbeat-api/v1/search')) {
      const query = (requestUrl.searchParams.get('q') ?? '').trim();
      const country = (requestUrl.searchParams.get('country') ?? '').trim();
      if (query.length > 80 || country.length > 8) {
        return reply(400, { error: 'Búsqueda inválida' });
      }

      const { data: snapshot, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_search_catalog',
        {
          p_query: query,
          p_country: country || null,
          p_limit: 50,
        },
      );
      if (
        error ||
        !snapshot ||
        snapshot.schemaVersion !== 1 ||
        snapshot.demo !== false
      ) {
        return reply(503, { error: 'Búsqueda temporalmente no disponible' });
      }
      // Remote discovery in progress: never cache this partial answer.
      if (asRecord(snapshot.coverage).pendingRemote === true) {
        return replyNoStore(200, snapshot);
      }
      return reply(200, snapshot);
    }

    if (path.endsWith('/futbeat-api/v1/favorites')) {
      const rawKeys = (requestUrl.searchParams.get('keys') ?? '').trim();
      const keys = rawKeys.length === 0 ? [] : rawKeys.split(',');
      if (
        keys.length > 50 ||
        keys.some((key) =>
          !/^(team|player|competition|match):fb_[A-Za-z0-9_-]{3,120}$/.test(key)
        )
      ) {
        return reply(400, { error: 'Favoritos inválidos' });
      }

      const { data: snapshot, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_read_favorites',
        { p_keys: keys },
      );
      if (
        error ||
        !snapshot ||
        snapshot.schemaVersion !== 1 ||
        snapshot.demo !== false
      ) {
        return reply(503, { error: 'Favoritos temporalmente no disponibles' });
      }
      return reply(200, snapshot);
    }

    if (path.endsWith('/futbeat-api/v1/match-context')) {
      const id = requestUrl.searchParams.get('id');
      if (!validEntityId(id) || !id?.startsWith('fb_match_')) {
        return reply(400, { error: 'Partido inválido' });
      }

      const { data: snapshot, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_read_match_context',
        { p_match_id: id },
      );

      if (error) {
        return reply(503, { error: 'Partido temporalmente no disponible' });
      }
      if (!snapshot) {
        return reply(404, { error: 'Partido no encontrado' });
      }
      if (snapshot.schemaVersion !== 1 || snapshot.demo !== false) {
        return reply(503, { error: 'Partido temporalmente no disponible' });
      }

      return reply(200, snapshot);
    }

    if (path.endsWith('/futbeat-api/v1/match-detail')) {
      const id = requestUrl.searchParams.get('id');
      if (!validEntityId(id) || !id?.startsWith('fb_match_')) {
        return replyNoStore(400, { error: 'Partido inválido' });
      }

      const shouldRequest =
        requestUrl.searchParams.get('request') !== '0';
      const [
        { data: detail, error },
        { data: videos, error: videosError },
      ] = await Promise.all([
        ctx.supabaseAdmin.rpc(
          shouldRequest
            ? 'futbeat_request_match_detail'
            : 'futbeat_read_match_detail',
          { p_match_id: id },
        ),
        ctx.supabaseAdmin.rpc(
          'futbeat_read_match_videos',
          { p_match_id: id },
        ),
      ]);

      if (videosError) {
        console.warn('match videos unavailable', String(videosError.message ?? ''));
      }

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

      let playerMedia: PlayerMedia = {};
      const playerIds = lineupPlayerIds(detail);
      if (playerIds.length > 0) {
        const { data: media, error: mediaError } = await ctx.supabaseAdmin.rpc(
          'futbeat_read_lineup_player_media',
          { p_provider: 'goal_api', p_external_ids: playerIds },
        );
        if (mediaError) {
          console.warn('lineup player media unavailable');
        } else {
          playerMedia = asRecord(media) as PlayerMedia;
        }
      }

      return replyNoStore(
        200,
        normalizeMatchDetail(detail, videosError ? [] : videos, playerMedia),
      );
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

      if (snapshot.coverage?.partial === true) {
        const { error: requestError } = await ctx.supabaseAdmin.rpc(
          'futbeat_request_calendar_date',
          { p_local_date: date, p_timezone: timezone },
        );
        if (requestError) {
          console.warn('calendar recovery request unavailable');
        }
      }

      return new Response(JSON.stringify(snapshot), {
        status: 200,
        headers: { ...jsonHeaders, 'Cache-Control': calendarCacheControl(
          date!, timezone, snapshot.coverage?.partial === true) },
      });
    }

    return reply(404, { error: 'Not found' });
  }),
};
