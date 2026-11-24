import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import test from 'node:test';
import { createFederatedTokenSource, createPublisherFetch } from '../../supabase/functions/futbeat-billing/lib/billing-adapters.mjs';
import { createPremiumReleasePublisher } from '../../supabase/functions/futbeat-billing/lib/premium-play-api.mjs';

// PREMIUM-G2: keyless Google credential (Workload Identity Federation) against a simulated Google STS +
// IAM Credentials + Play. No network, no real key, no real token.

const AUD = '//iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/futbeat-billing/providers/edge-qa';
const SA = 'futbeat-billing-qa@futbeat.iam.gserviceaccount.com';
const ISS = 'https://futbeat.com/billing-wif/qa';
const SUB = 'futbeat-billing:qa';
const fromB64url = (t) => Buffer.from(t.replace(/-/g, '+').replace(/_/g, '/'), 'base64');

async function keypair(kid = 'k1') {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const priv = { ...(await crypto.subtle.exportKey('jwk', pair.privateKey)), kid };
  const pub = { ...(await crypto.subtle.exportKey('jwk', pair.publicKey)), kid };
  return { priv, pub };
}

// Google side: STS validates the assertion like a WIF provider with an UPLOADED JWKS and an attribute
// condition on issuer/audience/subject; IAM Credentials only lets that principal impersonate SA.
function fakeGoogle(clock, uploadedJwks) {
  const calls = { sts: 0, iam: 0, play: 0 };
  const g = { calls, stsDown: 0, iamStatus: 0, stsStatus: 0, lifetimeS: 3600, minted: [], lastClaims: null, lastScope: null, revoked: new Set() };
  g.fetch = async (url, init = {}) => {
    const u = new URL(url);
    if (u.host === 'sts.googleapis.com') {
      calls.sts++;
      if (g.stsDown > 0) { g.stsDown--; throw new Error('network'); }
      if (g.stsStatus) return Response.json({ error: 'invalid_grant' }, { status: g.stsStatus });
      const form = new URLSearchParams(init.body);
      assert.equal(form.get('grant_type'), 'urn:ietf:params:oauth:grant-type:token-exchange');
      assert.equal(form.get('subject_token_type'), 'urn:ietf:params:oauth:token-type:jwt');
      const [h, c, s] = form.get('subject_token').split('.');
      const header = JSON.parse(fromB64url(h)); const claims = JSON.parse(fromB64url(c));
      const jwk = uploadedJwks.find((k) => k.kid === header.kid);
      if (!jwk || header.alg !== 'ES256') return Response.json({ error: 'invalid_grant' }, { status: 400 });
      const key = await crypto.subtle.importKey('jwk', jwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
      const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, fromB64url(s), Buffer.from(`${h}.${c}`));
      const t = Math.floor(clock.now() / 1000);
      if (!ok || claims.iss !== ISS || claims.aud !== `https:${AUD}` || form.get('audience') !== AUD || claims.sub !== SUB
          || !(claims.exp > t) || claims.exp - claims.iat > 3600) {
        return Response.json({ error: 'invalid_grant' }, { status: 400 });
      }
      g.lastClaims = claims;
      return Response.json({ access_token: `fed-${calls.sts}`, token_type: 'Bearer', expires_in: 3600 });
    }
    if (u.host === 'iamcredentials.googleapis.com') {
      calls.iam++;
      assert.match(init.headers.Authorization, /^Bearer fed-\d+$/);
      if (g.iamStatus) return Response.json({ error: { status: 'PERMISSION_DENIED' } }, { status: g.iamStatus });
      assert.equal(decodeURIComponent(u.pathname.split('/').pop()), `${SA}:generateAccessToken`);
      const body = JSON.parse(init.body);
      g.lastScope = body.scope;
      const token = `ya29.fake-${calls.iam}`;
      g.minted.push(token);
      return Response.json({ accessToken: token, expireTime: new Date(clock.now() + g.lifetimeS * 1000).toISOString() });
    }
    if (u.host === 'androidpublisher.googleapis.com') {
      calls.play++;
      const bearer = init.headers.Authorization.slice(7);
      if (g.revoked.has(bearer) || !g.minted.includes(bearer)) return new Response('{}', { status: 401 });
      return Response.json({ subscriptionState: 'SUBSCRIPTION_STATE_ACTIVE', lineItems: [] });
    }
    return new Response('{}', { status: 404 });
  };
  return g;
}

