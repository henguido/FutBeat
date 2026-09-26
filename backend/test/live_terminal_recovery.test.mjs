import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { createHash } from 'node:crypto';
import { worker } from './helpers/worker_harness.mjs';

// #120: a match that leaves the GOAL /fixtures/live feed (or stays LIVE far
// too long) before FutBeat recorded any terminal status must still resolve.
// Exercises the real migration (20260926100000_live_terminal_recovery.sql)
// and the real worker (futbeat-goal-live-sync/index.ts) against real SQL and
// a simulated GOAL API. No real network, no fixed teams/matches.

let seq = 0;
async function seedLive(db, n, { minutes = -30 } = {}) {
  const out = [];
  for (let i = 0; i < n; i++) {
    const k = ++seq;
    const ids = { comp: `fb_comp_tc${k}`, home: `fb_team_tc${k}h`, away: `fb_team_tc${k}a`, match: `fb_match_tc${k}`, ext: `tc-${k}` };
    const start = new Date(Date.now() + minutes * 60000).toISOString();
    for (const [id, kind, payload] of [
      [ids.comp, 'competition', { id: ids.comp, name: `Comp ${k}` }],
      [ids.home, 'team', { id: ids.home, name: `H ${k}` }],
      [ids.away, 'team', { id: ids.away, name: `A ${k}` }],
      [ids.match, 'match', { id: ids.match, competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away,
        status: 'SCHEDULED', startTime: start, events: [], statistics: [],
        provenance: { receivedAt: new Date(Date.now() - 2 * 3600000).toISOString() } }],
    ]) await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
    await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [ids.ext, ids.match]);
    out.push({ ...ids, start });
  }
  return out;
}
const fixtureOf = (m, status = 'LIVE', minute = 30, score = ['1', '0']) => ({ apiId: m.ext, kickoffUtc: m.start,
  matchStatus: status, matchElapsed: minute, homeTeamScore: score[0], awayTeamScore: score[1],
  homeTeam: { id: `${m.ext}-h`, name: 'H' }, awayTeam: { id: `${m.ext}-a`, name: 'A' } });

// Simulated GOAL: /fixtures/live paginated by `pages`; /fixtures/{externalId}
// answered per-call from `details` (a map externalId -> fixture-shaped object,
// or a function returning one/throwing to simulate an error); everything
// else (squads/news/etc.) answered harmlessly.
function goalSim({ pages = [[]], details = {}, remainingStart = 700 } = {}) {
  let remaining = remainingStart;
  return (url) => {
    remaining -= 1;
    const headers = { 'x-ratelimit-remaining': String(remaining), 'content-type': 'application/json' };
    if (url.pathname === '/v1/fixtures/live') {
      const offset = Number(url.searchParams.get('offset') ?? 0);
      const index = Math.floor(offset / 100);
      const data = pages[index] ?? [];
      return new Response(JSON.stringify({ success: true, data,
        pagination: { total: pages.flat().length, limit: 100, hasMore: index + 1 < pages.length } }), { status: 200, headers });
    }
    const detailMatch = url.pathname.match(/^\/v1\/fixtures\/([^/]+)$/);
    if (detailMatch) {
      const external = decodeURIComponent(detailMatch[1]);
      const entry = details[external];
      if (!entry) return new Response(JSON.stringify({ success: false }), { status: 404, headers });
      const fixture = typeof entry === 'function' ? entry() : entry;
      return new Response(JSON.stringify({ success: true, data: fixture }), { status: 200, headers });
    }
    return new Response(JSON.stringify({ success: true, data: [] }), { status: 200, headers });
  };
}

const nextPoll = (db) => db.query("update futbeat_private.provider_call_ledger set reserved_at=reserved_at-interval '5 minutes' where call_kind='live-goal'");
const makeDue = (db, ext) => db.query("update futbeat_private.live_terminal_recovery set next_attempt_at=now()-interval '1 second' where external_match_id=$1", [ext]);
const shown = (db, m) => db.query(`select futbeat_private.match_read_model(payload) v from futbeat_private.entities where id=$1`, [m.match]).then((r) => r.rows[0].v);
const recoveryRow = (db, ext) => db.query('select * from futbeat_private.live_terminal_recovery where external_match_id=$1', [ext]).then((r) => r.rows[0] ?? null);
const recoveryLedgerRows = (db) => db.query("select metadata from futbeat_private.provider_call_ledger where call_kind='match-detail' order by id").then((r) => r.rows);
async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

