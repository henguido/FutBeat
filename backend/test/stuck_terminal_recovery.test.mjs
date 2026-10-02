import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { openDatabase } from '../storage/database.mjs';
import { goalOk, worker } from './helpers/worker_harness.mjs';

// Stuck non-terminal matches (20261002110000): a match seen in play whose
// final never arrived (capped bulk lists, recovery expired before quota, the
// results lane gave up on its date) is offered to the provider again, bounded:
// one more results answer for its date, then one detail request per match.
// Nothing here writes a status or a score. Generic fixtures only.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
let seq = 0;
const iso = (ms) => new Date(ms).toISOString();
const utcDate = (ms) => iso(ms).slice(0, 10);
const put = (db, id, kind, payload) => db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);

// A mapped calendar match, optionally recorded in play by the live pipeline.
async function match(db, { kickoff, live = 'LIVE', liveAfterMinutes = 60 } = {}) {
  const n = ++seq;
  const ids = { n, comp: `fb_comp_st${n}`, home: `fb_team_sth${n}`, away: `fb_team_sta${n}`, match: `fb_match_st${n}`, ext: `goal-st-${n}`, kickoff };
  await put(db, ids.comp, 'competition', { name: `Liga ${n}` });
  await put(db, ids.home, 'team', { name: `Local ${n}` });
  await put(db, ids.away, 'team', { name: `Visita ${n}` });
  await put(db, ids.match, 'match', { competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away,
    startTime: iso(kickoff), status: 'SCHEDULED', events: [], statistics: [],
    provenance: { source: 'GOAL API', externalId: ids.ext, receivedAt: iso(kickoff - 86400e3), verificationStatus: 'PROVISIONAL' } });
  for (const [kind, ext, id] of [['match', ids.ext, ids.match], ['team', `STH${n}`, ids.home], ['team', `STA${n}`, ids.away]]) {
    await db.query("insert into futbeat_private.provider_entities values('goal_api',$1,$2,$3)", [kind, ext, id]);
  }
  if (live) await observe(db, ids, live, kickoff + liveAfterMinutes * 60e3);
  return ids;
}
async function observe(db, ids, status, at, { home = 1, away = 1 } = {}) {
  const raw = { apiId: ids.ext, matchStatus: status, matchElapsed: 70, homeTeamScore: home, awayTeamScore: away,
    homeTeam: { id: `STH${ids.n}` }, awayTeam: { id: `STA${ids.n}` }, events: [], cards: [], substitutions: [] };
  const obs = { externalMatchId: ids.ext, status, minute: 70, score: { home, away }, events: [], rawPayload: raw, source: 'live-list',
    payloadHash: createHash('sha256').update(JSON.stringify([ids.ext, status, at, home, away])).digest('hex') };
  await db.query('select public.futbeat_record_live_batch($1,$2,$3)', ['goal_api', iso(at), JSON.stringify([obs])]);
}
const sweep = (db) => db.query('select futbeat_private.sweep_stuck_terminal(true) v').then((r) => r.rows[0].v);
const canonical = (db, id) => db.query("select payload->>'status' status,payload->'score' score from futbeat_private.entities where id=$1", [id]).then((r) => r.rows[0]);
const readStatus = (db, id) => db.query('select futbeat_private.match_read_model(payload)->>\'status\' s from futbeat_private.entities where id=$1', [id]).then((r) => r.rows[0].s);
const attempts = (db, date) => db.query("select attempt_count::int n from futbeat_private.results_date_attempts where provider='goal_api' and provider_date=$1", [date]).then((r) => r.rows[0]?.n);
const demand = (db, date) => db.query("select count(*)::int n from futbeat_private.results_date_user_demand where provider='goal_api' and provider_date=$1", [date]).then((r) => r.rows[0].n);
const stuckRows = (db) => db.query("select canonical_match_id m,state,attempts,next_attempt_at from futbeat_private.live_terminal_recovery where reason='stuck_nonterminal' order by canonical_match_id").then((r) => r.rows);
async function gaveUp(db, date) {
  await db.query(`insert into futbeat_private.results_date_attempts(provider,provider_date,last_attempt_at,attempt_count,last_outcome,next_retry_at,updated_at)
    values('goal_api',$1,now()-interval '2 days',4,'PARTIAL',now()-interval '1 hour',now()-interval '2 days')
    on conflict(provider,provider_date) do update set attempt_count=4,next_retry_at=now()-interval '1 hour',updated_at=now()-interval '2 days'`, [date]);
}
async function served(db, date, at) {
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,metadata)
    values('goal_api','results-date','test',$2,$2,'SUCCEEDED',jsonb_build_object('date',$1::text,'results',500))`, [date, at]);
}
const settings = (db, values) => db.query("update futbeat_private.provider_quota_policy set freshness=freshness||$1::jsonb where provider='goal_api'", [JSON.stringify(values)]);
// The latest provider-reported remaining budget (what the recovery guard reads).
const budget = (db, remaining) => db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,provider_remaining)
  values('goal_api','live-goal','test',now(),now(),'SUCCEEDED',$1)`, [remaining]);

