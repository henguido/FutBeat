import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// 20261005070000: the calendar ingest's legacy daily limit counted every
// goal_api call of the day (~700 match-detail rows), so every hot/calendar
// ingest was skipped. For goal_api the limit now counts the same kind only.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const reserve = (db, provider, kind, limit) => db.query(
  "select public.futbeat_reserve_provider_call($1,$2,'github-actions',$3,0,true) v", [provider, kind, limit],
).then((r) => r.rows[0].v);
const fill = (db, provider, kind, n) => db.query(
  `insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at)
   select $1,$2,'supabase-cron',now() from generate_series(1,$3)`, [provider, kind, n]);

test('goal_api hot ingest is allowed after hundreds of match-detail calls today', () => withDb(async (db) => {
  await fill(db, 'goal_api', 'match-detail', 300);
  const plan = await reserve(db, 'goal_api', 'global-ingest', 24);
  assert.equal(plan.allowed, true, JSON.stringify(plan));
  assert.equal(plan.usedToday, 1);
}));

test('goal_api: the limit still bounds the same kind', () => withDb(async (db) => {
  await fill(db, 'goal_api', 'global-ingest', 24);
  const plan = await reserve(db, 'goal_api', 'global-ingest', 24);
  assert.equal(plan.allowed, false);
  assert.equal(plan.reason, 'daily_limit');
}));

test('other providers keep the per-provider count (unchanged)', () => withDb(async (db) => {
  await fill(db, 'thesportsdb', 'country-plus-regional-cup', 10);
  const plan = await reserve(db, 'thesportsdb', 'central-america-cup', 10);
  assert.equal(plan.allowed, false);
  assert.equal(plan.reason, 'daily_limit');
}));
