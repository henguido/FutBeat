import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { openDatabase } from '../storage/database.mjs';
import { createTransport, ttlSecondsOf, expiryOf, isExpired, FALLBACK_LIFETIME_SECONDS } from '../notifications/transports.mjs';
import { dispatchNotifications } from '../notifications/dispatch.mjs';

// PUSH TRANSPORT TTL HARDENING 69: the claim returns expiresAt from the event's
// own time; expired rows never reach a transport; FCM/APNs get android.ttl /
// apns-expiration; policy knobs are bounded and never make the claim raise.
// Synthetic data and mocked providers only: no network, no real devices.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
let seq = 0;
async function seed(db, { kickoffMinutesFromNow = 120 } = {}) {
  const n = ++seq;
  const s = { match: `fb_match_ttl${n}`, uid: randomUUID() };
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [s.match,
    JSON.stringify({ id: s.match, status: 'LIVE', startTime: new Date(Date.now() + kickoffMinutesFromNow * 60e3).toISOString() })]);
  s.device = (await db.query(`insert into futbeat_private.push_devices(user_id,installation_id,platform,transport,token,registered_at)
    values($1,$2,'android','test',$3,now()-interval '1 day') returning id`, [s.uid, randomUUID(), `tok-ttl-${n}`])).rows[0].id;
  await db.query(`insert into futbeat_private.push_follows(user_id,entity_type,entity_id,created_at) values($1,'match',$2,now()-interval '1 day')`, [s.uid, s.match]);
  return s;
}
const msg = (s, type, extra = {}) => JSON.stringify({ type, title: 't', matchId: s.match,
  subjectRefs: [{ type: 'match', id: s.match }], ...extra });
