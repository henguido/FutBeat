import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import * as matchDetail from '../../supabase/functions/_shared/match_detail.ts';
import * as calendarCache from '../../supabase/functions/_shared/calendar_cache.ts';
import * as access from '../../supabase/functions/_shared/api_access.ts';

// futbeat-api access contract (FutBeat 1.0). The @supabase/server wrapper is
// simulated: a test header carries the claims it would have verified, and
// an absent token in 'user' mode is answered 401 by the wrapper itself, as
// the library does. The database is a fake that records every RPC.

const GUEST = { sub: '11111111-1111-4111-8111-111111111111', role: 'authenticated', is_anonymous: true };
const MEMBER = { sub: '22222222-2222-4222-8222-222222222222', role: 'authenticated', is_anonymous: false };
const SERVICE = { sub: '33333333-3333-4333-8333-333333333333', role: 'service_role' };

async function api(env, answer = () => ({ data: null, error: null })) {
  const source = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  const calls = [];
  const configs = [];
  const withSupabase = (config, handler) => {
    configs.push(config);
    return (request) => {
      const raw = request.headers.get('x-test-claims');
      const claims = raw ? JSON.parse(raw) : null;
      const modes = [config.auth].flat();
      if (!claims && !modes.includes('none')) {
        return new Response(JSON.stringify({ code: 'INVALID_CREDENTIALS' }), { status: 401 });
      }
      const ctx = {
        authMode: claims && modes.includes('user') ? 'user' : 'none',
        jwtClaims: claims && modes.includes('user') ? claims : null,
        supabaseAdmin: { rpc: async (name, args) => {
          if (name === 'futbeat_read_national_teams') return { data: null, error: null };
          calls.push({ name, args: JSON.parse(JSON.stringify(args ?? {})) });
          return answer(name, args);
        } },
      };
      return handler(request, ctx);
    };
  };
  const context = vm.createContext({
    Request, Response, URL, JSON, TextEncoder, crypto, setTimeout, clearTimeout, Promise, Math, Number, Date,
    console: { warn() {}, error() {}, log() {} },
    Deno: { env: { get: (key) => env[key] } },
    withSupabase, fromSupabaseUrl: (url) => `${url}/auth/v1`,
    ...matchDetail, ...calendarCache, ...access,
  });
  vm.runInContext(stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''))
    .replace('export default {', 'globalThis.__api = {'), context);
  const call = async (path, claims = null, ip = '203.0.113.7') => {
    const headers = { 'x-forwarded-for': `${ip}, 10.0.0.1` };
    if (claims) headers['x-test-claims'] = JSON.stringify(claims);
    const response = await context.__api.fetch(new Request(`https://api.test/functions/v1/futbeat-api${path}`, { headers }));
    return { status: response.status, body: await response.json(), retry: response.headers.get('retry-after') };
  };
  return { call, calls, config: JSON.parse(JSON.stringify(configs[0])) };
}

const admitted = (name) => name === 'futbeat_api_admit' ? { data: { allowed: true }, error: null } : { data: null, error: null };
const SALT = 'salt-for-tests-0123456789';

test('unset environment: exactly the open API (no auth, no admission RPC)', async () => {
  const { call, calls, config } = await api({});
  assert.deepEqual(config, { auth: 'none' });
  await call('/v1/snapshot');
  assert.ok(!calls.some((c) => c.name === 'futbeat_api_admit'));
});

test('user mode: no session -> 401; service/anon keys are not identities', async () => {
  const { call, calls, config } = await api({ FUTBEAT_API_ACCESS_MODE: 'user', SUPABASE_URL: 'https://ref.supabase.co' }, admitted);
  assert.deepEqual(config, { auth: 'user', issuer: 'https://ref.supabase.co/auth/v1' });
  assert.equal((await call('/v1/snapshot')).status, 401);
  const service = await call('/v1/snapshot', SERVICE);
  assert.equal(service.status, 401);
  assert.equal(service.body.code, 'SESSION_REQUIRED');
  assert.equal(calls.length, 0, 'nothing reached the database');
});

test('user mode: guest and registered users are served and admitted under their own subject', async () => {
  const { call, calls } = await api({ FUTBEAT_API_ACCESS_MODE: 'user', FUTBEAT_API_ADMISSION: 'on', FUTBEAT_RATE_SALT: SALT }, admitted);
  await call('/v1/snapshot', GUEST);
  await call('/v1/search?q=ab', MEMBER);
  const admits = calls.filter((c) => c.name === 'futbeat_api_admit').map((c) => c.args);
  assert.equal(admits[0].p_subject, `anon:${GUEST.sub}`);
  assert.equal(admits[0].p_kind, 'anonymous');
  assert.equal(admits[0].p_cost, 1);
  assert.equal(admits[1].p_subject, `user:${MEMBER.sub}`);
  assert.equal(admits[1].p_kind, 'registered');
  assert.equal(admits[1].p_cost, 2, 'search weighs more');
  // Same IP, same salted hash; never the raw IP.
  assert.match(admits[0].p_ip_hash, /^[0-9a-f]{32}$/);
  assert.equal(admits[0].p_ip_hash, admits[1].p_ip_hash);
  assert.ok(!JSON.stringify(calls).includes('203.0.113.7'));
});

