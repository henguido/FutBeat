import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, randomUUID } from 'node:crypto';
import { openDatabase } from '../storage/database.mjs';
import { createTransport, collapseKeyOf, DEFAULT_ANDROID_CHANNEL } from '../notifications/transports.mjs';
import { dispatchNotifications, summarize } from '../notifications/dispatch.mjs';
import { fixtureEventSections, liveEventsContentSignature, normalizeFixtureEvents } from '../../supabase/functions/_shared/live_events.ts';

// Notifications v2 (20261002130000): dispatcher throughput, dead tokens,
// send-time age, match start, goal annulled, approved types / preferences,
// shared phone. Generic fixtures only; no network, no provider.

// ---------------------------------------------------------------- transport
const serviceAccount = () => {
  const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  return JSON.stringify({ project_id: 'demo-project', client_email: 'svc@demo.iam', private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }) });
};
function fakeFetch(handler) {
  const calls = [];
  const fetcher = async (url, init) => {
    calls.push({ url, init, body: typeof init.body === 'string' ? JSON.parse(init.body) : null });
    const { status = 200, json = {}, headers = {} } = (await handler(url, init, calls)) ?? {};
    return { ok: status >= 200 && status < 300, status, json: async () => json, headers: { get: (k) => headers[k] ?? null } };
  };
  return { fetcher, calls };
}
const fcmRow = (over = {}) => ({ id: randomUUID(), attemptId: randomUUID(), transport: 'fcm', token: 'tok',
  message: { title: '⚽ 10\' Gol — Local', body: 'Local 1-0 Visita', eventId: 'fb_event_abc', matchId: 'fb_match_x', type: 'GOAL', collapseKey: 'fb_event_abc' }, ...over });

test('FCM: one OAuth token per invocation, body + channel + per-event collapse key', async () => {
  const { fetcher, calls } = fakeFetch((url) => url.includes('oauth2')
    ? { json: { access_token: 'access-1', expires_in: 3600 } } : { json: { name: 'projects/demo/messages/1' } });
  const transport = createTransport({ mode: 'live', env: { FCM_SERVICE_ACCOUNT_JSON: serviceAccount() }, fetcher });
  const results = await Promise.all([fcmRow(), fcmRow(), fcmRow()].map((row) => transport.send(row)));
  assert.ok(results.every((r) => r.state === 'sent'));
  assert.equal(calls.filter((c) => c.url.includes('oauth2')).length, 1, 'token cached and shared by concurrent sends');
  const send = calls.find((c) => c.url.includes('messages:send'));
  assert.equal(send.init.headers.Authorization, 'Bearer access-1');
  const msg = send.body.message;
  assert.equal(msg.notification.body, 'Local 1-0 Visita');
  assert.equal(msg.android.notification.channel_id, DEFAULT_ANDROID_CHANNEL);
  assert.equal(msg.android.collapse_key, 'fb_event_abc');
  assert.equal(msg.android.notification.tag, 'fb_event_abc');
  assert.equal(msg.apns.headers['apns-collapse-id'], 'fb_event_abc');
  assert.equal(msg.data.type, 'GOAL');
  assert.ok(Object.values(msg.data).every((v) => typeof v === 'string'));
  // Without a collapseKey the event id (not the outbox row id) is the slot.
  assert.equal(collapseKeyOf({ id: 'row', message: { eventId: 'fb_event_z' } }), 'fb_event_z');
});

