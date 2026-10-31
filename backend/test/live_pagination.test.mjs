import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { worker } from './helpers/worker_harness.mjs';
import { liveFeedFreshness, nextLivePage } from '../../supabase/functions/_shared/results_pagination.ts';

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

// BE-240: the cases a real peak can produce, through the real sweep bookkeeping.
const mapped = async (db, ext) => {
  await db.query('insert into futbeat_private.entities values($1,$2,$3)', [`fb_match_${ext}`, 'match', JSON.stringify({ id: `fb_match_${ext}`,
    competitionId: 'fb_comp_p', homeTeamId: `fb_team_${ext}h`, awayTeamId: `fb_team_${ext}a`, status: 'SCHEDULED', startTime: start(), events: [], statistics: [] })]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [ext, `fb_match_${ext}`]);
  return ext;
};
const liveRow = (ext, minute = 30) => ({ ...rows(0, 1)[0], apiId: ext, matchElapsed: minute });
const shownStatus = (db, ext) => db.query("select futbeat_private.match_read_model(payload)->>'status' s from futbeat_private.entities where id=$1", [`fb_match_${ext}`]).then((r) => r.rows[0].s);
const units = (db) => db.query("select coalesce(sum(futbeat_private.provider_call_units(metadata)),0)::int n from futbeat_private.provider_call_ledger where call_kind='live-goal'").then((r) => r.rows[0].n);
const observed = (db) => db.query('select count(*)::int n,count(distinct external_match_id)::int d from futbeat_private.provider_observations').then((r) => r.rows[0]);
// One shared GOAL: remaining falls per request, across polls.
const sharedGoal = (feed, remaining) => {
  const counter = { remaining, calls: 0 };
  counter.goal = (url) => {
    if (url.pathname !== '/v1/fixtures/live') return new Response(JSON.stringify({ success: true, data: [] }), { status: 200 });
    counter.remaining -= 1;
    counter.calls += 1;
    return new Response(JSON.stringify({ success: true, ...feed(Number(url.searchParams.get('offset') ?? 0)) }),
      { status: 200, headers: { 'x-ratelimit-remaining': String(counter.remaining), 'content-type': 'application/json' } });
  };
  return counter;
};

test('a feed that shifts between pages loses nothing and stores no match twice', () => withDb(async (db) => {
  const w = worker(db, goal((o) => ({ data: o === 0 ? rows(0, 100) : rows(50, 100) })));
  await w.run('live');
  const m = await lastPoll(db);
  assert.equal(m.liveMatches, 150);
  const seen = await observed(db);
  assert.equal(seen.n, seen.d);
  assert.equal(seen.d, 150);
}));

test('the third page repeating the second stops there, proven by nothing', () => withDb(async (db) => {
  const w = worker(db, goal((o) => ({ data: o === 0 ? rows(0, 100) : rows(100, 100) })));
  await w.run('live');
  const m = await lastPoll(db);
  assert.equal(liveCalls(w).length, 3);
  assert.equal(m.liveMatches, 200);
  assert.equal(m.stopReason, 'offset_ignored');
  assert.equal(m.reachedEnd, false);
}));

test('quota: ledger units equal real calls and paging stops at the margin across polls', () => withDb(async (db) => {
  const { rows: [{ f }] } = await db.query("select (class_floors->>'live')::int f from futbeat_private.provider_quota_policy where provider='goal_api'");
  const sim = sharedGoal((o) => ({ data: rows(o, 100) }), f + 104);
  for (let poll = 0; poll < 4; poll += 1) {
    await worker(db, sim.goal).run('live');
    await nextPoll(db);
  }
  assert.equal(await units(db), sim.calls);
  // +104: 3 pages leave +101, then one more page crosses the margin; 1 page per poll after.
  assert.equal(sim.calls, 3 + 2 + 1 + 1);
  assert.ok(sim.remaining - f >= 96);
  assert.equal((await lastPoll(db)).stopReason, 'quota_margin');
}));

