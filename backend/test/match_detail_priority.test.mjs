import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

let seq = 0;
async function seedMatch(db, {
  status = 'SCHEDULED', startOffsetMinutes = 0, cache = null,
} = {}) {
  seq += 1;
  const competition = `fb_dp_comp_${seq}`;
  const home = `fb_dp_home_${seq}`;
  const away = `fb_dp_away_${seq}`;
  const match = `fb_dp_match_${seq}`;
  const external = `dp-ext-${seq}`;
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)", [
    competition, JSON.stringify({ id: competition, name: 'Competition ' + seq }),
  ]);
  for (const [id, name] of [[home, 'Home'], [away, 'Away']]) {
    await db.query("insert into futbeat_private.entities values($1,'team',$2)", [
      id, JSON.stringify({ id, name }),
    ]);
  }
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [
    match,
    JSON.stringify({
      id: match, competitionId: competition, homeTeamId: home, awayTeamId: away,
      status,
      startTime: new Date(Date.now() + startOffsetMinutes * 60000).toISOString(),
      score: null, events: [], statistics: [],
    }),
  ]);
  await db.query(
    'insert into futbeat_private.provider_entities values($1,$2,$3,$4)',
    ['goal_api', 'match', external, match],
  );
  if (cache) {
    await db.query(
      "insert into futbeat_private.match_detail_cache(match_id,provider,external_match_id,fetched_at,payload) values($1,'goal_api',$2,$3,'{}'::jsonb)",
      [match, external, cache],
    );
  }
  return { match, competition, home, away, external };
}

async function liveState(db, match, { lastSeenAgoMinutes = 20, status = 'LIVE' } = {}) {
  await db.query(
    `insert into futbeat_private.live_match_state(
      provider,external_match_id,canonical_match_id,status,minute,last_payload_hash,
      first_seen_at,last_seen_at,changed_at)
     values('goal_api',$1,$2,$3,10,$4,now(),now()-($5||' minutes')::interval,now()-($5||' minutes')::interval)`,
    [`live-${match}`, match, status, 'a'.repeat(64), String(lastSeenAgoMinutes)],
  );
}

async function follow(db, subjectType, subjectId, { followers = 1 } = {}) {
  await db.query(
    `insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth)
     values($1,$2,$3,'DEEP') on conflict(subject_type,subject_id) do update set explicit_followers=excluded.explicit_followers`,
    [subjectType, subjectId, followers],
  );
}

async function relevance(db, competition, { score = 900, source = 'editorial' } = {}) {
  await db.query(
    `insert into futbeat_private.competition_editorial_metadata(
       competition_id,competition_class,relevance_score,source)
     values($1,'domestic_league',$2,$3)
     on conflict(competition_id) do update set relevance_score=excluded.relevance_score,source=excluded.source`,
    [competition, score, source],
  );
}

async function temporaryInterest(db, entityType, entityId, { expiresInMinutes = 60 } = {}) {
  const touched = expiresInMinutes <= 0 ? -Math.abs(expiresInMinutes) - 120 : -5;
  const userId = `00000000-0000-0000-0000-${String(seq).padStart(12, '0')}`;
  await db.query(
    `insert into futbeat_private.temporary_interests(user_id,entity_type,entity_id,touched_at,expires_at)
     values($1,$2,$3,now()+($4||' minutes')::interval,now()+($5||' minutes')::interval)`,
    [userId, entityType, entityId, String(touched), String(expiresInMinutes)],
  );
}

const enqueue = (db) => db.query('select public.futbeat_enqueue_stale_live_detail() v').then((r) => r.rows[0].v);
const reserve = (db) => db.query("select public.futbeat_reserve_match_detail_call('test') v").then((r) => r.rows[0].v);
const pendingRow = (db, match) => db.query(
  'select requested_at,expires_at,request_count from futbeat_private.match_detail_requests where match_id=$1',
  [match],
).then((r) => r.rows[0]);

test('reservation migration preserves all pre-existing quota/order/cache logic verbatim', async () => {
  const folder = new URL('../../supabase/migrations/', import.meta.url);
  const before = await readFile(new URL('20260918213000_match_event_history.sql', folder), 'utf8');
  const after = await readFile(new URL('20260922194540_guard_match_detail_inflight.sql', folder), 'utf8');
  const definition = (sql) => sql.replaceAll('\r\n', '\n').match(
    /create or replace function futbeat_private\.reserve_match_detail_call\([\s\S]*?\n\$\$;/,
  )[0];
  const restored = definition(after)
    .replace(/    -- In-flight candidates[\s\S]*?\n    \)\n/, '')
    .replace(/  -- Preserve the existing quota lock above;[\s\S]*?\n  end if;\n\n/, '');
  assert.equal(restored, definition(before));
});

