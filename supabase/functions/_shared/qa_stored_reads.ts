// QA227 candidate: dedicated read-only routes, disabled until operator review.
// Never reuse demand-aware routes or futbeat_read_calendar_range (it can queue
// calendar materialization). No provider, request_*, wake_* or write RPC here.
import { asRecord, lineupPlayerIds, normalizeMatchDetail, type PlayerMedia } from './match_detail.ts';

type Rpc = (name: string, args?: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }>;
export const qaStoredPrefix = '/futbeat-api/v1/qa-stored/';
const headers = { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-FutBeat-QA-Stored': 'v1' };
const reply = (status: number, data: unknown) => new Response(JSON.stringify(data), { status, headers });

export async function handleQaStoredRead(request: Request, rpc: Rpc, enabled = false): Promise<Response> {
  if (!enabled) return new Response(JSON.stringify({ error: 'QA stored reads disabled' }), {
    status: 404, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
  if (request.method !== 'GET') return reply(405, { error: 'Read only' });
  const url = new URL(request.url);
  const route = url.pathname.split(qaStoredPrefix)[1];
  if (!url.pathname.includes(qaStoredPrefix) || !['calendar', 'match-context', 'match-detail'].includes(route)) {
    return reply(403, { error: 'Route outside QA stored-read scope' });
  }
  try {
    if (route === 'calendar') {
      const date = url.searchParams.get('date') ?? '';
      const timezone = url.searchParams.get('timezone') ?? 'America/Costa_Rica';
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date) ||
          !Number.isFinite(Date.parse(date)) || new Date(date).toISOString().slice(0, 10) !== date ||
          timezone !== 'America/Costa_Rica') return reply(400, { error: 'Invalid QA calendar input' });
      const result = await rpc('futbeat_read_qa_stored_calendar', { p_local_date: date, p_timezone: timezone });
      if (result.error) return reply(503, { error: 'Stored calendar unavailable' });
      return result.data ? reply(200, result.data) : reply(404, { error: 'No stored calendar; no demand registered' });
    }
    const id = url.searchParams.get('id') ?? '';
    if (!/^fb_match_[A-Za-z0-9_-]{3,120}$/.test(id)) return reply(400, { error: 'Invalid canonical match' });
    if (route === 'match-context') {
      const result = await rpc('futbeat_read_match_context', { p_match_id: id });
      if (result.error) return reply(503, { error: 'Stored context unavailable' });
      return result.data ? reply(200, result.data) : reply(404, { error: 'No stored match' });
    }
    const result = await rpc('futbeat_read_match_detail', { p_match_id: id });
    if (result.error) return reply(503, { error: 'Stored detail unavailable' });
    if (!result.data) return reply(404, { error: 'No stored detail' });
    const ids = lineupPlayerIds(result.data);
    let media: PlayerMedia = {};
    if (ids.length) {
      const result = await rpc('futbeat_read_lineup_player_media', { p_provider: 'goal_api', p_external_ids: ids });
      if (result.error) return reply(503, { error: 'Stored media unavailable' });
      media = asRecord(result.data) as PlayerMedia;
    }
    const videos = await rpc('futbeat_read_match_videos', { p_match_id: id });
    if (videos.error) return reply(503, { error: 'Stored videos unavailable' });
    return reply(200, normalizeMatchDetail(result.data, videos.data, media));
  } catch {
    return reply(503, { error: 'Stored read failed; no demand registered' });
  }
}