test('A. SCHEDULED -> LIVE -> HALFTIME -> LIVE -> FT via live polls: FINISHED_PENDING_VERIFICATION, no recovery row', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1);
  const sequence = [
    fixtureOf(m, 'LIVE', 10),
    fixtureOf(m, 'HALF_TIME', 45),
    fixtureOf(m, 'LIVE', 50),
    fixtureOf(m, 'FINISHED', 90, ['2', '1']),
  ];
  for (const fixture of sequence) {
    const w = worker(db, goalSim({ pages: [[fixture]] }));
    assert.equal((await w.run('live')).live.status, 'ok');
    await nextPoll(db);
  }
  const model = await shown(db, m);
  assert.equal(model.status, 'FINISHED_PENDING_VERIFICATION');
  assert.deepEqual(model.score, { home: 2, away: 1 });
  assert.equal(await recoveryRow(db, m.ext), null, 'no recovery row was ever needed');
}));

test('B. LIVE disappears from a complete poll -> recovery row, then detail fetch resolves FINISHED 2-3', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1);
  let w = worker(db, goalSim({ pages: [[fixtureOf(m, 'LIVE', 60)]] }));
  await w.run('live');
  await nextPoll(db);

  // Next complete poll: the match is simply gone from the feed.
  w = worker(db, goalSim({ pages: [[]] }));
  const result = await w.run('live');
  assert.equal(result.live.paginationTruncated, false);
  let row = await recoveryRow(db, m.ext);
  assert.equal(row.state, 'PENDING');
  assert.equal(row.reason, 'absent_from_live');

  await makeDue(db, m.ext);
  w = worker(db, goalSim({ details: { [m.ext]: fixtureOf(m, 'FINISHED', 90, ['2', '3']) } }));
  const detailResult = await w.run('detail-only');
  assert.equal(detailResult.status, 'ok');
  assert.deepEqual(detailResult.detail[0].status, 'ok', JSON.stringify(detailResult.detail));

  const model = await shown(db, m);
  assert.equal(model.status, 'FINISHED_PENDING_VERIFICATION');
  assert.deepEqual(model.score, { home: 2, away: 3 });
  row = await recoveryRow(db, m.ext);
  assert.equal(row.state, 'RESOLVED');
  // The default/'live' cascade also runs its own stale-LIVE prefetch lane
  // (unrelated to #120), which may add its own match-detail ledger rows; the
  // recovery-specific reservation is what this case is about.
  const recoveryLedger = (await recoveryLedgerRows(db)).filter((r) => r.metadata.bucket === 'recovery');
  assert.equal(recoveryLedger.length, 1);
  assert.equal(recoveryLedger[0].metadata.recoveryReason, 'absent_from_live');
}));

test('C. LIVE disappears then reappears in the next complete poll -> recovery CANCELLED, not terminal', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1);
  let w = worker(db, goalSim({ pages: [[fixtureOf(m, 'LIVE', 60)]] }));
  await w.run('live');
  await nextPoll(db);

  w = worker(db, goalSim({ pages: [[]] }));
  await w.run('live');
  assert.equal((await recoveryRow(db, m.ext)).state, 'PENDING');
  await nextPoll(db);

  w = worker(db, goalSim({ pages: [[fixtureOf(m, 'LIVE', 65)]] }));
  await w.run('live');
  const row = await recoveryRow(db, m.ext);
  assert.equal(row.state, 'CANCELLED');
  assert.equal(row.resolution, 'reappeared');
  const model = await shown(db, m);
  assert.equal(model.status, 'LIVE');
}));

