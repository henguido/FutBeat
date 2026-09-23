import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// Match detail on user demand + central quota manager. Local PGlite only: no
// provider, no pg_net (wake-ups record 'unavailable').

let seq = 0;
async function seedMatch(db, { status = 'SCHEDULED', startOffsetMinutes = 60, cachedMinutesAgo = null } = {}) {
  const n = ++seq;
  const comp = `fb_comp_ud_${n}`, home = `fb_team_ud_h${n}`, away = `fb_team_ud_a${n}`, match = `fb_match_ud_${n}`;
  const start = new Date(Date.now() + startOffsetMinutes * 60000).toISOString();
  for (const [id, kind, payload] of [
    [comp, 'competition', { id: comp, name: `Liga ${n}` }],
    [home, 'team', { id: home, name: `Home ${n}` }],
    [away, 'team', { id: away, name: `Away ${n}` }],
    [match, 'match', { id: match, competitionId: comp, homeTeamId: home, awayTeamId: away, startTime: start,
      status, events: [], statistics: [] }],
  ]) await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [`ud-${n}`, match]);
  if (cachedMinutesAgo != null) {
    await db.query(`insert into futbeat_private.match_detail_cache values($1,'goal_api',$2,now()-make_interval(mins=>$3),'{}')`,
      [match, `ud-${n}`, cachedMinutesAgo]);
  }
  return match;
}

