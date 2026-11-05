import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import * as matchDetail from '../../supabase/functions/_shared/match_detail.ts';
import * as calendarCache from '../../supabase/functions/_shared/calendar_cache.ts';
import * as matchSummary from '../../supabase/functions/_shared/match_summary.ts';
import * as access from '../../supabase/functions/_shared/api_access.ts';

// FutBeat 1.0 acceptance, end to end in one process: the real futbeat-api
// (user mode + admission) over the real migrated schema (PGlite, passive
// default). Several clients browse at the same time; each is a different
// Supabase user (two guests, one registered). Verified: everyone is served,
// no provider demand or ledger row appears, limits are per user and global,
// and favourites stay separate. The JWT verification itself is
// @supabase/server's; here its verified claims are injected.

const A = { sub: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', role: 'authenticated', is_anonymous: true };
const B = { sub: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', role: 'authenticated', is_anonymous: true };
const C = { sub: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', role: 'authenticated', is_anonymous: false };
const DEMAND_TABLES = ['match_detail_requests', 'calendar_date_requests', 'player_search_demands', 'standings_demands',
  'team_squad_demands', 'team_match_demands', 'results_date_user_demand'];

async function setup() {
  const db = await openDatabase(undefined, { navigationDemands: null });
  await db.exec(`create schema if not exists auth;
    create or replace function auth.jwt() returns jsonb language sql stable as
      $$ select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
    create or replace function auth.uid() returns uuid language sql stable as
      $$ select nullif(auth.jwt()->>'sub','')::uuid $$;`);
  await db.query(`insert into futbeat_private.entities values
    ('fb_comp_mc','competition','{"id":"fb_comp_mc","name":"Liga Multi","season":"2026","country":"Costa Rica"}'),
    ('fb_team_mc1','team','{"id":"fb_team_mc1","name":"Club Multi","competitionId":"fb_comp_mc"}'),
    ('fb_team_mc2','team','{"id":"fb_team_mc2","name":"Rival Multi","competitionId":"fb_comp_mc"}')`);
  await db.query(`insert into futbeat_private.entities values('fb_match_mc','match',$1)`, [JSON.stringify({
    id: 'fb_match_mc', competitionId: 'fb_comp_mc', homeTeamId: 'fb_team_mc1', awayTeamId: 'fb_team_mc2',
    startTime: new Date(Date.now() - 26 * 3600e3).toISOString(), status: 'VERIFIED', score: { home: 2, away: 1 },
    events: [], statistics: [] })]);
  for (const [kind, ext, id] of [['team', 'mc-1', 'fb_team_mc1'], ['team', 'mc-2', 'fb_team_mc2'], ['match', 'mc-m', 'fb_match_mc'], ['competition', 'mc-c', 'fb_comp_mc']]) {
    await db.query("insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) values('goal_api',$1,$2,$3)", [kind, ext, id]);
  }
  return db;
}

async function api(db) {
  const source = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  const env = { FUTBEAT_API_ACCESS_MODE: 'user', FUTBEAT_API_ADMISSION: 'on', FUTBEAT_RATE_SALT: 'multi-client-salt-0123', SUPABASE_URL: 'https://staging.example' };
  const rpc = async (name, args = {}) => {
    try {
      const keys = Object.keys(args);
      const sql = `select public.${name}(${keys.map((k, i) => `${k}=>$${i + 1}`).join(',')}) v`;
      const values = keys.map((k) => (args[k] !== null && typeof args[k] === 'object' ? JSON.stringify(args[k]) : args[k]));
      return { data: (await db.query(sql, values)).rows[0]?.v ?? null, error: null };
    } catch (error) { return { data: null, error: { message: error.message } }; }
  };
  const withSupabase = (config, handler) => (request) => {
    const raw = request.headers.get('x-test-claims');
    if (!raw) return new Response('{"code":"INVALID_CREDENTIALS"}', { status: 401 });
    return handler(request, { authMode: 'user', jwtClaims: JSON.parse(raw), supabaseAdmin: { rpc } });
  };
  const context = vm.createContext({
    Request, Response, URL, JSON, TextEncoder, crypto, Intl, BigInt, setTimeout, clearTimeout, Promise, Math, Number, Date,
    console: { warn() {}, error() {}, log() {} }, Deno: { env: { get: (k) => env[k] } },
    withSupabase, fromSupabaseUrl: (u) => `${u}/auth/v1`, ...matchDetail, ...calendarCache, ...matchSummary, ...access,
  });
  vm.runInContext(stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''))
    .replace('export default {', 'globalThis.__api = {'), context);
  return async (claims, path, ip) => {
    const response = await context.__api.fetch(new Request(`https://api.test/functions/v1/futbeat-api${path}`, {
      headers: { 'x-test-claims': JSON.stringify(claims), 'x-forwarded-for': ip } }));
    return response.status;
  };
}

const ROUTES = [
  '/v1/explore', '/v1/match-detail?id=fb_match_mc', '/v1/match-context?id=fb_match_mc',
  '/v1/match-preview?id=fb_match_mc', '/v1/entity?type=team&id=fb_team_mc1',
  '/v1/team-matches?id=fb_team_mc1&bucket=results', '/v1/search?q=jugador%20desconocido',
  '/v1/match-summary?id=fb_match_mc',
];

const demandRows = async (db) => {
  let total = 0;
  for (const table of DEMAND_TABLES) {
    if ((await db.query('select to_regclass($1) t', [`futbeat_private.${table}`])).rows[0].t) {
      total += (await db.query(`select count(*)::int n from futbeat_private.${table}`)).rows[0].n;
    }
  }
  return total;
};

test('three users browse concurrently: served, passive, counted per user', async () => {
  const db = await setup();
  try {
    const call = await api(db);
    const clients = [[A, '198.51.100.1'], [B, '198.51.100.2'], [C, '198.51.100.3']];
    const statuses = await Promise.all(clients.flatMap(([claims, ip]) =>
      Array.from({ length: 2 }, () => ROUTES.map((route) => call(claims, route, ip))).flat()));
    assert.equal(statuses.length, 48);
    assert.ok(statuses.every((s) => s < 500 && s !== 401 && s !== 429), JSON.stringify(statuses));
    assert.equal(await demandRows(db), 0, 'browsing created no provider demand');
    assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 0);
    const counters = Object.fromEntries((await db.query(
      "select bucket,hits from futbeat_private.api_rate_counters where bucket like 'id:%'")).rows.map((r) => [r.bucket, r.hits]));
    // 8 routes x 2 rounds; search costs 2.
    assert.deepEqual(counters, { [`id:anon:${A.sub}`]: 18, [`id:anon:${B.sub}`]: 18, [`id:user:${C.sub}`]: 18 });
  } finally { await db.close(); }
});

