import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { openDatabase } from '../storage/database.mjs';

// Issue #111: GOAL LIVE is a protected class of the central quota manager and
// overdue SCHEDULED matches keep the global LIVE poll running, while the clock
// never turns a match LIVE by itself. Synthetic data only; no provider calls.

let seq = 0;
// The calendar entry was ingested before the LIVE poll (as in production).
async function seed(db, { minutes = -10, status = 'SCHEDULED', receivedMinutesAgo = 120 } = {}) {
  const n = ++seq;
  const ids = { comp: `fb_comp_lq${n}`, home: `fb_team_lq${n}h`, away: `fb_team_lq${n}a`, match: `fb_match_lq${n}`, ext: `lq-${n}` };
  const start = new Date(Date.now() + minutes * 60000).toISOString();
  for (const [id, kind, payload] of [
    [ids.comp, 'competition', { id: ids.comp, name: `Comp ${n}` }],
    [ids.home, 'team', { id: ids.home, name: `H ${n}` }],
    [ids.away, 'team', { id: ids.away, name: `A ${n}` }],
    [ids.match, 'match', { id: ids.match, competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away, status,
      startTime: start, events: [], statistics: [],
      provenance: { receivedAt: new Date(Date.now() - receivedMinutesAgo * 60000).toISOString() } }],
  ]) await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [ids.ext, ids.match]);
  return { ...ids, start };
}
// A provider observation, recorded exactly as the LIVE worker does.
async function observe(db, m, status, { minute = null, home = 0, away = 0, receivedMinutesAgo = 0 } = {}) {
  const observation = { externalMatchId: m.ext, status, minute, score: { home, away }, events: [], startTime: m.start };
  observation.payloadHash = createHash('sha256').update(JSON.stringify([m.ext, status, minute, home, away, receivedMinutesAgo])).digest('hex');
  await db.query('select public.futbeat_record_live_batch($1,$2,$3)',
    ['goal_api', new Date(Date.now() - receivedMinutesAgo * 60000).toISOString(), JSON.stringify([observation])]);
}
const shown = (db, m) => db.query(`select futbeat_private.match_read_model(payload)->>'status' s
  from futbeat_private.entities where id=$1`, [m.match]).then((r) => r.rows[0].s);
const reserve = (db) => db.query("select public.futbeat_reserve_goal_live_call('test') v").then((r) => r.rows[0].v);
const need = (db) => db.query('select futbeat_private.live_poll_need() v').then((r) => r.rows[0].v);
const liveCalls = (db) => db.query("select count(*)::int n from futbeat_private.provider_call_ledger where call_kind='live-goal'")
  .then((r) => r.rows[0].n);
// Latest provider-reported remaining (a non-LIVE kind, so it does not touch
// the LIVE interval or its safety cap).
const remaining = (db, n) => db.query(`insert into futbeat_private.provider_call_ledger
  (provider,call_kind,trigger_source,status,provider_remaining,reserved_at,completed_at)
  values('goal_api','global-ingest','test','SUCCEEDED',$1,now(),now())`, [n]);
const clearLive = (db) => db.query("delete from futbeat_private.provider_call_ledger where call_kind='live-goal'");

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

// ---------------------------------------------------------------------------
// Quota
// ---------------------------------------------------------------------------
test('quota: LIVE is allowed at remaining 900, 500, 150 and 21; stopped at the central floor (20)', () => withDb(async (db) => {
  await seed(db, { minutes: -30, status: 'LIVE' });
  for (const value of [900, 500, 150, 21]) {
    await clearLive(db);
    await remaining(db, value);
    const r = await reserve(db);
    assert.equal(r.allowed, true, `remaining ${value}`);
    assert.equal(r.reserve, 20, 'the reserve is the central live floor');
  }
  await clearLive(db);
  await remaining(db, 20);
  const stopped = await reserve(db);
  assert.equal(stopped.allowed, false);
  assert.equal(stopped.reason, 'provider_remaining_reserve');
  assert.equal(await liveCalls(db), 0, 'a refusal spends nothing');
  // One source of truth: changing the central floor moves the LIVE reserve.
  await db.query(`update futbeat_private.provider_quota_policy set class_floors=class_floors||'{"live":10}' where provider='goal_api'`);
  assert.equal((await reserve(db)).allowed, true);
}));

