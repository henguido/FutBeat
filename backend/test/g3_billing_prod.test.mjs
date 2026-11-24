import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, createVerify, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { PGlite } from '@electric-sql/pglite';
import { createBillingApp } from '../../supabase/functions/futbeat-billing/lib/billing-app.mjs';
import { createPushVerifier, createServiceAccountTokenSource, createSupabaseAuthenticator } from '../../supabase/functions/futbeat-billing/lib/billing-adapters.mjs';
import { createPremiumReleasePublisher, createPublisherBudget } from '../../supabase/functions/futbeat-billing/lib/premium-play-api.mjs';
import { createPremiumReleaseService } from '../../supabase/functions/futbeat-billing/lib/premium-release-service.mjs';
import { createPremiumTokenVault } from '../../supabase/functions/futbeat-billing/lib/premium-token-vault.mjs';

// PREMIUM-PROD acceptance: Codex ledger + production additions on Postgres (PGlite), the real Publisher
// client against a simulated Google Play, the production HTTP app and adapters. No network, no real purchase.

const ORIGIN = 'https://project.example';
const ISSUER = `${ORIGIN}/auth/v1`;
const HOUR = 3_600_000;
const tag = (account) => createHash('sha256').update(`futbeat:account:${account}`).digest('hex');

// ------------------------------------------------------------ simulated Google Play (subscriptionsv2)
function fakePlay(clock) {
  const subs = new Map();
  const calls = { get: 0, ack: 0, acksBeforeCommit: 0 };
  let failNext = 0; let status429 = 0; let down = false; let onAck = null;
  const play = {
    subs, calls,
    add(token, { account, plan = 'monthly', state = 'SUBSCRIPTION_STATE_ACTIVE', hours = 720, test = true, linked } = {}) {
      subs.set(token, {
        kind: 'androidpublisher#subscriptionPurchaseV2', subscriptionState: state,
        acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING',
        externalAccountIdentifiers: { obfuscatedExternalAccountId: tag(account) },
        lineItems: [{ productId: 'futbeat_premium', offerDetails: { basePlanId: plan }, expiryTime: new Date(clock.now() + hours * HOUR).toISOString() }],
        ...(test ? { testPurchase: {} } : {}), ...(linked ? { linkedPurchaseToken: linked } : {}),
      });
    },
    set(token, patch) { Object.assign(subs.get(token), patch); },
    expiry(token, hours) { subs.get(token).lineItems[0].expiryTime = new Date(clock.now() + hours * HOUR).toISOString(); },
    failAck(n) { failNext = n; }, rateLimit(n) { status429 = n; }, outage(v) { down = v; }, onAck(fn) { onAck = fn; },
    fetch: async (url, init = {}) => {
      if (down) throw new Error('network');
      if (status429 > 0) { status429--; return new Response('{}', { status: 429, headers: { 'Retry-After': '45' } }); }
      const u = new URL(url);
      const get = /\/purchases\/subscriptionsv2\/tokens\/([^/:]+)$/.exec(u.pathname);
      const ack = /\/purchases\/subscriptions\/futbeat_premium\/tokens\/([^/:]+):acknowledge$/.exec(u.pathname);
      assert.ok(u.pathname.includes('/applications/com.futbeat.futbeat/'), 'official package only');
      if (get && (init.method ?? 'GET') === 'GET') {
        calls.get++;
        const s = subs.get(decodeURIComponent(get[1]));
        return s ? Response.json(structuredClone(s)) : new Response('{}', { status: 404 });
      }
      if (ack && init.method === 'POST') {
        calls.ack++;
        if (onAck) await onAck(decodeURIComponent(ack[1]));
        if (failNext > 0) { failNext--; return new Response('{}', { status: 503 }); }
        subs.get(decodeURIComponent(ack[1])).acknowledgementState = 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED';
        return new Response('{}', { status: 200 });
      }
      return new Response('{}', { status: 400 });
    },
  };
  return play;
}

