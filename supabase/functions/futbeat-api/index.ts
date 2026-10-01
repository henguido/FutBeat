import { withSupabase } from 'npm:@supabase/server';
import { calendarCacheControl } from '../_shared/calendar_cache.ts';
import {
  asRecord,
  cleanText,
  lineupPlayerIds,
  lineupPlayerIdsBySection,
  normalizeMatchDetail,
  safeImage,
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

// Season: a raw label ('2026/27', 'Apertura 2026') or a normalized key
// (the server normalizes both), or '-' for the seasonless option.
const validSeasonKey = (value: string | null) =>
  value === null || value === '-' ||
  /^[\p{L}\p{N}][\p{L}\p{N} ._/-]{0,39}$/u.test(value);

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

      // The demands below and the stored read are independent (the read is a
      // stable snapshot of what is stored; a demand only queues work for the
      // workers), so they run concurrently: the profile answers in the time
      // of its slowest RPC instead of the sum of all of them.
      //
      // Opening a player records a deduplicated hydration demand (server-side
      // only). A failure here never blocks the cached profile.
      const playerDemand = type === 'player'
        ? ctx.supabaseAdmin.rpc('futbeat_request_player_profile', { p_player_id: id })
          .then(({ data: demand, error: demandError }) => {
            if (demandError) {
              console.warn('player profile demand unavailable');
              return false;
            }
            return asRecord(demand).enrichmentPending === true;
          }, () => {
            console.warn('player profile demand unavailable');
            return false;
          })
        : Promise.resolve(false);
      // Opening a team whose squad is missing or stale records ONE central
      // deduplicated demand (#111); the squad planner fetches it later.
      // Missing/stale match coverage records ONE central deduplicated demand
      // (#150); the worker fetches it later. Neither blocks the read.
      const teamDemands = type === 'team'
        ? Promise.all([
          ctx.supabaseAdmin.rpc('futbeat_request_team_squad', { p_team_id: id })
            .then(({ error: squadError }) => {
              if (squadError) console.warn('team squad demand unavailable');
            }, () => console.warn('team squad demand unavailable')),
          ctx.supabaseAdmin.rpc('futbeat_request_team_matches', { p_team_id: id })
            .then(({ error: matchesError }) => {
              if (matchesError) console.warn('team matches demand unavailable');
            }, () => console.warn('team matches demand unavailable')),
        ])
        : Promise.resolve();

      const [enrichmentPending, , { data: snapshot, error }] = await Promise.all([
        playerDemand,
        teamDemands,
        ctx.supabaseAdmin.rpc(
          'futbeat_read_entity_detail',
          {
            p_type: type,
            p_id: id,
          },
        ),
      ]);

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

    // Profile context (#161): the team's real (competition, season)
    // combinations, the selected one (requested when real, else the
    // deterministic default) and its exact table.
    if (path.endsWith('/futbeat-api/v1/team-context')) {
      const id = requestUrl.searchParams.get('id');
      const competitionId = requestUrl.searchParams.get('competitionId');
      const season = requestUrl.searchParams.get('season');
      if (
        !validEntityId(id) ||
        (competitionId !== null && !validEntityId(competitionId)) ||
        !validSeasonKey(season) ||
        (season !== null && competitionId === null)
      ) {
        return reply(400, { error: 'Solicitud inválida' });
      }
      const { data: context, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_read_team_context',
        { p_team_id: id, p_competition_id: competitionId, p_season_key: season },
      );
      if (error) return reply(503, { error: 'Datos temporalmente no disponibles' });
      if (!context) return reply(404, { error: 'Entidad no encontrada' });
      if (context.schemaVersion !== 1) {
        return reply(503, { error: 'Datos temporalmente no disponibles' });
      }
      return reply(200, context);
    }

    // Team / national-team matches across every competition (#150): one
    // bucket (live | upcoming ascending | results descending) per page,
    // keyset cursor; optionally one competition / season (#161).
    if (path.endsWith('/futbeat-api/v1/team-matches')) {
      const id = requestUrl.searchParams.get('id');
      const bucket = requestUrl.searchParams.get('bucket');
      const cursor = requestUrl.searchParams.get('cursor');
      const limit = Number(requestUrl.searchParams.get('limit') ?? '20');
      const competitionId = requestUrl.searchParams.get('competitionId');
      const season = requestUrl.searchParams.get('season');
      if (
        !validEntityId(id) ||
        (bucket !== 'live' && bucket !== 'upcoming' && bucket !== 'results') ||
        (cursor !== null && (cursor.length < 3 || cursor.length > 200)) ||
        !Number.isInteger(limit) || limit < 1 || limit > 50 ||
        (competitionId !== null && !validEntityId(competitionId)) ||
        !validSeasonKey(season) ||
        (season !== null && competitionId === null)
      ) {
        return reply(400, { error: 'Solicitud inválida' });
      }
      const filtered = competitionId !== null;
      const { data: page, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_read_team_matches',
        filtered
          ? {
            p_team_id: id, p_bucket: bucket, p_cursor: cursor, p_limit: limit,
            p_competition_id: competitionId, p_season_key: season,
          }
          : { p_team_id: id, p_bucket: bucket, p_cursor: cursor, p_limit: limit },
      );
      if (error) {
        return reply(error.message?.includes('cursor') ? 400 : 503, {
          error: 'Datos temporalmente no disponibles',
        });
      }
      if (!page) return reply(404, { error: 'Entidad no encontrada' });
      if (page.schemaVersion !== 1 || page.demo !== false) {
        return reply(503, { error: 'Datos temporalmente no disponibles' });
      }
      // End of Resultados: ask centrally for the older window before the
      // oldest stored result (deduplicated; the server decides if needed).
      // No stored result and a confirmed-empty recent window (NO_DATA): the
      // window before that range. A filtered list ending is not the end of
      // the team's history. Only a demand is recorded (floor, dedup,
      // backoff, lease, quota and wake are the central lane's).
      let historyRequested = false;
      if (bucket === 'results' && page.hasMore !== true && !filtered) {
        const matches = Array.isArray(page.matches) ? page.matches : [];
        const coverage = asRecord(asRecord(page.coverage).teamMatches);
        const oldest = matches.length
          ? String(asRecord(matches[matches.length - 1]).startTime ?? '')
          : coverage.state === 'NO_DATA'
          ? String(coverage.emptyFrom ?? '')
          : '';
        const before = /^\d{4}-\d{2}-\d{2}/.test(oldest)
          ? oldest.slice(0, 10)
          : null;
        if (before) {
          const { data: history, error: historyError } = await ctx.supabaseAdmin.rpc(
            'futbeat_request_team_matches',
            { p_team_id: id, p_before: before },
          );
          if (historyError) console.warn('team history demand unavailable');
          historyRequested = !historyError && asRecord(history).backfill === true;
        }
      }
      if (historyRequested) {
        // Older history is being asked: never a cached "no results".
        page.coverage = {
          ...asRecord(page.coverage),
          teamMatches: { ...asRecord(asRecord(page.coverage).teamMatches), history: 'requested' },
        };
        return replyNoStore(200, page);
      }
      return reply(200, page);
    }

    if (path.endsWith('/futbeat-api/v1/explore')) {
      // Country only reorders/adds local suggestions; the global list stays.
      const country = (requestUrl.searchParams.get('country') ?? '').trim().toUpperCase();
      const { data: snapshot, error } = /^[A-Z]{2}$/.test(country)
        ? await ctx.supabaseAdmin.rpc('futbeat_read_country_explore', { p_country: country })
        : await ctx.supabaseAdmin.rpc('futbeat_read_explore');
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

      // Opening a historical partial match elevates that day's terminal-result
      // recovery (server-side only, deduped by date). A failure here never
      // blocks the read.
      // Exact (competition, season) standings: cache hit, or one deduplicated
      // demand. The read below reports coverage.standings/standingsPending.
      // The two demands do not depend on each other: one round trip, not two
      // (the read still runs after both, so it reports what they queued).
      const [{ error: demandError }, { error: standingsError }] = await Promise
        .all([
          ctx.supabaseAdmin.rpc(
            'futbeat_request_terminal_result',
            { p_match_id: id },
          ),
          ctx.supabaseAdmin.rpc(
            'futbeat_request_match_standings',
            { p_match_id: id },
          ),
        ]);
      if (demandError) console.warn('terminal result demand unavailable');
      if (standingsError) console.warn('standings demand unavailable');

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

      // Data still arriving: never let an edge cache pin this partial answer.
      if (asRecord(snapshot.coverage).standingsPending === true) {
        return replyNoStore(200, snapshot);
      }
      return reply(200, snapshot);
    }

    // Recent form + head-to-head (#99): a separate DB-only read model, so the
    // match context stays light. Never wakes the worker, never calls a
    // provider. Opening it asks for the central per-team match coverage of
    // both teams (deduplicated; nothing when coverage is already fine).
    if (path.endsWith('/futbeat-api/v1/match-preview')) {
      const id = requestUrl.searchParams.get('id');
      if (!validEntityId(id) || !id?.startsWith('fb_match_')) {
        return reply(400, { error: 'Partido inválido' });
      }
      const { error: h2hDemandError } = await ctx.supabaseAdmin.rpc(
        'futbeat_request_match_h2h',
        { p_match_id: id },
      );
      if (h2hDemandError) console.warn('h2h coverage demand unavailable');
      const { data: preview, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_read_match_preview',
        { p_match_id: id },
      );
      if (error) {
        return replyNoStore(503, { error: 'Previa temporalmente no disponible' });
      }
      if (!preview) {
        return replyNoStore(404, { error: 'Partido no encontrado' });
      }
      if (preview.schemaVersion !== 1) {
        return replyNoStore(503, { error: 'Previa temporalmente no disponible' });
      }
      // Coverage still arriving (nothing yet, or a stale history being
      // refreshed): never cache, the next open reads fresh.
      const availability = asRecord(preview.h2h).availability;
      if (availability === 'PENDING' || availability === 'STALE') {
        return replyNoStore(200, preview);
      }
      return reply(200, preview);
    }

    // Tabla v2 "Forma" (#158): last results per team of one competition +
    // season, from stored canonical finals only. DB-only, loaded lazily by
    // the app; never a demand nor a provider call.
    if (path.endsWith('/futbeat-api/v1/standings-form')) {
      const competitionId = requestUrl.searchParams.get('competitionId');
      const season = (requestUrl.searchParams.get('season') ?? '').trim();
      // Optional cap: the published table's updatedAt (ISO 8601).
      const until = requestUrl.searchParams.get('until');
      if (
        !validEntityId(competitionId) ||
        !competitionId?.startsWith('fb_comp_') ||
        season.length < 1 || season.length > 20 ||
        (until !== null && (until.length > 40 ||
          !/^\d{4}-\d{2}-\d{2}T/.test(until) || Number.isNaN(Date.parse(until))))
      ) {
        return reply(400, { error: 'Solicitud inválida' });
      }
      const { data: form, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_read_standings_form',
        {
          p_competition_id: competitionId,
          p_season_key: season,
          p_limit: 5,
          p_until: until,
        },
      );
      if (error) {
        return replyNoStore(503, { error: 'Datos temporalmente no disponibles' });
      }
      if (!form) return reply(404, { error: 'Competición no encontrada' });
      if (form.schemaVersion !== 1) {
        return replyNoStore(503, { error: 'Datos temporalmente no disponibles' });
      }
      return reply(200, form);
    }

    // Full stored head-to-head of the pair (#155): keyset pages for 'all' or
    // 'competition', totals independent of the page, and the verified
    // window. `extend=1` asks the central per-team coverage for one older
    // step of both teams (deduplicated; never a provider call here).
    if (path.endsWith('/futbeat-api/v1/match-h2h')) {
      const id = requestUrl.searchParams.get('id');
      const scope = requestUrl.searchParams.get('scope') ?? 'all';
      const cursor = requestUrl.searchParams.get('cursor');
      const limit = Number(requestUrl.searchParams.get('limit') ?? '20');
      const extend = requestUrl.searchParams.get('extend') === '1';
      if (
        !validEntityId(id) || !id?.startsWith('fb_match_') ||
        (scope !== 'all' && scope !== 'competition') ||
        (cursor !== null && (cursor.length < 3 || cursor.length > 200)) ||
        !Number.isInteger(limit) || limit < 1 || limit > 50
      ) {
        return replyNoStore(400, { error: 'Solicitud inválida' });
      }
      if (extend) {
        const { error: historyError } = await ctx.supabaseAdmin.rpc(
          'futbeat_request_match_h2h_history',
          { p_match_id: id },
        );
        if (historyError) console.warn('h2h history demand unavailable');
      }
      const { data: page, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_read_match_h2h',
        { p_match_id: id, p_scope: scope, p_cursor: cursor, p_limit: limit },
      );
      if (error) {
        return replyNoStore(error.message?.includes('cursor') ? 400 : 503, {
          error: 'Cara a cara temporalmente no disponible',
        });
      }
      if (!page) return replyNoStore(404, { error: 'Partido no encontrado' });
      if (page.schemaVersion !== 1) {
        return replyNoStore(503, { error: 'Cara a cara temporalmente no disponible' });
      }
      // An extension in progress changes the answer soon: never cache it.
      if (extend || asRecord(page.window).extending === true) {
        return replyNoStore(200, page);
      }
      return reply(200, page);
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

      let lineupEnrichmentPending = false;
      const { starters, substitutes } = lineupPlayerIdsBySection(detail);
      const missingCanonicalIds = (ids: string[]) =>
        ids
          .map((id) => asRecord(playerMedia[id]))
          .filter((entry) => cleanText(entry.canonicalId) && !safeImage(entry.image))
          .map((entry) => cleanText(entry.canonicalId));
      const starterIds = missingCanonicalIds(starters);
      const benchIds = missingCanonicalIds(substitutes);
      if (starterIds.length > 0 || benchIds.length > 0) {
        const { data: hydration, error: hydrationError } = await ctx.supabaseAdmin.rpc(
          'futbeat_request_lineup_hydration',
          { p_starter_ids: starterIds, p_bench_ids: benchIds },
        );
        if (hydrationError) {
          console.warn('lineup player hydration demand unavailable');
        } else {
          lineupEnrichmentPending = asRecord(hydration).enrichmentPending === true;
        }
      }

      const normalized = normalizeMatchDetail(detail, videosError ? [] : videos, playerMedia) as Record<string, unknown>;
      normalized.coverage = {
        ...asRecord(normalized.coverage),
        videos: videosError ? 'unavailable' : 'available',
      };
      if (lineupEnrichmentPending) {
        // Partial lineup photos now; the app refreshes once hydration lands.
        normalized.coverage = { ...asRecord(normalized.coverage), lineupEnrichmentPending: true };
      }
      return replyNoStore(200, normalized);
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