test('resume: a match on a later page goes LIVE and the first page stays LIVE meanwhile', () => withDb(async (db) => {
  const early = await mapped(db, 'early');
  const late = await mapped(db, 'late');
  const feed = (o) => ({ data: o === 0 ? [liveRow(early), ...rows(1, 99)] : o === 300 ? [liveRow(late), ...rows(301, 20)] : rows(o, 100) });
  await worker(db, goal(feed)).run('live');
  assert.equal(await shownStatus(db, early), 'LIVE');
  assert.notEqual(await shownStatus(db, late), 'LIVE');
  await nextPoll(db);
  await worker(db, goal(feed)).run('live');
  const m = await lastPoll(db);
  assert.equal(m.startOffset, 300);
  assert.equal(m.reachedEnd, true);
  assert.equal(await shownStatus(db, late), 'LIVE');
  assert.equal(await shownStatus(db, early), 'LIVE');
  assert.equal(await absent(db), 0, 'both pages of the sweep count as seen');
}));

test('absence: only a whole sweep proves it, a truncated one never does', () => withDb(async (db) => {
  const gone = await mapped(db, 'gone');
  await worker(db, goal(() => ({ data: [liveRow(gone)] }))).run('live');
  const feed = (o) => ({ data: rows(o, o < 300 ? 100 : 10) });
  await nextPoll(db);
  await worker(db, goal(feed)).run('live');
  assert.equal(await absent(db), 0, 'three of four pages read');
  await nextPoll(db);
  await worker(db, goal(feed)).run('live');
  assert.equal((await lastPoll(db)).reachedEnd, true);
  assert.equal(await absent(db), 1, 'the sweep finished without it');
}));

test('a sweep older than its window proves no absence', () => withDb(async (db) => {
  const gone = await mapped(db, 'gone');
  await worker(db, goal(() => ({ data: [liveRow(gone)] }))).run('live');
  const feed = (o) => ({ data: rows(o, o < 300 ? 100 : 10) });
  await nextPoll(db);
  await worker(db, goal(feed)).run('live');
  await db.query("update futbeat_private.live_poll_sweep set started_at=now()-interval '2 hours'");
  await nextPoll(db);
  await worker(db, goal(feed)).run('live');
  assert.equal(await absent(db), 0);
}));