async function world({ environment = 'qa', intake = true } = {}) {
  const db = new PGlite();
  await db.exec(await readFile(new URL('./fixtures/g3-premium-production-ledger.sql', import.meta.url), 'utf8'));
  await db.exec(await readFile(new URL('./fixtures/g3-premium-production-additions.sql', import.meta.url), 'utf8'));
  let t = Date.parse('2026-11-18T12:00:00Z');
  const clock = { now: () => t, advance: (ms) => { t += ms; } };
  // PGlite runs at real time; the service clock is advanced explicitly (entitlement uses the service clock,
  // SQL leases use now(): leases are aged with SQL updates where a test needs it).
  const play = fakePlay(clock);
  const keys = new Map([['v1', createPremiumTokenVault({ key: Buffer.alloc(32, 7), authOrigin: ORIGIN, packageName: 'com.futbeat.futbeat' })]]);
  const mk = () => createPremiumReleaseService({
    db, issuer: ISSUER, keys, currentKey: 'v1', environment, now: clock.now,
    publisher: createPremiumReleasePublisher({ environment, accessToken: async () => 'access', fetchImpl: play.fetch, budget: createPublisherBudget(db, 600) }),
  });
  const service = mk();
  const users = new Map();   // bearer -> {id, anonymous}
  const authFetch = async (url, init) => {
    const u = users.get(init.headers.Authorization.slice(7));
    return u ? Response.json({ id: u.id, aud: 'authenticated', is_anonymous: u.anonymous }) : new Response('{}', { status: 401 });
  };
  const state = { intake };
  const app = createBillingApp({
    service, intakeEnabled: () => state.intake, cronToken: 'cron-secret-0123456789abcdef0123456789',
    authenticate: createSupabaseAuthenticator({ supabaseUrl: ORIGIN, anonKey: 'anon', fetchImpl: authFetch }),
    rtdn: { enabled: true, verifyPush: async (h) => h === 'Bearer good-push' },
    allowRequest: async (account) => (await db.query('select billing_private.allow_request($1,$2) ok', [account, 10])).rows[0].ok,
  });
  const user = (anonymous = false) => { const id = randomUUID(); const bearer = `b-${id}`; users.set(bearer, { id, anonymous }); return { id, bearer }; };
  const call = async (method, path, bearer, body, headers = {}) => {
    const res = await app(new Request(`https://edge.example/functions/v1/futbeat-billing${path}`, {
      method, headers: { ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}), ...(body ? { 'content-type': 'application/json' } : {}), ...headers },
      ...(body ? { body: JSON.stringify(body) } : {}),
    }));
    return { status: res.status, body: await res.json() };
  };
  const cron = () => call('POST', '/billing/v1/cron', null, null, { 'x-futbeat-billing-cron': 'cron-secret-0123456789abcdef0123456789' });
  const rtdn = (token, auth = 'Bearer good-push') => call('POST', '/billing/v1/rtdn', null,
    { message: { data: Buffer.from(JSON.stringify({ packageName: 'com.futbeat.futbeat', subscriptionNotification: { notificationType: 12, purchaseToken: token } })).toString('base64') } },
    { authorization: auth });
  const dueNow = () => db.query("update billing_private.purchases set next_check_at=now()-interval '1 second' where not terminal");
  return { db, clock, play, service, mk, app, user, call, cron, rtdn, state, dueNow, close: () => db.close() };
}

test('1. auth: missing session, anonymous user and a foreign-project session are 401; free users read inactive', async (t) => {
  const w = await world(); t.after(w.close);
  assert.equal((await w.call('GET', '/billing/v1/entitlement')).status, 401);
  const anon = w.user(true);
  assert.equal((await w.call('GET', '/billing/v1/entitlement', anon.bearer)).status, 401, 'anonymous cannot subscribe');
  assert.equal((await w.call('POST', '/billing/v1/verify', 'b-unknown', { token: 'x' })).status, 401);
  const free = w.user();
  assert.deepEqual((await w.call('GET', '/billing/v1/entitlement', free.bearer)).body, { version: 1, status: 'inactive', purchasesEnabled: true });
});