test('FCM / APNs dead tokens are classified; server errors stay uncertain; auth failure retried next send', async () => {
  let status = 404, json = { error: { status: 'NOT_FOUND', details: [{ errorCode: 'UNREGISTERED' }] } };
  let authOk = false;
  const { fetcher, calls } = fakeFetch((url) => url.includes('oauth2')
    ? (authOk ? { json: { access_token: 'a', expires_in: 3600 } } : { status: 500 }) : { status, json });
  const transport = createTransport({ mode: 'live', env: { FCM_SERVICE_ACCOUNT_JSON: serviceAccount() }, fetcher });
  assert.deepEqual(await transport.send(fcmRow()), { state: 'failed', receipt: 'FCM_AUTH_FAILED' });
  authOk = true;
  assert.deepEqual(await transport.send(fcmRow()), { state: 'failed', receipt: 'FCM_UNREGISTERED' });
  status = 400; json = { error: { status: 'INVALID_ARGUMENT', details: [{ errorCode: 'UNREGISTERED' }] } };
  assert.equal((await transport.send(fcmRow())).receipt, 'FCM_UNREGISTERED');
  status = 400; json = { error: { status: 'INVALID_ARGUMENT', details: [{ errorCode: 'INVALID_ARGUMENT' }] } };
  assert.deepEqual(await transport.send(fcmRow()), { state: 'failed', receipt: 'FCM_HTTP_400:INVALID_ARGUMENT' });
  status = 503; json = {};
  assert.equal((await transport.send(fcmRow())).state, 'uncertain');
  assert.equal(calls.filter((c) => c.url.includes('oauth2')).length, 2);

  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const apnsEnv = { APNS_PRIVATE_KEY: privateKey.export({ type: 'pkcs8', format: 'pem' }), APNS_KEY_ID: 'K', APNS_TEAM_ID: 'T', APNS_TOPIC: 'app.futbeat' };
  let apnsStatus = 410;
  const apns = fakeFetch(() => ({ status: apnsStatus, json: { reason: 'Unregistered' } }));
  const apnsTransport = createTransport({ mode: 'live', env: apnsEnv, fetcher: apns.fetcher });
  assert.deepEqual(await apnsTransport.send(fcmRow({ transport: 'apns' })), { state: 'failed', receipt: 'APNS_UNREGISTERED' });
  const sent = apns.calls[0];
  assert.equal(sent.init.headers['apns-collapse-id'], 'fb_event_abc');
  assert.equal(sent.body.aps.alert.body, 'Local 1-0 Visita');
  apnsStatus = 200;
  await apnsTransport.send(fcmRow({ transport: 'apns' }));
  assert.equal(apns.calls[0].init.headers.authorization, apns.calls[1].init.headers.authorization, 'APNs provider token reused');
});

// ---------------------------------------------------------------- dispatcher
function fakeQueue(total, { sendMs = 5 } = {}) {
  const pending = Array.from({ length: total }, (_, i) => ({ id: `row-${i}`, attemptId: `a-${i}`, transport: 'test', message: {} }));
  const finished = [];
  const claims = [];
  let inFlight = 0, maxInFlight = 0;
  const rpc = async (name, args) => {
    if (name === 'futbeat_claim_notifications') { claims.push(args.p_limit); return pending.splice(0, args.p_limit); }
    finished.push(args); return true;
  };
  const transport = { async send(row) {
    inFlight++; maxInFlight = Math.max(maxInFlight, inFlight);
    await new Promise((r) => setTimeout(r, sendMs));
    inFlight--;
    if (row.id === 'row-3') throw new Error('boom');
    return { state: 'simulated', receipt: 'ok' };
  } };
  return { rpc, transport, finished, claims, max: () => maxInFlight, left: () => pending.length };
}

test('dispatcher drains in batches of 50 with at most 10 concurrent sends', async () => {
  const q = fakeQueue(120);
  const results = await dispatchNotifications({ rpc: q.rpc, transport: q.transport, mode: 'dry_run' });
  assert.equal(results.length, 120);
  assert.deepEqual(q.claims, [50, 50, 50, 50], 'claims until an empty answer');
  assert.ok(q.max() <= 10 && q.max() > 1, `concurrency ${q.max()}`);
  assert.equal(q.finished.length, 120, 'every claimed row is finished');
  assert.equal(results.find((r) => r.id === 'row-3').state, 'uncertain', 'a transport exception is uncertain, never retried');
  assert.deepEqual(summarize(results).counts, { simulated: 119, uncertain: 1 });
});

