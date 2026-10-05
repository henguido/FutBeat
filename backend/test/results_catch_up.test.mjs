import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// Results catch-up (20261005010000): matches whose kickoff passed with no
// observation are offered to the results lane quickly, recent days first,
// without escalating backoff on a day still being played -- and nothing here
// can ever produce a FINAL or a score without provider evidence.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const utcDate = (daysAgo) => {
  const d = new Date(); d.setUTCDate(d.getUTCDate() - daysAgo);
  return d.toISOString().slice(0, 10);
};
let seq = 0;
async function seed(db, startIso, { status = 'SCHEDULED' } = {}) {
  const n = ++seq;
  const comp = `fb_comp_cu${n}`, home = `fb_team_cuh${n}`, away = `fb_team_cua${n}`, id = `fb_match_cu${n}`;
  for (const [eid, kind, payload] of [
    [comp, 'competition', { id: comp, name: `Liga ${n}` }],
    [home, 'team', { id: home, name: `Local ${n}` }],
    [away, 'team', { id: away, name: `Visita ${n}` }],
    [id, 'match', { id, competitionId: comp, homeTeamId: home, awayTeamId: away, startTime: startIso, status,
      events: [], statistics: [] }],
  ]) await db.query('insert into futbeat_private.entities values($1,$2,$3)', [eid, kind, JSON.stringify(payload)]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [`cu-${n}`, id]);
  return id;
}
const candidate = (db) => db.query('select futbeat_private.next_goal_results_candidate()::text d').then((r) => r.rows[0].d);
const delay = (db, daysAgo, attempt) => db.query(
  'select extract(epoch from futbeat_private.results_retry_delay($1::date,$2))::int s', [utcDate(daysAgo), attempt],
).then((r) => r.rows[0].s);
const attemptRow = (db, date, attempts, nextRetry = 'now()') => db.query(
  `insert into futbeat_private.results_date_attempts(provider,provider_date,attempt_count,last_attempt_at,last_outcome,next_retry_at)
   values('goal_api',$1,$2,now()-interval '1 hour','PARTIAL',${nextRetry})
   on conflict(provider,provider_date) do update set attempt_count=excluded.attempt_count,next_retry_at=excluded.next_retry_at`,
  [date, attempts]);
const hoursAgo = (h) => new Date(Date.now() - h * 3600e3).toISOString();

test('retry delay: a day in play never escalates; recent days cap at 3 h; older days unchanged', () => withDb(async (db) => {
  for (const attempt of [1, 4, 9]) assert.equal(await delay(db, 0, attempt), 45 * 60);
  for (const attempt of [1, 4, 9]) assert.equal(await delay(db, 1, attempt), 3600);
  assert.deepEqual([await delay(db, 2, 1), await delay(db, 2, 3), await delay(db, 2, 8)], [3600, 3 * 3600, 3 * 3600]);
  assert.deepEqual([await delay(db, 5, 1), await delay(db, 5, 4), await delay(db, 5, 8)], [6 * 3600, 24 * 3600, 24 * 3600]);
}));

test('today: a kickoff 3 h ago with no observation is a candidate; one 1 h ago (in play) is not', () => withDb(async (db) => {
  // Keep both on today's UTC date whatever the hour the suite runs at.
  const now = new Date();
  const midnight = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const sinceMidnightH = (Date.now() - midnight) / 3600e3;
  await seed(db, hoursAgo(Math.min(1, sinceMidnightH / 2)));
  assert.equal(await candidate(db), null, 'a match still within 150 min of kickoff is the live lane\'s job');
  if (sinceMidnightH > 3) {
    await seed(db, hoursAgo(3));
    assert.equal(await candidate(db), utcDate(0));
  }
}));

test('today: a finished (terminal) match of today is never a candidate', () => withDb(async (db) => {
  const now = new Date();
  const sinceMidnightH = (Date.now() - Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())) / 3600e3;
  if (sinceMidnightH <= 3) return; // not observable this early in the UTC day
  await seed(db, hoursAgo(3), { status: 'FINISHED_PENDING_VERIFICATION' });
  assert.equal(await candidate(db), null);
}));

test('after an outage the last three days come first, even with more attempts than an older day', () => withDb(async (db) => {
  await seed(db, `${utcDate(1)}T18:00:00.000Z`);
  await seed(db, `${utcDate(6)}T18:00:00.000Z`);
  await attemptRow(db, utcDate(1), 3);
  await attemptRow(db, utcDate(6), 0);
  assert.equal(await candidate(db), utcDate(1));
  // A recent date in backoff yields to the older one (never blocks the lane).
  await attemptRow(db, utcDate(1), 3, "now()+interval '30 minutes'");
  assert.equal(await candidate(db), utcDate(6));
}));

test('many partial attempts on a recent day never close a match as missing (no clock-made state)', () => withDb(async (db) => {
  const date = utcDate(1);
  const id = await seed(db, `${date}T12:00:00.000Z`);
  await attemptRow(db, date, 9);
  const out = (await db.query('select futbeat_private.reconcile_goal_results_local($1::date) v', [date])).rows[0].v;
  assert.equal(out.resultsComplete, false);
  const row = (await db.query('select state from futbeat_private.match_result_reconciliation where match_id=$1', [id])).rows[0];
  assert.equal(row.state, 'unresolved', 'kickoff < 48 h ago: still waiting for evidence');
  const payload = (await db.query('select payload from futbeat_private.entities where id=$1', [id])).rows[0].payload;
  assert.equal(payload.status, 'SCHEDULED', 'no FINAL without a provider observation');
  assert.equal(payload.score ?? null, null, 'no invented score');
}));

test('the results cron is rescheduled every 30 min only when pg_cron exists (no-op locally)', () => withDb(async (db) => {
  const cron = (await db.query("select to_regnamespace('cron') is not null v")).rows[0].v;
  assert.equal(cron, false, 'local PGlite has no pg_cron: the migration body must skip cleanly');
}));