test('D. recovery fetch returns SUSPENDED: not terminal, row stays PENDING, attempts incremented, backed off', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1);
  let w = worker(db, goalSim({ pages: [[fixtureOf(m, 'LIVE', 60)]] }));
  await w.run('live');
  await nextPoll(db);
  w = worker(db, goalSim({ pages: [[]] }));
  await w.run('live');
  await makeDue(db, m.ext);

  w = worker(db, goalSim({ details: { [m.ext]: fixtureOf(m, 'SUSPENDED', 60) } }));
  await w.run('detail-only');

  const row = await recoveryRow(db, m.ext);
  assert.equal(row.state, 'PENDING');
  assert.equal(row.attempts, 1);
  assert.ok(new Date(row.next_attempt_at).getTime() > Date.now(), 'backoff pushes next attempt into the future');
  const model = await shown(db, m);
  assert.notEqual(model.status, 'FINISHED_PENDING_VERIFICATION');
}));

// ABANDONED is surfaced by the read model (it used to be dropped), so the row
// settles on terminal evidence; POSTPONED/CANCELLED stop the recovery (the
// results reconciliation owns them). None ever becomes FINISHED.
test('E. recovery fetch returns POSTPONED/CANCELLED/ABANDONED: resolved, never FINISHED', () => withDb(async (db) => {
  for (const providerStatus of ['POSTPONED', 'CANCELLED', 'ABANDONED']) {
    await nextPoll(db);
    const [m] = await seedLive(db, 1);
    let w = worker(db, goalSim({ pages: [[fixtureOf(m, 'LIVE', 30)]] }));
    await w.run('live');
    await nextPoll(db);
    w = worker(db, goalSim({ pages: [[]] }));
    await w.run('live');
    await makeDue(db, m.ext);

    w = worker(db, goalSim({ details: { [m.ext]: fixtureOf(m, providerStatus, 30) } }));
    await w.run('detail-only');

    const row = await recoveryRow(db, m.ext);
    assert.equal(row.state, 'RESOLVED', providerStatus);
    assert.equal(row.resolution, providerStatus === 'ABANDONED' ? 'terminal_evidence' : `provider_${providerStatus.toLowerCase()}`);
    const model = await shown(db, m);
    if (providerStatus === 'ABANDONED') assert.equal(model.status, 'ABANDONED');
    assert.notEqual(model.status, 'FINISHED_PENDING_VERIFICATION', `${providerStatus} must never become FINISHED`);
  }
}));

test('F. an already-terminal match absent from a complete poll gets no recovery row; a later stale LIVE never revives it', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1);
  let w = worker(db, goalSim({ pages: [[fixtureOf(m, 'FINISHED', 90, ['1', '0'])]] }));
  await w.run('live');
  assert.equal((await shown(db, m)).status, 'FINISHED_PENDING_VERIFICATION');
  await nextPoll(db);

  w = worker(db, goalSim({ pages: [[]] }));
  await w.run('live');
  assert.equal(await recoveryRow(db, m.ext), null, 'no recovery row for an already-terminal match');
  await nextPoll(db);

  // A stale LIVE observation reappearing does not revive it (absorbing guard).
  w = worker(db, goalSim({ pages: [[fixtureOf(m, 'LIVE', 91)]] }));
  await w.run('live');
  const model = await shown(db, m);
  assert.equal(model.status, 'FINISHED_PENDING_VERIFICATION');
  assert.equal(await recoveryRow(db, m.ext), null);
}));