test('one guest flooding is limited; the others are not', async () => {
  const db = await setup();
  try {
    await db.query('update futbeat_private.api_access_policy set anonymous_per_minute=10');
    const call = await api(db);
    const [flood, calm] = await Promise.all([
      Promise.all(Array.from({ length: 20 }, () => call(A, '/v1/snapshot', '198.51.100.1'))),
      Promise.all(Array.from({ length: 5 }, () => call(B, '/v1/snapshot', '198.51.100.2'))),
    ]);
    assert.equal(flood.filter((s) => s === 429).length, 10);
    assert.ok(calm.every((s) => s !== 429));
  } finally { await db.close(); }
});

test('global limit protects the service from many users at once', async () => {
  const db = await setup();
  try {
    await db.query('update futbeat_private.api_access_policy set global_per_minute=12');
    const call = await api(db);
    const users = Array.from({ length: 6 }, (_, i) => ({ ...A, sub: `dddddddd-dddd-4ddd-8ddd-00000000000${i}` }));
    const statuses = await Promise.all(users.flatMap((u, i) => Array.from({ length: 3 }, () => call(u, '/v1/snapshot', `198.51.100.${10 + i}`))));
    assert.equal(statuses.filter((s) => s === 429).length, 6);
  } finally { await db.close(); }
});

test('favourites of two guests on two phones stay separate', async () => {
  const db = await setup();
  try {
    const as = (claims) => db.query("select set_config('request.jwt.claims',$1,false)", [JSON.stringify(claims)]);
    await as(A);
    await db.query('select public.futbeat_sync_push_follows($1)', [JSON.stringify([{ type: 'team', id: 'fb_team_mc1' }])]);
    await as(B);
    await db.query('select public.futbeat_sync_push_follows($1)', [JSON.stringify([{ type: 'team', id: 'fb_team_mc2' }, { type: 'match', id: 'fb_match_mc' }])]);
    const rows = (await db.query('select user_id::text,entity_id from futbeat_private.push_follows order by 1,2')).rows;
    assert.deepEqual(rows, [
      { user_id: A.sub, entity_id: 'fb_team_mc1' },
      { user_id: B.sub, entity_id: 'fb_match_mc' },
      { user_id: B.sub, entity_id: 'fb_team_mc2' },
    ]);
  } finally { await db.close(); }
});