test('a date the results lane gave up on while it holds matches seen in play gets exactly one more results answer per reopen', () => withDb(async (db) => {
  const kickoff = Date.now() - 3 * 86400e3;
  const date = utcDate(kickoff);
  const stuck = await match(db, { kickoff });
  const neverLive = await match(db, { kickoff: kickoff + 60e3, live: null });
  await gaveUp(db, date);
  await budget(db, 700);

  // Before: the local repair closes the date (attempts >= 4, > 48 h): no call.
  const before = (await db.query("select futbeat_private.reserve_goal_results_date('test') v")).rows[0].v;
  assert.equal(before.allowed, false, JSON.stringify(before));
  assert.equal(before.reason, 'reconciled_locally');

  const first = await sweep(db);
  assert.equal(first.stuck, 1, 'only the match seen in play is chased');
  assert.deepEqual(first.reopenedDates.map((d) => d.date), [date]);
  assert.equal(await attempts(db, date), 3, 'one attempt below the give-up threshold');
  assert.equal(await demand(db, date), 1);
  assert.deepEqual(first.detailRequests, [], 'the cheap results answer comes first');

  const plan = (await db.query("select futbeat_private.reserve_goal_results_date('test') v")).rows[0].v;
  assert.deepEqual([plan.allowed, plan.date, plan.userPriority], [true, date, true], JSON.stringify(plan));
  assert.equal(plan.attempt, 4, 'that answer is the last before the date closes again');

  // Nothing was written to the matches.
  for (const ids of [stuck, neverLive]) assert.deepEqual(await canonical(db, ids.match), { status: 'SCHEDULED', score: null });

  // Not again within the reopen gap, at most twice per date.
  await gaveUp(db, date);
  assert.deepEqual((await sweep(db)).reopenedDates, []);
  await db.query("update futbeat_private.stuck_results_reopen set last_reopened_at=now()-interval '13 hours'");
  await db.query('delete from futbeat_private.results_date_user_demand');
  assert.deepEqual((await sweep(db)).reopenedDates.map((d) => d.date), [date]);
  await gaveUp(db, date);
  await db.query("update futbeat_private.stuck_results_reopen set last_reopened_at=now()-interval '13 hours'");
  await db.query('delete from futbeat_private.results_date_user_demand');
  assert.deepEqual((await sweep(db)).reopenedDates, [], 'reopen budget spent');
  assert.equal((await db.query('select reopen_count::int n from futbeat_private.stuck_results_reopen')).rows[0].n, 2);
}));