test('2. purchase: entitlement persisted first, Play acknowledged by the cron only after commit, exactly once', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user();
  w.play.add('tok-a', { account: u.id });
  w.play.onAck(async () => {
    const r = await w.db.query("select ack_pending from billing_private.purchases");
    if (r.rows.length !== 1) w.play.calls.acksBeforeCommit++;
  });
  const v = await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok-a' });
  assert.equal(v.status, 200);
  assert.equal(v.body.status, 'active');
  assert.equal(v.body.plan, 'monthly');
  assert.equal(w.play.calls.ack, 0, 'no acknowledgement inside the request');
  assert.equal((await w.db.query('select count(*)::int n from billing_private.purchases where ack_pending')).rows[0].n, 1);
  const c = await w.cron();
  assert.equal(c.body.acknowledgements, 1);
  assert.equal(w.play.calls.ack, 1);
  assert.equal(w.play.calls.acksBeforeCommit, 0);
  await w.cron();
  assert.equal(w.play.calls.ack, 1, 'never acknowledged twice');
  const sealed = (await w.db.query('select sealed_token from billing_private.purchases')).rows[0].sealed_token;
  assert.ok(!Buffer.from(sealed).toString('latin1').includes('tok-a'), 'token stored encrypted');
});

test('3. isolation: another account cannot claim, restore or see a purchase; a mismatched Play tag is rejected', async (t) => {
  const w = await world(); t.after(w.close);
  const a = w.user(); const b = w.user();
  w.play.add('tok-a', { account: a.id });
  assert.equal((await w.call('POST', '/billing/v1/verify', b.bearer, { token: 'tok-a' })).status, 403, 'Play tag belongs to A');
  await w.call('POST', '/billing/v1/verify', a.bearer, { token: 'tok-a' });
  assert.equal((await w.call('POST', '/billing/v1/verify', b.bearer, { token: 'tok-a' })).status, 403, 'stored owner is A');
  const r = await w.call('POST', '/billing/v1/restore', b.bearer, { tokens: ['tok-a'] });
  assert.equal(r.body.status, 'inactive'); assert.equal(r.body.rejected, 1);
  assert.equal((await w.call('GET', '/billing/v1/entitlement', b.bearer)).body.status, 'inactive');
  assert.equal((await w.call('GET', '/billing/v1/entitlement', a.bearer)).body.status, 'active');
});