async function setup(opts = {}) {
  let t = Date.parse('2026-11-18T16:00:00Z');
  const clock = { now: () => t, advance: (ms) => { t += ms; } };
  const { priv, pub } = await keypair();
  const google = fakeGoogle(clock, [pub]);
  const logs = [];
  const source = createFederatedTokenSource({
    signingJwk: JSON.stringify(priv), issuer: ISS, subject: SUB, audience: AUD, serviceAccountEmail: SA,
    fetchImpl: google.fetch, now: clock.now, log: (...a) => logs.push(a.join(' ')), ...opts,
  });
  return { clock, google, source, logs, priv, pub };
}

test('G2-1 mint: ES256 assertion (5 min, pinned iss/aud/sub) -> STS -> impersonated androidpublisher token, 1 h', async () => {
  const { google, source } = await setup();
  const token = await source();
  assert.equal(token, 'ya29.fake-1');
  assert.deepEqual(google.lastScope, ['https://www.googleapis.com/auth/androidpublisher'], 'least privilege: Publisher scope only');
  assert.equal(google.lastClaims.exp - google.lastClaims.iat, 300);
  assert.equal(source.status().expiresInS, 3600);
});

test('G2-2 cache and EARLY refresh: no call while > 10 min left; refresh before expiry; one refresh for 20 parallel callers', async () => {
  const { clock, google, source } = await setup();
  await source();
  clock.advance(49 * 60_000);
  assert.equal(await source(), 'ya29.fake-1', 'cached');
  assert.equal(google.calls.sts, 1);
  clock.advance(2 * 60_000);                       // 9 min left: inside the refresh window
  const all = await Promise.all(Array.from({ length: 20 }, () => source()));
  assert.ok(all.every((x) => x === 'ya29.fake-2'));
  assert.equal(google.calls.sts, 2, 'single-flight refresh');
  assert.equal(google.calls.iam, 2);
});

test('G2-3 refresh failure keeps serving the still-valid token; no token at all returns null, never throws', async () => {
  const { clock, google, source, logs } = await setup();
  await source();
  clock.advance(52 * 60_000);
  google.stsStatus = 503;
  assert.equal(await source(), 'ya29.fake-1', 'still valid for 8 min: served');
  assert.equal(source.status().failures, 1);
  clock.advance(8 * 60_000);                       // expired
  assert.equal(await source(), null, 'no valid token: null (caller maps it to unavailable)');
  assert.ok(logs.every((l) => !/ya29|fed-|eyJ/.test(l)), 'logs never contain a token or the assertion');
});

test('G2-4 backoff: repeated auth failures are spaced 5 s, 10 s, 20 s ... capped at 5 min; recovery resets it', async () => {
  const { clock, google, source } = await setup();
  google.iamStatus = 403;                          // e.g. Token Creator binding missing
  assert.equal(await source(), null);
  assert.match(source.status().lastError, /iamcredentials 403 \(PERMISSION_DENIED\)/);
  for (let i = 0; i < 5; i++) await source();
  assert.equal(google.calls.sts, 1, 'no hammering inside the backoff');
  clock.advance(5_000); await source();
  assert.equal(google.calls.sts, 2);
  clock.advance(5_000); await source();
  assert.equal(google.calls.sts, 2, 'second backoff is 10 s');
  for (let i = 0; i < 12; i++) { clock.advance(300_000); await source(); }
  assert.ok(source.status().backoffS <= 300, 'capped at 5 min');
  google.iamStatus = 0;
  clock.advance(300_000);
  assert.match(await source(), /^ya29\.fake-/);
  assert.equal(source.status().backoffS, 0);
  assert.equal(source.status().lastError, null);
});