test('tier 0 unchanged: LIVE via live_match_state with no interest still enqueues', async () => {
  const db = await openDatabase();
  try {
    const { match } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -40 });
    await liveState(db, match, { lastSeenAgoMinutes: 20 });
    assert.equal(await enqueue(db), match);
    assert.ok(await pendingRow(db, match));
  } finally { await db.close(); }
});

test('tier 0 unchanged: fresh cache after last_seen_at is not re-enqueued', async () => {
  const db = await openDatabase();
  try {
    const { match, external } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -40 });
    await liveState(db, match, { lastSeenAgoMinutes: 20 });
    await db.query(
      "insert into futbeat_private.match_detail_cache(match_id,provider,external_match_id,fetched_at,payload) values($1,'goal_api',$2,now(),'{}'::jsonb)",
      [match, external],
    );
    assert.equal(await enqueue(db), null);
  } finally { await db.close(); }
});

test('tier 0 order regression: most recently seen LIVE match wins (last_seen_at DESC)', async () => {
  const db = await openDatabase();
  try {
    const older = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -60 });
    await liveState(db, older.match, { lastSeenAgoMinutes: 30 });
    const newer = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -60 });
    await liveState(db, newer.match, { lastSeenAgoMinutes: 16 });
    assert.equal(await enqueue(db), newer.match);
  } finally { await db.close(); }
});

test('tier 0 order regression: equal last_seen_at breaks by startTime DESC (most recent kickoff first)', async () => {
  const db = await openDatabase();
  try {
    const earlier = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -80 });
    const later = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
    const stamp = new Date(Date.now() - 20 * 60000).toISOString();
    for (const { match } of [earlier, later]) {
      await db.query(
        `insert into futbeat_private.live_match_state(
          provider,external_match_id,canonical_match_id,status,minute,last_payload_hash,
          first_seen_at,last_seen_at,changed_at)
         values('goal_api',$1,$2,'LIVE',10,$3,$4,$4,$4)`,
        [`live-${match}`, match, 'a'.repeat(64), stamp],
      );
    }
    assert.equal(await enqueue(db), later.match);
  } finally { await db.close(); }
});

test('tier 1 new: favorite team match is LIVE by canonical status without a live_match_state row', async () => {
  const db = await openDatabase();
  try {
    const { match, home } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
    await follow(db, 'team', home);
    assert.equal(await enqueue(db), match);
  } finally { await db.close(); }
});

test('tier 1 new: followed competition (not team) qualifies a LIVE match', async () => {
  const db = await openDatabase();
  try {
    const { match, competition } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
    await follow(db, 'competition', competition);
    assert.equal(await enqueue(db), match);
  } finally { await db.close(); }
});

test('tier 1 new: authoritative editorial relevance >=800 qualifies a LIVE match with zero follows', async () => {
  const db = await openDatabase();
  try {
    const { match, competition } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
    await relevance(db, competition, { score: 900, source: 'editorial' });
    assert.equal(await enqueue(db), match);
  } finally { await db.close(); }
});

test('tier 1 new: derived-source high score never counts as relevance', async () => {
  const db = await openDatabase();
  try {
    const { match, competition } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
    await relevance(db, competition, { score: 900, source: 'derived' });
    assert.equal(await enqueue(db), null);
  } finally { await db.close(); }
});

test('tier 1 new: provider-source high score never counts as relevance either (only editorial does)', async () => {
  const db = await openDatabase();
  try {
    const { match, competition } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
    await relevance(db, competition, { score: 950, source: 'provider' });
    assert.equal(await enqueue(db), null);
  } finally { await db.close(); }
});

test('tier 1 new: missing editorial metadata (no row at all) never counts as relevance', async () => {
  const db = await openDatabase();
  try {
    const { match } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
    assert.equal(await enqueue(db), null);
  } finally { await db.close(); }
});

test('tier 1 new: editorial relevance below 800 does not qualify even though source is trusted', async () => {
  const db = await openDatabase();
  try {
    const { match, competition } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
    await relevance(db, competition, { score: 799, source: 'editorial' });
    assert.equal(await enqueue(db), null);
  } finally { await db.close(); }
});