test('dispatcher stops claiming when the time budget is spent but finishes the claimed batch', async () => {
  const q = fakeQueue(200, { sendMs: 0 });
  let now = 0;
  const clock = () => now;
  const transport = { send: async (row) => { now += 1000; return q.transport.send(row); } };
  const results = await dispatchNotifications({ rpc: q.rpc, transport, clock, budgetMs: 45000 });
  assert.equal(results.length, 50, 'the first batch alone spends 50 s of the 45 s budget');
  assert.equal(q.left(), 150);
});

// ---------------------------------------------------------------- database
async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
let seq = 0;
let clockMs = Date.now();
const tick = () => new Date((clockMs = Math.max(clockMs + 1000, Date.now()))).toISOString();

async function seed(db, { startMinutesAgo = 60, follow = 'match' } = {}) {
  const n = ++seq;
  const ids = { comp: `fb_comp_nv${n}`, home: `fb_team_nvh${n}`, away: `fb_team_nva${n}`, match: `fb_match_nv${n}`,
    ext: `goal-nv-${n}`, homeExt: `NH${n}`, awayExt: `NA${n}`, p1: `fb_player_nv${n}a`, p2: `fb_player_nv${n}b`, n };
  const put = (id, kind, payload) => db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
  await put(ids.comp, 'competition', { name: `Liga ${n}` });
  await put(ids.home, 'team', { name: `Local ${n}` });
  await put(ids.away, 'team', { name: `Visita ${n}` });
  await put(ids.p1, 'player', { name: `Jugador A ${n}` });
  await put(ids.p2, 'player', { name: `Jugador B ${n}` });
  await put(ids.match, 'match', { competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away,
    startTime: new Date(Date.now() - startMinutesAgo * 60e3).toISOString(), status: 'SCHEDULED', events: [],
    provenance: { source: 'GOAL API', receivedAt: new Date(Date.now() - 7200e3).toISOString() } });
  for (const [kind, ext, id] of [['match', ids.ext, ids.match], ['team', ids.homeExt, ids.home], ['team', ids.awayExt, ids.away],
    ['player', `P1-${n}`, ids.p1], ['player', `P2-${n}`, ids.p2]]) {
    await db.query("insert into futbeat_private.provider_entities values('goal_api',$1,$2,$3)", [kind, ext, id]);
  }
  ids.uid = randomUUID();
  ids.device = (await db.query(`insert into futbeat_private.push_devices(user_id,installation_id,platform,transport,token,registered_at)
    values($1,$2,'android','test',$3,now()-interval '1 day') returning id`, [ids.uid, randomUUID(), `tok-nv-${n}`])).rows[0].id;
  if (follow) await db.query(`insert into futbeat_private.push_follows(user_id,entity_type,entity_id,created_at)
    values($1,$2,$3,now()-interval '1 day')`, [ids.uid, follow, follow === 'match' ? ids.match : ids.home]);
  return ids;
}
function fixture(s, { home = 0, away = 0, minute = 10, status = 'LIVE', events = [], cards = [], substitutions = [] } = {}) {
  const raw = { id: s.ext, matchStatus: status, matchElapsed: minute, homeTeamScore: home, awayTeamScore: away,
    homeTeam: { id: s.homeExt }, awayTeam: { id: s.awayExt }, events, cards, substitutions };
  const normalized = normalizeFixtureEvents(raw).map((e) => (e.providerEventId ? { ...e, eventKey: e.providerEventId } : e));
  const completeSections = fixtureEventSections(raw);
  const obs = { externalMatchId: s.ext, status, minute, score: { home, away }, events: normalized, completeSections, rawPayload: raw };
  obs.payloadHash = createHash('sha256').update(JSON.stringify([s.ext, status, minute, home, away,
    normalized.map((e) => e.eventKey), liveEventsContentSignature(normalized, completeSections)])).digest('hex');
  return obs;
}
const record = (db, obs) => db.query('select public.futbeat_record_live_batch($1,$2,$3) v', ['goal_api', tick(), JSON.stringify([obs])]).then((r) => r.rows[0].v);
const goalRow = (s, { id, time, player = 'P1' } = {}) => ({ ...(id ? { id } : {}), type: 'goal', time, homeScorerId: `${player}-${s.n}`, homeScorer: 'Nombre' });
const outbox = (db, uid) => db.query(`select id,notification_key,event_id,message,state,provider_receipt from futbeat_private.notification_outbox
  where user_id=$1 order by created_at,id`, [uid]).then((r) => r.rows);
