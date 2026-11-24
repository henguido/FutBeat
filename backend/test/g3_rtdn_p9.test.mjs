import assert from 'node:assert/strict';
import { createHash, createSign, generateKeyPairSync, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { PGlite } from '@electric-sql/pglite';
import { createBillingApp } from '../../supabase/functions/futbeat-billing/lib/billing-app.mjs';
import { createPushVerifier, createSupabaseAuthenticator } from '../../supabase/functions/futbeat-billing/lib/billing-adapters.mjs';
import { createPremiumReleasePublisher, createPublisherBudget } from '../../supabase/functions/futbeat-billing/lib/premium-play-api.mjs';
import { createPremiumReleaseService } from '../../supabase/functions/futbeat-billing/lib/premium-release-service.mjs';
import { createPremiumTokenVault } from '../../supabase/functions/futbeat-billing/lib/premium-token-vault.mjs';

// P-9 (RTDN) acceptance on the UNCHANGED G3 code: real Pub/Sub push envelope, the REAL OIDC push verifier
// (createPushVerifier, Google certs simulated), the production HTTP app, Postgres (PGlite) and a simulated
// Play. The notification is only a wake-up: every outcome comes from Play (subscriptionsv2), never from
// notificationType. No network, no real purchase.

const ORIGIN = 'https://project.example';
const PROD_URL = 'https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-billing/billing/v1/rtdn';
const QA_URL = 'https://wctxcnqcblgewaznxrqh.supabase.co/functions/v1/futbeat-billing/billing/v1/rtdn';
const PUSH_SA = 'futbeat-rtdn-push@futbeat.iam.gserviceaccount.com';
const PUSH_SA_QA = 'futbeat-rtdn-push-qa@futbeat.iam.gserviceaccount.com';
const HOUR = 3_600_000;
const tag = (account) => createHash('sha256').update(`futbeat:account:${account}`).digest('hex');
const T = { RECOVERED: 1, RENEWED: 2, CANCELED: 3, PURCHASED: 4, ON_HOLD: 5, IN_GRACE: 6, RESTARTED: 7, REVOKED: 12, EXPIRED: 13 };

// ------------------------------------------------------------ Google OIDC signer (simulated certs endpoint)
const google = (() => {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'g1', alg: 'RS256', use: 'sig' };
  let certsUp = true; let certFetches = 0;
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  return {
    sign(claims = {}, { key = privateKey, kid = 'g1', alg = 'RS256' } = {}) {
      const now = Math.floor(Date.now() / 1000);
      const body = { iss: 'https://accounts.google.com', aud: PROD_URL, email: PUSH_SA, email_verified: true,
        sub: '1', iat: now, exp: now + 3600, ...claims };
      const h = enc({ alg, kid, typ: 'JWT' }); const c = enc(body);
      const s = createSign('RSA-SHA256'); s.update(`${h}.${c}`);
      return `${h}.${c}.${s.sign(key).toString('base64url')}`;
    },
    certs: async (url) => {
      certFetches++;
      assert.equal(url, 'https://www.googleapis.com/oauth2/v3/certs');
      return certsUp ? Response.json({ keys: [jwk] }) : new Response('{}', { status: 503 });
    },
    down(v) { certsUp = !v; }, get fetches() { return certFetches; },
  };
})();

