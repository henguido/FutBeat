// Stored-only reads for Android QA, off unless FUTBEAT_QA_STORED_READS_ENABLED
// is 'true'. A separate function so that enabling it never redeploys
// futbeat-api. Paths and the acknowledgment header are the ones
// QaStoredReadInterceptor expects. Only the STABLE RPCs below are callable: no
// provider, request_*, wake_*, cache-filling or write path, and no fallback.
import {
  asRecord,
  cleanText,
  lineupPlayerIds,
  normalizeMatchDetail,
  type PlayerMedia,
} from '../_shared/match_detail.ts';

type Rpc = (name: string, args?: Record<string, unknown>) =>
  PromiseLike<{ data: unknown; error: unknown }>;

export const storedRpcs = [
  'futbeat_read_qa_stored_calendar',
  'futbeat_read_qa_stored_explore',
  'futbeat_read_qa_stored_search',
  'futbeat_read_qa_stored_national_teams',
  'futbeat_read_match_context',
  'futbeat_read_match_detail',
  'futbeat_read_match_videos',
  'futbeat_read_lineup_player_media',
  'futbeat_read_match_preview',
  'futbeat_read_match_h2h',
  'futbeat_read_entity_detail',
  'futbeat_read_team_context',
  'futbeat_read_team_matches',
  'futbeat_read_standings_form',
  'futbeat_read_favorites',
];

const prefix = '/v1/qa-stored/';
const headers = {
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store',
  'X-FutBeat-QA-Stored': 'v1',
};
const unavailable = { error: 'Stored data unavailable; no demand registered' };
const missing = { error: 'Not stored; no demand registered' };
const invalid = { error: 'Invalid request' };

const validId = (value: string | null) =>
  value !== null && /^fb_[A-Za-z0-9_-]{3,120}$/.test(value);
const validMatchId = (value: string | null) =>
  validId(value) && value!.startsWith('fb_match_');
const validSeason = (value: string | null) =>
  value === null || value === '-' ||
  /^[\p{L}\p{N}][\p{L}\p{N} ._/-]{0,39}$/u.test(value);
const validDate = (value: string | null) =>
  value !== null && /^\d{4}-\d{2}-\d{2}$/.test(value) &&
  !Number.isNaN(Date.parse(value)) &&
  new Date(value).toISOString().slice(0, 10) === value;

// Same national-team marks as futbeat-api, from the stored cache as it is.
const nationalTeamsTtlMs = 10 * 60 * 1000;
let nationalTeams: { teams: Record<string, unknown>; at: number } | null = null;
export const resetStoredReadCache = () => {
  nationalTeams = null;
};

const loadNationalTeams = async (read: Rpc) => {
  if (nationalTeams && Date.now() - nationalTeams.at < nationalTeamsTtlMs) return;
  const { data, error } = await read('futbeat_read_qa_stored_national_teams');
  const teams = asRecord(data).teams;
  nationalTeams = {
    teams: !error && teams && typeof teams === 'object' && !Array.isArray(teams)
      ? teams as Record<string, unknown>
      : nationalTeams?.teams ?? {},
    at: Date.now(),
  };
};

const nationalTeamFields = (_key: string, value: unknown) => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return value;
  const entity = value as Record<string, unknown>;
  const id = entity.id;
  if (
    typeof id !== 'string' || !id.startsWith('fb_team_') ||
    typeof entity.name !== 'string' || 'nationalTeamCode' in entity ||
    !nationalTeams || !Object.hasOwn(nationalTeams.teams, id)
  ) {
    return value;
  }
  const national = asRecord(nationalTeams.teams[id]);
  const code = cleanText(national.code);
  if (!/^[A-Z]{2}(?:-[A-Z]{3})?$/.test(code)) return value;
  const suffix = cleanText(national.suffix);
  return suffix
    ? { ...entity, nationalTeamCode: code, nationalTeamSuffix: suffix }
    : { ...entity, nationalTeamCode: code };
};

const reply = (status: number, data: unknown) =>
  new Response(
    JSON.stringify(data, status === 200 ? nationalTeamFields : undefined),
    { status, headers },
  );

// Legacy news carries no per-source rights: link-out metadata only.
const withoutNewsExcerpts = (snapshot: Record<string, unknown>) => ({
  ...snapshot,
  news: Array.isArray(snapshot.news)
    ? snapshot.news.map((item: unknown) => {
      const safe = { ...asRecord(item) };
      delete safe.description;
      delete safe.imageUrl;
      return safe;
    })
    : snapshot.news,
});

const answer = (result: { data: unknown; error: unknown }) => {
  if (result.error) return reply(503, unavailable);
  if (!result.data) return reply(404, missing);
  const data = asRecord(result.data);
  if (data.schemaVersion !== 1 || data.demo === true) return reply(503, unavailable);
  return reply(200, data);
};

async function matchDetail(read: Rpc, id: string) {
  const { data: detail, error } = await read('futbeat_read_match_detail', { p_match_id: id });
  if (error) return reply(503, unavailable);
  if (!detail) return reply(404, missing);
  const [videos, media] = await Promise.all([
    read('futbeat_read_match_videos', { p_match_id: id }),
    lineupPlayerIds(detail).length > 0
      ? read('futbeat_read_lineup_player_media', {
        p_provider: 'goal_api',
        p_external_ids: lineupPlayerIds(detail),
      })
      : Promise.resolve({ data: {}, error: null }),
  ]);
  const normalized = normalizeMatchDetail(
    detail,
    videos.error ? [] : videos.data,
    (media.error ? {} : asRecord(media.data)) as PlayerMedia,
  ) as Record<string, unknown>;
  // Nothing was requested, so nothing is on its way: `pending` would only make
  // the app poll. hydrationNeeded stays: it tells the stored data is incomplete.
  normalized.pending = false;
  normalized.coverage = {
    ...asRecord(normalized.coverage),
    pending: false,
    videos: videos.error ? 'unavailable' : 'available',
    storedRead: true,
  };
  return reply(200, normalized);
}