test('a date still worked by the normal results lane, in provider backoff, or already queued is never reopened', () => withDb(async (db) => {
  const kickoff = Date.now() - 2 * 86400e3;
  const date = utcDate(kickoff);
  await match(db, { kickoff });
  await budget(db, 700);
  await db.query(`insert into futbeat_private.results_date_attempts(provider,provider_date,attempt_count,last_outcome,next_retry_at,updated_at)
    values('goal_api',$1,2,'PARTIAL',now()-interval '1 hour',now()-interval '1 day')`, [date]);
  assert.deepEqual((await sweep(db)).reopenedDates, [], 'fewer than 4 attempts: the normal lane still owns it');
  await db.query("update futbeat_private.results_date_attempts set attempt_count=4,next_retry_at=now()+interval '3 hours'");
  assert.deepEqual((await sweep(db)).reopenedDates, [], 'provider backoff is respected');
  await db.query("update futbeat_private.results_date_attempts set next_retry_at=now()-interval '1 minute'");
  await db.query("insert into futbeat_private.results_date_user_demand(provider,provider_date,requested_at) values('goal_api',$1,now())", [date]);
  assert.deepEqual((await sweep(db)).reopenedDates, [], 'a waiting demand is not duplicated');
}));

test('a reopen never spends the user_high reserve (remaining minus in-flight reservations)', () => withDb(async (db) => {
  const kickoff = Date.now() - 3 * 86400e3;
  const date = utcDate(kickoff);
  await match(db, { kickoff });
  await gaveUp(db, date);
  const none = await sweep(db);
  assert.deepEqual([none.reopenedDates, none.headroom.reason], [[], 'headroom_unknown'], 'unknown budget is no permission');
  await budget(db, 140);
  assert.deepEqual((await sweep(db)).reopenedDates, [], 'below the 150 floor');
  await budget(db, 152);
  // Three reservations still in flight eat the margin above the floor.
  for (let i = 0; i < 3; i++) {
    await db.query("insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata) values('goal_api','match-detail','test',now(),'{\"providerRequests\":1}')");
  }
  const tight = await sweep(db);
  assert.deepEqual([tight.reopenedDates, tight.headroom.effectiveProviderRemaining], [[], 149]);
  await budget(db, 400);
  assert.deepEqual((await sweep(db)).reopenedDates.map((d) => d.date), [date]);
  assert.equal(await attempts(db, date), 3);
}));

test('a date too big for the reservation local repair is never reopened: its stuck matches go straight to detail', () => withDb(async (db) => {
  const kickoff = Date.now() - 3 * 86400e3;
  const date = utcDate(kickoff);
  const a = await match(db, { kickoff });
  const b = await match(db, { kickoff: kickoff + 60e3 });
  await match(db, { kickoff: kickoff + 120e3, live: null });
  await gaveUp(db, date);
  await budget(db, 700);
  await settings(db, { stuckReopenMaxDateMatches: 2 });
  const out = await sweep(db);
  assert.deepEqual(out.reopenedDates, []);
  assert.deepEqual(out.skippedDates, [{ date, calendarMatches: 3 }]);
  assert.equal(await attempts(db, date), 4, 'the date stays closed: no demand, no local repair under the quota lock');
  assert.equal(await demand(db, date), 0);
  assert.deepEqual(out.detailRequests.map((r) => r.matchId).sort(), [a.match, b.match].sort(), 'detail path at once');
  assert.equal((await db.query('select skipped_reason from futbeat_private.stuck_results_reopen')).rows[0].skipped_reason, 'date_too_large');
  await db.query("update futbeat_private.results_date_attempts set next_retry_at=now()-interval '1 minute'");
  await db.query("update futbeat_private.stuck_results_reopen set last_reopened_at=now()-interval '2 days'");
  assert.deepEqual((await sweep(db)).reopenedDates, [], 'never reopened later either');
}));