// ------------------------------------------------------------ simulated Play (subscriptionsv2 + acknowledge)
function fakePlay(clock) {
  const subs = new Map(); const calls = { get: 0 }; let down = false;
  return {
    subs, calls, outage(v) { down = v; },
    add(token, { account, state = 'SUBSCRIPTION_STATE_ACTIVE', hours = 720, test = true } = {}) {
      subs.set(token, {
        kind: 'androidpublisher#subscriptionPurchaseV2', subscriptionState: state,
        acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING',
        externalAccountIdentifiers: { obfuscatedExternalAccountId: tag(account) },
        lineItems: [{ productId: 'futbeat_premium', offerDetails: { basePlanId: 'monthly' }, expiryTime: new Date(clock.now() + hours * HOUR).toISOString() }],
        ...(test ? { testPurchase: {} } : {}),
      });
    },
    set(token, patch) { Object.assign(subs.get(token), patch); },
    expiry(token, hours) { subs.get(token).lineItems[0].expiryTime = new Date(clock.now() + hours * HOUR).toISOString(); },
    fetch: async (url, init = {}) => {
      if (down) throw new Error('network');
      const u = new URL(url);
      assert.ok(u.pathname.includes('/applications/com.futbeat.futbeat/'), 'official package only');
      const get = /\/purchases\/subscriptionsv2\/tokens\/([^/:]+)$/.exec(u.pathname);
      const ack = /\/tokens\/([^/:]+):acknowledge$/.exec(u.pathname);
      if (get) { calls.get++; const s = subs.get(decodeURIComponent(get[1])); return s ? Response.json(structuredClone(s)) : new Response('{}', { status: 404 }); }
      if (ack && init.method === 'POST') { subs.get(decodeURIComponent(ack[1])).acknowledgementState = 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED'; return new Response('{}'); }
      return new Response('{}', { status: 400 });
    },
  };
}

async function world({ environment = 'production', intake = false, audience = PROD_URL, pushSa = PUSH_SA, rtdnOn = true } = {}) {
  const db = new PGlite();
  await db.exec(await readFile(new URL('./fixtures/g3-premium-production-ledger.sql', import.meta.url), 'utf8'));
  await db.exec(await readFile(new URL('./fixtures/g3-premium-production-additions.sql', import.meta.url), 'utf8'));
  let t = Date.parse('2026-11-19T12:00:00Z');
  const clock = { now: () => t, advance: (ms) => { t += ms; } };
  const play = fakePlay(clock);
  const keys = new Map([['p1', createPremiumTokenVault({ key: Buffer.alloc(32, 9), authOrigin: ORIGIN, packageName: 'com.futbeat.futbeat' })]]);
  const service = createPremiumReleaseService({
    db, issuer: `${ORIGIN}/auth/v1`, keys, currentKey: 'p1', environment, now: clock.now,
    publisher: createPremiumReleasePublisher({ environment, accessToken: async () => 'access', fetchImpl: play.fetch, budget: createPublisherBudget(db, 600) }),
  });
  const users = new Map();
  const state = { intake };
  const app = createBillingApp({
    service, intakeEnabled: () => state.intake, cronToken: 'cron-secret-0123456789abcdef0123456789',
    authenticate: createSupabaseAuthenticator({ supabaseUrl: ORIGIN, anonKey: 'anon', fetchImpl: async (url, init) => {
      const u = users.get(init.headers.Authorization.slice(7));
      return u ? Response.json({ id: u.id, aud: 'authenticated', is_anonymous: false }) : new Response('{}', { status: 401 });
    } }),
    // exactly what index.ts builds when FUTBEAT_PREMIUM_RTDN=on
    rtdn: rtdnOn ? { enabled: true, verifyPush: createPushVerifier({ audience, serviceAccountEmail: pushSa, fetchImpl: google.certs }) } : { enabled: false },
    allowRequest: async () => true,
  });
  const call = async (method, path, { bearer, body, headers = {}, raw } = {}) => {
    const res = await app(new Request(`https://edge.example/functions/v1/futbeat-billing${path}`, {
      method, headers: { ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}), 'content-type': 'application/json', ...headers },
      ...(raw !== undefined ? { body: raw } : body ? { body: JSON.stringify(body) } : {}),
    }));
    return { status: res.status, body: await res.json() };
  };
  const user = () => { const id = randomUUID(); users.set(`b-${id}`, { id }); return { id, bearer: `b-${id}` }; };
  const ent = async (u) => (await call('GET', '/billing/v1/entitlement', { bearer: u.bearer })).body;
  // Pub/Sub push (wrapped format, payload unwrapping OFF), as delivered by the subscription
  const push = (note, { jwt = google.sign({ aud: audience, email: pushSa }), messageId = randomUUID(), data } = {}) =>
    call('POST', '/billing/v1/rtdn', {
      headers: { authorization: `Bearer ${jwt}` },
      body: { message: { data: data ?? Buffer.from(JSON.stringify(note)).toString('base64'), messageId, publishTime: new Date().toISOString(), attributes: {} },
        subscription: 'projects/futbeat/subscriptions/play-rtdn-prod-push' },
    });
  const sub = (token, type) => ({ version: '1.0', packageName: 'com.futbeat.futbeat', eventTimeMillis: String(Date.now()),
    subscriptionNotification: { version: '1.0', notificationType: type, purchaseToken: token } });
  const cron = () => call('POST', '/billing/v1/cron', { headers: { 'x-futbeat-billing-cron': 'cron-secret-0123456789abcdef0123456789' } });
  const dueNow = () => db.query("update billing_private.purchases set next_check_at=now()-interval '1 second' where not terminal");
  const kinds = async () => (await db.query('select kind from billing_private.events order by id')).rows.map((r) => r.kind);
  // seed a purchase the way production would hold it (verified while intake was on)
  const seed = async (u, token, opts = {}) => {
    play.add(token, { account: u.id, test: environment === 'qa', ...opts });
    state.intake = true;
    const r = await call('POST', '/billing/v1/verify', { bearer: u.bearer, body: { token } });
    state.intake = intake;
    assert.equal(r.body.status, 'active');
  };
  return { db, clock, play, app, call, user, ent, push, sub, cron, dueNow, kinds, seed, state, close: () => db.close() };
}