test('tier 1 new: an expired temporary_interests row does not count as demand', async () => {
  const db = await openDatabase();
  try {
    const { match, home } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
    await temporaryInterest(db, 'team', home, { expiresInMinutes: -10 });
    assert.equal(await enqueue(db), null);
  } finally { await db.close(); }
});

test('tier 1 new: an unexpired temporary_interests row on the home/away team counts as real demand', async () => {
  const db = await openDatabase();
  try {
    const { match, away } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
    await temporaryInterest(db, 'team', away, { expiresInMinutes: 30 });
    assert.equal(await enqueue(db), match);
  } finally { await db.close(); }
});

test('tier 1 new: an unexpired temporary_interests row on the competition also counts as demand', async () => {
  const db = await openDatabase();
  try {
    const { match, competition } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
    await temporaryInterest(db, 'competition', competition, { expiresInMinutes: 30 });
    assert.equal(await enqueue(db), match);
  } finally { await db.close(); }
});

test('tier 1 new: a stale aggregate coverage_interests.temporary_users cannot substitute for a real temporary interest', async () => {
  const db = await openDatabase();
  try {
    const { match, home } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
    await db.query(
      `insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,temporary_users,depth)
       values('team',$1,0,999,'TEMPORARY')`,
      [home],
    );
    assert.equal(await enqueue(db), null);
  } finally { await db.close(); }
});

test('tier 1 new: a LIVE-by-status match with zero follows/relevance/temporary interest and no live_match_state row is not enqueued', async () => {
  const db = await openDatabase();
  try {
    await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
    assert.equal(await enqueue(db), null);
  } finally { await db.close(); }
});

test('tier 2 new: pre-hydrates a followed match kicking off in 10 minutes that was never fetched', async () => {
  const db = await openDatabase();
  try {
    const { match, home } = await seedMatch(db, { status: 'SCHEDULED', startOffsetMinutes: 10 });
    await follow(db, 'team', home);
    assert.equal(await enqueue(db), match);
  } finally { await db.close(); }
});

test('tier 2 new: pre-hydrates on a live temporary interest even without an explicit follow', async () => {
  const db = await openDatabase();
  try {
    const { match, home } = await seedMatch(db, { status: 'SCHEDULED', startOffsetMinutes: 10 });
    await temporaryInterest(db, 'team', home, { expiresInMinutes: 30 });
    assert.equal(await enqueue(db), match);
  } finally { await db.close(); }
});

test('tier 2 new: does not pre-hydrate beyond the 30-minute window', async () => {
  const db = await openDatabase();
  try {
    const { match, home } = await seedMatch(db, { status: 'SCHEDULED', startOffsetMinutes: 45 });
    await follow(db, 'team', home);
    assert.equal(await enqueue(db), null);
  } finally { await db.close(); }
});

test('tier 2 new: does not re-trigger once any detail has already been fetched', async () => {
  const db = await openDatabase();
  try {
    const { match, home } = await seedMatch(db, {
      status: 'SCHEDULED', startOffsetMinutes: 10, cache: new Date(Date.now() - 3600000).toISOString(),
    });
    await follow(db, 'team', home);
    assert.equal(await enqueue(db), null);
  } finally { await db.close(); }
});

test('tier 2 new: no blanket pre-hydration for a match with zero demand', async () => {
  const db = await openDatabase();
  try {
    await seedMatch(db, { status: 'SCHEDULED', startOffsetMinutes: 10 });
    assert.equal(await enqueue(db), null);
  } finally { await db.close(); }
});

test('tier ordering: an unconditional LIVE candidate always wins over a pre-hydration candidate', async () => {
  const db = await openDatabase();
  try {
    const live = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -40 });
    await liveState(db, live.match, { lastSeenAgoMinutes: 20 });
    const upcoming = await seedMatch(db, { status: 'SCHEDULED', startOffsetMinutes: 5 });
    await follow(db, 'team', upcoming.home, { followers: 50 });
    assert.equal(await enqueue(db), live.match);
  } finally { await db.close(); }
});

test('never competes with an unexpired explicit Match Center request, and touches nothing', async () => {
  const db = await openDatabase();
  try {
    const requested = await seedMatch(db, { status: 'SCHEDULED', startOffsetMinutes: -100 });
    await db.query(
      "insert into futbeat_private.match_detail_requests(match_id,requested_at,expires_at,request_count) values($1,now(),now()+interval '5 minutes',1)",
      [requested.match],
    );
    const live = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -40 });
    await liveState(db, live.match, { lastSeenAgoMinutes: 20 });
    const before = await pendingRow(db, requested.match);
    assert.equal(await enqueue(db), null);
    assert.equal((await pendingRow(db, live.match)), undefined);
    assert.deepEqual(await pendingRow(db, requested.match), before);
  } finally { await db.close(); }
});