test('a date whose last results answer was lost at the record stage gets exactly one reopen, even without stuck matches', () => withDb(async (db) => {
  const kickoff = Date.now() - 3 * 86400e3;
  const date = utcDate(kickoff);
  await match(db, { kickoff, live: null });
  await budget(db, 700);
  await db.query(`insert into futbeat_private.results_date_attempts(provider,provider_date,attempt_count,last_outcome,next_retry_at,updated_at)
    values('goal_api',$1,4,'FAILED',now()-interval '1 hour',now()-interval '1 day')`, [date]);
  const fail = (stage, ago) => db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,metadata)
    values('goal_api','results-date','test',now()-$2::interval,now()-$2::interval,'FAILED',jsonb_build_object('date',$1::text,'stage',$3::text))`, [date, ago, stage]);
  await fail('provider_fetch', '1 day');
  assert.deepEqual((await sweep(db)).reopenedDates, [], 'a provider failure is the normal lane\'s business');
  await fail('record', '20 hours');
  const out = await sweep(db);
  assert.deepEqual(out.reopenedDates, [{ date, stuck: 0, reason: 'record_failed' }]);
  assert.equal(await attempts(db, date), 3);
  // Served and failed again: no second reopen for this reason.
  await db.query("update futbeat_private.results_date_attempts set attempt_count=4,last_outcome='FAILED',next_retry_at=now()-interval '1 minute'");
  await db.query("update futbeat_private.stuck_results_reopen set last_reopened_at=now()-interval '13 hours'");
  await db.query('delete from futbeat_private.results_date_user_demand');
  await fail('record', '1 minute');
  assert.deepEqual((await sweep(db)).reopenedDates, []);
}));

test('a provider answer for an old match never pushes; a recent one still does', () => withDb(async (db) => {
  const old = await match(db, { kickoff: Date.now() - 2 * 86400e3, live: null });
  const recent = await match(db, { kickoff: Date.now() - 3600e3, live: null });
  const device = (await db.query("insert into futbeat_private.push_devices(user_id,installation_id,platform,transport,token) values(gen_random_uuid(),gen_random_uuid(),'android','test','tok-stale') returning id,user_id")).rows[0];
  for (const g of [old, recent]) {
    await db.query("insert into futbeat_private.push_follows(user_id,entity_type,entity_id,created_at) values($1,'match',$2,now()-interval '3 days')", [device.user_id, g.match]);
    await db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,notify_candidate,first_seen_at)
      values($1,$2,'goal_api','FULL_TIME',jsonb_build_object('id',$1::text,'matchId',$2::text,'type','FULL_TIME'),true,now())`, [`fb_event_stale_${g.n}`, g.match]);
    await db.query(`insert into futbeat_private.notification_outbox(event_id,device_id,user_id,message)
      values($1,$2,$3,'{"title":"t","body":"b"}')`, [`fb_event_stale_${g.n}`, device.id, device.user_id]);
  }
  const rows = (await db.query('select event_id from futbeat_private.notification_outbox where device_id=$1', [device.id])).rows.map((r) => r.event_id);
  assert.deepEqual(rows, [`fb_event_stale_${recent.n}`]);
  assert.equal((await db.query("select count(*)::int n from futbeat_private.canonical_events where id like 'fb_event_stale_%'")).rows[0].n, 2, 'events are still stored');
}));