const types = async (db, uid) => (await outbox(db, uid)).map((r) => r.message.type);
const rpc = (db) => async (name, args) => {
  const keys = Object.keys(args);
  return (await db.query('select public.' + name + '(' + keys.map((_, i) => '$' + (i + 1)).join(',') + ') as value', Object.values(args))).rows[0].value;
};
const dryRun = (db) => dispatchNotifications({ rpc: rpc(db), transport: createTransport(), mode: 'dry_run' });

test('match start: first sighting already LIVE pushes once ("Local vs Visita"); replay none; old match none', () => withDb(async (db) => {
  const s = await seed(db, { startMinutesAgo: 3 });
  await record(db, fixture(s, { minute: 2 }));
  let rows = await outbox(db, s.uid);
  assert.deepEqual(rows.map((r) => r.message.type), ['KICKOFF']);
  assert.equal(rows[0].message.title, `▶ Local ${s.n} vs Visita ${s.n}`);
  assert.equal(rows[0].message.body, 'Comienza el partido');
  await record(db, fixture(s, { minute: 3 }));
  await record(db, fixture(s, { minute: 4, status: 'HALFTIME' }));
  await record(db, fixture(s, { minute: 46 }));
  assert.deepEqual(await types(db, s.uid), ['KICKOFF'], 'replay / second half / halftime never push');

  const old = await seed(db, { startMinutesAgo: 75 });
  await record(db, fixture(old, { minute: 70 }));
  assert.deepEqual(await types(db, old.uid), [], 'first seen late in the game: no match start');
  const lateList = await seed(db, { startMinutesAgo: 40 });
  await record(db, fixture(lateList, { minute: 5 }));
  assert.deepEqual(await types(db, lateList.uid), [], 'received outside the kickoff window');
}));

test('approved types only: goal, red card, final push; halftime, yellow, VAR, missed penalty, team sub never', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s, { minute: 30 }));
  const goal = goalRow(s, { id: 'g1', time: '31' });
  const yellow = { id: 'c1', card: 'Yellow Card', time: '32', homePlayerId: `P1-${s.n}`, homeFault: 'N' };
  const red = { id: 'c2', card: 'Red Card', time: '33', homePlayerId: `P2-${s.n}`, homeFault: 'N' };
  const sub = { id: 's1', team: 'home', time: '34', substitutionPlayerId: `P1-${s.n}|P2-${s.n}` };
  const varRow = { id: 'v1', type: 'VAR', time: '35', info: 'Goal confirmed' };
  await record(db, fixture(s, { home: 1, minute: 31, events: [goal] }));
  await record(db, fixture(s, { home: 1, minute: 36, events: [goal, varRow], cards: [yellow, red], substitutions: [sub] }));
  await record(db, fixture(s, { home: 1, minute: 45, status: 'HALFTIME', events: [goal, varRow], cards: [yellow, red], substitutions: [sub] }));
  await record(db, fixture(s, { home: 1, minute: 90, status: 'FINISHED_PENDING_VERIFICATION', events: [goal, varRow], cards: [yellow, red], substitutions: [sub] }));
  assert.deepEqual((await types(db, s.uid)).sort(), ['FULL_TIME', 'GOAL', 'RED_CARD']);
  const goalMsg = (await outbox(db, s.uid)).find((r) => r.message.type === 'GOAL').message;
  assert.equal(goalMsg.body, `Local ${s.n} 1-0 Visita ${s.n}`);
  assert.equal(goalMsg.collapseKey, goalMsg.eventId);
}));