test('4. environments: production rejects license-test purchases; QA rejects real ones', async (t) => {
  const prod = await world({ environment: 'production' }); t.after(prod.close);
  const u = prod.user();
  prod.play.add('tok-test', { account: u.id, test: true });
  assert.equal((await prod.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok-test' })).status, 403);
  prod.play.add('tok-real', { account: u.id, test: false });
  assert.equal((await prod.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok-real' })).body.status, 'active');
  const qa = await world({ environment: 'qa' }); t.after(qa.close);
  const q = qa.user();
  qa.play.add('tok-real', { account: q.id, test: false });
  assert.equal((await qa.call('POST', '/billing/v1/verify', q.bearer, { token: 'tok-real' })).status, 403);
});

test('5-6. renewal moves paidUntil; cancellation keeps access until expiry, then inactive', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user();
  w.play.add('tok', { account: u.id, hours: 1 });
  await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok' });
  const first = (await w.call('GET', '/billing/v1/entitlement', u.bearer)).body.paidUntil;
  w.play.expiry('tok', 720);                                 // Play renewed the period
  w.clock.advance(50 * 60_000); await w.dueNow(); await w.cron();
  const renewed = (await w.call('GET', '/billing/v1/entitlement', u.bearer)).body;
  assert.equal(renewed.status, 'active');
  assert.ok(Date.parse(renewed.paidUntil) > Date.parse(first), 'renewal seen by reconciliation, no phone needed');
  w.play.set('tok', { subscriptionState: 'SUBSCRIPTION_STATE_CANCELED' });
  await w.dueNow(); await w.cron();
  assert.equal((await w.call('GET', '/billing/v1/entitlement', u.bearer)).body.status, 'active', 'canceled = active until expiry');
  w.clock.advance(721 * HOUR);
  assert.equal((await w.call('GET', '/billing/v1/entitlement', u.bearer)).body.status, 'inactive');
});

test('7. revocation: RTDN triggers an authoritative recheck; EXPIRED is terminal; unknown tokens and bad JWTs are handled', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user();
  w.play.add('tok', { account: u.id });
  await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok' });
  w.play.set('tok', { subscriptionState: 'SUBSCRIPTION_STATE_EXPIRED' });   // refunded + revoked in Play
  assert.equal((await w.rtdn('tok')).body.status, 'rechecked');
  assert.equal((await w.call('GET', '/billing/v1/entitlement', u.bearer)).body.status, 'inactive');
  assert.equal((await w.db.query('select terminal from billing_private.purchases')).rows[0].terminal, true);
  assert.equal((await w.rtdn('never-seen')).body.status, 'ignored', 'the notification itself grants nothing');
  assert.equal((await w.rtdn('tok', 'Bearer forged')).status, 401);
  const kinds = (await w.db.query('select kind from billing_private.events order by id')).rows.map((r) => r.kind);
  assert.deepEqual(kinds, ['purchase', 'rtdn', 'recheck']);
});

test('8. plan change: a replacement token (linkedPurchaseToken) retires the previous one', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user();
  w.play.add('tok-month', { account: u.id });
  await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok-month' });
  w.play.add('tok-year', { account: u.id, plan: 'yearly', hours: 8760, linked: 'tok-month' });
  const v = await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok-year' });
  assert.equal(v.body.plan, 'yearly');
  const rows = (await w.db.query('select base_plan_id,terminal from billing_private.purchases order by base_plan_id')).rows;
  assert.deepEqual(rows.map((r) => [r.base_plan_id, r.terminal]), [['monthly', true], ['yearly', false]]);
});

test('9. restore: the owner restores from Play tokens on a new device; intake off keeps existing rights reconcilable', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user();
  w.play.add('tok', { account: u.id });
  const r = await w.call('POST', '/billing/v1/restore', u.bearer, { tokens: ['tok', 'tok'] });
  assert.equal(r.body.status, 'active'); assert.equal(r.body.restored, 1);
  w.state.intake = false;
  w.play.add('tok-new', { account: u.id });
  assert.equal((await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok-new' })).status, 503, 'no new purchases while intake is off');
  assert.equal((await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok' })).body.status, 'active', 'existing purchase still served');
  assert.equal((await w.call('GET', '/billing/v1/entitlement', u.bearer)).body.purchasesEnabled, false);
});

test('10-11. acknowledgement retries with backoff; a crash after claim is recovered once the lease expires', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user();
  w.play.add('tok', { account: u.id });
  await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok' });
  w.play.failAck(1);
  await w.cron();
  let row = (await w.db.query('select ack_pending,ack_attempts,ack_due_at>now() later from billing_private.purchases')).rows[0];
  assert.deepEqual([row.ack_pending, row.ack_attempts, row.later], [true, 1, true], 'failed ack stays queued with backoff');
  await w.db.query("update billing_private.purchases set ack_due_at=now()-interval '1 second'");
  // crash: claimed, never finished
  await w.db.query('select * from billing_private.claim_ack($1,1)', [ISSUER]);
  assert.equal((await w.cron()).body.acknowledgements, 0, 'lease held by the crashed worker');
  await w.db.query("update billing_private.purchases set ack_lease_until=now()-interval '1 second'");
  assert.equal((await w.cron()).body.acknowledgements, 1);
  row = (await w.db.query('select ack_pending from billing_private.purchases')).rows[0];
  assert.equal(row.ack_pending, false);
  assert.equal(w.play.subs.get('tok').acknowledgementState, 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED');
});

test('12. two instances draining at once acknowledge each purchase once', async (t) => {
  const w = await world(); t.after(w.close);
  for (let i = 0; i < 4; i++) { const u = w.user(); w.play.add(`tok-${i}`, { account: u.id }); await w.call('POST', '/billing/v1/verify', u.bearer, { token: `tok-${i}` }); }
  const a = w.mk(); const b = w.mk();
  const drain = async (s) => { let n = 0; while (await s.drainAcknowledgements()) n++; return n; };
  const [na, nb] = await Promise.all([drain(a), drain(b)]);
  assert.equal(na + nb, 4);
  assert.equal(w.play.calls.ack, 4);
});

test('13. Play outage: a paying user keeps Premium (72 h staleness in production), revocation applies at the next successful check', async (t) => {
  const w = await world({ environment: 'production' }); t.after(w.close);
  const u = w.user();
  w.play.add('tok', { account: u.id, test: false });
  await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok' });
  w.play.outage(true);
  w.clock.advance(7 * HOUR); await w.dueNow(); await w.cron();
  assert.equal((await w.call('GET', '/billing/v1/entitlement', u.bearer)).body.status, 'active', 'no Premium loss on a Google outage');
  w.clock.advance(70 * HOUR);
  assert.equal((await w.call('GET', '/billing/v1/entitlement', u.bearer)).body.status, 'inactive', 'bounded: unverifiable for > 72 h');
  w.play.outage(false); await w.dueNow(); await w.cron();
  assert.equal((await w.call('GET', '/billing/v1/entitlement', u.bearer)).body.status, 'active', 'restored by the next successful recheck');
});

test('14. Publisher 429: the shared budget pauses every instance (Retry-After), then resumes', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user();
  w.play.add('tok', { account: u.id });
  w.play.rateLimit(1);
  assert.equal((await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok' })).status, 503);
  const paused = (await w.db.query('select blocked_until>now() p from billing_private.publisher_budget')).rows[0].p;
  assert.equal(paused, true);
  assert.equal((await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok' })).status, 503, 'still paused: no call to Google');
  assert.equal(w.play.calls.get, 0);
  await w.db.query("update billing_private.publisher_budget set blocked_until=now()-interval '1 second'");
  assert.equal((await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok' })).body.status, 'active');
});

test('15. the client cannot grant Premium: unknown, garbage or foreign tokens never create a right', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user();
  assert.equal((await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'made-up' })).status, 503);
  assert.equal((await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'x', premium: true })).status, 400);
  assert.equal((await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'a'.repeat(5000) })).status, 400);
  assert.equal((await w.db.query('select count(*)::int n from billing_private.purchases')).rows[0].n, 0);
  assert.equal((await w.call('GET', '/billing/v1/entitlement', u.bearer)).body.status, 'inactive');
});

test('16. cron and RTDN need their own credentials; unknown routes are 404', async (t) => {
  const w = await world(); t.after(w.close);
  assert.equal((await w.call('POST', '/billing/v1/cron', null, null, { 'x-futbeat-billing-cron': 'wrong' })).status, 403);
  assert.equal((await w.call('POST', '/billing/v1/cron')).status, 403);
  assert.equal((await w.call('GET', '/billing/v1/grant')).status, 404);
  assert.equal((await w.call('GET', '/billing/v1/entitlement', null, null, { 'x-forwarded-proto': 'http' })).status, 400);
});

test('17. account deletion erases rights and sealed tokens', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user();
  w.play.add('tok', { account: u.id });
  await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok' });
  assert.equal(await w.service.forgetAccount(u.id), 1);
  assert.equal((await w.db.query('select (select count(*) from billing_private.purchases)+(select count(*) from billing_private.events) n')).rows[0].n, 0);
  assert.equal((await w.call('GET', '/billing/v1/entitlement', u.bearer)).body.status, 'inactive');
});

test('18. pending, on-hold and paused purchases grant nothing and are never acknowledged', async (t) => {
  const w = await world(); t.after(w.close);
  for (const state of ['SUBSCRIPTION_STATE_PENDING', 'SUBSCRIPTION_STATE_ON_HOLD', 'SUBSCRIPTION_STATE_PAUSED']) {
    const u = w.user();
    w.play.add(state, { account: u.id, state });
    assert.equal((await w.call('POST', '/billing/v1/verify', u.bearer, { token: state })).body.status, 'inactive', state);
  }
  await w.cron();
  assert.equal(w.play.calls.ack, 0);
});

test('adapters: service-account JWT is RS256-signed and cached; push verifier checks signature, audience and email', async () => {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  let issued = 0; let assertion = null;
  const tokenSource = createServiceAccountTokenSource({
    json: { client_email: 'billing@p.iam', private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }) },
    fetchImpl: async (url, init) => { issued++; assertion = new URLSearchParams(init.body).get('assertion'); return Response.json({ access_token: 'at', expires_in: 3600 }); },
  });
  assert.equal(await tokenSource(), 'at'); assert.equal(await tokenSource(), 'at'); assert.equal(issued, 1);
  const [h, c, s] = assertion.split('.');
  const v = createVerify('RSA-SHA256'); v.update(`${h}.${c}`);
  assert.ok(v.verify(publicKey, Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64')));
  const claims = JSON.parse(Buffer.from(c, 'base64').toString());
  assert.equal(claims.scope, 'https://www.googleapis.com/auth/androidpublisher');

  const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'k1', alg: 'RS256', use: 'sig' };
  const sign = (claimsObj, key = privateKey, kid = 'k1') => {
    const enc = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
    const head = enc({ alg: 'RS256', kid, typ: 'JWT' }); const body = enc(claimsObj);
    const { createSign } = require_();
    const sg = createSign('RSA-SHA256'); sg.update(`${head}.${body}`);
    return `${head}.${body}.${sg.sign(key).toString('base64url')}`;
  };
  const verify = createPushVerifier({ audience: 'https://x/billing/v1/rtdn', serviceAccountEmail: 'push@p.iam',
    fetchImpl: async () => Response.json({ keys: [jwk] }) });
  const now = Math.floor(Date.now() / 1000);
  const good = { iss: 'https://accounts.google.com', aud: 'https://x/billing/v1/rtdn', email: 'push@p.iam', email_verified: true, iat: now, exp: now + 300 };
  assert.equal(await verify(`Bearer ${sign(good)}`), true);
  assert.equal(await verify(`Bearer ${sign({ ...good, aud: 'other' })}`), false);
  assert.equal(await verify(`Bearer ${sign({ ...good, email: 'evil@p.iam' })}`), false);
  assert.equal(await verify(`Bearer ${sign({ ...good, exp: now - 10 })}`), false);
  const { privateKey: other } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  assert.equal(await verify(`Bearer ${sign(good, other)}`), false, 'wrong key');
});