test('quota: heavy match-detail use never cuts LIVE while remaining allows the live class', () => withDb(async (db) => {
  await seed(db, { minutes: -30, status: 'LIVE' });
  await db.exec(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status)
    select 'goal_api','match-detail','test','SUCCEEDED' from generate_series(1,900)`);
  await remaining(db, 60);
  const r = await reserve(db);
  assert.equal(r.allowed, true);
  assert.equal(r.pageBudget, 10);
  assert.equal(r.usedToday, 901 + r.pageBudget, 'total units (in-flight page budget included) are reported, not used as a cutoff');
}));

test('quota: the live-goal safety cap is independent of match-detail', () => withDb(async (db) => {
  await seed(db, { minutes: -30, status: 'LIVE' });
  await remaining(db, 900);
  await db.exec(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,reserved_at)
    select 'goal_api','live-goal','test','SUCCEEDED',now()-interval '10 minutes' from generate_series(1,400)`);
  const capped = await reserve(db);
  assert.equal(capped.allowed, false);
  assert.equal(capped.reason, 'kind_daily_cap');
  assert.equal(capped.safetyCap, 400);
  // The match-detail cap is untouched by LIVE use.
  const detail = (await db.query("select futbeat_private.quota_decision('goal_api','match-detail','user') v")).rows[0].v;
  assert.equal(detail.allowed, true);
  assert.equal(detail.usedToday, 0);
}));