// ================================================================== 1. origin / authentication
test('P9-1 auth: only a Google-signed OIDC token for the pinned push SA and audience is accepted', async (t) => {
  const w = await world(); t.after(w.close);
  const n = w.sub('tok', T.RENEWED);
  assert.equal((await w.push(n)).status, 200, 'genuine push');
  const bad = {
    'missing header': '',
    'QA audience replayed to production': google.sign({ aud: QA_URL }),
    'QA push SA': google.sign({ email: PUSH_SA_QA }),
    'other SA': google.sign({ email: 'attacker@evil.iam.gserviceaccount.com' }),
    'email not verified': google.sign({ email_verified: false }),
    'expired': google.sign({ exp: Math.floor(Date.now() / 1000) - 5 }),
    'issued in the future': google.sign({ iat: Math.floor(Date.now() / 1000) + 3600 }),
    'wrong issuer': google.sign({ iss: 'https://evil.example' }),
    'unknown kid': google.sign({}, { kid: 'nope' }),
    'other RSA key': google.sign({}, { key: generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey }),
    'alg none header': (() => { const [, c] = google.sign().split('.'); return `${Buffer.from('{"alg":"none","kid":"g1"}').toString('base64url')}.${c}.x`; })(),
    'cron token in place of OIDC': 'cron-secret-0123456789abcdef0123456789',
  };
  for (const [why, jwt] of Object.entries(bad)) {
    const r = await w.push(n, { jwt });
    assert.equal(r.status, 401, why);
    assert.equal(r.body.status, 'unauthorized', why);
  }
  assert.equal(w.play.calls.get, 0, 'nothing reaches Play without authentication (tok unknown anyway)');
});

test('P9-2 auth: Google certs unavailable -> 401 (Pub/Sub retries), certs cached for 1 h', async (t) => {
  const w = await world(); t.after(w.close);
  const before = google.fetches;
  google.down(true);
  try {
    assert.equal((await w.push(w.sub('x', T.RENEWED))).status, 401);
  } finally { google.down(false); }
  assert.equal((await w.push(w.sub('x', T.RENEWED))).status, 200);
  assert.equal((await w.push(w.sub('x', T.RENEWED))).status, 200);
  assert.equal(google.fetches - before, 2, 'one failed fetch + one cached fetch for many pushes');
});