test('concurrency/idempotency: repeated enqueue calls never duplicate the row and the advisory lock guard is present', async () => {
  const db = await openDatabase();
  try {
    const { match } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -40 });
    await liveState(db, match, { lastSeenAgoMinutes: 20 });
    assert.equal(await enqueue(db), match);
    const first = await pendingRow(db, match);
    assert.equal(first.request_count, 1);
    // A second "racing" caller (simulated back-to-back here, since the
    // pending-request guard plus the advisory lock make the check+insert
    // atomic against real concurrent callers too) must not create a second
    // row or increment request_count from an unrelated candidate search.
    assert.equal(await enqueue(db), null);
    assert.deepEqual(await pendingRow(db, match), first);
    assert.equal(
      (await db.query('select count(*)::int n from futbeat_private.match_detail_requests where match_id=$1', [match])).rows[0].n,
      1,
    );
    const source = (await db.query(
      "select prosrc from pg_proc where oid='futbeat_private.enqueue_stale_interested_match_detail()'::regprocedure",
    )).rows[0].prosrc;
    assert.match(source, /pg_advisory_xact_lock\(hashtext\('futbeat-match-detail-enqueue'\)\)/);
  } finally { await db.close(); }
});

test('same match has only one allowed reservation before store completes', async () => {
  const db = await openDatabase();
  try {
    const { match } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -40 });
    await liveState(db, match, { lastSeenAgoMinutes: 20 });
    assert.equal(await enqueue(db), match);
    const first = await reserve(db);
    assert.equal(first.allowed, true);
    assert.equal(first.matchId, match);
    const second = await reserve(db);
    assert.equal(second.allowed, false);
    assert.equal(
      (await db.query(
        "select count(*)::int n from futbeat_private.provider_call_ledger where metadata->>'matchId'=$1",
        [match],
      )).rows[0].n,
      1,
    );
  } finally { await db.close(); }
});

test('in-flight first match does not prevent reserving a different queued match', async () => {
  const db = await openDatabase();
  try {
    const first = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -40 });
    const second = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -40 });
    await db.query(`insert into futbeat_private.match_detail_requests values
      ($1,now(),now()+interval '10 minutes',1),
      ($2,now()-interval '1 minute',now()+interval '10 minutes',1)`, [first.match, second.match]);
    const a = await reserve(db);
    const b = await reserve(db);
    assert.equal(a.allowed, true);
    assert.equal(b.allowed, true);
    assert.equal(a.matchId, first.match);
    assert.equal(b.matchId, second.match);
    assert.equal((await reserve(db)).allowed, false);
    const counts = (await db.query(`select metadata->>'matchId' id,count(*)::int n
      from futbeat_private.provider_call_ledger where call_kind='match-detail'
      and status='RESERVED' group by metadata->>'matchId'`)).rows;
    assert.equal(counts.length, 2);
    assert.ok(counts.every((row) => row.n === 1));
  } finally { await db.close(); }
});

test('FAILED releases flight; existing cache eligibility still controls retry', async () => {
  const db = await openDatabase();
  try {
    const { match, external } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -40 });
    await db.query("insert into futbeat_private.match_detail_requests values($1,now(),now()+interval '10 minutes',1)", [match]);
    const first = await reserve(db);
    await db.query(`select public.futbeat_complete_provider_call($1,'FAILED',null,500,'TEST_FAILURE',$2)`,
      [first.reservationId, JSON.stringify({ matchId: match })]);
    // Detail has no extra failure-delay column: preserve the existing cache cooldown.
    await db.query("insert into futbeat_private.match_detail_cache values($1,'goal_api',$2,now(),'{}')", [match, external]);
    assert.equal((await reserve(db)).allowed, false);
    await db.query("update futbeat_private.match_detail_cache set fetched_at=now()-interval '6 minutes' where match_id=$1", [match]);
    assert.equal((await reserve(db)).allowed, true);
    assert.equal((await reserve(db)).allowed, false);
    assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_call_ledger where status='RESERVED'")).rows[0].n, 1);
  } finally { await db.close(); }
});

