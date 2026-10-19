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
  const call = async (query) => {
    const response = await context.__api.fetch(new Request(`https://api.test/functions/v1/futbeat-api/v1/news${query}`));
    return { status: response.status, body: await response.json() };
  };
  return { call, calls };
}

const feed = { schemaVersion: 2, tab: 'for_you', stories: [] };

test('news: follows are parsed into the RPC; defaults are for_you/0/20', async () => {
  const { call, calls } = await api(() => ({ data: feed, error: null }));
  const r = await call('?follows=team:fb_team_abc,player:fb_player_xyz');
  assert.equal(r.status, 200);
  assert.deepEqual(JSON.parse(JSON.stringify(calls[0])), { name: 'futbeat_read_news_feed', args: {
    p_tab: 'for_you', p_country: null, p_follows: [{ type: 'team', id: 'fb_team_abc' }, { type: 'player', id: 'fb_player_xyz' }],
    p_offset: 0, p_limit: 20 } });
});

test('news: invalid requests never reach the database', async () => {
  const { call, calls } = await api(() => ({ data: feed, error: null }));
  for (const query of ['?tab=all', '?tab=country', '?country=cr', '?limit=0', '?limit=51', '?offset=-1',
    '?follows=match:fb_match_abc', '?follows=team:../../x', `?follows=${Array.from({ length: 51 }, (_, i) => `team:fb_team_${i}aa`).join(',')}`]) {
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
