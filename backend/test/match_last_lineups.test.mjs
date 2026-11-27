// FB-05: GET /v1/match-last-lineups ("Última alineación confirmada"). Handler-level contract:
// one read-only RPC, no demand, no provider call; 400/404/503/405; never served when it claims to be a prediction.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import * as matchDetail from '../../supabase/functions/_shared/match_detail.ts';
import * as calendarCache from '../../supabase/functions/_shared/calendar_cache.ts';
import * as access from '../../supabase/functions/_shared/api_access.ts';

const ID = 'fb_match_0fdc6049-eab8-4081-80a1-446451154612';
const BODY = {
  schemaVersion: 1, matchId: ID, eligible: true, kind: 'LAST_CONFIRMED', isPrediction: false,
  home: { kind: 'LAST_CONFIRMED', teamId: 'fb_team_a', sourceMatch: { matchId: 'fb_match_src', startTime: '2026-11-20T20:00:00Z',
    competitionId: 'fb_competition_k', side: 'away', opponentTeamId: 'fb_team_c' },
  lineups: [{ team: 'home', type: 'starting_lineups', lineupPlayer: 'P', playerKey: 'k1' }] },
  away: null, teams: [{ id: 'fb_team_c', name: 'Club C' }], competitions: [{ id: 'fb_competition_k', name: 'Copa K' }],
};

async function api(env, answer) {
  const source = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  const calls = [];
  const withSupabase = (_config, handler) => (request) => handler(request, {
    authMode: 'none', jwtClaims: null,
    supabaseAdmin: { rpc: async (name, args) => {
      if (name === 'futbeat_read_national_teams') return { data: null, error: null };
      calls.push(name);
      if (name === 'futbeat_api_admit') return { data: { allowed: true }, error: null };
      return answer(name, args);
    } },
  });
  const context = vm.createContext({
    Request, Response, URL, JSON, TextEncoder, crypto, setTimeout, clearTimeout, Promise, Math, Number, Date,
    console: { warn() {}, error() {}, log() {} },
    Deno: { env: { get: (key) => env[key] } },
    withSupabase, fromSupabaseUrl: (url) => `${url}/auth/v1`,
    ...matchDetail, ...calendarCache, ...access,
  });
  vm.runInContext(stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''))
    .replace('export default {', 'globalThis.__api = {'), context);
  const call = async (query, method = 'GET') => {
    const r = await context.__api.fetch(new Request(`https://api.test/functions/v1/futbeat-api/v1/match-last-lineups${query}`,
      { method, headers: { 'x-forwarded-for': '203.0.113.7' } }));
    return { status: r.status, body: await r.json(), cache: r.headers.get('cache-control') };
  };
  return { call, calls };
}

const rpc = (data, error = null) => (name, args) => {
  assert.equal(name, 'futbeat_read_match_last_lineups');
  assert.deepEqual(JSON.parse(JSON.stringify(args)), { p_match_id: ID });
  return { data, error };
};

test('200: forwards the read model unchanged, cacheable, one read-only RPC', async () => {
  const { call, calls } = await api({}, rpc(BODY));
  const r = await call(`?id=${ID}`);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, BODY);
  assert.equal(r.cache, 'public, max-age=300, stale-while-revalidate=60', 'app persists only public + max-age=300');
  assert.deepEqual(calls, ['futbeat_read_match_last_lineups'], 'no demand, no detail/provider RPC');
});

test('200: not eligible (live/finished) is a normal answer', async () => {
  const { call } = await api({}, rpc({ schemaVersion: 1, matchId: ID, eligible: false }));
  const r = await call(`?id=${ID}`);
  assert.equal(r.status, 200);
  assert.equal(r.body.eligible, false);
});

test('400 invalid id never reaches the database', async () => {
  const { call, calls } = await api({}, rpc(BODY));
  assert.equal((await call('?id=not-a-match')).status, 400);
  assert.equal((await call('?id=fb_team_x')).status, 400);
  assert.equal((await call('')).status, 400);
  assert.deepEqual(calls, []);
});

test('400 is never cached (no-store, like 404/503)', async () => {
  const { call } = await api({}, rpc(BODY));
  for (const q of ['?id=not-a-match', '?id=fb_team_x', '', "?id=bad'id"]) {
    const r = await call(q);
    assert.equal(r.status, 400, q);
    assert.match(r.cache ?? '', /no-store/, `400 ${q} must be no-store`);
    assert.doesNotMatch(r.cache ?? '', /max-age=[1-9]/, `400 ${q} must not carry a max-age`);
  }
});

test('404 unknown match, 503 on RPC error, not cached', async () => {
  let r = await (await api({}, rpc(null))).call(`?id=${ID}`);
  assert.equal(r.status, 404); assert.match(r.cache, /no-store/);
  r = await (await api({}, rpc(null, { message: 'boom' }))).call(`?id=${ID}`);
  assert.equal(r.status, 503); assert.match(r.cache, /no-store/);
});

test('503 when the payload breaks the contract (schema or isPrediction)', async () => {
  for (const bad of [{ ...BODY, schemaVersion: 2 }, { ...BODY, isPrediction: true }, { ...BODY, isPrediction: undefined }]) {
    const r = await (await api({}, rpc(bad))).call(`?id=${ID}`);
    assert.equal(r.status, 503);
  }
});

test('405 for non-GET', async () => {
  const { call, calls } = await api({}, rpc(BODY));
  assert.equal((await call(`?id=${ID}`, 'POST')).status, 405);
  assert.deepEqual(calls, []);
});

test('gated mode: the route is known (admitted, not a 404)', async () => {
  const { call, calls } = await api({ FUTBEAT_API_ACCESS_MODE: 'dual', FUTBEAT_API_ADMISSION: 'on', FUTBEAT_RATE_SALT: 'x'.repeat(32) }, rpc(BODY));
  const r = await call(`?id=${ID}`);
  assert.equal(r.status, 200);
  assert.ok(calls.includes('futbeat_read_match_last_lineups'));
  assert.ok(access.isKnownRoute('/functions/v1/futbeat-api/v1/match-last-lineups'));
});