test('completed SUCCEEDED with fresh detail cannot duplicate; stale detail may retry', async () => {
  const db = await openDatabase();
  try {
    const { match, external } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -40 });
    await db.query("insert into futbeat_private.match_detail_requests values($1,now(),now()+interval '10 minutes',1)", [match]);
    const first = await reserve(db);
    await db.query("select public.futbeat_store_match_detail($1,$2,now(),'{}'::jsonb)", [match, external]);
    await db.query("select public.futbeat_complete_provider_call($1,'SUCCEEDED',null,200,null,$2)",
      [first.reservationId, JSON.stringify({ matchId: match })]);
    assert.equal((await reserve(db)).allowed, false);
    await db.query("update futbeat_private.match_detail_cache set fetched_at=now()-interval '6 minutes' where match_id=$1", [match]);
    assert.equal((await reserve(db)).allowed, true);
  } finally { await db.close(); }
});

test('expired flight permits retry without refunding its quota or modifying the request', async () => {
  const db = await openDatabase();
  try {
    const { match } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -40 });
    await db.query("insert into futbeat_private.match_detail_requests values($1,now(),now()+interval '10 minutes',1)", [match]);
    const before = await pendingRow(db, match);
    const first = await reserve(db);
    await db.query("update futbeat_private.provider_call_ledger set reserved_at=now()-interval '10 minutes' where id=$1", [first.reservationId]);
    assert.equal((await reserve(db)).allowed, true);
    assert.equal((await reserve(db)).allowed, false);
    assert.deepEqual(await pendingRow(db, match), before);
    const counts = (await db.query(`select count(*)::int total,
      count(*) filter(where status='RESERVED' and completed_at is null
        and reserved_at>now()-interval '10 minutes')::int active
      from futbeat_private.provider_call_ledger where metadata->>'matchId'=$1`, [match])).rows[0];
    assert.deepEqual(counts, { total: 2, active: 1 });
  } finally { await db.close(); }
});

test('detail daily quota and remaining reserve unchanged; denied attempts add no ledger rows', async () => {
  const db = await openDatabase();
  try {
    const { match } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -40 });
    await db.query("insert into futbeat_private.match_detail_requests values($1,now(),now()+interval '10 minutes',1)", [match]);
    await db.exec(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,provider_remaining)
      values('goal_api','live','test','SUCCEEDED',80)`);
    assert.equal((await reserve(db)).reason, 'provider_remaining_reserve');
    assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 1);
    await db.exec(`update futbeat_private.provider_call_ledger set provider_remaining=81;
      insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status)
      select 'goal_api','match-detail','test','FAILED' from generate_series(1,23)`);
    assert.equal((await reserve(db)).allowed, true);
    assert.equal((await reserve(db)).reason, 'detail_daily_limit');
    assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_call_ledger where call_kind='match-detail'")).rows[0].n, 24);
  } finally { await db.close(); }
});

test('enqueued candidate is a real, reservable match-detail request (downstream contract unchanged)', async () => {
  const db = await openDatabase();
  try {
    const { match, external } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
    await relevance(db, (await db.query(
      "select payload->>'competitionId' c from futbeat_private.entities where id=$1", [match],
    )).rows[0].c, { score: 950, source: 'editorial' });
    assert.equal(await enqueue(db), match);
    const reservation = await reserve(db);
    assert.equal(reservation.allowed, true);
    assert.equal(reservation.matchId, match);
    assert.equal(reservation.externalMatchId, external);
  } finally { await db.close(); }
});

test('read-only planning: no ledger/coverage writes from the enqueuer itself, and the private helper stays revoked', async () => {
  const db = await openDatabase();
  try {
    const { match, competition } = await seedMatch(db, { status: 'LIVE', startOffsetMinutes: -20 });
    await relevance(db, competition, { score: 900, source: 'editorial' });
    const before = (await db.query(
      'select count(*)::int n from futbeat_private.provider_call_ledger',
    )).rows[0].n;
    assert.equal(await enqueue(db), match);
    const after = (await db.query(
      'select count(*)::int n from futbeat_private.provider_call_ledger',
    )).rows[0].n;
    assert.equal(after, before);
    for (const role of ['anon', 'authenticated']) {
      assert.equal((await db.query(
        "select has_function_privilege($1,'futbeat_private.enqueue_stale_interested_match_detail()','EXECUTE') v",
        [role],
      )).rows[0].v, false);
    }
  } finally { await db.close(); }
});