test('19. per-account limit: the 11th verify in a minute is 429 and never reaches Google', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user();
  for (let i = 0; i < 10; i++) await w.call('POST', '/billing/v1/verify', u.bearer, { token: `junk-${i}` });
  const calls = w.play.calls.get;
  const r = await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'junk-x' });
  assert.equal(r.status, 429); assert.equal(r.body.status, 'limited');
  assert.equal(w.play.calls.get, calls);
  const other = w.user();
  w.play.add('tok', { account: other.id });
  assert.equal((await w.call('POST', '/billing/v1/verify', other.bearer, { token: 'tok' })).body.status, 'active', 'other accounts unaffected');
});

test('20. deleting the Supabase Auth user erases its billing data (trigger on auth.users)', async (t) => {
  const db = new PGlite(); t.after(() => db.close());
  await db.exec('create schema auth; create table auth.users(id uuid primary key);');
  await db.exec(await readFile(new URL('./fixtures/g3-premium-production-ledger.sql', import.meta.url), 'utf8'));
  await db.exec(await readFile(new URL('./fixtures/g3-premium-production-additions.sql', import.meta.url), 'utf8'));
  const id = randomUUID();
  await db.query('insert into auth.users values($1)', [id]);
  await db.query("insert into billing_private.events(token_hash,account_id,kind) values(decode(repeat('ab',32),'hex'),$1,'purchase')", [id]);
  await db.query('select billing_private.allow_request($1,10)', [id]);
  await db.query('delete from auth.users where id=$1', [id]);
  const n = (await db.query('select (select count(*) from billing_private.events)+(select count(*) from billing_private.request_window) n')).rows[0].n;
  assert.equal(Number(n), 0);
});

