// Passive read API for FutBeat Preview (API275), built on the PR #240 stored-only reads.
// Off unless the database policy row is enabled (created disabled); FUTBEAT_PASSIVE_API_ENABLED=false is an emergency stop.
// A separate function so enabling it never redeploys futbeat-api.
//
// Guarantees:
// - Only the STABLE RPCs in storedRpcs are callable. No provider, request_*, wake_*,
//   cache-filling or write path, and no fallback to one.
// - index.ts calls every RPC with GET, so PostgREST runs it in a READ ONLY transaction:
//   a write anywhere below would fail instead of landing.
// - Bounded: per-client and per-isolate rate limits, a cap on database reads in flight,
//   and a response cache with request coalescing. Revocable from the policy row in 30 s
//   or less, with no deploy.
// Paths: /v1/<route> (the same as futbeat-api) and /v1/qa-stored/<route> (the paths and
// acknowledgment header that QaStoredReadInterceptor expects).
import {
  asRecord,
  cleanText,
  lineupPlayerIds,
  normalizeMatchDetail,
  type PlayerMedia,
} from '../_shared/deployed/match_detail.passive-v7.ts';

type Rpc = (name: string, args?: Record<string, unknown>) =>
  PromiseLike<{ data: unknown; error: unknown }>;

export const storedRpcs = [
  'futbeat_read_passive_api_policy',
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

// Seconds a 200 stays fresh, in this isolate and in the client. LIVE-bearing routes are short.
export const routeTtl: Record<string, number> = {
  'calendar': 30,
  'match-context': 15,
  'match-detail': 15,
  'match-preview': 300,
  'match-h2h': 600,
  'entity': 300,
  'team-context': 300,
  'team-matches': 120,
  'standings-form': 300,
  'favorites': 60,
  'explore': 600,
  'search': 300,
};
const missTtl = 30;
const policyTtlMs = 30_000;
const cacheMaxEntries = 500;
const cacheMaxChars = 48_000_000;
const maxDbReadsInFlight = 4; // entity reads take up to 2.4 s; this database has had 57014 under load
const maxArgChars = 6000;
const cacheParams = new Set(['id', 'type', 'date', 'timezone', 'scope', 'cursor', 'limit',
  'competitionId', 'season', 'bucket', 'until', 'keys', 'country', 'q']);

const baseHeaders = {
  'Content-Type': 'application/json; charset=utf-8',
  'X-FutBeat-QA-Stored': 'v1',
  'X-FutBeat-Passive': 'v1',
};
const unavailable = { error: 'Stored data unavailable; no demand registered' };
const missing = { error: 'Not stored; no demand registered' };
const invalid = { error: 'Invalid request' };

type Out = { status: number; body: string; retryAfter?: number };

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
const safeArrayItem = /^[A-Za-z0-9_:.-]{1,140}$/;
// NUL and other control characters: Postgres text cannot hold NUL, and no route needs them.
const controlChars = /[\u0000-\u001f\u007f]/;
const maxParamChars = 300;

// GET rpc puts arguments in the query string: a null would arrive as the text 'null', so
// nulls are dropped (every nullable argument has a SQL default), and array items must be
// plain tokens that need no quoting inside a Postgres array literal.
export const getArgs = (args: Record<string, unknown> = {}) => {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(args)) {
    if (value === null || value === undefined) continue;
    if (typeof value === 'string' && controlChars.test(value)) throw new Error('Control character in argument');
    if (Array.isArray(value) && value.some((item) => typeof item !== 'string' || !safeArrayItem.test(item))) {
      throw new Error('Unsafe array argument');
    }
    out[key] = value;
  }
  if (JSON.stringify(out).length > maxArgChars) throw new Error('Arguments too long');
  return out;
};

// Isolate state. All of it is best effort and resets with the isolate.
let nationalTeams: { teams: Record<string, unknown>; at: number } | null = null;
let policy: { enabled: boolean; keys: Set<string>; perClient: number; perIsolate: number; at: number } | null = null;
const cache = new Map<string, Out & { expires: number }>();
let cacheChars = 0;
const inflight = new Map<string, Promise<Out>>();
let dbReads = 0;
const clientWindows = new Map<string, { minute: number; count: number }>();
let isolateWindow = { minute: 0, count: 0 };
const keyHashes = new Map<string, string>();

