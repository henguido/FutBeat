import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { worker } from './helpers/worker_harness.mjs';

// BE-239: real worker, real SQL, simulated GOAL. On 2026-10-31 the link failed
// for five hours and every paid batch was thrown away with it.

async function seed(db, ext) {
  const start = new Date(Date.now() - 1800000).toISOString();
  for (const [id, kind, payload] of [
    [`fb_comp_${ext}`, 'competition', { id: `fb_comp_${ext}`, name: `Comp ${ext}` }],
    [`fb_team_${ext}h`, 'team', { id: `fb_team_${ext}h`, name: `Home ${ext}` }],
    [`fb_team_${ext}a`, 'team', { id: `fb_team_${ext}a`, name: `Away ${ext}` }],
    [`fb_match_${ext}`, 'match', { id: `fb_match_${ext}`, competitionId: `fb_comp_${ext}`, homeTeamId: `fb_team_${ext}h`,
      awayTeamId: `fb_team_${ext}a`, status: 'SCHEDULED', startTime: start, events: [], statistics: [] }],
  ]) await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
  return { ext, match: `fb_match_${ext}`, start };
}
const map = (db, m) => db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [m.ext, m.match]);
const fixture = (m, minute = 30) => ({ apiId: m.ext, kickoffUtc: m.start, matchStatus: 'LIVE', matchElapsed: minute,
  homeTeamScore: '1', awayTeamScore: '0', homeTeam: { name: `Home ${m.ext}` }, awayTeam: { name: `Away ${m.ext}` } });
const goal = (data) => () => new Response(JSON.stringify({ success: true, data,
  pagination: { total: data.length, limit: 100, hasMore: false } }),
{ status: 200, headers: { 'x-ratelimit-remaining': '700', 'content-type': 'application/json' } });

// The link statement dies as it did in production; everything else is real.
const linkDown = (db) => ({ query: (sql, values) => (sql.includes('futbeat_link_goal_live_matches')
  ? Promise.reject(new Error('canceling statement due to statement timeout')) : db.query(sql, values)) });

const lastCall = (db) => db.query("select status,metadata from futbeat_private.provider_call_ledger where call_kind='live-goal' order by id desc limit 1").then((r) => r.rows[0]);
const nextPoll = (db) => db.query("update futbeat_private.provider_call_ledger set reserved_at=reserved_at-interval '5 minutes' where call_kind='live-goal'");
const state = (db, ext) => db.query('select canonical_match_id c,minute from futbeat_private.live_match_state where external_match_id=$1', [ext]).then((r) => r.rows[0]);
const observations = (db, ext) => db.query('select canonical_match_id c from futbeat_private.provider_observations where external_match_id=$1', [ext]).then((r) => r.rows);
async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

test('a dead link still records the batch, once, with one GOAL call', () => withDb(async (db) => {
  const m = await seed(db, 't1');
  await map(db, m);
  const w = worker(linkDown(db), goal([fixture(m)]));
  const out = await w.run('live');
  assert.equal(out.status, 'ok');
  const call = await lastCall(db);
  assert.equal(call.status, 'SUCCEEDED');
  assert.match(call.metadata.linkFailure, /statement timeout/);
  assert.equal(call.metadata.insertedObservations, 1);
  assert.equal(w.goalCalls().filter((u) => u.includes('/fixtures/live')).length, 1);
  assert.equal((await state(db, m.ext)).c, m.match);
}));

test('the same batch after a failed link is a duplicate, not a second observation', () => withDb(async (db) => {
  const m = await seed(db, 't2');
  await map(db, m);
  await worker(linkDown(db), goal([fixture(m)])).run('live');
  await nextPoll(db);
  await worker(linkDown(db), goal([fixture(m)])).run('live');
  const call = await lastCall(db);
  assert.equal(call.metadata.insertedObservations, 0);
  assert.equal(call.metadata.duplicates, 1);
  assert.equal((await observations(db, m.ext)).length, 1);
}));

test('an unmapped fixture waits unlinked and the next good link claims its evidence', () => withDb(async (db) => {
  const m = await seed(db, 't3');
  const other = await seed(db, 't4');
  await map(db, other);
  await worker(linkDown(db), goal([fixture(m), fixture(other)])).run('live');
  assert.equal((await state(db, m.ext)).c, null);
  await nextPoll(db);
  await worker(db, goal([fixture(m), fixture(other)])).run('live');
  const call = await lastCall(db);
  assert.equal(call.metadata.linkFailure, undefined);
  assert.equal(call.metadata.linkedMatches, 1);
  assert.equal((await state(db, m.ext)).c, m.match);
  assert.deepEqual((await observations(db, m.ext)).map((o) => o.c), [m.match]);
  const twin = await db.query("select count(*)::int n from futbeat_private.entities where kind='match' and id like 'fb_match_%' and payload->>'homeTeamId'=$1", ['fb_team_t3h']);
  assert.equal(twin.rows[0].n, 1);
}));