test('P9-3 RTDN off (current production state): the route does not exist', async (t) => {
  const w = await world({ rtdnOn: false }); t.after(w.close);
  assert.equal((await w.push(w.sub('tok', T.REVOKED))).status, 404);
});

// ================================================================== 2. payload handling (always acked, never trusted)
test('P9-4 payloads: test notification, other package, one-time product, malformed and oversized are acked and ignored', async (t) => {
  const w = await world(); t.after(w.close);
  const cases = {
    'Play Console test notification': { version: '1.0', packageName: 'com.futbeat.futbeat', testNotification: { version: '1.0' } },
    'other package': { packageName: 'com.evil.app', subscriptionNotification: { notificationType: 12, purchaseToken: 'tok' } },
    'one-time product': { packageName: 'com.futbeat.futbeat', oneTimeProductNotification: { notificationType: 1, purchaseToken: 'tok', sku: 'x' } },
    'token too long': { packageName: 'com.futbeat.futbeat', subscriptionNotification: { notificationType: 2, purchaseToken: 'a'.repeat(4097) } },
    'token not a string': { packageName: 'com.futbeat.futbeat', subscriptionNotification: { notificationType: 2, purchaseToken: 42 } },
  };
  for (const [why, note] of Object.entries(cases)) {
    const r = await w.push(note);
    assert.equal(r.status, 200, why); assert.equal(r.body.status, 'ignored', why);
  }
  for (const data of ['%%%not-base64', Buffer.from('not json').toString('base64'), '']) {
    const r = await w.push(null, { data });
    assert.equal(r.status, 200); assert.equal(r.body.status, 'ignored');
  }
  const big = await w.call('POST', '/billing/v1/rtdn', { headers: { authorization: `Bearer ${google.sign()}` }, raw: JSON.stringify({ message: { data: 'A'.repeat(70000) } }) });
  assert.equal(big.status, 200); assert.equal(big.body.status, 'ignored', 'oversized body acked, not processed');
  const q = await w.call('POST', '/billing/v1/rtdn?x=1', { headers: { authorization: `Bearer ${google.sign()}` }, body: {} });
  assert.equal(q.status, 400, 'push endpoint must be configured without a query string');
  assert.equal(w.play.calls.get, 0);
  assert.deepEqual(await w.kinds(), []);
});

test('P9-5 unknown tokens grant nothing (intake off): license-tester or foreign purchases are ignored', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user();
  w.play.add('tester-tok', { account: u.id, test: true });   // license tester buys in production
  for (const type of [T.PURCHASED, T.RENEWED, T.RECOVERED]) {
    const r = await w.push(w.sub('tester-tok', type));
    assert.equal(r.status, 200); assert.equal(r.body.status, 'ignored');
  }
  assert.equal(w.play.calls.get, 0, 'unknown token: Play not even asked');
  assert.equal((await w.db.query('select count(*)::int n from billing_private.purchases')).rows[0].n, 0, 'RTDN never creates a purchase');
  assert.equal((await w.ent(u)).status, 'inactive');
});

// ================================================================== 3. lifecycle: Play is authoritative
test('P9-6 renewal: RENEWED rechecks Play and extends the paid period', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user(); await w.seed(u, 'tok', { test: false, hours: 1 });
  const first = (await w.ent(u)).paidUntil ?? (await w.ent(u)).expiresAt;
  w.play.expiry('tok', 721);
  const r = await w.push(w.sub('tok', T.RENEWED));
  assert.equal(r.body.status, 'rechecked'); assert.equal(r.body.entitlement, undefined, 'no entitlement detail leaks to Pub/Sub');
  const e = await w.ent(u);
  assert.equal(e.status, 'active');
  assert.ok(Date.parse(e.paidUntil ?? e.expiresAt) > Date.parse(first), 'paid period extended');
});