import { createSign } from 'node:crypto';
function require_() { return { createSign }; }

// ------------------------------------------------------------ G2: renewal grace (G1 A1 found a 67 s gap)
const MIN = 60_000;
const autoRenew = (w, token, on = true) => { w.play.subs.get(token).lineItems[0].autoRenewingPlan = { autoRenewEnabled: on }; };

test('G2-R1 renewal never shows inactive: grace past the paid end while ACTIVE + auto-renew, retry each minute until Play renews', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user();
  w.play.add('tok', { account: u.id, hours: 5 / 60 }); autoRenew(w, 'tok');
  await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok' });
  const paidEnd = Date.parse(w.play.subs.get('tok').lineItems[0].expiryTime);
  const next = Date.parse((await w.db.query('select next_check_at from billing_private.purchases')).rows[0].next_check_at);
  assert.equal(next, paidEnd + 30_000, 'first check 30 s after the paid end (was +60 s)');
  w.clock.advance(5 * MIN + 10_000);                       // paid end passed, Play has not renewed yet
  assert.equal((await w.call('GET', '/billing/v1/entitlement', u.bearer)).body.status, 'active', 'inside the grace');
  w.clock.advance(25_000); await w.dueNow(); await w.cron(); // recheck: Play still shows the old expiry
  const p = (await w.db.query('select expires_at, next_check_at, terminal from billing_private.purchases')).rows[0];
  assert.equal(p.terminal, false);
  assert.equal(Date.parse(p.expires_at), paidEnd + 2 * MIN, 'QA grace 2 min');
  assert.equal(Date.parse(p.next_check_at), w.clock.now() + MIN, 'renewal pending: ask again in 1 min');
  assert.equal((await w.call('GET', '/billing/v1/entitlement', u.bearer)).body.status, 'active');
  w.play.expiry('tok', 5 / 60);                            // Play publishes the renewal
  w.clock.advance(MIN); await w.dueNow(); await w.cron();
  const e = (await w.call('GET', '/billing/v1/entitlement', u.bearer)).body;
  assert.equal(e.status, 'active');
  assert.ok(Date.parse(e.paidUntil) > paidEnd + 4 * MIN, 'new period seen');
});