test('player alerts: comes on / goes off / red card with their switches; yellow card silent', () => withDb(async (db) => {
  const s = await seed(db, { follow: null });
  const fan1 = s.uid;
  await db.query("insert into futbeat_private.push_follows values($1,'player',$2,now()-interval '1 day')", [fan1, s.p1]);
  const fan2 = randomUUID();
  await db.query(`insert into futbeat_private.push_devices(user_id,installation_id,platform,transport,token,registered_at)
    values($1,$2,'android','test',$3,now()-interval '1 day')`, [fan2, randomUUID(), `tok-fan2-${fan2}`]);
  await db.query("insert into futbeat_private.push_follows values($1,'player',$2,now()-interval '1 day')", [fan2, s.p2]);
  await db.query('insert into futbeat_private.user_preferences(user_id,notify_player_sub_in) values($1,false)', [fan2]);
  await record(db, fixture(s, { minute: 50 }));
  const sub = { id: 's1', team: 'home', time: '51', substitutionPlayerId: `P1-${s.n}|P2-${s.n}` };
  const yellow = { id: 'c1', card: 'Yellow Card', time: '52', homePlayerId: `P1-${s.n}`, homeFault: 'N' };
  const red = { id: 'c2', card: 'Red Card', time: '53', homePlayerId: `P2-${s.n}`, homeFault: 'N' };
  await record(db, fixture(s, { minute: 53, cards: [yellow, red], substitutions: [sub] }));
  assert.deepEqual((await outbox(db, fan1)).map((r) => r.message.title.replace(/^\S+ \d+' /, '')), [`Sale Jugador A ${s.n}`]);
  assert.deepEqual((await outbox(db, fan2)).map((r) => r.message.type), ['RED_CARD'], 'comes on switched off; red card kept');
}));

test('goal annulled before send: the goal is cancelled and nothing else is sent', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { id: '9001', time: '19' })] }));
  await record(db, fixture(s, { home: 0, minute: 22, events: [] }));
  assert.deepEqual(await types(db, s.uid), ['GOAL']);
  const sent = await dryRun(db);
  assert.equal(sent.length, 0);
  assert.deepEqual((await outbox(db, s.uid)).map((r) => [r.message.type, r.state, r.provider_receipt]), [['GOAL', 'cancelled', 'retracted']]);
}));

test('goal annulled after send: exactly one GOAL_ANNULLED replacing the goal; correction twins never', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { id: '9001', time: '19' })] }));
  assert.equal((await dryRun(db)).length, 1);
  await record(db, fixture(s, { home: 0, minute: 22, events: [] }));
  await record(db, fixture(s, { home: 0, minute: 23, events: [] }));
  let rows = await outbox(db, s.uid);
  const annul = rows.filter((r) => r.message.type === 'GOAL_ANNULLED');
  assert.equal(annul.length, 1);
  const goal = rows.find((r) => r.message.type === 'GOAL');
  assert.equal(annul[0].notification_key, `annul:${goal.event_id}`);
  assert.equal(annul[0].event_id, null);
  assert.equal(annul[0].message.collapseKey, goal.message.collapseKey, 'replaces the goal notification');
  assert.match(annul[0].message.title, /Gol anulado/);
  assert.equal(annul[0].message.body, `Local ${s.n} 0-0 Visita ${s.n}`);
  const delivered = await dryRun(db);
  assert.deepEqual(delivered.map((r) => r.state), ['simulated']);

  // Correction (scorer changed, no provider id): retract + add, no annulment.
  const t = await seed(db);
  await record(db, fixture(t));
  await record(db, fixture(t, { home: 1, minute: 20, events: [goalRow(t, { time: '19' })] }));
  await dryRun(db);
  await record(db, fixture(t, { home: 1, minute: 22, events: [goalRow(t, { time: '19', player: 'P2' })] }));
  assert.deepEqual(await types(db, t.uid), ['GOAL'], 'a corrected goal never annuls nor pushes again');

  // Annulment of a goal whose push never left (notify off): nothing.
  const u = await seed(db);
  await db.query('insert into futbeat_private.user_preferences(user_id,notify_goals) values($1,false)', [u.uid]);
  await record(db, fixture(u));
  await record(db, fixture(u, { home: 1, minute: 20, events: [goalRow(u, { id: '9001', time: '19' })] }));
  await record(db, fixture(u, { home: 0, minute: 22, events: [] }));
  assert.deepEqual(await types(db, u.uid), []);
}));