test('a denied admission is a 429 with Retry-After and the route is not read', async () => {
  const { call, calls } = await api({ FUTBEAT_API_ACCESS_MODE: 'user', FUTBEAT_API_ADMISSION: 'on', FUTBEAT_RATE_SALT: SALT },
    (name) => name === 'futbeat_api_admit'
      ? { data: { allowed: false, reason: 'identity_minute', retryAfterSeconds: 17 }, error: null }
      : { data: null, error: null });
  const r = await call('/v1/snapshot', GUEST);
  assert.equal(r.status, 429);
  assert.equal(r.retry, '17');
  assert.deepEqual(r.body, { error: 'Demasiadas solicitudes', code: 'RATE_LIMITED', reason: 'identity_minute' });
  assert.deepEqual(calls.map((c) => c.name), ['futbeat_api_admit']);
});

test('dual mode: tokenless installed apps keep working, counted by IP hash', async () => {
  const { call, calls, config } = await api({ FUTBEAT_API_ACCESS_MODE: 'dual', FUTBEAT_API_ADMISSION: 'on', FUTBEAT_RATE_SALT: SALT }, admitted);
  assert.deepEqual(config.auth, ['user', 'none']);
  await call('/v1/snapshot');
  await call('/v1/snapshot', GUEST);
  const admits = calls.filter((c) => c.name === 'futbeat_api_admit').map((c) => [c.args.p_kind, c.args.p_subject]);
  assert.deepEqual(admits, [['none', null], ['anonymous', `anon:${GUEST.sub}`]]);
});

test('unknown paths never reach the database; a typo in the mode never opens the API', async () => {
  const { call, calls, config } = await api({ FUTBEAT_API_ACCESS_MODE: 'usr', FUTBEAT_API_ADMISSION: 'on' }, admitted);
  assert.equal(config.auth, 'user');
  assert.equal((await call('/v1/admin', GUEST)).status, 404);
  assert.equal(calls.length, 0);
});

test('without a salt no IP hash is sent; admission outage falls back to a per-isolate limit', async () => {
  const { call, calls } = await api({ FUTBEAT_API_ACCESS_MODE: 'user', FUTBEAT_API_ADMISSION: 'on' },
    (name) => name === 'futbeat_api_admit' ? { data: null, error: { message: 'down' } } : { data: null, error: null });
  const statuses = [];
  for (let i = 0; i < 125; i++) statuses.push((await call('/v1/snapshot', GUEST)).status);
  assert.equal(calls.find((c) => c.name === 'futbeat_api_admit').args.p_ip_hash, null);
  assert.equal(statuses.filter((s) => s === 429).length, 5, 'the 121st request in the minute is limited');
});

test('helpers: identity, mode parsing, IP extraction, isolate limiter', async () => {
  assert.deepEqual(access.requestIdentity({ authMode: 'none', jwtClaims: GUEST }), { kind: 'none', subject: null });
  assert.deepEqual(access.requestIdentity({ authMode: 'user', jwtClaims: { ...GUEST, sub: 'nope' } }), { kind: 'none', subject: null });
  assert.equal(access.accessMode(undefined), 'open');
  assert.equal(access.accessMode(' DUAL '), 'dual');
  assert.equal(access.accessMode('anything-else'), 'user');
  assert.equal(access.clientIp(new Request('https://x', { headers: { 'x-forwarded-for': 'not an ip' } })), null);
  assert.equal(await access.ipHash('203.0.113.7', 'short'), null);
  const limiter = new access.IsolateLimiter(2, 2);
  assert.deepEqual([limiter.take('a', 1, 0), limiter.take('a', 1, 0), limiter.take('a', 1, 0), limiter.take('a', 1, 60000)], [true, true, false, true]);
  limiter.take('b', 1, 60000); limiter.take('c', 1, 120000);
  assert.ok(limiter.take('c', 1, 120000));
});

test('legacy project bearer (old APKs): stripped before auth in dual/user, untouched in open', async () => {
  const legacy = ['eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9',
    Buffer.from(JSON.stringify({ iss: 'supabase', ref: 'ref', role: 'anon', iat: 1, exp: 4102444800 })).toString('base64url'),
    'sig'].join('.');
  const source = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  for (const [env, stripped] of [[{}, false], [{ FUTBEAT_API_ACCESS_MODE: 'dual' }, true], [{ FUTBEAT_API_ACCESS_MODE: 'user' }, true]]) {
    const seen = [];
    const context = vm.createContext({
      Request, Response, URL, JSON, TextEncoder, crypto, setTimeout, clearTimeout, Promise, Math, Number, Date, Headers, atob,
      console: { warn() {}, error() {}, log() {} },
      Deno: { env: { get: (key) => env[key] } },
      withSupabase: () => (request) => { seen.push(request.headers.get('authorization')); return new Response('{}'); },
      fromSupabaseUrl: (url) => `${url}/auth/v1`,
      ...matchDetail, ...calendarCache, ...access,
    });
    vm.runInContext(stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''))
      .replace('export default {', 'globalThis.__api = {'), context);
    const at = (authorization) => context.__api.fetch(new Request(
      'https://api.test/functions/v1/futbeat-api/v1/snapshot', { headers: { authorization } }));
    await at(`Bearer ${legacy}`);
    await at('Bearer eyJ.user.token');
    assert.deepEqual(seen, [stripped ? null : `Bearer ${legacy}`, 'Bearer eyJ.user.token'], JSON.stringify(env));
  }
});