test('P9-7 cancellation: CANCELED keeps access until the paid end, then expiry removes it', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user(); await w.seed(u, 'tok', { test: false, hours: 10 });
  w.play.set('tok', { subscriptionState: 'SUBSCRIPTION_STATE_CANCELED' });
  await w.push(w.sub('tok', T.CANCELED));
  assert.equal((await w.ent(u)).status, 'active', 'cancelled but paid: still active');
  w.clock.advance(11 * HOUR);
  w.play.set('tok', { subscriptionState: 'SUBSCRIPTION_STATE_EXPIRED' });
  assert.equal((await w.push(w.sub('tok', T.EXPIRED))).body.status, 'rechecked');
  assert.equal((await w.ent(u)).status, 'inactive');
  assert.equal((await w.db.query('select terminal from billing_private.purchases')).rows[0].terminal, true);
  assert.equal((await w.push(w.sub('tok', T.EXPIRED))).body.status, 'ignored', 'terminal: no more Play calls');
});

test('P9-8 revocation / refund: REVOKED and voidedPurchaseNotification remove access at once', async (t) => {
  const w = await world(); t.after(w.close);
  const a = w.user(); const b = w.user();
  await w.seed(a, 'tok-a', { test: false }); await w.seed(b, 'tok-b', { test: false });
  w.play.set('tok-a', { subscriptionState: 'SUBSCRIPTION_STATE_EXPIRED' });
  await w.push(w.sub('tok-a', T.REVOKED));
  w.play.set('tok-b', { subscriptionState: 'SUBSCRIPTION_STATE_EXPIRED' });
  await w.push({ version: '1.0', packageName: 'com.futbeat.futbeat',
    voidedPurchaseNotification: { purchaseToken: 'tok-b', orderId: 'GPA.0', productType: 1, refundType: 1 } });
  assert.equal((await w.ent(a)).status, 'inactive');
  assert.equal((await w.ent(b)).status, 'inactive');
});

test('P9-9 hold, grace and recovery follow Play state, not the notification type', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user(); await w.seed(u, 'tok', { test: false });
  w.play.set('tok', { subscriptionState: 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD' });
  await w.push(w.sub('tok', T.IN_GRACE));
  assert.equal((await w.ent(u)).status, 'active', 'grace keeps access');
  w.play.set('tok', { subscriptionState: 'SUBSCRIPTION_STATE_ON_HOLD' });
  await w.push(w.sub('tok', T.ON_HOLD));
  assert.equal((await w.ent(u)).status, 'inactive', 'on hold: no access');
  assert.equal((await w.db.query('select terminal from billing_private.purchases')).rows[0].terminal, false, 'on hold is recoverable');
  w.play.set('tok', { subscriptionState: 'SUBSCRIPTION_STATE_ACTIVE' }); w.play.expiry('tok', 720);
  await w.push(w.sub('tok', T.RECOVERED));
  assert.equal((await w.ent(u)).status, 'active', 'recovered');
});

test('P9-10 out of order / lying type: a late CANCELED or a forged REVOKED cannot override Play', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user(); await w.seed(u, 'tok', { test: false });
  // Play says ACTIVE (user restored the subscription); a stale CANCELED and a REVOKED arrive late
  for (const type of [T.CANCELED, T.REVOKED, T.EXPIRED]) await w.push(w.sub('tok', type));
  assert.equal((await w.ent(u)).status, 'active');
});