test('G. truncated/partial poll never treats absence as evidence; a resumed (offset>0, not restarted) poll neither', () => withDb(async (db) => {
  const [a, b] = await seedLive(db, 2);
  let w = worker(db, goalSim({ pages: [[fixtureOf(a, 'LIVE', 10), fixtureOf(b, 'LIVE', 10)]] }));
  await w.run('live');
  await nextPoll(db);

  // Truncated: page budget cut to 1 via a low observed remaining, and only
  // page 0 (A) is ever read; B is not in the read pages.
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,provider_remaining,reserved_at,completed_at)
    values('goal_api','global-ingest','test','SUCCEEDED',21,now(),now())`);
  const filler = Array.from({ length: 99 }, (_, i) => ({ ...fixtureOf(a, 'LIVE', 40), apiId: `unmapped-tc-${i}` }));
  w = worker(db, goalSim({ pages: [[fixtureOf(a, 'LIVE', 40), ...filler], [fixtureOf(b, 'LIVE', 40)]], remainingStart: 300 }));
  const result = await w.run('live');
  assert.equal(result.live.paginationTruncated, true);
  assert.equal(await recoveryRow(db, b.ext), null, 'B was never read: absence is not evidence');
  await nextPoll(db);

  // A poll that resumes at offset>0 without restarting: the reservation
  // itself (via provider_call_ledger.metadata.resumeOffset from the
  // truncated poll above) resumes at offset 100, so only the unread page
  // (holding B) is ever fetched; A is simply not on it. A high observed
  // remaining removes any further truncation from this poll.
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,provider_remaining,reserved_at,completed_at)
    values('goal_api','global-ingest','test','SUCCEEDED',400,now(),now())`);
  // pages[0] is never requested (the worker starts straight at offset 100 /
  // pages[1]); a poison page proves that if it ever got read it would fail.
  const poison = [{ apiId: 'never-read', kickoffUtc: a.start, matchStatus: 'LIVE', matchElapsed: 1,
    homeTeamScore: '0', awayTeamScore: '0', homeTeam: { id: 'x-h' }, awayTeam: { id: 'x-a' } }];
  w = worker(db, goalSim({ pages: [poison, [fixtureOf(b, 'LIVE', 41)]] }));
  const resumed = await w.run('live');
  assert.equal(resumed.live.status, 'ok');
  assert.equal(w.goalCalls().filter((u) => u.includes('/fixtures/live')).length, 1, 'only the unread page is fetched');
  assert.ok(w.goalCalls().some((u) => u.includes('/fixtures/live') && u.includes('offset=100')));
  assert.equal(await recoveryRow(db, a.ext), null, 'A absent from a resumed (offset>0, non-restarted) poll is not evidence');
}));

test('H. idempotency: two absences make one row without resetting attempts; EXHAUSTED after max attempts stops reservation', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1);
  let w = worker(db, goalSim({ pages: [[fixtureOf(m, 'LIVE', 60)]] }));
  await w.run('live');
  await nextPoll(db);
  w = worker(db, goalSim({ pages: [[]] }));
  await w.run('live');
  await nextPoll(db);
  w = worker(db, goalSim({ pages: [[]] }));
  await w.run('live');
  let rows = await db.query('select * from futbeat_private.live_terminal_recovery where external_match_id=$1', [m.ext]).then((r) => r.rows);
  assert.equal(rows.length, 1, 'idempotent: one row for the same absence noted twice');
  assert.equal(rows[0].attempts, 0, 'noting the absence again is not an attempt');

  // Drive it to EXHAUSTED: repeatedly make it due and answer with SUSPENDED
  // (never terminal) until the attempt cap (6) is spent.
  for (let i = 0; i < 6; i++) {
    await makeDue(db, m.ext);
    w = worker(db, goalSim({ details: { [m.ext]: fixtureOf(m, 'SUSPENDED', 60) } }));
    await w.run('detail-only');
  }
  const row = await recoveryRow(db, m.ext);
  assert.equal(row.state, 'EXHAUSTED');
  assert.equal(row.attempts, 6);

  await makeDue(db, m.ext);
  const reserved = (await db.query("select public.futbeat_reserve_terminal_recovery_call('test') v")).rows[0].v;
  assert.equal(reserved.allowed, false);
  assert.equal(reserved.reason, 'no_recovery_due');
}));

test('overdue_live: a match still LIVE in the feed with kickoff far in the past gets an overdue row; reappearing does not cancel it', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1, { minutes: -190 }); // kickoff 3h10m ago
  const w = worker(db, goalSim({ pages: [[fixtureOf(m, 'LIVE', 190)]] }));
  await w.run('live');

  const row = await recoveryRow(db, m.ext);
  assert.equal(row.state, 'PENDING');
  assert.equal(row.reason, 'overdue_live');

  // Reappearing (still LIVE, still seen) does not cancel an overdue row: only
  // absence-cancellation looks at reason='absent_from_live'.
  await nextPoll(db);
  const w2 = worker(db, goalSim({ pages: [[fixtureOf(m, 'LIVE', 200)]] }));
  await w2.run('live');
  const row2 = await recoveryRow(db, m.ext);
  assert.equal(row2.state, 'PENDING');
  assert.equal(row2.reason, 'overdue_live');
}));

