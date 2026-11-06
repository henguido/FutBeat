import test from 'node:test';
import assert from 'node:assert/strict';
import { SignJWT, exportJWK, generateKeyPair } from 'jose';
import { withSupabase } from '@supabase/server';
import * as access from '../../supabase/functions/_shared/api_access.ts';

// Package C' against the REAL @supabase/server 1.8.0 (the version index.ts
// pins) with a real ES256 JWKS, as the project uses. Proves (1) the defect:
// in dual mode the legacy HS256 project bearer of installed APKs is rejected
// as INVALID_JWT; (2) the fix: stripped first, it is served as `none`;
// (3) user tokens are still verified: nothing forged is downgraded or
// accepted.

const BASE = 'https://ref.supabase.co';
const ISS = `${BASE}/auth/v1`;
const { privateKey, publicKey } = await generateKeyPair('ES256');
const jwk = { ...(await exportJWK(publicKey)), kid: 'k1', alg: 'ES256', use: 'sig' };
Object.assign(process.env, {
  SUPABASE_URL: BASE,
  SUPABASE_JWKS: JSON.stringify({ keys: [jwk] }),
  SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: 'sb_publishable_test' }),
  SUPABASE_SECRET_KEYS: JSON.stringify({ default: 'sb_secret_test' }),
});

const now = Math.floor(Date.now() / 1000);
const es = (claims, opts = {}) => new SignJWT(claims)
  .setProtectedHeader({ alg: 'ES256', kid: 'k1', typ: 'JWT' })
  .setIssuer(opts.iss ?? ISS).setIssuedAt(now - 10).setExpirationTime(opts.exp ?? now + 3600)
  .sign(privateKey);
const hs = (claims) => new SignJWT(claims).setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
  .setIssuedAt(now - 10).setExpirationTime(now + 3600)
  .sign(new TextEncoder().encode('legacy-secret-0123456789abcdef0123'));

const GUEST = '11111111-1111-4111-8111-111111111111';
const MEMBER = '22222222-2222-4222-8222-222222222222';
const tokens = {
  legacy: await hs({ iss: 'supabase', ref: 'ref', role: 'anon' }),
  guest: await es({ sub: GUEST, role: 'authenticated', is_anonymous: true, aud: 'authenticated' }),
  member: await es({ sub: MEMBER, role: 'authenticated', is_anonymous: false, aud: 'authenticated' }),
  expired: await es({ sub: GUEST, role: 'authenticated', is_anonymous: true, aud: 'authenticated' }, { exp: now - 60 }),
  wrongIssuer: await es({ sub: GUEST, role: 'authenticated', aud: 'authenticated' }, { iss: 'https://evil.example/auth/v1' }),
  forgedHsUser: await hs({ sub: MEMBER, role: 'authenticated', is_anonymous: false }),
  forgedAnonWithSub: await hs({ sub: MEMBER, role: 'anon' }),
};

function server(auth, compat) {
  const handle = withSupabase({ auth, ...(auth === 'none' ? {} : { issuer: ISS }) }, async (_request, ctx) =>
    Response.json({ kind: access.requestIdentity(ctx).kind }));
  return (request) => handle(compat ? access.withoutLegacyProjectToken(request) : request);
}

async function call(fetch, bearer) {
  const headers = { apikey: 'sb_publishable_test' };
  if (bearer) headers.authorization = `Bearer ${bearer}`;
  const r = await fetch(new Request(`${BASE}/functions/v1/futbeat-api/v1/snapshot`, { headers }));
  const body = await r.json();
  return { status: r.status, kind: body.kind ?? null };
}

test('defect reproduced: dual without the fix rejects the legacy bearer of installed APKs', async () => {
  assert.equal((await call(server(['user', 'none'], false), tokens.legacy)).status, 401);
});

test('dual with the fix: old APKs, tokenless and publishable callers are served as none', async () => {
  const fetch = server(['user', 'none'], true);
  for (const bearer of [tokens.legacy, null, 'sb_publishable_test']) {
    assert.deepEqual(await call(fetch, bearer), { status: 200, kind: 'none' }, String(bearer).slice(0, 14));
  }
});

test('dual and user: guest and registered JWTs are verified and identified', async () => {
  for (const auth of [['user', 'none'], 'user']) {
    const fetch = server(auth, true);
    assert.deepEqual(await call(fetch, tokens.guest), { status: 200, kind: 'anonymous' });
    assert.deepEqual(await call(fetch, tokens.member), { status: 200, kind: 'registered' });
  }
});

test('nothing invalid is downgraded or accepted (expired, wrong issuer, forged HS256)', async () => {
  for (const auth of [['user', 'none'], 'user']) {
    const fetch = server(auth, true);
    for (const name of ['expired', 'wrongIssuer', 'forgedHsUser', 'forgedAnonWithSub']) {
      assert.equal((await call(fetch, tokens[name])).status, 401, `${name} ${JSON.stringify(auth)}`);
    }
  }
});

test('user mode: old APKs and tokenless callers get 401 (production target, later)', async () => {
  const fetch = server('user', true);
  assert.equal((await call(fetch, tokens.legacy)).status, 401);
  assert.equal((await call(fetch, null)).status, 401);
});

test('isLegacyProjectToken only matches role anon without a subject', () => {
  assert.equal(access.isLegacyProjectToken(tokens.legacy), true);
  for (const name of ['guest', 'member', 'forgedHsUser', 'forgedAnonWithSub']) {
    assert.equal(access.isLegacyProjectToken(tokens[name]), false, name);
  }
  for (const junk of ['', 'a.b', 'a.b.c', 'sb_publishable_test', `x.${Buffer.from('null').toString('base64url')}.y`]) {
    assert.equal(access.isLegacyProjectToken(junk), false, junk);
  }
});
