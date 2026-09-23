import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

let seq = 0;
async function seedPartialMatch(db, { startOffsetHours = -30, status = 'SCHEDULED', withScore = true } = {}) {
  const n = ++seq;
  const comp = `fb_comp_tr_${n}`, home = `fb_team_tr_h${n}`, away = `fb_team_tr_a${n}`, match = `fb_match_tr_${n}`;
  const start = new Date(Date.now() + startOffsetHours * 3600000).toISOString();
  const score = withScore ? { home: 1, away: 0 } : undefined;
  for (const [id, kind, payload] of [
    [comp, 'competition', { id: comp, name: `Liga ${n}` }],
    [home, 'team', { id: home, name: `Home ${n}` }],
    [away, 'team', { id: away, name: `Away ${n}` }],
    [match, 'match', { id: match, competitionId: comp, homeTeamId: home, awayTeamId: away,
      startTime: start, status, ...(score ? { score } : {}), events: [], statistics: [] }],
  ]) await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
  // futbeat_private.futbeat_index_calendar_match already indexes calendar_matches
  // from the entities insert above (trigger on entities, keyed off startTime).
  return match;
}

const request = (db, match) =>
  db.query('select public.futbeat_request_terminal_result($1) v', [match]).then((r) => r.rows[0].v);
const reserve = (db) =>
  db.query("select futbeat_private.reserve_goal_results_date('test') v").then((r) => r.rows[0].v);
const metric = (db, name) =>
  db.query('select coalesce(sum(value),0)::int n from futbeat_private.demand_metrics where metric=$1', [name])
    .then((r) => r.rows[0].n);

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

test('unknown match: no crash, no demand', () => withDb(async (db) => {
  const result = await request(db, 'fb_match_does_not_exist');
  assert.deepEqual(result, { resultsPending: false, reason: 'unknown_match' });
}));

test('calendar_matches row missing after indexing (data drift, defensive path): reports unscheduled, no crash', () => withDb(async (db) => {
  // futbeat_index_calendar_match keeps calendar_matches in sync with a valid
  // startTime, so this row is only ever missing via drift (e.g. a manual
  // delete) — simulate that to exercise futbeat_request_terminal_result's
  // defensive v_date-is-null branch.
  const match = await seedPartialMatch(db);
  await db.query('delete from futbeat_private.calendar_matches where match_id=$1', [match]);
  const result = await request(db, match);
  assert.deepEqual(result, { resultsPending: false, reason: 'unscheduled' });
  assert.equal((await db.query('select count(*)::int n from futbeat_private.results_date_user_demand')).rows[0].n, 0);
}));

test('CANCELLED/POSTPONED/SUSPENDED matches are treated as terminal, never re-queued', () => withDb(async (db) => {
  for (const status of ['CANCELLED', 'POSTPONED', 'SUSPENDED']) {
    const match = await seedPartialMatch(db, { status });
    const result = await request(db, match);
    assert.deepEqual(result, { resultsPending: false, reason: 'terminal' }, status);
  }
  assert.equal((await db.query('select count(*)::int n from futbeat_private.results_date_user_demand')).rows[0].n, 0);
}));

test('terminal result real -> Finalizado: once GOAL evidence lands, match_read_model reports it terminal', () => withDb(async (db) => {
  const match = await seedPartialMatch(db);
  const { providerDate } = await request(db, match);
  const plan = await reserve(db);
  assert.equal(plan.allowed, true);
  assert.equal(plan.date, providerDate);

  // Simulate the worker's GOAL fetch landing real terminal evidence for the date.
  await db.query(`insert into futbeat_private.provider_observations(
      provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,minute,raw_payload,payload_hash)
    values('goal_api','ext-finalize-test',$1,now(),'VERIFIED',2,1,90,'{}',md5(random()::text)||md5(clock_timestamp()::text))`,
    [match]);
  await db.query('select futbeat_private.finalize_goal_results_date($1,now())', [providerDate]);

  const status = (await db.query('select payload->>\'status\' s from futbeat_private.entities where id=$1', [match])).rows[0].s;
  assert.equal(status, 'VERIFIED');
  const stillDue = await request(db, match);
  assert.deepEqual(stillDue, { resultsPending: false, reason: 'terminal' });
}));

test('score + past kickoff + no terminal evidence: still partial, records date demand', () => withDb(async (db) => {
  const match = await seedPartialMatch(db);
  const result = await request(db, match);
  assert.equal(result.resultsPending, true);
  assert.ok(result.providerDate);
  const row = (await db.query('select request_count::int n from futbeat_private.results_date_user_demand where provider_date=$1', [result.providerDate])).rows[0];
  assert.deepEqual(row, { n: 1 });
  assert.equal(await metric(db, 'terminal_result_user_demands'), 1);
}));