async function eventRow(db, s, { minutesAgo, type = 'GOAL' }) {
  const ev = `fb_event_ttl_${++seq}`;
  await db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,first_seen_at)
    values($1,$2,'goal_api',$3,'{}'::jsonb,now())`, [ev, s.match, type]);
  await db.query(`insert into futbeat_private.notification_outbox(event_id,device_id,user_id,message,created_at)
    values($1,$2,$3,$4,now()-make_interval(mins=>$5))`, [ev, s.device, s.uid, msg(s, type, { eventId: ev }), minutesAgo]);
  return ev;
}
const keyedRow = (db, s, { key, type, createdSql = 'now()', enqueuedSql = 'now()', extra = {} }) => db.query(
  `insert into futbeat_private.notification_outbox(notification_key,device_id,user_id,message,created_at,enqueued_at)
   values($1,$2,$3,$4,${createdSql},${enqueuedSql})`, [key, s.device, s.uid, msg(s, type, extra)]);
const claim = (db) => db.query("select public.futbeat_claim_notifications_v2('dry_run',50) v").then((r) => r.rows[0].v);
const setFreshness = (db, values) => db.query("update futbeat_private.provider_quota_policy set freshness=freshness||$1::jsonb where provider='goal_api'", [JSON.stringify(values)]);
const ms = (iso) => Date.parse(iso);
const near = (a, b, tol = 5000) => Math.abs(a - b) <= tol;

// ---------------------------------------------------------------- SQL claim
test('claim returns expiresAt from the event time per category (goal, lineup, news, transfer)', () => withDb(async (db) => {
  const s = await seed(db, { kickoffMinutesFromNow: 120 });
  const ev = await eventRow(db, s, { minutesAgo: 3 });
  await keyedRow(db, s, { key: `lineup:${s.match}:p:starter`, type: 'LINEUP', extra: { playerRole: 'starter' } });
  await keyedRow(db, s, { key: 'news:a', type: 'NEWS', createdSql: "now()-interval '2 hours'" });
  // provider clock in the future: enqueued_at bounds it
  await keyedRow(db, s, { key: 'transfer:future', type: 'TRANSFER', createdSql: "now()+interval '5 hours'", enqueuedSql: "now()-interval '1 hour'" });
  const c = await claim(db);
  const now = Date.now();
  const by = Object.fromEntries(c.rows.map((r) => [r.message.eventId ?? r.message.type, r]));
  assert.ok(near(ms(by[ev].expiresAt), now + 7 * 60e3), 'goal: created_at (3 min ago) + 10 min');
  assert.ok(near(ms(by.LINEUP.expiresAt), now + 140 * 60e3), 'lineup: kickoff (in 120 min) + 20 min');
  assert.ok(near(ms(by.NEWS.expiresAt), now + 22 * 3600e3), 'news: published 2 h ago + 24 h');
  assert.ok(near(ms(by.TRANSFER.expiresAt), now + 23 * 3600e3), 'transfer: future created_at bounded by enqueued_at (1 h ago) + 24 h');
}));

test('a lineup whose kickoff is unknown lives 6 h from its creation', () => withDb(async (db) => {
  const s = await seed(db);
  await db.query("update futbeat_private.entities set payload=payload-'startTime' where id=$1", [s.match]);
  await keyedRow(db, s, { key: `lineup:${s.match}:p:bench`, type: 'LINEUP', extra: { playerRole: 'bench' } });
  const c = await claim(db);
  assert.equal(c.rows.length, 1);
  assert.ok(near(ms(c.rows[0].expiresAt), Date.now() + 6 * 3600e3));
}));

test('invalid knobs never make the claim raise: a fresh goal still goes out (LIVE protected)', () => withDb(async (db) => {
  for (const bad of [{ contentPushMaxAgeHours: 'abc' }, { matchPushMaxDelayMinutes: 'x' }, { lineupAlertLateMinutes: { nested: true } }]) {
    const s = await seed(db);
    await setFreshness(db, bad);
    const ev = await eventRow(db, s, { minutesAgo: 1 });
    const c = await claim(db);
    assert.ok(c.rows.some((r) => r.message.eventId === ev), `goal claimed with ${JSON.stringify(bad)}`);
    await db.query("update futbeat_private.provider_quota_policy set freshness=freshness-'contentPushMaxAgeHours'-'matchPushMaxDelayMinutes'-'lineupAlertLateMinutes' where provider='goal_api'");
  }
}));

test('contentPushMaxAgeHours is clamped to [1,168]: 0 no longer cancels everything, 1000 cannot keep 8-day news', () => withDb(async (db) => {
  const s = await seed(db);
  await setFreshness(db, { contentPushMaxAgeHours: 0 });
  await keyedRow(db, s, { key: 'news:30min', type: 'NEWS', createdSql: "now()-interval '30 minutes'" });
  await keyedRow(db, s, { key: 'news:2h', type: 'NEWS', createdSql: "now()-interval '2 hours'" });
  let c = await claim(db);
  assert.deepEqual(c.rows.map((r) => r.message.type), ['NEWS'], 'only the 30-min news survives a 1 h floor');
  await setFreshness(db, { contentPushMaxAgeHours: 1000 });
  await keyedRow(db, s, { key: 'news:8d', type: 'NEWS', createdSql: "now()-interval '8 days'" });
  await keyedRow(db, s, { key: 'news:5d', type: 'NEWS', createdSql: "now()-interval '5 days'" });
  c = await claim(db);
  assert.deepEqual(c.rows.map((r) => r.message.type), ['NEWS'], '168 h cap: the 8-day row expires, the 5-day row goes');
  const states = (await db.query("select notification_key k,state,provider_receipt r from futbeat_private.notification_outbox where user_id=$1 order by 1", [s.uid])).rows;
  assert.deepEqual(states.filter((x) => x.state === 'cancelled').map((x) => [x.k, x.r]), [['news:2h', 'expired'], ['news:8d', 'expired']]);
}));

test('quota_setting_bounded: default for missing/non-numeric/NaN, clamped otherwise', () => withDb(async (db) => {
  const q = (key) => db.query("select futbeat_private.quota_setting_bounded('goal_api',$1,24,1,168)::float8 v", [key]).then((r) => r.rows[0].v);
  assert.equal(await q('ttlTestMissing'), 24);
  for (const [value, expected] of [['abc', 24], ['NaN', 24], [-5, 1], [0, 1], [12, 12], [1e6, 168]]) {
    await setFreshness(db, { ttlTestKey: value });
    assert.equal(await q('ttlTestKey'), expected, JSON.stringify(value));
  }
  for (const role of ['anon', 'authenticated']) {
    const ok = (await db.query("select has_function_privilege($1,'futbeat_private.quota_setting_bounded(text,text,numeric,numeric,numeric)','execute') ok", [role])).rows[0].ok;
    assert.equal(ok, false, role);
  }
}));

test('retry then expiry: a requeued goal is cancelled by the next claim once its lifetime ended', () => withDb(async (db) => {
  const s = await seed(db);
  const ev = await eventRow(db, s, { minutesAgo: 1 });
  const first = await claim(db);
  const row = first.rows.find((r) => r.message.eventId === ev);
  assert.ok(await db.query('select public.futbeat_requeue_notification_attempt($1,$2,$3,60) v', [row.id, row.attemptId, 'FCM_HTTP_429']).then((r) => r.rows[0].v));
  await db.query("update futbeat_private.notification_outbox set created_at=now()-interval '11 minutes',attempt_at=now()-interval '2 minutes' where id=$1", [row.id]);
  const second = await claim(db);
  assert.equal(second.rows.length, 0);
  const r = (await db.query('select state,provider_receipt from futbeat_private.notification_outbox where id=$1', [row.id])).rows[0];
  assert.deepEqual([r.state, r.provider_receipt], ['cancelled', 'expired']);
}));

// ---------------------------------------------------------------- transports (mocked providers)
const T0 = Date.parse('2026-10-16T18:00:00Z');
const fcmAccount = () => JSON.stringify({ project_id: 'demo', client_email: 'svc@demo.iam',
  private_key: generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey.export({ type: 'pkcs8', format: 'pem' }) });
function fakeFetch() {
  const calls = [];
  const fetcher = async (url, init) => {
    calls.push({ url, init });
    if (url.includes('oauth2')) return new Response(JSON.stringify({ access_token: 'at', expires_in: 3600 }), { status: 200 });
    if (url.includes('fcm.googleapis')) return new Response(JSON.stringify({ name: 'projects/demo/messages/1' }), { status: 200 });
    return new Response(null, { status: 200, headers: { 'apns-id': 'A1' } });
  };
  return { fetcher, calls };
}
const liveRow = (transport, extra = {}) => ({ id: randomUUID(), attemptId: randomUUID(), deviceId: 'd1', transport, token: 'tk',
  retryCount: 0, message: { type: 'GOAL', title: 'Gol', eventId: 'e1', matchId: 'm1' }, ...extra });

test('FCM: android.ttl and apns-expiration carry the remaining lifetime from expiresAt', async () => {
  const { fetcher, calls } = fakeFetch();
  const t = createTransport({ mode: 'live', env: { FCM_SERVICE_ACCOUNT_JSON: fcmAccount() }, fetcher, clock: () => T0 });
  const out = await t.send(liveRow('fcm', { expiresAt: new Date(T0 + 300e3).toISOString() }));
  assert.equal(out.state, 'sent');
  const body = JSON.parse(calls.find((c) => c.url.includes('fcm.googleapis')).init.body);
  assert.equal(body.message.android.ttl, '300s');
  assert.equal(body.message.apns.headers['apns-expiration'], String(T0 / 1000 + 300));
  assert.equal(body.message.apns.headers['apns-collapse-id'], 'e1', 'collapse/dedup unchanged');
});

test('APNs: apns-expiration header; collapse id and apns-id unchanged', async () => {
  const { fetcher, calls } = fakeFetch();
  const env = { APNS_PRIVATE_KEY: generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'pem' }),
    APNS_KEY_ID: 'K', APNS_TEAM_ID: 'T', APNS_TOPIC: 'app.futbeat' };
  const t = createTransport({ mode: 'live', env, fetcher, clock: () => T0 });
  const row = liveRow('apns', { expiresAt: new Date(T0 + 86400e3).toISOString(), message: { type: 'NEWS', title: 'n', articleId: 'a1', collapseKey: 'news:a1' } });
  assert.equal((await t.send(row)).state, 'sent');
  const h = calls[0].init.headers;
  assert.equal(h['apns-expiration'], String(T0 / 1000 + 86400));
  assert.equal(h['apns-collapse-id'], 'news:a1');
  assert.equal(h['apns-id'], row.id);
});

test('TTL bounds and fallback: no expiresAt -> per-type lifetime; far future capped at 28 days; minimum 1 s', () => {
  assert.equal(ttlSecondsOf({ message: { type: 'GOAL' } }, T0), FALLBACK_LIFETIME_SECONDS.GOAL);
  assert.equal(ttlSecondsOf({ message: { type: 'NEWS' } }, T0), 86400);
  assert.equal(ttlSecondsOf({ message: { type: 'SOMETHING_NEW' } }, T0), 3600);
  assert.equal(ttlSecondsOf({ expiresAt: new Date(T0 + 400 * 86400e3).toISOString() }, T0), 28 * 86400);
  assert.equal(ttlSecondsOf({ expiresAt: new Date(T0 + 200).toISOString() }, T0), 1);
  assert.equal(expiryOf({ expiresAt: 'garbage', message: { type: 'LINEUP' } }, T0), T0 + 3600e3);
  assert.equal(isExpired({ expiresAt: new Date(T0).toISOString() }, T0), true);
  assert.equal(isExpired({ message: { type: 'GOAL' } }, T0), false, 'no expiresAt: never cancelled client-side');
});

// ---------------------------------------------------------------- dispatcher
function fakeRpc(rows) {
  const calls = [];
  let claimed = false;
  const rpc = async (name, args) => {
    calls.push({ name, args });
    if (name === 'futbeat_claim_notifications_v2') {
      if (claimed) return { rows: [], scanned: 0 };
      claimed = true; return { rows, scanned: rows.length };
    }
    return true;
  };
  return { rpc, calls };
}

test('dispatcher: an expired row is cancelled (receipt expired) and never reaches the transport', async () => {
  const row = liveRow('test', { expiresAt: new Date(Date.now() - 1000).toISOString() });
  const { rpc, calls } = fakeRpc([row]);
  let sent = 0;
  const transport = { async send() { sent++; return { state: 'sent', receipt: 'x' }; } };
  const results = await dispatchNotifications({ rpc, transport, mode: 'dry_run' });
  assert.deepEqual(results.map((r) => [r.state, r.receipt]), [['cancelled', 'expired']]);
  assert.equal(sent, 0);
  assert.deepEqual(calls.filter((c) => c.name !== 'futbeat_claim_notifications_v2').map((c) => [c.name, c.args.p_reason]),
    [['futbeat_cancel_notification_attempt', 'expired']], 'no validation, no send-start mark');
});

test('dispatcher: a row that expires during a slow OAuth preparation is cancelled before the send boundary', async () => {
  let now = Date.parse('2026-10-16T18:00:00Z');
  const row = liveRow('fcm', { expiresAt: new Date(now + 5000).toISOString() });
  const { rpc, calls } = fakeRpc([row]);
  let sent = 0;
  const transport = { async prepare() { now += 10000; return null; }, async send() { sent++; return { state: 'sent' }; } };
  const results = await dispatchNotifications({ rpc, transport, mode: 'live', expiryClock: () => now });
  assert.deepEqual(results.map((r) => [r.state, r.receipt]), [['cancelled', 'expired']]);
  assert.equal(sent, 0);
  assert.ok(!calls.some((c) => c.name === 'futbeat_mark_notification_send_started'));
});

test('dispatcher: a live row is sent normally; transport failure and retry paths are unchanged', async () => {
  const fresh = liveRow('fcm', { expiresAt: new Date(Date.now() + 600e3).toISOString() });
  const retry = liveRow('fcm', { id: randomUUID(), expiresAt: new Date(Date.now() + 600e3).toISOString(), message: { type: 'GOAL', title: 'g', eventId: 'e2' } });
  const crash = liveRow('fcm', { id: randomUUID(), expiresAt: new Date(Date.now() + 600e3).toISOString(), message: { type: 'GOAL', title: 'g', eventId: 'e3' } });
  const { rpc, calls } = fakeRpc([fresh, retry, crash]);
  const transport = { async send(r) {
    if (r.id === retry.id) return { state: 'retryable', receipt: 'FCM_HTTP_429', retryAfterSeconds: 120 };
    if (r.id === crash.id) throw new Error('socket reset');
    return { state: 'sent', receipt: 'ok' };
  } };
  const results = await dispatchNotifications({ rpc, transport, mode: 'live' });
  const by = Object.fromEntries(results.map((r) => [r.id, [r.state, r.receipt]]));
  assert.deepEqual(by[fresh.id], ['sent', 'ok']);
  assert.deepEqual(by[retry.id], ['pending', 'FCM_HTTP_429']);
  assert.deepEqual(by[crash.id], ['uncertain', 'TRANSPORT_FAILURE'], 'an ambiguous send is never retried automatically');
  assert.ok(calls.some((c) => c.name === 'futbeat_requeue_notification_attempt' && c.args.p_id === retry.id && c.args.p_retry_after_seconds === 120));
});

// ---------------------------------------------------------------- deploy order (review 70)
test('PUSH69 applied without PUSH68 (no enqueued_at, base claim) still claims content rows', () => withDb(async (db) => {
  const { readFile } = await import('node:fs/promises');
  const dir = new URL('../../supabase/migrations/', import.meta.url);
  const baseFile = (await readFile(new URL('20261002130000_notifications_v2.sql', dir), 'utf8')).replace(/\r/g, '');
  const a = baseFile.indexOf('create or replace function public.futbeat_claim_notifications_v2(');
  const baseClaim = baseFile.slice(a, baseFile.indexOf('$$;', a) + 3);
  // Production today: the 20261002130000 claim and no enqueued_at column.
  await db.exec(baseClaim);
  await db.exec('alter table futbeat_private.notification_outbox drop column enqueued_at');
  const s = await seed(db);
  await db.query(`insert into futbeat_private.notification_outbox(notification_key,device_id,user_id,message,created_at)
    values('news:order',$1,$2,$3,now()-interval '1 hour')`, [s.device, s.uid, msg(s, 'NEWS')]);
  await db.exec((await readFile(new URL('20261016130000_push_ttl_hardening.sql', dir), 'utf8')).replace(/\r/g, ''));
  const c = await claim(db);
  assert.equal(c.rows.length, 1, 'no "record has no field enqueued_at" error');
  assert.ok(near(ms(c.rows[0].expiresAt), Date.now() + 23 * 3600e3), 'created_at (1 h ago) decides');
}));