test('matches the results answer did not carry get one bounded detail request each, newest first, never when final or never seen in play', () => withDb(async (db) => {
  const base = Date.now() - 4 * 86400e3;
  const date = utcDate(base);
  const games = [];
  for (let i = 0; i < 6; i++) games.push(await match(db, { kickoff: base + i * 60e3, live: i % 2 ? 'HALFTIME' : 'LIVE' }));
  const quiet = await match(db, { kickoff: base + 10 * 60e3, live: null });
  // Final through another path: the latest live state still says LIVE but a
  // provider FINISHED observation exists (read model is final).
  const finalElsewhere = await match(db, { kickoff: base + 11 * 60e3 });
  await db.query(`insert into futbeat_private.provider_observations(provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,minute,events,payload_hash,raw_payload)
    values('goal_api',$1,$2,$3,'FINISHED_PENDING_VERIFICATION',1,1,90,'[]',$4,'{}')`,
    [finalElsewhere.ext, finalElsewhere.match, iso(finalElsewhere.kickoff + 30 * 60e3), 'f'.repeat(64)]);
  assert.equal(await readStatus(db, finalElsewhere.match), 'FINISHED_PENDING_VERIFICATION');

  // Not yet: the date was never answered and can still be reopened.
  assert.deepEqual((await sweep(db)).detailRequests, []);

  await served(db, date, iso(base + 3 * 3600e3));
  const first = await sweep(db);
  assert.equal(first.detailRequests.length, 4, 'max pending');
  assert.deepEqual(first.detailRequests.map((r) => r.matchId), [games[5], games[4], games[3], games[2]].map((g) => g.match), 'newest kickoff first');
  assert.ok(!first.detailRequests.some((r) => [quiet.match, finalElsewhere.match].includes(r.matchId)));
  assert.equal((await stuckRows(db)).every((r) => r.state === 'PENDING' && r.attempts === 0), true);
  assert.deepEqual((await sweep(db)).detailRequests, [], 'pending cap holds');
  for (const g of games) assert.deepEqual(await canonical(db, g.match), { status: 'SCHEDULED', score: null });

  // Daily cap.
  await db.query("update futbeat_private.live_terminal_recovery set state='EXHAUSTED',resolved_at=now(),resolution='max_attempts' where reason='stuck_nonterminal'");
  await settings(db, { stuckDetailDailyRequests: 5 });
  assert.equal((await sweep(db)).detailRequests.length, 1, '5 per day, 4 already used');
  assert.deepEqual((await sweep(db)).detailRequests, []);
}));

test('a stuck match is requested at most twice, a day apart; the provider answer closes it through the normal pipeline', () => withDb(async (db) => {
  const kickoff = Date.now() - 2 * 86400e3;
  const date = utcDate(kickoff);
  const g = await match(db, { kickoff, live: 'PENALTIES', liveAfterMinutes: 120 });
  await served(db, date, iso(kickoff + 5 * 3600e3));
  assert.equal((await sweep(db)).detailRequests.length, 1);
  const exhaust = () => db.query("update futbeat_private.live_terminal_recovery set state='EXHAUSTED',resolved_at=now(),resolution='max_attempts' where reason='stuck_nonterminal'");
  await exhaust();
  assert.deepEqual((await sweep(db)).detailRequests, [], 'not again within 24 h');
  await db.query("update futbeat_private.stuck_terminal_requests set requested_at=requested_at-interval '25 hours'");
  assert.equal((await sweep(db)).detailRequests.length, 1, 'second request');
  await exhaust();
  await db.query("update futbeat_private.stuck_terminal_requests set requested_at=requested_at-interval '25 hours'");
  assert.deepEqual((await sweep(db)).detailRequests, [], 'lifetime cap');

  // A pending request answered FINISHED by the provider (recorded by the
  // worker through futbeat_record_live_batch) is settled as resolved.
  await db.query('delete from futbeat_private.stuck_terminal_requests');
  assert.equal((await sweep(db)).detailRequests.length, 1);
  await observe(db, g, 'FINISHED_PENDING_VERIFICATION', Date.now() - 1000, { home: 2, away: 2 });
  await db.query("select futbeat_private.settle_terminal_recovery()");
  assert.deepEqual((await stuckRows(db)).map((r) => r.state), ['RESOLVED']);
  assert.equal(await readStatus(db, g.match), 'FINISHED_PENDING_VERIFICATION');
}));