async function route(name: string, query: URLSearchParams, read: Rpc): Promise<Response> {
  const id = query.get('id');
  const limit = Number(query.get('limit') ?? '20');
  const cursor = query.get('cursor');
  const validPage = Number.isInteger(limit) && limit >= 1 && limit <= 50 &&
    (cursor === null || (cursor.length >= 3 && cursor.length <= 200));
  const competitionId = query.get('competitionId');
  const season = query.get('season');
  const validFilter = (competitionId === null || validId(competitionId)) &&
    validSeason(season) && (season === null || competitionId !== null);

  switch (name) {
    case 'calendar': {
      const date = query.get('date');
      const timezone = query.get('timezone') ?? 'America/Costa_Rica';
      if (!validDate(date) || timezone.length < 1 || timezone.length > 80) {
        return reply(400, invalid);
      }
      return answer(await read('futbeat_read_qa_stored_calendar',
        { p_local_date: date, p_timezone: timezone }));
    }
    case 'match-context':
      if (!validMatchId(id)) return reply(400, invalid);
      return answer(await read('futbeat_read_match_context', { p_match_id: id }));
    case 'match-detail':
      if (!validMatchId(id)) return reply(400, invalid);
      return matchDetail(read, id!);
    case 'match-preview':
      if (!validMatchId(id)) return reply(400, invalid);
      return answer(await read('futbeat_read_match_preview', { p_match_id: id }));
    case 'match-h2h': {
      const scope = query.get('scope') ?? 'all';
      if (!validMatchId(id) || !validPage || (scope !== 'all' && scope !== 'competition')) {
        return reply(400, invalid);
      }
      return answer(await read('futbeat_read_match_h2h',
        { p_match_id: id, p_scope: scope, p_cursor: cursor, p_limit: limit }));
    }
    case 'entity': {
      const type = query.get('type');
      if (!validId(id) || !['team', 'player', 'competition'].includes(type ?? '')) {
        return reply(400, invalid);
      }
      const result = await read('futbeat_read_entity_detail', { p_type: type, p_id: id });
      return answer(result.data
        ? { ...result, data: withoutNewsExcerpts(asRecord(result.data)) }
        : result);
    }
    case 'team-context':
      if (!validId(id) || !validFilter) return reply(400, invalid);
      return answer(await read('futbeat_read_team_context',
        { p_team_id: id, p_competition_id: competitionId, p_season_key: season }));
    case 'team-matches': {
      const bucket = query.get('bucket');
      if (
        !validId(id) || !validPage || !validFilter ||
        !['live', 'upcoming', 'results'].includes(bucket ?? '')
      ) {
        return reply(400, invalid);
      }
      return answer(await read('futbeat_read_team_matches', {
        p_team_id: id, p_bucket: bucket, p_cursor: cursor, p_limit: limit,
        ...(competitionId !== null
          ? { p_competition_id: competitionId, p_season_key: season }
          : {}),
      }));
    }
    case 'standings-form': {
      const seasonKey = (season ?? '').trim();
      const until = query.get('until');
      if (
        !validId(competitionId) || seasonKey.length < 1 || seasonKey.length > 20 ||
        (until !== null && (until.length > 40 || Number.isNaN(Date.parse(until))))
      ) {
        return reply(400, invalid);
      }
      return answer(await read('futbeat_read_standings_form', {
        p_competition_id: competitionId, p_season_key: seasonKey, p_limit: 5, p_until: until,
      }));
    }
    case 'favorites': {
      const raw = (query.get('keys') ?? '').trim();
      const keys = raw.length === 0 ? [] : raw.split(',');
      if (
        keys.length > 50 ||
        keys.some((key) => !/^(team|player|competition|match):fb_[A-Za-z0-9_-]{3,120}$/.test(key))
      ) {
        return reply(400, invalid);
      }
      return answer(await read('futbeat_read_favorites', { p_keys: keys }));
    }
    case 'explore': {
      const country = (query.get('country') ?? '').trim().toUpperCase();
      return answer(await read('futbeat_read_qa_stored_explore',
        { p_country: /^[A-Z]{2}$/.test(country) ? country : null }));
    }
    case 'search': {
      const text = (query.get('q') ?? '').trim();
      const country = (query.get('country') ?? '').trim();
      if (text.length > 80 || country.length > 8) return reply(400, invalid);
      return answer(await read('futbeat_read_qa_stored_search',
        { p_query: text, p_country: country || null, p_limit: 50 }));
    }
    default:
      return reply(403, { error: 'Route outside stored-read scope' });
  }
}

export async function handleStoredRead(request: Request, rpc: Rpc, enabled = false): Promise<Response> {
  // Off: the same plain 404 as a server without the route, without the header.
  if (!enabled) {
    return new Response(JSON.stringify({ error: 'Not found' }), {
      status: 404,
      headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
    });
  }
  if (request.method !== 'GET') return reply(405, { error: 'Read only' });
  const url = new URL(request.url);
  const at = url.pathname.indexOf(prefix);
  if (at < 0) return reply(403, { error: 'Route outside stored-read scope' });
  const read: Rpc = (name, args) => {
    if (!storedRpcs.includes(name)) throw new Error('RPC outside stored-read scope');
    return rpc(name, args);
  };
  try {
    await loadNationalTeams(read);
    return await route(url.pathname.slice(at + prefix.length), url.searchParams, read);
  } catch {
    return reply(503, unavailable);
  }
}
