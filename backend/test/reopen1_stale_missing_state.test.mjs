import './helpers/midday_utc_clock.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// REOPEN-1 (20261124150000): 'missing_from_provider' is decided by the date's
// attempt count and age, not by the inputs BE16 uses to skip unchanged rows.
// A closed date keeps skipping its rows (no rewrites, BE16/BE18b intact); once
// attempts drop below 4 (stuck-sweep reopen) the rows are due again and the
// date is no longer reported complete. Generic fixtures only, no provider.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const iso = (ms) => new Date(ms).toISOString();
const put = (db, id, kind, payload) => db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
const local = (db, date) => db.query('select futbeat_private.reconcile_goal_results_local($1::date) v', [date]).then((r) => r.rows[0].v);
const states = (db) => db.query("select match_id m,state,updated_at from futbeat_private.match_result_reconciliation order by 1").then((r) => r.rows);
const setAttempts = (db, date, n) => db.query(`insert into futbeat_private.results_date_attempts(provider,provider_date,last_attempt_at,attempt_count,last_outcome,next_retry_at,updated_at)
  values('goal_api',$1,now()-interval '2 days',$2,'PARTIAL',now()-interval '1 hour',now()-interval '2 days')
  on conflict(provider,provider_date) do update set attempt_count=$2`, [date, n]);

async function fixture(db) {
  const kickoff = Date.now() - 3 * 86400e3;
  const date = iso(kickoff).slice(0, 10);
  await put(db, 'fb_comp_r1', 'competition', { name: 'Liga R' });
  await put(db, 'fb_team_r1h', 'team', { name: 'Local R' });
  await put(db, 'fb_team_r1a', 'team', { name: 'Visita R' });
  await put(db, 'fb_match_r1', 'match', { competitionId: 'fb_comp_r1', homeTeamId: 'fb_team_r1h', awayTeamId: 'fb_team_r1a',
    startTime: iso(kickoff), status: 'SCHEDULED', events: [], statistics: [],
    provenance: { source: 'GOAL API', externalId: 'goal-r1', receivedAt: iso(kickoff - 86400e3), verificationStatus: 'PROVISIONAL' } });
  await put(db, 'fb_match_r2', 'match', { competitionId: 'fb_comp_r1', homeTeamId: 'fb_team_r1a', awayTeamId: 'fb_team_r1h',
    startTime: iso(kickoff + 60e3), status: 'VERIFIED', score: { home: 2, away: 0 }, events: [], statistics: [],
    provenance: { source: 'GOAL API', externalId: 'goal-r2', receivedAt: iso(kickoff + 3 * 3600e3), verificationStatus: 'VERIFIED' } });
  return date;
}

test('a closed date keeps skipping its rows: no rewrite, still complete (BE16 unchanged)', () => withDb(async (db) => {
  const date = await fixture(db);
  await setAttempts(db, date, 4);
  const first = await local(db, date);
  assert.equal(first.resultsComplete, true, JSON.stringify(first));
  const before = await states(db);
  assert.deepEqual(before.map((r) => [r.m, r.state]), [['fb_match_r1', 'missing_from_provider'], ['fb_match_r2', 'resolved']]);
  const second = await local(db, date);
  assert.deepEqual([second.resultsComplete, second.updated, second.unresolved], [true, 0, 0]);
  assert.deepEqual(await states(db), before, 'no reconciliation row rewritten while the date stays closed');
}));

test('after a reopen lowers attempts below 4 the stale row is due again; a VERIFIED row is never touched', () => withDb(async (db) => {
  const date = await fixture(db);
  await setAttempts(db, date, 4);
  await local(db, date);
  const verifiedBefore = (await states(db)).find((r) => r.m === 'fb_match_r2');
  const payloadBefore = (await db.query("select payload from futbeat_private.entities where id='fb_match_r2'")).rows[0].payload;
  await setAttempts(db, date, 3);
  const reopened = await local(db, date);
  assert.deepEqual([reopened.resultsComplete, reopened.unresolved], [false, 1], JSON.stringify(reopened));
  const after = await states(db);
  assert.equal(after.find((r) => r.m === 'fb_match_r1').state, 'unresolved');
  assert.deepEqual(after.find((r) => r.m === 'fb_match_r2'), verifiedBefore, 'resolved row not rewritten');
  assert.deepEqual((await db.query("select payload from futbeat_private.entities where id='fb_match_r2'")).rows[0].payload, payloadBefore);
  // Closing the date again (attempts back to 4) restores the closed state without touching the match.
  await setAttempts(db, date, 4);
  const closed = await local(db, date);
  assert.equal(closed.resultsComplete, true);
  assert.equal((await states(db)).find((r) => r.m === 'fb_match_r1').state, 'missing_from_provider');
  assert.deepEqual((await db.query("select payload->>'status' s from futbeat_private.entities where id='fb_match_r1'")).rows[0].s, 'SCHEDULED');
}));