test('terminal evidence already present: 0 provider calls, no demand', () => withDb(async (db) => {
  const match = await seedPartialMatch(db, { status: 'VERIFIED' });
  const result = await request(db, match);
  assert.deepEqual(result, { resultsPending: false, reason: 'terminal' });
  assert.equal((await db.query('select count(*)::int n from futbeat_private.results_date_user_demand')).rows[0].n, 0);
}));

test('20 partial matches same date: opening several dedupes to one date demand, one wake', () => withDb(async (db) => {
  const matches = [];
  for (let i = 0; i < 20; i++) matches.push(await seedPartialMatch(db, { startOffsetHours: -25 - i / 60 }));
  for (const m of matches) await request(db, m);
  const rows = (await db.query('select provider_date,request_count::int n from futbeat_private.results_date_user_demand')).rows;
  assert.equal(rows.length, 1, 'all 20 matches bucket into the same provider_date');
  assert.equal(rows[0].n, 20);
  assert.equal((await db.query("select wake_count::int n from futbeat_private.worker_wakeups where trigger='results'")).rows[0].n, 1);
}));

test('user-opened date is reserved before a more recent background candidate', () => withDb(async (db) => {
  // Without user demand, next_goal_results_candidate() breaks ties by
  // provider_date desc (most recent first), so the newer background match
  // would normally win. A user opening the OLDER match's partial must
  // override that background ordering.
  await seedPartialMatch(db, { startOffsetHours: -30 });
  const userMatch = await seedPartialMatch(db, { startOffsetHours: -80 });
  const requested = await request(db, userMatch);
  const plan = await reserve(db);
  assert.equal(plan.allowed, true);
  assert.equal(plan.date, requested.providerDate);
  assert.equal(plan.userPriority, true);
}));

test('date in backoff is skipped even when user-requested', () => withDb(async (db) => {
  const match = await seedPartialMatch(db);
  const { providerDate } = await request(db, match);
  await db.query(`insert into futbeat_private.results_date_attempts(provider,provider_date,last_attempt_at,attempt_count,last_outcome,next_retry_at)
    values('goal_api',$1,now(),1,'FAILED',now()+interval '1 hour')
    on conflict(provider,provider_date) do update set next_retry_at=excluded.next_retry_at`, [providerDate]);
  const plan = await reserve(db);
  assert.equal(plan.allowed, false);
  assert.equal(plan.reason, 'no_results_due');
}));

test('quota class results: a user-requested date is taken via the results class floor (20), below the background guard (120)', () => withDb(async (db) => {
  const match = await seedPartialMatch(db);
  await request(db, match);
  // remaining=50 sits below the background planner's hardcoded 120 reserve
  // but above the central 'results' class floor (20): only the new
  // user-priority path (gated by quota_decision) can succeed here.
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,
    reserved_at,completed_at,status,provider_remaining) values('goal_api','live-goal','test',now(),now(),'SUCCEEDED',50)`);
  const plan = await reserve(db);
  assert.equal(plan.allowed, true);
  assert.equal(plan.userPriority, true);
}));

test('quota class results: a user-requested date is blocked once remaining is at or below its floor (20)', () => withDb(async (db) => {
  const match = await seedPartialMatch(db);
  await request(db, match);
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,
    reserved_at,completed_at,status,provider_remaining) values('goal_api','live-goal','test',now(),now(),'SUCCEEDED',15)`);
  const plan = await reserve(db);
  // Falls through to the unmodified background guard, which also blocks at
  // remaining<=120 -- so either way this date is not reserved right now.
  assert.equal(plan.allowed, false);
}));

test('same date requested twice within 5 minutes dedupes (no second wake)', () => withDb(async (db) => {
  const match = await seedPartialMatch(db);
  await request(db, match);
  const second = await seedPartialMatch(db, { startOffsetHours: -30.1 });
  await request(db, second);
  assert.equal((await db.query("select wake_count::int n from futbeat_private.worker_wakeups where trigger='results'")).rows[0].n, 1);
  assert.equal(await metric(db, 'deduped_requests'), 1);
}));

test('match-context API route requests terminal result recovery', async () => {
  const source = await readFile(
    new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url),
    'utf8',
  );
  assert.match(source, /futbeat_request_terminal_result/);
  assert.ok(
    source.indexOf("/futbeat-api/v1/match-context") <
      source.indexOf("futbeat_request_terminal_result"),
    'terminal result demand must run inside the match-context route',
  );
});
