import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

// BE-229: two requests from September led every plan, the first date cost 15 calls and
// timed out with 57014, and the run never reached the dates after it.

const workflow = await readFile(new URL('../../.github/workflows/global-fixtures.yml', import.meta.url), 'utf8');

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

const request = (db, date, age) => db.query(`insert into futbeat_private.calendar_date_requests(
  provider,provider_date,first_requested_at,last_requested_at,request_count)
  values('goal_api',$1::date,now()-$2::interval,now()-$2::interval,1)`, [date, age]);
const plan = (db) => db.query('select public.futbeat_requested_calendar_dates(12) value').then((r) => r.rows[0].value);

test('an expired request leaves the plan and the queue', () => withDb(async (db) => {
  await request(db, '2026-09-19', '37 days');
  assert.deepEqual(await plan(db), []);
  const { rows } = await db.query('select count(*)::int n from futbeat_private.calendar_date_requests');
  assert.equal(rows[0].n, 0);
}));

test('a request inside the window stays, also for a past date', () => withDb(async (db) => {
  await request(db, '2026-09-19', '2 days');
  assert.deepEqual(await plan(db), ['2026-09-19']);
}));

test('the newest request goes first', () => withDb(async (db) => {
  await request(db, '2026-11-20', '2 days');
  await request(db, '2026-11-05', '1 hour');
  assert.deepEqual(await plan(db), ['2026-11-05', '2026-11-20']);
}));

test('the tiers add up: requested dates do not close the near or the wide plan', () => {
  assert.doesNotMatch(workflow, /if \(\$planDates\.Count -eq 0\) \{\s+\$nearToday/);
  assert.doesNotMatch(workflow, /if \(\$planDates\.Count -eq 0 -and \$shouldExpand\)/);
  assert.equal(workflow.match(/\| Select-Object -Unique/g)?.length, 2);
  assert.ok(workflow.indexOf('$nearToday =') < workflow.indexOf('$todayUtc ='));
});

test('a failed date does not stop the dates after it', () => {
  assert.match(workflow, /\$calendarFailureLimit = 2/);
  assert.match(workflow, /CALENDAR_INGEST_FAILED date=/);
  assert.match(workflow, /CALENDAR_EXPAND_STOP reason=ingest_failures/);
  assert.match(workflow, /if \(\$hotFailed -or \$calendarFailures -gt 0\)/);
});

test('an unfinished expansion resumes: stored dates leave the plan, the failed one stays', () => withDb(async (db) => {
  const missing = () => db.query(`select public.futbeat_calendar_missing_provider_dates(
    'goal_api',current_date+2,current_date+4,10) value`).then((r) => r.rows[0].value);
  const all = await missing();
  await db.query(`insert into futbeat_private.calendar_coverage(provider,provider_date,fetched_at,fixture_count)
    values('goal_api',$1::date,now(),10)`, [all[0]]);
  assert.deepEqual(await missing(), all.slice(1));
}));