test('G2-R2 no grace for a cancelled plan, and a refund/revocation inside the grace is terminal at once', async (t) => {
  const w = await world(); t.after(w.close);
  const a = w.user(); const b = w.user();
  w.play.add('can', { account: a.id, hours: 5 / 60 }); autoRenew(w, 'can', false);
  w.play.add('rev', { account: b.id, hours: 5 / 60 }); autoRenew(w, 'rev');
  await w.call('POST', '/billing/v1/verify', a.bearer, { token: 'can' });
  await w.call('POST', '/billing/v1/verify', b.bearer, { token: 'rev' });
  w.clock.advance(5 * MIN + 1_000);
  assert.equal((await w.call('GET', '/billing/v1/entitlement', a.bearer)).body.status, 'inactive', 'cancelled: ends exactly at the paid end');
  assert.equal((await w.call('GET', '/billing/v1/entitlement', b.bearer)).body.status, 'active', 'auto-renewing: grace');
  w.play.set('rev', { subscriptionState: 'SUBSCRIPTION_STATE_EXPIRED' });   // refunded with "remove access"
  await w.dueNow(); await w.cron();
  assert.equal((await w.call('GET', '/billing/v1/entitlement', b.bearer)).body.status, 'inactive');
  const r = (await w.db.query('select terminal from billing_private.purchases where account_id=$1', [b.id])).rows[0];
  assert.equal(r.terminal, true);
});

test('G2-R3 credential or Play outage during a renewal: Premium kept up to the grace, never terminal, recovered by the next check', async (t) => {
  const w = await world(); t.after(w.close);
  const u = w.user();
  w.play.add('tok', { account: u.id, hours: 5 / 60 }); autoRenew(w, 'tok');
  await w.call('POST', '/billing/v1/verify', u.bearer, { token: 'tok' });
  w.play.outage(true);
  w.clock.advance(5 * MIN + 40_000); await w.dueNow(); await w.cron();
  assert.equal((await w.call('GET', '/billing/v1/entitlement', u.bearer)).body.status, 'active', 'outage inside the grace');
  w.clock.advance(2 * MIN);
  assert.equal((await w.call('GET', '/billing/v1/entitlement', u.bearer)).body.status, 'inactive', 'bounded by the grace');
  assert.equal((await w.db.query('select terminal from billing_private.purchases')).rows[0].terminal, false, 'not a revocation');
  w.play.outage(false); w.play.expiry('tok', 5 / 60);
  await w.dueNow(); await w.cron();
  assert.equal((await w.call('GET', '/billing/v1/entitlement', u.bearer)).body.status, 'active', 'recovered without the phone');
});

test('G2-C cron reply carries the awaited credential status (no token in it)', async () => {
  const app = createBillingApp({
    service: { drainAcknowledgements: async () => false, reconcileDue: async () => 0 },
    authenticate: async () => null, intakeEnabled: () => true, cronToken: 'cron-secret-0123456789abcdef0123456789',
    credentialStatus: async () => ({ mode: 'wif', ready: true, expiresInS: 900, lastError: null }),
  });
  const res = await app(new Request('https://edge.example/functions/v1/futbeat-billing/billing/v1/cron',
    { method: 'POST', headers: { 'x-futbeat-billing-cron': 'cron-secret-0123456789abcdef0123456789' } }));
  const body = await res.json();
  assert.equal(res.status, 200);
  assert.deepEqual(body.credential, { mode: 'wif', ready: true, expiresInS: 900, lastError: null });
});