test('quota: unknown remaining has no blind cutoff for LIVE (only its safety cap)', () => withDb(async (db) => {
  await seed(db, { minutes: -30, status: 'LIVE' });
  await db.exec(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status)
    select 'goal_api','match-detail','test','SUCCEEDED' from generate_series(1,960)`);
  const r = await reserve(db);
  assert.equal(r.allowed, true, 'the legacy 950-call fallback is gone');
  assert.equal(r.band, 'unknown');
}));

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------
test('lifecycle: SCHEDULED before kickoff stays SCHEDULED and outside the LIVE window', () => withDb(async (db) => {
  const m = await seed(db, { minutes: 60 });
  assert.equal(await shown(db, m), 'SCHEDULED');
  assert.equal((await need(db)).active, 0);
  assert.equal((await reserve(db)).reason, 'outside_live_window');
}));

test('lifecycle: just after kickoff an unconfirmed SCHEDULED is an overdue recovery candidate, never LIVE by clock', () => withDb(async (db) => {
  const m = await seed(db, { minutes: -2 });
  const n = await need(db);
  assert.equal(n.overdueScheduled, 1);
  assert.equal(await shown(db, m), 'SCHEDULED', 'the clock alone never makes it LIVE');
  const late = await seed(db, { minutes: -75 });
  assert.equal((await need(db)).overdueScheduled, 2);
  assert.equal(await shown(db, late), 'SCHEDULED');
  const r = await reserve(db);
  assert.equal(r.allowed, true);
  assert.equal(r.overdueScheduled, 2);
}));

test('lifecycle: SCHEDULED -> LIVE -> HALFTIME -> LIVE -> FINISHED_PENDING_VERIFICATION from provider evidence', () => withDb(async (db) => {
  const m = await seed(db, { minutes: -60 });
  await observe(db, m, 'LIVE', { minute: 20, home: 1, receivedMinutesAgo: 4 });
  assert.equal(await shown(db, m), 'LIVE');
  assert.equal((await need(db)).live, 1);
  await observe(db, m, 'HALFTIME', { minute: 45, home: 1, receivedMinutesAgo: 3 });
  assert.equal(await shown(db, m), 'HALFTIME');
  await observe(db, m, 'LIVE', { minute: 50, home: 1, receivedMinutesAgo: 2 });
  assert.equal(await shown(db, m), 'LIVE');
  await observe(db, m, 'EXTRA_TIME', { minute: 95, home: 1, away: 1, receivedMinutesAgo: 1 });
  assert.equal(await shown(db, m), 'EXTRA_TIME');
  await observe(db, m, 'FINISHED_PENDING_VERIFICATION', { minute: 120, home: 2, away: 1 });
  assert.equal(await shown(db, m), 'FINISHED_PENDING_VERIFICATION');
  const n = await need(db);
  assert.equal(n.terminal, 1);
  assert.equal(n.active, 0, 'a finished match no longer drives the LIVE poll');
}));

test('lifecycle: an old LIVE observation never reopens a terminal match', () => withDb(async (db) => {
  const m = await seed(db, { minutes: -130 });
  await observe(db, m, 'FINISHED_PENDING_VERIFICATION', { minute: 90, home: 2, away: 1, receivedMinutesAgo: 1 });
  // An older LIVE batch is rejected outright by the ingest guard...
  await assert.rejects(observe(db, m, 'LIVE', { minute: 70, home: 1, away: 1, receivedMinutesAgo: 20 }), /Stale live batch/);
  assert.equal(await shown(db, m), 'FINISHED_PENDING_VERIFICATION');
  // ...and an old LIVE provider observation stored for the match (e.g. from
  // another path) does not override the final in the read model either.
  await db.query(`insert into futbeat_private.provider_observations(provider,external_match_id,canonical_match_id,
    received_at,status,minute,home_score,away_score,events,payload_hash,raw_payload)
    values('goal_api',$1,$2,now()-interval '25 minutes','LIVE',70,1,1,'[]',md5('old')||md5('live'),'{}')`, [m.ext, m.match]);
  assert.equal(await shown(db, m), 'FINISHED_PENDING_VERIFICATION');
  assert.equal((await need(db)).active, 0);
}));

for (const status of ['POSTPONED', 'CANCELLED']) {
  test(`lifecycle: ${status} is never turned LIVE and does not drive the LIVE poll`, () => withDb(async (db) => {
    const m = await seed(db, { minutes: -40, status });
    assert.equal(await shown(db, m), status);
    const n = await need(db);
    assert.equal(n.active, 0);
    assert.equal(n.overdueScheduled, 0);
    assert.equal((await reserve(db)).reason, 'outside_live_window');
  }));
}

test('lifecycle: stale LIVE expires (presentation after 15 min, live evidence after liveMaxHours)', () => withDb(async (db) => {
  // Canonical LIVE whose evidence is 30 minutes old: not shown as LIVE.
  const stale = await seed(db, { minutes: -60, status: 'LIVE', receivedMinutesAgo: 30 });
  assert.equal(await shown(db, stale), 'SCHEDULED');
  // Still inside the window: keep polling to learn its real state.
  assert.equal((await need(db)).active, 1);
  // LIVE status 5 h after kickoff: not live evidence, outside the window.
  await db.query('delete from futbeat_private.provider_entities where canonical_id=$1', [stale.match]);
  const ancient = await seed(db, { minutes: -300, status: 'LIVE', receivedMinutesAgo: 200 });
  assert.equal((await db.query('select futbeat_private.match_detail_status($1) s', [ancient.match])).rows[0].s, null);
  assert.equal(await shown(db, ancient), 'SCHEDULED');
  assert.equal((await need(db)).active, 0);
}));

// ---------------------------------------------------------------------------
// Recovery
// ---------------------------------------------------------------------------
test('recovery: 3 h after kickoff is still recoverable with liveMaxHours=4; outside it is not', () => withDb(async (db) => {
  await seed(db, { minutes: -180 });
  assert.equal((await need(db)).overdueScheduled, 1);
  assert.equal((await reserve(db)).allowed, true);
  await db.query("delete from futbeat_private.provider_entities where kind='match'");
  await clearLive(db);
  await seed(db, { minutes: -300 });
  assert.equal((await need(db)).active, 0);
  assert.equal((await reserve(db)).reason, 'outside_live_window');
  // The window is central policy, not a fixed number.
  await db.query(`update futbeat_private.provider_quota_policy set freshness=freshness||'{"liveMaxHours":6}' where provider='goal_api'`);
  assert.equal((await need(db)).overdueScheduled, 1);
}));

test('recovery: many overdue matches are served by one global poll, not one call per match', () => withDb(async (db) => {
  for (let i = 0; i < 12; i++) await seed(db, { minutes: -20 - i * 10 });
  const r = await reserve(db);
  assert.equal(r.allowed, true);
  assert.equal(r.overdueScheduled, 12);
  assert.equal((await reserve(db)).reason, 'min_interval');
  assert.equal(await liveCalls(db), 1);
  const meta = (await db.query("select metadata from futbeat_private.provider_call_ledger where call_kind='live-goal'")).rows[0].metadata;
  assert.equal(meta.overdueScheduled, 12);
}));

test('recovery: unmapped matches do not drive the GOAL LIVE poll', () => withDb(async (db) => {
  const m = await seed(db, { minutes: -20 });
  await db.query('delete from futbeat_private.provider_entities where canonical_id=$1', [m.match]);
  assert.equal((await need(db)).active, 0);
}));

// ---------------------------------------------------------------------------
// Cron cadence
// ---------------------------------------------------------------------------
test('cron: nothing near -> no reservation; upcoming in the lead window -> reserve; min interval holds', () => withDb(async (db) => {
  assert.equal((await reserve(db)).reason, 'outside_live_window');
  assert.equal(await liveCalls(db), 0);
  await seed(db, { minutes: 3 });
  const first = await reserve(db);
  assert.equal(first.allowed, true);
  assert.equal(first.upcomingMatches, 1);
  const again = await reserve(db);
  assert.equal(again.reason, 'min_interval');
  assert.ok(again.retryAfterSeconds > 0 && again.retryAfterSeconds <= 240);
  // After the configured interval (five-minute cron jitter tolerated).
  await db.query("update futbeat_private.provider_call_ledger set reserved_at=now()-interval '241 seconds' where call_kind='live-goal'");
  assert.equal((await reserve(db)).allowed, true);
  assert.equal(await liveCalls(db), 2);
}));

test('security: LIVE need and diagnostics are service-only', () => withDb(async (db) => {
  for (const role of ['anon', 'authenticated']) {
    for (const fn of ['public.futbeat_live_poll_status()', 'public.futbeat_reserve_goal_live_call(text)']) {
      assert.equal((await db.query('select has_function_privilege($1,$2,\'EXECUTE\') ok', [role, fn])).rows[0].ok, false, `${role} ${fn}`);
    }
  }
  const status = (await db.query('select public.futbeat_live_poll_status() v')).rows[0].v;
  assert.ok(status.need && status.quota && status.minIntervalSeconds === 240);
}));