// ================================================================== 4. idempotency, retries, backup reconciliation
test('P9-11 duplicates: the same message delivered 3 times yields one purchase, same entitlement, bounded Play calls', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user(); await w.seed(u, 'tok', { test: false });
  const calls = w.play.calls.get;
  const note = w.sub('tok', T.RENEWED); const messageId = 'm-1';
  const outs = []; for (let i = 0; i < 3; i++) outs.push((await w.push(note, { messageId })).body.status);
  assert.deepEqual(outs, ['rechecked', 'rechecked', 'rechecked']);
  assert.equal(w.play.calls.get - calls, 3, 'one Play read per delivery, never more');
  assert.equal((await w.db.query('select count(*)::int n from billing_private.purchases')).rows[0].n, 1);
  assert.equal((await w.ent(u)).status, 'active');
  assert.deepEqual((await w.kinds()).filter((k) => k === 'rtdn').length, 3);
});

test('P9-12 Play outage during RTDN: acked (no Pub/Sub storm), row stays due, cron reconciles after recovery', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user(); await w.seed(u, 'tok', { test: false });
  w.play.set('tok', { subscriptionState: 'SUBSCRIPTION_STATE_EXPIRED' });
  w.play.outage(true);
  const r = await w.push(w.sub('tok', T.REVOKED));
  assert.equal(r.status, 200, 'acked: Pub/Sub must not redeliver forever');
  assert.ok(['deferred', 'rechecked'].includes(r.body.status));
  const due = (await w.db.query('select next_check_at <= now() due from billing_private.purchases')).rows[0].due;
  assert.equal(due, true, 'row stays due for the cron');
  w.play.outage(false);
  await w.cron();
  assert.equal((await w.ent(u)).status, 'inactive', 'cron backup applied the revocation');
});

test('P9-13 lost RTDN: periodic reconciliation alone sees revocation and renewal', async (t) => {
  const w = await world(); t.after(w.close);
  const a = w.user(); const b = w.user();
  await w.seed(a, 'tok-a', { test: false }); await w.seed(b, 'tok-b', { test: false, hours: 1 });
  w.play.set('tok-a', { subscriptionState: 'SUBSCRIPTION_STATE_EXPIRED' });   // revoked, notification lost
  w.play.expiry('tok-b', 721);                                               // renewed, notification lost
  await w.dueNow(); await w.cron();
  assert.equal((await w.ent(a)).status, 'inactive');
  assert.equal((await w.ent(b)).status, 'active');
});

// ================================================================== 5. QA pilot subscription (test purchases only)
test('P9-14 QA pilot: QA function with its own audience/SA processes license-tester lifecycle; production tokens rejected there', async (t) => {
  const w = await world({ environment: 'qa', intake: true, audience: QA_URL, pushSa: PUSH_SA_QA }); t.after(w.close);
  const u = w.user(); await w.seed(u, 'tester', { test: true, hours: 0.1 });
  const prodJwt = google.sign({ aud: PROD_URL, email: PUSH_SA });
  assert.equal((await w.push(w.sub('tester', T.RENEWED), { jwt: prodJwt })).status, 401, 'production push identity cannot reach QA');
  const qaJwt = () => google.sign({ aud: QA_URL, email: PUSH_SA_QA });
  w.play.expiry('tester', 0.2);
  assert.equal((await w.push(w.sub('tester', T.RENEWED), { jwt: qaJwt() })).body.status, 'rechecked');
  assert.equal((await w.ent(u)).status, 'active');
  w.play.set('tester', { subscriptionState: 'SUBSCRIPTION_STATE_EXPIRED' });
  await w.push(w.sub('tester', T.EXPIRED), { jwt: qaJwt() });
  assert.equal((await w.ent(u)).status, 'inactive');
});

test('P9-15 production never accepts a license-tester token even if a QA-style purchase reaches it', async (t) => {
  const w = await world({ intake: true }); t.after(w.close);
  const u = w.user(); w.play.add('tester', { account: u.id, test: true });
  const r = await w.call('POST', '/billing/v1/verify', { bearer: u.bearer, body: { token: 'tester' } });
  assert.notEqual(r.body.status, 'active');
  assert.equal((await w.push(w.sub('tester', T.PURCHASED))).body.status, 'ignored');
});