// Read-model safety of surfacing non-final provider states.
const liveObs = (ext, status, minute = 30, [home, away] = [0, 0]) => {
  const obs = { externalMatchId: ext, status, minute, score: { home, away }, events: [], nonce: ++seq };
  obs.payloadHash = createHash('sha256').update(JSON.stringify(obs)).digest('hex');
  return obs;
};
let recordClock = Date.now();
const recordObs = (db, observations) => db.query('select public.futbeat_record_live_batch($1,$2,$3) v',
  ['goal_api', new Date((recordClock = Math.max(recordClock + 1000, Date.now()))).toISOString(), JSON.stringify(observations)]);

test('SUSPENDED then resumed: the newest provider state (LIVE) wins, never a final', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1);
  await recordObs(db, [liveObs(m.ext, 'LIVE', 30)]);
  await recordObs(db, [liveObs(m.ext, 'SUSPENDED', 31)]);
  assert.equal((await shown(db, m)).status, 'SUSPENDED');
  await recordObs(db, [liveObs(m.ext, 'LIVE', 32)]);
  assert.equal((await shown(db, m)).status, 'LIVE');
}));

test('ABANDONED evidence before a rescheduled kickoff never absorbs the replayed fixture', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1, { minutes: -5 });
  await recordObs(db, [liveObs(m.ext, 'ABANDONED', 3)]);
  assert.equal((await shown(db, m)).status, 'ABANDONED');
  // Provider reschedules the same fixture id; the calendar moves the kickoff.
  // New kickoff after the ABANDONED observation; the replay is observed at it.
  const kickoff = new Date(recordClock + 1000).toISOString();
  await db.query("update futbeat_private.entities set payload=jsonb_set(payload,'{startTime}',to_jsonb($2::text)) where id=$1", [m.match, kickoff]);
  const result = (await recordObs(db, [liveObs(m.ext, 'LIVE', 3, [1, 0])])).rows[0].v;
  assert.notEqual(result.suppressedByCanonicalTerminal, true);
  const model = await shown(db, m);
  assert.equal(model.status, 'LIVE');
  assert.deepEqual(model.score, { home: 1, away: 0 });
}));

// Review follow-ups.
test('a truncated poll + its resumed poll form one sweep: absence counts; an expired sweep does not', () => withDb(async (db) => {
  const [a, b, c] = await seedLive(db, 3);
  let w = worker(db, goalSim({ pages: [[fixtureOf(a), fixtureOf(b), fixtureOf(c)]] }));
  await w.run('live');
  await nextPoll(db);
  const note = (seen, fromStart, reachedEnd) => db.query('select public.futbeat_note_live_poll($1,$2,$3,$4) v',
    ['goal_api', JSON.stringify(seen), fromStart, reachedEnd]).then((r) => r.rows[0].v);

  // Expired sweep: started long ago, the tail never completes it.
  assert.equal((await note([a.ext], true, false)).complete, false);
  await db.query("update futbeat_private.live_poll_sweep set started_at=now()-interval '1 hour'");
  assert.equal((await note([b.ext], false, true)).complete, false);
  assert.equal(await recoveryRow(db, c.ext), null);

  // Fresh sweep across two polls: A on page 1, B on the resumed page; C gone.
  assert.equal((await note([a.ext], true, false)).complete, false);
  const done = await note([b.ext], false, true);
  assert.equal(done.complete, true);
  assert.equal(done.absent, 1);
  assert.equal((await recoveryRow(db, c.ext)).reason, 'absent_from_live');
  assert.equal(await recoveryRow(db, a.ext), null);
  assert.equal(await recoveryRow(db, b.ext), null);
  // A resumed tail without a sweep start is never complete.
  assert.equal((await note([], false, true)).complete, false);
}));