export const resetStoredReadCache = () => {
  nationalTeams = null;
  policy = null;
  cache.clear();
  cacheChars = 0;
  inflight.clear();
  dbReads = 0;
  clientWindows.clear();
  isolateWindow = { minute: 0, count: 0 };
  keyHashes.clear();
};
export const passiveStats = () => ({ cacheEntries: cache.size, cacheChars, dbReads, clients: clientWindows.size });

const loadNationalTeams = async (read: Rpc) => {
  if (nationalTeams && Date.now() - nationalTeams.at < 10 * 60 * 1000) return;
  const { data, error } = await read('futbeat_read_qa_stored_national_teams');
  const teams = asRecord(data).teams;
  nationalTeams = {
    teams: !error && teams && typeof teams === 'object' && !Array.isArray(teams)
      ? teams as Record<string, unknown>
      : nationalTeams?.teams ?? {},
    at: Date.now(),
  };
};

// Fails closed: no row, a disabled row or a read error all mean off.
const loadPolicy = async (read: Rpc) => {
  if (policy && Date.now() - policy.at < policyTtlMs) return policy;
  const { data, error } = await read('futbeat_read_passive_api_policy');
  const row = asRecord(data);
  const keys = Array.isArray(row.clientKeys) ? row.clientKeys.filter((k) => typeof k === 'string') : [];
  const num = (value: unknown, fallback: number, max: number) =>
    Number.isInteger(value) && (value as number) >= 1 && (value as number) <= max ? value as number : fallback;
  policy = {
    enabled: !error && row.enabled === true,
    keys: new Set(keys as string[]),
    perClient: num(row.perClientPerMinute, 60, 600),
    perIsolate: num(row.perIsolatePerMinute, 600, 10000),
    at: Date.now(),
  };
  return policy;
};