const open = (db, match) => db.query('select public.futbeat_request_match_detail($1) v', [match]).then((r) => r.rows[0].v);
const reserve = (db) => db.query("select public.futbeat_reserve_match_detail_call('test') v").then((r) => r.rows[0].v);
const complete = (db, id) => db.query("select public.futbeat_complete_provider_call($1,'SUCCEEDED',null,200,null,'{}')", [id]);
const remaining = (db, value) => db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,
  reserved_at,completed_at,status,provider_remaining) values('goal_api','live-goal','test',now(),now(),'SUCCEEDED',$1)`, [value]);
const metric = (db, name) => db.query('select coalesce(sum(value),0)::int n from futbeat_private.demand_metrics where metric=$1',
  [name]).then((r) => r.rows[0].n);
const detailCalls = (db) => db.query("select count(*)::int n from futbeat_private.provider_call_ledger where call_kind='match-detail'")
  .then((r) => r.rows[0].n);

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

test('fresh complete detail: opening Match Center costs 0 provider calls (cache hit)', () => withDb(async (db) => {
  const match = await seedMatch(db, { status: 'VERIFIED', startOffsetMinutes: -600, cachedMinutesAgo: 60 });
  for (let i = 0; i < 5; i++) await open(db, match);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.match_detail_requests')).rows[0].n, 0);
  assert.equal((await reserve(db)).reason, 'no_detail_due');
  assert.equal(await detailCalls(db), 0);
  assert.equal(await metric(db, 'match_detail_cache_hits'), 5);
}));

test('missing detail: one user demand, immediate wake-up; 100 concurrent opens -> one reservation', () => withDb(async (db) => {
  const match = await seedMatch(db, { status: 'SCHEDULED', startOffsetMinutes: 30 });
  const detail = await open(db, match);
  assert.ok(detail.requestedAt, 'app sees pending');
  const wake = (await db.query("select * from futbeat_private.worker_wakeups where trigger='demand'")).rows[0];
  assert.equal(wake.wake_count, 1);
  assert.equal(wake.last_result, 'unavailable');
  await Promise.all(Array.from({ length: 99 }, () => open(db, match)));
  const request = (await db.query('select source,request_count::int n from futbeat_private.match_detail_requests')).rows;
  assert.deepEqual(request, [{ source: 'user', n: 100 }]);
  assert.equal(await metric(db, 'match_detail_user_demands'), 1);
  assert.equal(await metric(db, 'deduped_requests'), 99);
  // Debounced: 99 more opens did not post 99 wake-ups.
  assert.equal((await db.query("select wake_count::int n from futbeat_private.worker_wakeups")).rows[0].n, 1);
  const results = await Promise.all(Array.from({ length: 100 }, () => reserve(db)));
  assert.equal(results.filter((r) => r.allowed).length, 1);
  assert.equal(await detailCalls(db), 1);
}));

test('priority: LIVE opened by user > system LIVE > upcoming user > historical user > prefetch', () => withDb(async (db) => {
  const prefetch = await seedMatch(db, { status: 'SCHEDULED', startOffsetMinutes: 20 });
  await db.query("insert into futbeat_private.match_detail_requests(match_id,requested_at,expires_at,request_count) values($1,now(),now()+interval '10 minutes',1)", [prefetch]);
  const historical = await seedMatch(db, { status: 'VERIFIED', startOffsetMinutes: -3000 });
  const upcoming = await seedMatch(db, { status: 'SCHEDULED', startOffsetMinutes: 90 });
  const systemLive = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -30 });
  await db.query("insert into futbeat_private.match_detail_requests(match_id,requested_at,expires_at,request_count) values($1,now(),now()+interval '10 minutes',1)", [systemLive]);
  const userLive = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -50 });
  for (const m of [historical, upcoming, userLive]) await open(db, m);
  const order = [];
  for (let i = 0; i < 5; i++) {
    const r = await reserve(db);
    assert.equal(r.allowed, true);
    order.push([r.matchId, r.quotaClass, r.priority]);
    await complete(db, r.reservationId);
    // Completed reservations free the match; drop its request so the next one surfaces.
    await db.query('delete from futbeat_private.match_detail_requests where match_id=$1', [r.matchId]);
  }
  assert.deepEqual(order, [
    [userLive, 'live', 1], [systemLive, 'live', 2], [upcoming, 'user_high', 3], [historical, 'user', 4],
    [prefetch, 'coverage', 5],
  ]);
}));

test('quota bands: high allows all, medium user+coverage, low only high-priority user + LIVE, critical LIVE only', () => withDb(async (db) => {
  const decide = async (kind, cls) => (await db.query("select futbeat_private.quota_decision('goal_api',$1,$2) v", [kind, cls])).rows[0].v;
  const matrix = async () => {
    const out = {};
    for (const cls of ['live', 'results', 'user_high', 'user', 'coverage', 'bootstrap']) {
      out[cls] = (await decide('match-detail', cls)).allowed;
    }
    return out;
  };
  // Unknown remaining (no reading yet today): allowed; per-kind safety caps still apply.
  assert.deepEqual(Object.values(await matrix()), [true, true, true, true, true, true]);
  await remaining(db, 900);
  assert.equal((await decide('match-detail', 'bootstrap')).band, 'abundant');
  assert.deepEqual(await matrix(), { live: true, results: true, user_high: true, user: true, coverage: true, bootstrap: true });
  await db.query("update futbeat_private.provider_call_ledger set provider_remaining=450");
  assert.deepEqual(await matrix(), { live: true, results: true, user_high: true, user: true, coverage: true, bootstrap: false });
  await db.query("update futbeat_private.provider_call_ledger set provider_remaining=200");
  assert.deepEqual(await matrix(), { live: true, results: true, user_high: true, user: false, coverage: false, bootstrap: false });
  await db.query("update futbeat_private.provider_call_ledger set provider_remaining=100");
  assert.equal((await decide('match-detail', 'live')).band, 'critical');
  assert.deepEqual(await matrix(), { live: true, results: true, user_high: false, user: false, coverage: false, bootstrap: false });
  // Hard reserve: even LIVE/results stop at the floor; nothing else ever reaches it.
  await db.query("update futbeat_private.provider_call_ledger set provider_remaining=20");
  assert.deepEqual(await matrix(), { live: false, results: false, user_high: false, user: false, coverage: false, bootstrap: false });
}));

test('low budget: a LIVE match is still served while historical/prefetch demand waits', () => withDb(async (db) => {
  const historical = await seedMatch(db, { status: 'VERIFIED', startOffsetMinutes: -3000 });
  await open(db, historical);
  await remaining(db, 120);
  const denied = await reserve(db);
  assert.equal(denied.allowed, false);
  assert.equal(denied.reason, 'provider_remaining_reserve');
  const live = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
  await open(db, live);
  const served = await reserve(db);
  assert.deepEqual([served.allowed, served.matchId, served.quotaClass], [true, live, 'live']);
}));

test('squads use the central manager; per-kind safety cap stops a runaway loop', () => withDb(async (db) => {
  await db.query(`insert into futbeat_private.entities values('fb_team_ud_sq','team','{"id":"fb_team_ud_sq","name":"Sq"}')`);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','team','ud-sq','fb_team_ud_sq')");
  await remaining(db, 250);
  const tight = (await db.query("select public.futbeat_reserve_goal_squad_call('fb_team_ud_sq','ud-sq','test') v")).rows[0].v;
  assert.deepEqual([tight.allowed, tight.reason, tight.class], [false, 'provider_remaining_reserve', 'coverage']);
  await db.query("update futbeat_private.provider_call_ledger set provider_remaining=800");
  const ok = (await db.query("select public.futbeat_reserve_goal_squad_call('fb_team_ud_sq','ud-sq','test') v")).rows[0].v;
  assert.equal(ok.allowed, true);
}));

test('security: reservation, quota and wake helpers are not callable by anon/authenticated', () => withDb(async (db) => {
  const can = async (role, fn) => (await db.query("select has_function_privilege($1,$2,'EXECUTE') ok", [role, fn])).rows[0].ok;
  for (const role of ['anon', 'authenticated']) {
    for (const fn of ['public.futbeat_reserve_match_detail_call(text)', 'public.futbeat_request_match_detail(text)',
      'public.futbeat_provider_quota_status(text)', 'public.futbeat_reserve_goal_squad_call(text,text,text)']) {
      assert.equal(await can(role, fn), false, `${role} ${fn}`);
    }
  }
  for (const role of ['anon', 'authenticated', 'service_role']) {
    for (const fn of ['futbeat_private.quota_decision(text,text,text)', 'futbeat_private.wake_provider_worker(text)',
      'futbeat_private.bump_metric(text,bigint)', 'futbeat_private.lock_provider_quota(text)',
      'futbeat_private.match_detail_due(text,timestamp with time zone)']) {
      assert.equal(await can(role, fn), false, `${role} ${fn}`);
    }
  }
  for (const table of ['provider_quota_policy', 'runtime_settings', 'demand_metrics', 'worker_wakeups']) {
    assert.equal((await db.query("select has_table_privilege('anon',$1,'SELECT') ok", [`futbeat_private.${table}`])).rows[0].ok, false);
  }
}));
