import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { worker } from './helpers/worker_harness.mjs';
import { nextLivePage } from '../../supabase/functions/_shared/results_pagination.ts';

// BE-239: real worker, real SQL, simulated GOAL. 21 days of polls read one page
// while up to 445 matches were in play; 585 finished without ever showing live.

const start = () => new Date(Date.now() - 1800000).toISOString();
async function seed(db) {
  const s = start();
  for (const [id, kind, payload] of [
    ['fb_comp_p', 'competition', { id: 'fb_comp_p', name: 'Comp' }],
    ['fb_team_ph', 'team', { id: 'fb_team_ph', name: 'Home' }],
    ['fb_team_pa', 'team', { id: 'fb_team_pa', name: 'Away' }],
    ['fb_match_p', 'match', { id: 'fb_match_p', competitionId: 'fb_comp_p', homeTeamId: 'fb_team_ph', awayTeamId: 'fb_team_pa',
      status: 'SCHEDULED', startTime: s, events: [], statistics: [] }],
  ]) await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match','p-seed','fb_match_p')");
}
const rows = (from, n) => Array.from({ length: n }, (_, i) => ({ apiId: `p${from + i}`, kickoffUtc: start(), matchStatus: 'LIVE',
  matchElapsed: 30, homeTeamScore: '0', awayTeamScore: '0', homeTeam: { id: `h${from + i}`, name: `H${from + i}` }, awayTeam: { id: `a${from + i}`, name: `A${from + i}` } }));

// feed(offset) -> { data, pagination }
const goal = (feed, remaining = 700) => (url) => {
  const body = url.pathname === '/v1/fixtures/live' ? feed(Number(url.searchParams.get('offset') ?? 0)) : { data: [] };
  return new Response(JSON.stringify({ success: true, ...body }),
    { status: 200, headers: { 'x-ratelimit-remaining': String(remaining), 'content-type': 'application/json' } });
};
const liveCalls = (w) => w.goalCalls().filter((u) => u.includes('/fixtures/live'));
const lastPoll = (db) => db.query("select metadata m from futbeat_private.provider_call_ledger where call_kind='live-goal' order by id desc limit 1").then((r) => r.rows[0].m);
const nextPoll = (db) => db.query("update futbeat_private.provider_call_ledger set reserved_at=reserved_at-interval '5 minutes' where call_kind='live-goal'");
const absent = (db) => db.query("select count(*)::int n from futbeat_private.live_terminal_recovery where reason='absent_from_live'").then((r) => r.rows[0].n);
async function withDb(fn) {
  const db = await openDatabase();
  try { await seed(db); await fn(db); } finally { await db.close(); }
}

test('nextLivePage: a full page is not an end, a short or empty one is', () => {
  const page = (rowCount, added, pagination, currentOffset = 0) => nextLivePage({ rowCount, added, pagination, currentOffset });
  assert.deepEqual(page(100, 100, null), { next: 100, stalled: false });
  assert.deepEqual(page(100, 100, { hasMore: false, total: 100, limit: 100 }), { next: 100, stalled: false });
  assert.deepEqual(page(40, 40, { hasMore: false }, 100), { next: null, stalled: false });
  assert.deepEqual(page(0, 0, null, 100), { next: null, stalled: false });
  assert.deepEqual(page(100, 0, null, 100), { next: null, stalled: true });
  assert.deepEqual(page(50, 50, { hasMore: true, limit: 50 }), { next: 50, stalled: false });
});

test('a provider that hides pagination still gets its second page read', () => withDb(async (db) => {
  const w = worker(db, goal((o) => ({ data: o === 0 ? rows(0, 100) : rows(100, 20) })));
  await w.run('live');
  const m = await lastPoll(db);
  assert.equal(liveCalls(w).length, 2);
  assert.equal(m.liveMatches, 120);
  assert.equal(m.reachedEnd, true);
  assert.equal(m.paginationSeen ?? null, null);
}));

test('exactly one full page costs one empty probe and never restarts', () => withDb(async (db) => {
  const w = worker(db, goal((o) => ({ data: o === 0 ? rows(0, 100) : [], pagination: { total: 100, limit: 100, hasMore: false } })));
  await w.run('live');
  const m = await lastPoll(db);
  assert.equal(liveCalls(w).length, 2);
  assert.equal(m.liveMatches, 100);
  assert.equal(m.reachedEnd, true);
}));

test('a provider that ignores offset costs one call and proves no absence', () => withDb(async (db) => {
  await db.query(`insert into futbeat_private.live_match_state(provider,external_match_id,canonical_match_id,status,minute,home_score,away_score,last_payload_hash,first_seen_at,last_seen_at,changed_at)
    values('goal_api','p-seed','fb_match_p','LIVE',30,0,0,encode(sha256('x'),'hex'),now(),now(),now())`);
  const w = worker(db, goal(() => ({ data: rows(0, 100) })));
  await w.run('live');
  const m = await lastPoll(db);
  assert.equal(liveCalls(w).length, 2);
  assert.equal(m.stopReason, 'offset_ignored');
  assert.equal(m.reachedEnd, false);
  assert.equal(await absent(db), 0);
}));

test('a peak feed is capped at three pages and the next poll resumes', () => withDb(async (db) => {
  const feed = (o) => ({ data: rows(o, o < 400 ? 100 : 45) });
  let w = worker(db, goal(feed));
  await w.run('live');
  let m = await lastPoll(db);
  assert.equal(liveCalls(w).length, 3);
  assert.equal(m.resumeOffset, 300);
  assert.equal(m.stopReason, 'page_budget');
  await nextPoll(db);
  w = worker(db, goal(feed));
  await w.run('live');
  m = await lastPoll(db);
  assert.equal(m.startOffset, 300);
  assert.equal(liveCalls(w).length, 2);
  assert.equal(m.reachedEnd, true);
}));

test('low quota stays on the first page, without rotating or proving absence', () => withDb(async (db) => {
  const { rows: [{ f }] } = await db.query("select (class_floors->>'live')::int f from futbeat_private.provider_quota_policy where provider='goal_api'");
  const feed = (o) => ({ data: rows(o, 100) });
  let w = worker(db, goal(feed, f + 50));
  await w.run('live');
  let m = await lastPoll(db);
  assert.equal(liveCalls(w).length, 1);
  assert.equal(m.stopReason, 'quota_margin');
  assert.equal(m.resumeOffset ?? null, null);
  assert.equal(m.reachedEnd, false);
  await nextPoll(db);
  w = worker(db, goal(feed, f + 49));
  await w.run('live');
  assert.equal((await lastPoll(db)).startOffset, 0);
}));