// BE-244: feed health, coverage and how low quota meets a resumed sweep.
const quotaAt = (db, left) => db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,provider_remaining,reserved_at,completed_at)
  values('goal_api','global-ingest','test','SUCCEEDED',$1,now(),now())`, [left]);
const liveFloor = (db) => db.query("select (class_floors->>'live')::int f from futbeat_private.provider_quota_policy where provider='goal_api'").then((r) => r.rows[0].f);
const offsets = (w) => liveCalls(w).map((u) => Number(new URL(u).searchParams.get('offset')));
const noteCalls = (w) => w.calls.filter((u) => u.includes('futbeat_note_live_poll'));
const peak = (o) => ({ data: rows(o, o < 400 ? 100 : 45) });

test('liveFeedFreshness: only a whole feed of old clocks is stale', () => {
  const now = Date.parse('2026-10-31T20:00:00Z');
  const ago = (s) => new Date(now - s * 1000).toISOString();
  assert.deepEqual(liveFeedFreshness([ago(60), ago(2000)], now), { inPlayClocks: 2, staleClocks: 1, newestClockAgeSeconds: 60, stale: false });
  assert.deepEqual(liveFeedFreshness([ago(900), ago(2000)], now), { inPlayClocks: 2, staleClocks: 2, newestClockAgeSeconds: 900, stale: true });
  assert.deepEqual(liveFeedFreshness([null, 'nonsense'], now), { inPlayClocks: 0, staleClocks: 0, newestClockAgeSeconds: null, stale: false });
  assert.equal(liveFeedFreshness([ago(-30)], now).newestClockAgeSeconds, 0);
});

test('a frozen feed is flagged across polls, with no status invented and no extra call', () => withDb(async (db) => {
  const ext = await mapped(db, 'frozen');
  const old = new Date(Date.now() - 1800000).toISOString();
  const fixture = { ...liveRow(ext), clockUpdatedAt: old, updatedAt: old };
  const metas = [];
  let calls = 0;
  for (let poll = 0; poll < 3; poll += 1) {
    const w = worker(db, goal(() => ({ data: [fixture] })));
    await w.run('live');
    calls += liveCalls(w).length;
    metas.push(await lastPoll(db));
    await nextPoll(db);
  }
  assert.deepEqual(metas.map((m) => m.feed.unchanged), [false, true, true]);
  assert.ok(metas.every((m) => m.feed.stale && m.feed.staleClocks === 1));
  assert.equal(calls, 3);
  assert.equal(await shownStatus(db, ext), 'LIVE');
  assert.equal(await absent(db), 0);
}));

test('a moving feed with fresh clocks is not flagged', () => withDb(async (db) => {
  const ext = await mapped(db, 'moving');
  const fresh = () => new Date().toISOString();
  for (const minute of [30, 35]) {
    await worker(db, goal(() => ({ data: [{ ...liveRow(ext, minute), clockUpdatedAt: fresh() }] }))).run('live');
    await nextPoll(db);
  }
  const { feed } = await lastPoll(db);
  assert.equal(feed.unchanged, false);
  assert.equal(feed.stale, false);
  assert.equal(feed.inPlayClocks, 1);
}));

test('coverage: the ledger holds seen against expected, and no made-up provider total', () => withDb(async (db) => {
  const ext = await mapped(db, 'cov');
  await worker(db, goal(() => ({ data: [liveRow(ext)] }))).run('live');
  await nextPoll(db);
  await worker(db, goal((o) => ({ data: o === 0 ? [liveRow(ext), ...rows(1, 99)] : rows(100, 20) }))).run('live');
  const m = await lastPoll(db);
  assert.equal(m.providerTotal ?? null, null);
  assert.equal(m.coverage.seen, 120);
  assert.equal(m.coverage.mappedSeen, 1);
  assert.ok(m.coverage.expectedActive >= 1);
  assert.ok(m.coverage.expectedLive >= 1);
}));

test('quota margin on a resumed poll: high quota later starts a clean sweep from zero', () => withDb(async (db) => {
  const gone = await mapped(db, 'gone');
  await worker(db, goal(() => ({ data: [liveRow(gone)] }))).run('live');
  await nextPoll(db);
  const f = await liveFloor(db);
  await worker(db, goal(peak)).run('live');
  await nextPoll(db);
  await quotaAt(db, f + 500);
  // The provider reveals the low quota on the resumed page.
  let w = worker(db, goal(peak, f + 50));
  await w.run('live');
  let m = await lastPoll(db);
  assert.deepEqual(offsets(w), [300]);
  assert.equal(m.stopReason, 'quota_margin');
  assert.equal(m.resumeOffset ?? null, null);
  await nextPoll(db);
  await quotaAt(db, 700);
  w = worker(db, goal((o) => ({ data: rows(o, o < 100 ? 100 : 10) })));
  await w.run('live');
  m = await lastPoll(db);
  assert.deepEqual(offsets(w), [0, 100]);
  assert.equal(m.fromStart, true);
  assert.equal(m.reachedEnd, true);
  assert.equal(await absent(db), 1, 'a whole fresh sweep, not the abandoned one');
}));

test('the protected floor leaves no resume for a later day', () => withDb(async (db) => {
  const f = await liveFloor(db);
  await worker(db, goal(peak, f)).run('live');
  const m = await lastPoll(db);
  assert.equal(m.stopReason, 'quota_floor');
  assert.equal(m.resumeOffset ?? null, null);
}));

test('budget 1: the first page stays fresh instead of rotating through the tail', () => withDb(async (db) => {
  const f = await liveFloor(db);
  const ext = await mapped(db, 'first');
  const feed = (minute) => (o) => ({ data: o === 0 ? [liveRow(ext, minute), ...rows(1, 99)] : rows(o, o < 400 ? 100 : 45) });
  await worker(db, goal(feed(30))).run('live');
  assert.equal((await lastPoll(db)).resumeOffset, 300);
  const seenOffsets = [];
  for (const minute of [35, 40]) {
    await nextPoll(db);
    await quotaAt(db, f + 1);
    const w = worker(db, goal(feed(minute), f));
    await w.run('live');
    seenOffsets.push(...offsets(w));
  }
  assert.deepEqual(seenOffsets, [0, 0]);
  const minute = await db.query("select minute from futbeat_private.live_match_state where external_match_id=$1", [ext]);
  assert.equal(minute.rows[0].minute, 40);
}));

test('budget above 1 with quota inside the margin also drops the resume', () => withDb(async (db) => {
  const f = await liveFloor(db);
  await worker(db, goal(peak)).run('live');
  await nextPoll(db);
  await quotaAt(db, f + 50);
  const w = worker(db, goal(peak, f + 49));
  await w.run('live');
  const m = await lastPoll(db);
  assert.deepEqual(offsets(w), [0]);
  assert.equal(m.startOffset, 0);
  assert.equal(m.abandonedOffset, 300);
  assert.equal(m.fromStart, true);
  assert.equal(m.reachedEnd, false);
}));

test('reservation: units in flight follow livePageLimit, completion leaves the real count', () => withDb(async (db) => {
  await quotaAt(db, 700);
  const held = async () => {
    const r = (await db.query("select public.futbeat_reserve_goal_live_call('test') v")).rows[0].v;
    const row = (await db.query("select futbeat_private.provider_call_units(metadata) u from futbeat_private.provider_call_ledger where id=$1", [r.reservationId])).rows[0];
    return { r, units: row.u };
  };
  await db.query("update futbeat_private.entities set payload=payload||jsonb_build_object('startTime',now()-interval '10 minutes') where id='fb_match_p'");
  const first = await held();
  assert.equal(first.units, 10, 'policy livePageLimit, measured in production too');
  await db.query(`select public.futbeat_complete_provider_call($1,'SUCCEEDED',null,200,null,'{"providerRequests":3,"pageBudget":3}'::jsonb)`, [first.r.reservationId]);
  assert.equal(await units(db), 3);
  await nextPoll(db);
  await db.query("update futbeat_private.provider_quota_policy set freshness=freshness||'{\"livePageLimit\":3}' where provider='goal_api'");
  assert.equal((await held()).units, 3, 'the policy row alone aligns the reservation with the cap');
}));

test('a later page failing keeps the pages already paid for and still fails the poll', () => withDb(async (db) => {
  const ext = await mapped(db, 'paid');
  const w = worker(db, (url) => {
    if (url.pathname !== '/v1/fixtures/live') return new Response(JSON.stringify({ success: true, data: [] }), { status: 200 });
    if (Number(url.searchParams.get('offset')) > 0) return new Response('{}', { status: 500, headers: { 'x-ratelimit-remaining': '650' } });
    return new Response(JSON.stringify({ success: true, data: [liveRow(ext), ...rows(1, 99)] }),
      { status: 200, headers: { 'x-ratelimit-remaining': '651', 'content-type': 'application/json' } });
  });
  assert.equal((await w.run('live')).live.status, 'failed');
  const { rows: [row] } = await db.query("select status,provider_remaining,metadata m from futbeat_private.provider_call_ledger where call_kind='live-goal' order by id desc limit 1");
  assert.equal(row.status, 'FAILED');
  assert.equal(row.provider_remaining, 650);
  assert.equal(row.m.providerRequests, 2);
  assert.equal(row.m.matchesFetched, 100);
  assert.equal(await shownStatus(db, ext), 'LIVE');
  assert.equal(await absent(db), 0);
  await nextPoll(db);
  assert.equal((await db.query("select public.futbeat_reserve_goal_live_call('test') v")).rows[0].v.startOffset, 0);
}));

test('note: long polls go in page-sized calls and an absence still needs the whole sweep', () => withDb(async (db) => {
  const gone = await mapped(db, 'gone');
  await worker(db, goal(() => ({ data: [liveRow(gone)] }))).run('live');
  await nextPoll(db);
  const w = worker(db, goal((o) => ({ data: rows(o, o < 200 ? 100 : 30) })));
  await w.run('live');
  const m = await lastPoll(db);
  assert.equal(noteCalls(w).length, 3);
  assert.equal(m.liveMatches, 230);
  assert.equal(m.reachedEnd, true);
  assert.equal(m.recovery.complete, true);
  assert.equal(m.recovery.absent, 1);
  assert.equal(await absent(db), 1);
}));

test('note: an empty sweep still closes, in one call', () => withDb(async (db) => {
  const w = worker(db, goal(() => ({ data: [] })));
  await w.run('live');
  assert.equal(noteCalls(w).length, 1);
  assert.equal((await lastPoll(db)).recovery.complete, true);
}));

test('note failure: the resume is dropped so a sweep with a gap can never close', () => withDb(async (db) => {
  await db.query('alter function public.futbeat_note_live_poll(text,jsonb,boolean,boolean) rename to note_off');
  await worker(db, goal(peak)).run('live');
  await db.query('alter function public.note_off(text,jsonb,boolean,boolean) rename to futbeat_note_live_poll');
  const m = await lastPoll(db);
  assert.equal(m.noteFailed, true);
  assert.equal(m.resumeOffset ?? null, null);
  await nextPoll(db);
  assert.equal((await db.query("select public.futbeat_reserve_goal_live_call('test') v")).rows[0].v.startOffset, 0);
}));