test('an annulment whose goal is restored before dispatch is cancelled', () => withDb(async (db) => {
  const s = await seed(db);
  const g = goalRow(s, { id: '9001', time: '19' });
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20, events: [g] }));
  await dryRun(db);
  await record(db, fixture(s, { home: 0, minute: 22, events: [] }));
  await record(db, fixture(s, { home: 1, minute: 24, events: [g] }));
  assert.equal((await dryRun(db)).length, 0);
  const annul = (await outbox(db, s.uid)).find((r) => r.message.type === 'GOAL_ANNULLED');
  assert.deepEqual([annul.state, annul.provider_receipt], ['cancelled', 'restored']);
}));

test('send-time age: a match push older than matchPushMaxDelayMinutes and a lineup after kickoff+20 are cancelled', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { id: '9001', time: '19' })] }));
  await db.query("update futbeat_private.notification_outbox set created_at=now()-interval '11 minutes' where user_id=$1", [s.uid]);
  await db.query(`insert into futbeat_private.notification_outbox(notification_key,device_id,user_id,message)
    values($1,$2,$3,jsonb_build_object('type','LINEUP','title','t','matchId',$4::text,
      'subjectRefs',jsonb_build_array(jsonb_build_object('type','match','id',$4::text))))`,
    [`lineup:${s.match}:x:starter`, s.device, s.uid, s.match]);
  assert.equal((await dryRun(db)).length, 0);
  assert.deepEqual((await outbox(db, s.uid)).map((r) => [r.message.type, r.state, r.provider_receipt]),
    [['GOAL', 'cancelled', 'expired'], ['LINEUP', 'cancelled', 'expired']]);
  // A fresh one still goes out.
  await record(db, fixture(s, { home: 2, minute: 24, events: [goalRow(s, { id: '9001', time: '19' }), goalRow(s, { id: '9002', time: '23' })] }));
  assert.equal((await dryRun(db)).length, 1);
}));

test('dead token receipt disables the device and cancels its pending pushes; re-registering re-enables', () => withDb(async (db) => {
  const s = await seed(db);
  await record(db, fixture(s));
  await record(db, fixture(s, { home: 1, minute: 20, events: [goalRow(s, { id: '9001', time: '19' })] }));
  await record(db, fixture(s, { home: 2, minute: 21, events: [goalRow(s, { id: '9001', time: '19' }), goalRow(s, { id: '9002', time: '21' })] }));
  const dead = { send: async () => ({ state: 'failed', receipt: 'FCM_UNREGISTERED' }) };
  const results = await dispatchNotifications({ rpc: rpc(db), transport: dead, batchSize: 1, maxBatches: 1 });
  assert.equal(results.length, 1);
  const device = (await db.query('select enabled,disabled_reason from futbeat_private.push_devices where id=$1', [s.device])).rows[0];
  assert.deepEqual(device, { enabled: false, disabled_reason: 'FCM_UNREGISTERED' });
  assert.deepEqual((await outbox(db, s.uid)).map((r) => r.state), ['failed', 'cancelled']);
  // An ordinary failure never disables.
  const t = await seed(db);
  await record(db, fixture(t));
  await record(db, fixture(t, { home: 1, minute: 20, events: [goalRow(t, { id: '9001', time: '19' })] }));
  await dispatchNotifications({ rpc: rpc(db), transport: { send: async () => ({ state: 'failed', receipt: 'FCM_HTTP_400' }) } });
  assert.equal((await db.query('select enabled from futbeat_private.push_devices where id=$1', [t.device])).rows[0].enabled, true);
}));