test('an older SUSPENDED never outlives a later LIVE that went silent', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1, { minutes: -120 });
  await recordObs(db, [liveObs(m.ext, 'LIVE', 30)]);
  await recordObs(db, [liveObs(m.ext, 'SUSPENDED', 40)]);
  await recordObs(db, [liveObs(m.ext, 'LIVE', 41)]);
  assert.equal((await shown(db, m)).status, 'LIVE');
  await db.query("update futbeat_private.provider_observations set received_at=received_at-interval '30 minutes' where canonical_match_id=$1", [m.match]);
  await db.query("update futbeat_private.live_match_state set last_seen_at=last_seen_at-interval '30 minutes',changed_at=changed_at-interval '30 minutes',first_seen_at=first_seen_at-interval '30 minutes' where canonical_match_id=$1", [m.match]);
  const model = await shown(db, m);
  assert.notEqual(model.status, 'SUSPENDED');
  assert.notEqual(model.status, 'LIVE');
}));

test('recovery calls never consume the planner post-match budget', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1, { minutes: -180 });
  for (let i = 0; i < 6; i++) {
    await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,reserved_at,completed_at,metadata)
      values('goal_api','match-detail','test','SUCCEEDED',now(),now(),$1)`,
    [JSON.stringify({ matchId: m.match, bucket: 'recovery', source: 'recovery' })]);
  }
  await db.query("insert into futbeat_private.match_detail_cache values($1,'goal_api',$2,now()-interval '150 minutes','{}')", [m.match, m.ext]);
  const due = (await db.query("select futbeat_private.match_detail_planner_due($1,'recent_hot') v", [m.match])).rows[0].v;
  assert.equal(due, true, 'post-match fetch still due after 6 recovery calls');
}));

test('unknown GOAL statuses are recorded for diagnosis and never inferred as live or final', () => withDb(async (db) => {
  const [m, n] = await seedLive(db, 2);
  let w = worker(db, goalSim({ pages: [[fixtureOf(m, 'LIVE', 60), fixtureOf(n, 'MYSTERY_END', 90)]] }));
  await w.run('live');
  const live = (await db.query("select metadata from futbeat_private.provider_call_ledger where call_kind='live-goal' order by id desc limit 1")).rows[0].metadata;
  assert.deepEqual(live.unmappedStatuses, ['MYSTERY_END']);
  assert.notEqual((await shown(db, n)).status, 'FINISHED_PENDING_VERIFICATION');
  await nextPoll(db);

  w = worker(db, goalSim({ pages: [[]] }));
  await w.run('live');
  await makeDue(db, m.ext);
  w = worker(db, goalSim({ details: { [m.ext]: fixtureOf(m, 'MYSTERY_END', 90, ['2', '3']) } }));
  await w.run('detail-only');
  const detail = (await recoveryLedgerRows(db)).filter((r) => r.metadata.bucket === 'recovery').at(-1).metadata;
  assert.equal(detail.providerStatus, 'MYSTERY_END');
  assert.equal(detail.unmappedStatus, true);
  assert.equal((await recoveryRow(db, m.ext)).state, 'PENDING');
  assert.notEqual((await shown(db, m)).status, 'FINISHED_PENDING_VERIFICATION');
}));

// Production #120 case (generic): the provider keeps a finished fixture LIVE
// 90' in the feed and in detail for hours, then drops it. overdue_live spends
// its budget first; the later complete absence is stronger evidence and must
// reopen a bounded recovery exactly once.
const note = (db, seen, fromStart = true, reachedEnd = true) => db.query('select public.futbeat_note_live_poll($1,$2,$3,$4) v',
  ['goal_api', JSON.stringify(seen), fromStart, reachedEnd]).then((r) => r.rows[0].v);
const settle = (db) => db.query('select futbeat_private.settle_terminal_recovery()');
async function exhaustedOverdue(db) {
  const [m] = await seedLive(db, 1, { minutes: -170 });
  // Last LIVE observation a few minutes ago (real clock, so a later detail
  // fetch is never older than it).
  await db.query('select public.futbeat_record_live_batch($1,$2,$3)', ['goal_api',
    new Date(Date.now() - 5 * 60000).toISOString(), JSON.stringify([liveObs(m.ext, 'LIVE', 90, [2, 3])])]);
  await db.query(`insert into futbeat_private.live_terminal_recovery(provider,external_match_id,canonical_match_id,reason,state,
    last_live_status,detected_at,attempts,next_attempt_at,last_attempt_at,resolved_at,resolution)
    values('goal_api',$1,$2,'overdue_live','EXHAUSTED','LIVE',now()-interval '1 hour',6,now(),now(),now(),'max_attempts')`, [m.ext, m.match]);
  return m;
}

test('production #120: overdue_live exhausted while still LIVE, later absence reopens once and the final lands', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1, { minutes: -160 });
  const live90 = fixtureOf(m, 'LIVE', 90, ['2', '3']);
  let w = worker(db, goalSim({ pages: [[live90]], details: { [m.ext]: live90 } }));
  await w.run('live');
  let row = await recoveryRow(db, m.ext);
  assert.equal(row.reason, 'overdue_live');
  for (let guard = 0; (row = await recoveryRow(db, m.ext)).attempts < 6 && guard < 12; guard++) {
    await makeDue(db, m.ext);
    w = worker(db, goalSim({ details: { [m.ext]: live90 } }));
    await w.run('detail-only');
  }
  await settle(db);
  row = await recoveryRow(db, m.ext);
  assert.deepEqual([row.state, row.reason, row.attempts], ['EXHAUSTED', 'overdue_live', 6]);
  // Still in the feed as LIVE: no new overdue row, still exhausted.
  await nextPoll(db);
  w = worker(db, goalSim({ pages: [[live90]] }));
  await w.run('live');
  assert.equal((await recoveryRow(db, m.ext)).state, 'EXHAUSTED');

  // The fixture finally leaves a complete sweep.
  await nextPoll(db);
  w = worker(db, goalSim({ pages: [[]] }));
  await w.run('live');
  row = await recoveryRow(db, m.ext);
  assert.deepEqual([row.state, row.reason, row.attempts, row.last_attempt_at], ['PENDING', 'absent_from_live', 0, null]);

  await makeDue(db, m.ext);
  w = worker(db, goalSim({ details: { [m.ext]: fixtureOf(m, 'FINISHED', 90, ['2', '3']) } }));
  await w.run('detail-only');
  const model = await shown(db, m);
  assert.equal(model.status, 'FINISHED_PENDING_VERIFICATION');
  assert.deepEqual(model.score, { home: 2, away: 3 });
  row = await recoveryRow(db, m.ext);
  assert.deepEqual([row.state, row.resolution], ['RESOLVED', 'terminal_evidence']);

  // A later LIVE never revives it.
  await nextPoll(db);
  w = worker(db, goalSim({ pages: [[live90]] }));
  await w.run('live');
  assert.equal((await shown(db, m)).status, 'FINISHED_PENDING_VERIFICATION');
}));

test('reopen A/B: exhausted overdue reopens as absent exactly once; exhausted absence never resets', () => withDb(async (db) => {
  const m = await exhaustedOverdue(db);
  assert.equal((await note(db, [])).absent, 1);
  let row = await recoveryRow(db, m.ext);
  assert.deepEqual([row.state, row.reason, row.attempts], ['PENDING', 'absent_from_live', 0]);
  await db.query("update futbeat_private.live_terminal_recovery set attempts=6 where external_match_id=$1", [m.ext]);
  await settle(db);
  assert.equal((await recoveryRow(db, m.ext)).state, 'EXHAUSTED');
  assert.equal((await note(db, [])).absent, 0);
  row = await recoveryRow(db, m.ext);
  assert.deepEqual([row.state, row.reason, row.attempts], ['EXHAUSTED', 'absent_from_live', 6]);
}));

test('reopen C: a pending absence seen absent again keeps attempts and backoff', () => withDb(async (db) => {
  const m = await exhaustedOverdue(db);
  await note(db, []);
  await db.query("update futbeat_private.live_terminal_recovery set attempts=2,next_attempt_at=now()+interval '7 minutes' where external_match_id=$1", [m.ext]);
  const before = await recoveryRow(db, m.ext);
  assert.equal((await note(db, [])).absent, 0);
  const after = await recoveryRow(db, m.ext);
  assert.deepEqual([after.state, after.attempts, after.next_attempt_at.getTime()], ['PENDING', 2, before.next_attempt_at.getTime()]);
}));

test('reopen E: a partial sweep cannot reopen an exhausted overdue; the one reopen never repeats under flapping', () => withDb(async (db) => {
  const m = await exhaustedOverdue(db);
  assert.equal((await note(db, [], false, true)).complete, false, 'tail without its start');
  assert.equal((await note(db, [], true, false)).complete, false, 'truncated start');
  await db.query('delete from futbeat_private.live_poll_sweep');
  assert.deepEqual([(await recoveryRow(db, m.ext)).state, (await recoveryRow(db, m.ext)).reason], ['EXHAUSTED', 'overdue_live']);
  await note(db, []);
  assert.equal((await recoveryRow(db, m.ext)).state, 'PENDING');
  await db.query("update futbeat_private.live_terminal_recovery set attempts=2 where external_match_id=$1", [m.ext]);
  // Back in the feed (still LIVE, still overdue): the absence is cancelled
  // and the overdue lane resumes with the SAME attempt budget; never final.
  const back = await note(db, [m.ext]);
  assert.equal(back.reappeared, 1);
  let row = await recoveryRow(db, m.ext);
  assert.deepEqual([row.state, row.reason, row.attempts], ['PENDING', 'overdue_live', 2]);
  assert.notEqual((await shown(db, m)).status, 'FINISHED_PENDING_VERIFICATION');

  // Flapping after the one reopen: exhausted again, gone again -> no reset.
  await db.query("update futbeat_private.live_terminal_recovery set attempts=6 where external_match_id=$1", [m.ext]);
  await settle(db);
  assert.equal((await note(db, [])).absent, 0);
  row = await recoveryRow(db, m.ext);
  assert.deepEqual([row.state, row.reason, row.attempts], ['EXHAUSTED', 'overdue_live', 6]);
}));

test('reopen D: a fresh (not overdue) disappearance that reappears is CANCELLED, never final', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1, { minutes: -40 });
  await db.query('select public.futbeat_record_live_batch($1,$2,$3)', ['goal_api',
    new Date(Date.now() - 60000).toISOString(), JSON.stringify([liveObs(m.ext, 'LIVE', 38)])]);
  await note(db, []);
  assert.equal((await recoveryRow(db, m.ext)).state, 'PENDING');
  await note(db, [m.ext]);
  const row = await recoveryRow(db, m.ext);
  assert.deepEqual([row.state, row.resolution], ['CANCELLED', 'reappeared']);
  assert.notEqual((await shown(db, m)).status, 'FINISHED_PENDING_VERIFICATION');
}));

test('reopen F/G/H: the reopened absence follows the provider — SUSPENDED stays open, ABANDONED shows, FINISHED resolves', () => withDb(async (db) => {
  for (const [status, expected] of [['SUSPENDED', 'PENDING'], ['ABANDONED', 'RESOLVED'], ['FINISHED', 'RESOLVED']]) {
    await nextPoll(db);
    const m = await exhaustedOverdue(db);
    await note(db, []);
    await makeDue(db, m.ext);
    const w = worker(db, goalSim({ details: { [m.ext]: fixtureOf(m, status, 90, ['2', '3']) } }));
    await w.run('detail-only');
    const row = await recoveryRow(db, m.ext);
    assert.equal(row.state, expected, status);
    const model = await shown(db, m);
    if (status === 'FINISHED') assert.equal(model.status, 'FINISHED_PENDING_VERIFICATION');
    else assert.notEqual(model.status, 'FINISHED_PENDING_VERIFICATION', status);
    if (status === 'ABANDONED') assert.equal(model.status, 'ABANDONED');
  }
}));