test('G2-5 network outage at STS, then recovery without operator action', async () => {
  const { clock, google, source } = await setup();
  google.stsDown = 1;
  assert.equal(await source(), null);
  clock.advance(5_000);
  assert.equal(await source(), 'ya29.fake-1');
});

test('G2-6 identity pinning: a foreign key, wrong subject or wrong audience is refused by the provider', async () => {
  const { clock, google } = await setup();
  const other = await keypair('k1');               // same kid, different key
  const forged = createFederatedTokenSource({ signingJwk: other.priv, issuer: ISS, subject: SUB, audience: AUD, serviceAccountEmail: SA, fetchImpl: google.fetch, now: clock.now });
  assert.equal(await forged(), null);
  const { priv } = await setup();
  for (const bad of [{ subject: 'futbeat-billing:production' }, { issuer: 'https://futbeat.com/billing-wif/production' }]) {
    const s = createFederatedTokenSource({ signingJwk: priv, issuer: ISS, subject: SUB, audience: AUD, serviceAccountEmail: SA, fetchImpl: google.fetch, now: clock.now, ...bad });
    assert.equal(await s(), null);
  }
  assert.throws(() => createFederatedTokenSource({ signingJwk: priv, issuer: ISS, subject: SUB, audience: 'https://x', serviceAccountEmail: SA }), /audience/);
  assert.throws(() => createFederatedTokenSource({ signingJwk: { kty: 'RSA' }, issuer: ISS, subject: SUB, audience: AUD, serviceAccountEmail: SA }), Error);
});

test('G2-7 key rotation: a second uploaded JWK works; the old one keeps working until removed', async () => {
  let t = Date.parse('2026-11-18T16:00:00Z'); const clock = { now: () => t };
  const a = await keypair('k1'); const b = await keypair('k2');
  const jwks = [a.pub, b.pub];
  const google = fakeGoogle(clock, jwks);
  const mk = (priv) => createFederatedTokenSource({ signingJwk: priv, issuer: ISS, subject: SUB, audience: AUD, serviceAccountEmail: SA, fetchImpl: google.fetch, now: clock.now });
  assert.ok(await mk(a.priv)());
  assert.ok(await mk(b.priv)());
  jwks.splice(0, 1);                               // provider update: old key removed
  assert.equal(await mk(a.priv)(), null);
  assert.ok(await mk(b.priv)());
});

test('G2-8 Publisher 401 (token revoked or expired early): the token is re-minted once and the call retried', async () => {
  const { google, source } = await setup();
  const publisher = createPremiumReleasePublisher({
    environment: 'qa', accessToken: source, fetchImpl: createPublisherFetch({ accessToken: source, fetchImpl: google.fetch }),
    budget: { reserve: async () => true, pause: async () => {} },
  });
  await publisher.fetchPurchase('tok');
  assert.equal(google.calls.play, 1);
  google.revoked.add('ya29.fake-1');
  const p = await publisher.fetchPurchase('tok');
  assert.equal(p.subscriptionState, 'SUBSCRIPTION_STATE_ACTIVE');
  assert.equal(google.calls.iam, 2, 're-minted once');
  assert.equal(google.calls.play, 3, 'one retry');
  google.iamStatus = 403; google.revoked.add('ya29.fake-2');
  await assert.rejects(publisher.fetchPurchase('tok'), /failed \(401\)/, 'no valid credential: the call fails (unavailable), it never revokes');
});

test('G2-9 QA short lifetime (900 s): the refresh happens by itself at 5 min of age, repeatedly, without errors', async () => {
  const { clock, google, source } = await setup({ lifetimeSeconds: 900 });
  google.lifetimeS = 900;
  const seen = new Set();
  for (let minute = 0; minute <= 30; minute++) { seen.add(await source()); clock.advance(60_000); }
  assert.equal(seen.has(null), false, 'never without a token');
  assert.ok(seen.size >= 5, `>= 5 automatic renewals in 30 min (got ${seen.size})`);
  assert.equal(source.status().failures, 0);
});