test('shared phone: registering a token owned by another user moves it; profile v3 partial update', () => withDb(async (db) => {
  await db.exec("create schema auth; create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;");
  const as = (uid) => db.query("select set_config('request.jwt.claim.sub',$1,false)", [uid]);
  const a = randomUUID(), b = randomUUID(), instA = randomUUID(), instB = randomUUID();
  await as(a);
  const da = (await db.query("select public.futbeat_register_push($1,'android','fcm','shared-token',true) id", [instA])).rows[0].id;
  await as(b);
  const db2 = (await db.query("select public.futbeat_register_push($1,'android','fcm','shared-token',true) id", [instB])).rows[0].id;
  const rows = (await db.query('select id,user_id,token,enabled,disabled_reason from futbeat_private.push_devices where id in ($1,$2)', [da, db2])).rows;
  const byId = Object.fromEntries(rows.map((r) => [r.id, r]));
  assert.equal(byId[db2].user_id, b);
  assert.equal(byId[db2].token, 'shared-token');
  assert.equal(byId[da].enabled, false);
  assert.equal(byId[da].disabled_reason, 'token_moved');
  assert.notEqual(byId[da].token, 'shared-token');
  // Same user, same installation, new token: one row, re-enabled.
  await as(a);
  const again = (await db.query("select public.futbeat_register_push($1,'android','fcm','fresh-token',true) id", [instA])).rows[0].id;
  assert.equal(again, da);
  assert.deepEqual((await db.query('select enabled,disabled_reason from futbeat_private.push_devices where id=$1', [da])).rows[0], { enabled: true, disabled_reason: null });

  // Profile v3.
  const profile = (await db.query(`select public.futbeat_sync_user_profile_v3('{"notifyRedCards":false,"notifyPlayerSubIn":false,"hourFormat":"24h","unknownKey":1}'::jsonb) v`)).rows[0].v;
  assert.equal(profile.preferences.notifyRedCards, false);
  assert.equal(profile.preferences.notifyCards, false, 'red cards also drive the legacy cards switch');
  assert.equal(profile.preferences.notifyPlayerSubIn, false);
  assert.equal(profile.preferences.notifyPlayerSubOut, true);
  assert.equal(profile.preferences.notifyGoalAnnulled, true);
  assert.equal(profile.preferences.notifyGoals, true, 'absent keys never change');
  assert.equal(profile.preferences.hourFormat, '24h');
  await assert.rejects(db.query(`select public.futbeat_sync_user_profile_v3('{"notifyGoals":"no"}'::jsonb)`), /Invalid preference/);
  await assert.rejects(db.query(`select public.futbeat_sync_user_profile_v3('{"hourFormat":"13h"}'::jsonb)`), /Invalid hour format/);
  const read = (await db.query('select public.futbeat_read_user_profile() v')).rows[0].v;
  assert.equal(read.preferences.notifyPlayerStarter, true);
}));

test('new helpers are private; the profile RPC is for signed-in users only', () => withDb(async (db) => {
  const rows = (await db.query(`select n.nspname||'.'||p.proname f,has_function_privilege('anon',p.oid,'execute') anon,
      has_function_privilege('authenticated',p.oid,'execute') auth,has_function_privilege('service_role',p.oid,'execute') svc
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where p.proname in ('enqueue_goal_annulled','goal_annulled_push_trigger','kickoff_push_is_fresh','futbeat_sync_user_profile_v3',
      'futbeat_claim_notifications','futbeat_finish_notification')`)).rows;
  const by = Object.fromEntries(rows.map((r) => [r.f, r]));
  for (const f of ['futbeat_private.enqueue_goal_annulled', 'futbeat_private.goal_annulled_push_trigger', 'futbeat_private.kickoff_push_is_fresh'])
    assert.ok(!by[f].anon && !by[f].auth, f);
  assert.ok(by['public.futbeat_sync_user_profile_v3'].auth && !by['public.futbeat_sync_user_profile_v3'].anon);
  for (const f of ['public.futbeat_claim_notifications', 'public.futbeat_finish_notification'])
    assert.ok(by[f].svc && !by[f].auth && !by[f].anon, f);
}));
