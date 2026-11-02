import './helpers/just_after_utc_midnight_clock.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// The midday clock keeps offsets inside one day. This file holds the day change
// itself, so a real quota defect at 00:00 UTC cannot hide behind that clock.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const spend = (db, kind, minutesAgo, requests, remaining = null) => db.query(`insert into futbeat_private.provider_call_ledger(
  provider,call_kind,trigger_source,status,reserved_at,completed_at,provider_remaining,metadata)
  values('goal_api',$1,'test','SUCCEEDED',now()-make_interval(mins=>$2),now()-make_interval(mins=>$2),$3,$4)`,
[kind, minutesAgo, remaining, JSON.stringify({ providerRequests: requests })]);
const decision = (db, kind, cls) => db.query('select futbeat_private.quota_decision($1,$2,$3) v', ['goal_api', kind, cls]).then((r) => r.rows[0].v);

test('the clock really sits just after 00:00 UTC, in JS and in SQL', () => withDb(async (db) => {
  assert.equal(new Date().getUTCHours(), 0);
  const { rows: [r] } = await db.query("select extract(hour from now() at time zone 'UTC')::int h");
  assert.equal(r.h, 0);
}));

test('units spent before 00:00 UTC do not count today, units after it do', () => withDb(async (db) => {
  await spend(db, 'live-goal', 10, 7);
  await spend(db, 'live-goal', 2, 3);
  assert.equal((await decision(db, 'live-goal', 'live')).usedToday, 3);
}));

test('a poll after the reset can still spend: yesterday at the cap blocks nothing today', () => withDb(async (db) => {
  const cap = (await decision(db, 'live-goal', 'live')).safetyCap;
  await spend(db, 'live-goal', 10, cap);
  const d = await decision(db, 'live-goal', 'live');
  assert.equal(d.usedToday, 0);
  assert.equal(d.allowed, true);
}));

test('the same cap reached after the reset still stops LIVE', () => withDb(async (db) => {
  const cap = (await decision(db, 'live-goal', 'live')).safetyCap;
  await spend(db, 'live-goal', 2, cap);
  const d = await decision(db, 'live-goal', 'live');
  assert.equal(d.usedToday, cap);
  assert.equal(d.allowed, false);
}));

test('remaining reported before the reset does not hold the reserve today', () => withDb(async (db) => {
  await spend(db, 'global-ingest', 10, 1, 5);
  assert.equal((await decision(db, 'live-goal', 'live')).allowed, true);
}));

test('remaining reported after the reset does hold it', () => withDb(async (db) => {
  await spend(db, 'global-ingest', 2, 1, 5);
  const d = await decision(db, 'live-goal', 'live');
  assert.equal(d.allowed, false);
}));