test('recovery reservation serves fresh games first; a stuck row makes at most 2 calls hours apart and never re-demands its date', () => withDb(async (db) => {
  const old = Date.now() - 3 * 86400e3;
  const date = utcDate(old);
  const g = await match(db, { kickoff: old });
  await served(db, date, iso(old + 4 * 3600e3));
  assert.equal((await sweep(db)).detailRequests.length, 1);
  // A fresh absence from today's live feed.
  const fresh = await match(db, { kickoff: Date.now() - 2 * 3600e3, liveAfterMinutes: 30 });
  await db.query(`insert into futbeat_private.live_terminal_recovery(provider,external_match_id,canonical_match_id,reason,state,last_live_status,detected_at,attempts,next_attempt_at)
    values('goal_api',$1,$2,'absent_from_live','PENDING','LIVE',now(),0,now()-interval '1 minute')`, [fresh.ext, fresh.match]);
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,provider_remaining)
    values('goal_api','live-goal','test',now(),now(),'SUCCEEDED',700)`);
  const reserve = () => db.query("select futbeat_private.reserve_terminal_recovery_call('test') v").then((r) => r.rows[0].v);
  const a = await reserve();
  assert.deepEqual([a.allowed, a.matchId, a.reason], [true, fresh.match, 'absent_from_live'], JSON.stringify(a));
  const b = await reserve();
  assert.deepEqual([b.allowed, b.matchId, b.reason, b.attempt], [true, g.match, 'stuck_nonterminal', 1], JSON.stringify(b));
  const [row] = await stuckRows(db);
  const waitMin = (Date.parse(row.next_attempt_at) - Date.now()) / 60e3;
  assert.ok(waitMin > 170 && waitMin <= 181, `second call ${waitMin} min later`);

  // No results demand from a pending stuck row (its date was answered).
  await db.query("update futbeat_private.live_terminal_recovery set detected_at=now()-interval '1 hour' where reason='stuck_nonterminal'");
  await db.query('delete from futbeat_private.results_date_user_demand');
  await db.query("select futbeat_private.settle_terminal_recovery()");
  assert.equal(await demand(db, date), 0);

  // Second attempt exhausts it; a stuck row lives 24 h, not 6 h.
  await db.query("update futbeat_private.live_terminal_recovery set detected_at=now()-interval '7 hours' where reason='stuck_nonterminal'");
  await db.query("select futbeat_private.settle_terminal_recovery()");
  assert.equal((await stuckRows(db))[0].state, 'PENDING');
  await db.query("update futbeat_private.live_terminal_recovery set attempts=2 where reason='stuck_nonterminal'");
  await db.query("select futbeat_private.settle_terminal_recovery()");
  assert.deepEqual((await stuckRows(db)).map((r) => r.state), ['EXHAUSTED']);
  assert.deepEqual(await canonical(db, g.match), { status: 'SCHEDULED', score: null });
}));

test('the sweep runs outside settlement: a committed claim throttles it to once per 15 minutes, even when the run fails', () => withDb(async (db) => {
  const kickoff = Date.now() - 2 * 86400e3;
  await match(db, { kickoff, live: 'EXTRA_TIME' });
  // Settlement (inside the provider quota lock) never sweeps.
  await db.query('select futbeat_private.settle_terminal_recovery()');
  assert.equal((await db.query('select count(*)::int n from futbeat_private.stuck_terminal_sweep')).rows[0].n, 0);

  const claim = () => db.query('select public.futbeat_claim_stuck_sweep() v').then((r) => r.rows[0].v);
  const run = () => db.query('select public.futbeat_run_stuck_sweep() v').then((r) => r.rows[0].v);
  assert.deepEqual(await run(), { ran: false, reason: 'not_claimed' });
  assert.deepEqual(await claim(), { due: true });
  assert.equal((await run()).ran, true);
  assert.deepEqual(await run(), { ran: false, reason: 'not_claimed' }, 'one run per claim');
  assert.deepEqual(await claim(), { due: false }, 'throttled');

  // A run that fails (statement timeout, anything) leaves the claim committed:
  // the next attempt waits for the throttle instead of retrying every minute.
  await db.query("update futbeat_private.stuck_terminal_sweep set claimed_at=now()-interval '16 minutes'");
  assert.deepEqual(await claim(), { due: true });
  await db.query("update futbeat_private.provider_quota_policy set freshness=freshness||'{\"stuckTerminalWindowDays\":\"x\"}'::jsonb where provider='goal_api'");
  await assert.rejects(run());
  assert.deepEqual(await claim(), { due: false }, 'the failed run did not release the throttle');
  await db.query("update futbeat_private.provider_quota_policy set freshness=freshness-'stuckTerminalWindowDays' where provider='goal_api'");

  const status = (await db.query('select public.futbeat_stuck_terminal_status() v')).rows[0].v;
  assert.equal(status.stuck, 1);
  assert.deepEqual(status.byLastLiveStatus, { EXTRA_TIME: 1 });
  assert.equal(status.lastSweep.last_result.ran, true);
}));

test('end to end: the detail worker sweeps, then the provider answer closes the stuck match without a push', () => withDb(async (db) => {
  const kickoff = Date.now() - 3 * 86400e3;
  const g = await match(db, { kickoff, live: 'PENALTIES', liveAfterMinutes: 120 });
  await served(db, utcDate(kickoff), iso(kickoff + 5 * 3600e3));
  await budget(db, 700);
  const device = (await db.query("insert into futbeat_private.push_devices(user_id,installation_id,platform,transport,token) values(gen_random_uuid(),gen_random_uuid(),'android','test','tok-e2e') returning id,user_id")).rows[0];
  await db.query("insert into futbeat_private.push_follows(user_id,entity_type,entity_id,created_at) values($1,'match',$2,now()-interval '5 days')", [device.user_id, g.match]);
  await db.query('insert into futbeat_private.event_baselines values($1) on conflict do nothing', [g.match]);
  const detail = { id: g.ext, apiId: g.ext, matchStatus: 'AFTER_PEN', matchPeriod: 'FULL_TIME', matchElapsed: 120,
    homeTeamScore: 1, awayTeamScore: 1, homeTeam: { id: `STH${g.n}` }, awayTeam: { id: `STA${g.n}` },
    events: [], cards: [], substitutions: [], lineups: [] };
  const w = worker(db, (url) => {
    assert.equal(url.pathname, `/v1/fixtures/${g.ext}`, 'only the stuck fixture is asked');
    return goalOk(detail);
  });
  await w.run('detail-only');
  assert.equal(w.goalCalls().length, 1, JSON.stringify(w.logs));
  assert.equal(await readStatus(db, g.match), 'FINISHED_PENDING_VERIFICATION');
  assert.deepEqual((await stuckRows(db)).map((r) => r.state), ['RESOLVED']);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.notification_outbox where device_id=$1', [device.id])).rows[0].n, 0, 'no push days after the game');
  assert.ok((await db.query("select claimed_at from futbeat_private.stuck_terminal_sweep where provider='goal_api'")).rows[0].claimed_at);
}));

test('stuck recovery functions are service-only', () => withDb(async (db) => {
  const rows = (await db.query(`select p.proname,
      has_function_privilege('anon',p.oid,'execute') anon,has_function_privilege('authenticated',p.oid,'execute') auth
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where p.proname in ('sweep_stuck_terminal','stuck_nonterminal_candidates','stuck_terminal_status','futbeat_stuck_terminal_status',
      'settle_terminal_recovery','reserve_terminal_recovery_call','recovery_headroom','claim_stuck_sweep',
      'futbeat_claim_stuck_sweep','futbeat_run_stuck_sweep','drop_stale_match_push')`)).rows;
  assert.equal(rows.length, 11);
  for (const r of rows) assert.deepEqual([r.proname, r.anon, r.auth], [r.proname, false, false]);
}));