const sha256 = async (text: string) => {
  const known = keyHashes.get(text);
  if (known) return known;
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  const hex = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
  if (keyHashes.size > 100) keyHashes.clear();
  keyHashes.set(text, hex);
  return hex;
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

const reply = (status: number, data: unknown): Out => ({
  status,
  body: JSON.stringify(data, status === 200 ? nationalTeamFields : undefined),
});

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
  // Ids that are not plain tokens could not travel in a GET array: those players keep no photo.
  const ids = lineupPlayerIds(detail).filter((value) => safeArrayItem.test(value)).slice(0, 80);
  const [videos, media] = await Promise.all([
    read('futbeat_read_match_videos', { p_match_id: id }),
    ids.length > 0
      ? read('futbeat_read_lineup_player_media', { p_provider: 'goal_api', p_external_ids: ids })
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

async function route(name: string, query: URLSearchParams, read: Rpc): Promise<Out> {
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

const plainNotFound = () =>
  new Response(JSON.stringify({ error: 'Not found' }), {
    status: 404,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });

const send = (out: Out, ttl: number | null, cacheState: 'hit' | 'miss' | 'none') => {
  const headers: Record<string, string> = { ...baseHeaders, 'X-FutBeat-Cache': cacheState };
  headers['Cache-Control'] = ttl ? `public, max-age=${ttl}` : 'no-store';
  if (out.retryAfter) headers['Retry-After'] = String(out.retryAfter);
  return new Response(out.body, { status: out.status, headers });
};

// cf-connecting-ip is set by the edge network and cannot be supplied by the client; the
// first x-forwarded-for entry can. A spoofed one only evades the per-client limit, never
// the per-isolate limit or the in-flight cap.
const clientOf = (request: Request) =>
  (request.headers.get('cf-connecting-ip') ?? request.headers.get('x-real-ip') ??
    (request.headers.get('x-forwarded-for') ?? '').split(',')[0]).trim().slice(0, 64) || 'unknown';

const overLimit = (client: string, perClient: number, perIsolate: number, now: number) => {
  const minute = Math.floor(now / 60_000);
  if (isolateWindow.minute !== minute) isolateWindow = { minute, count: 0 };
  if (clientWindows.size > 5000) clientWindows.clear();
  const window = clientWindows.get(client);
  const current = window && window.minute === minute ? window : { minute, count: 0 };
  clientWindows.set(client, current);
  if (isolateWindow.count >= perIsolate || current.count >= perClient) {
    return 60 - Math.floor((now % 60_000) / 1000);
  }
  isolateWindow.count++;
  current.count++;
  return 0;
};

const store = (key: string, out: Out, ttl: number) => {
  const old = cache.get(key);
  if (old) { cacheChars -= old.body.length; cache.delete(key); }
  if (out.body.length > cacheMaxChars / 8) return;
  cache.set(key, { ...out, expires: Date.now() + ttl * 1000 });
  cacheChars += out.body.length;
  for (const [oldest, entry] of cache) {
    if (cache.size <= cacheMaxEntries && cacheChars <= cacheMaxChars) break;
    cache.delete(oldest);
    cacheChars -= entry.body.length;
  }
};

export async function handleStoredRead(request: Request, rpc: Rpc, enabled = false): Promise<Response> {
  // Off: the same plain 404 as a server without the route, without the header.
  if (!enabled) return plainNotFound();
  const read: Rpc = (fn, args) => {
    if (!storedRpcs.includes(fn)) throw new Error('RPC outside stored-read scope');
    return rpc(fn, getArgs(args));
  };
  try {
    // The policy comes first for every request: disabled or revoked, any method and any
    // path (valid, invalid or out of scope) gets the same plain 404 and no other read.
    const current = await loadPolicy(read);
    if (!current.enabled) return plainNotFound();
    if (current.keys.size > 0) {
      const key = request.headers.get('x-futbeat-client-key') ?? '';
      if (key.length < 16 || key.length > 200 || !current.keys.has(await sha256(key))) return plainNotFound();
    }
    const wait = overLimit(clientOf(request), current.perClient, current.perIsolate, Date.now());
    if (wait > 0) return send({ ...reply(429, { error: 'Too many requests' }), retryAfter: wait }, null, 'none');
    if (request.method !== 'GET') return send(reply(405, { error: 'Read only' }), null, 'none');
    const url = new URL(request.url);
    const at = url.pathname.lastIndexOf('/v1/');
    let name = at < 0 ? '' : url.pathname.slice(at + 4);
    if (name.startsWith('qa-stored/')) name = name.slice('qa-stored/'.length);
    // snapshot (6.4 MB), news, player-suggestions and anything else stay out of scope.
    if (!name || name.includes('/') || !Object.hasOwn(routeTtl, name)) {
      return send(reply(403, { error: 'Route outside stored-read scope' }), null, 'none');
    }

    for (const [k, v] of url.searchParams) {
      if (k.length > 40 || v.length > maxParamChars || controlChars.test(k) || controlChars.test(v)) {
        return send(reply(400, invalid), null, 'none');
      }
    }
    const params = [...url.searchParams].filter(([k]) => cacheParams.has(k))
      .sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
    const key = `${name}?${new URLSearchParams(params)}`;
    const hit = cache.get(key);
    if (hit && hit.expires > Date.now()) {
      cache.delete(key);
      cache.set(key, hit);
      return send(hit, hit.status === 200 ? routeTtl[name] : missTtl, 'hit');
    }
    let pending = inflight.get(key);
    if (!pending) {
      if (dbReads >= maxDbReadsInFlight) {
        return send({ ...reply(503, { error: 'Busy, retry shortly' }), retryAfter: 2 }, null, 'none');
      }
      dbReads++;
      pending = (async () => {
        try {
          await loadNationalTeams(read);
          const out = await route(name, url.searchParams, read);
          if (out.status === 200) store(key, out, routeTtl[name]);
          else if (out.status === 404) store(key, out, missTtl);
          return out;
        } catch {
          return reply(503, unavailable);
        } finally {
          dbReads--;
          inflight.delete(key);
        }
      })();
      inflight.set(key, pending);
    }
    const out = await pending;
    return send(out, out.status === 200 ? routeTtl[name] : out.status === 404 ? missTtl : null, 'miss');
  } catch {
    return send(reply(503, unavailable), null, 'none');
  }
}
