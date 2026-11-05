import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import * as matchDetail from '../../supabase/functions/_shared/match_detail.ts';
import * as calendarCache from '../../supabase/functions/_shared/calendar_cache.ts';

// /v1/news (#104): validation and the RPC contract. The app sends its own
// follows; the server only reads the central store.

async function api(answer) {
  const source = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  const calls = [];
  const ctx = { supabaseAdmin: { rpc: async (name, args) => {
    if (name === 'futbeat_read_national_teams') return { data: null, error: null };
    calls.push({ name, args });
    return answer(name, args);
  } } };
  const context = vm.createContext({
    Request, Response, URL, JSON, setTimeout, clearTimeout, Promise, console: { warn() {}, error() {}, log() {} },
    withSupabase: (_opts, handler) => (request) => handler(request, ctx),
    ...matchDetail, ...calendarCache,
  });
  vm.runInContext(stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''))
    .replace('export default {', 'globalThis.__api = {'), context);
  const call = async (query, path = 'news') => {
    const response = await context.__api.fetch(new Request(`https://api.test/functions/v1/futbeat-api/v1/${path}${query}`));
    return { status: response.status, body: await response.json(), cacheControl: response.headers.get('Cache-Control') };
  };
  return { call, calls };
}

const feed = { schemaVersion: 2, tab: 'for_you', stories: [] };

test('news: omitting tab preserves the v1 RPC and response', async () => {
  const legacy = { schemaVersion: 1, demo: false, news: [], transfers: [] };
  const { call, calls } = await api(() => ({ data: legacy, error: null }));
  const result = await call('?country=CR&subjects=team:fb_team_abc');
  assert.equal(result.status, 200);
  assert.equal(result.body.schemaVersion, 1);
  assert.equal(result.cacheControl, 'no-store');
  assert.deepEqual(JSON.parse(JSON.stringify(calls[0])), {
    name: 'futbeat_read_news_feed',
    args: { p_subjects: ['team:fb_team_abc'], p_country: 'CR' },
  });
});

test('legacy news and entity responses remove ungoverned excerpts', async () => {
  const legacy = { schemaVersion: 1, demo: false, news: [{
    id: 'newsdata:one', title: 'Titular', description: 'Texto ajeno',
    imageUrl: 'https://example.com/image.png', url: 'https://example.com/article',
    sourceName: 'Medio', publishedAt: '2026-10-19T09:00:00Z',
  }], transfers: [] };
  const { call } = await api(() => ({ data: legacy, error: null }));
  for (const [query, path] of [['', 'news'], ['?type=team&id=fb_team_test', 'entity']]) {
    const result = await call(query, path);
    assert.equal(result.status, 200);
    assert.equal(result.body.news[0].title, 'Titular');
    assert.equal(result.body.news[0].url, 'https://example.com/article');
    assert.equal(Object.hasOwn(result.body.news[0], 'description'), false);
    assert.equal(Object.hasOwn(result.body.news[0], 'imageUrl'), false);
  }
});

test('news: follows are parsed into the RPC; defaults are for_you/0/20', async () => {
  const { call, calls } = await api(() => ({ data: feed, error: null }));
  const r = await call('?tab=for_you&follows=team:fb_team_abc,player:fb_player_xyz');
  assert.equal(r.status, 200);
  assert.equal(r.cacheControl, 'no-store');
  assert.deepEqual(JSON.parse(JSON.stringify(calls[0])), { name: 'futbeat_read_news_feed', args: {
    p_tab: 'for_you', p_country: null, p_follows: [{ type: 'team', id: 'fb_team_abc' }, { type: 'player', id: 'fb_player_xyz' }],
    p_offset: 0, p_limit: 20 } });
});

test('news: invalid requests never reach the database', async () => {
  const { call, calls } = await api(() => ({ data: feed, error: null }));
  for (const query of ['?tab=all', '?tab=country', '?tab=country&country=cr', '?tab=latest&limit=0', '?tab=latest&limit=51', '?tab=latest&offset=-1',
    '?tab=latest&follows=match:fb_match_abc', '?tab=latest&follows=team:../../x', `?tab=latest&follows=${Array.from({ length: 51 }, (_, i) => `team:fb_team_${i}aa`).join(',')}`]) {
    assert.equal((await call(query)).status, 400, query);
  }
  assert.equal(calls.length, 0);
});

test('news: a store error or another contract is a 503', async () => {
  assert.equal((await (await api(() => ({ data: null, error: { message: 'x' } }))).call('?tab=latest')).status, 503);
  assert.equal((await (await api(() => ({ data: { schemaVersion: 1 }, error: null }))).call('?tab=latest')).status, 503);
  const ok = await (await api(() => ({ data: feed, error: null }))).call('?tab=country&country=CR');
  assert.equal(ok.status, 200);
});
