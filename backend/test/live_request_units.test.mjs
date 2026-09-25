import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { worker } from './helpers/worker_harness.mjs';

// Quota units are real provider requests, not ledger rows: a paginated LIVE
// poll spends one unit per page, failures keep the requests already spent,
// and a poll never pages through the protected LIVE reserve. The real GOAL
// worker runs against real SQL and a simulated GOAL API (no network).

let seq = 0;
// n mapped matches kicked off `minutes` ago; the calendar was ingested earlier.
async function seedLive(db, n, { minutes = -30 } = {}) {
  const out = [];
  for (let i = 0; i < n; i++) {
    const k = ++seq;
    const ids = { comp: `fb_comp_ru${k}`, home: `fb_team_ru${k}h`, away: `fb_team_ru${k}a`, match: `fb_match_ru${k}`, ext: `ru-${k}` };
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
const fixtureOf = (m, status = 'LIVE', minute = 30) => ({ apiId: m.ext, kickoffUtc: m.start, matchStatus: status,
  matchElapsed: minute, homeTeamScore: '1', awayTeamScore: '0',
  homeTeam: { id: `${m.ext}-h`, name: 'H' }, awayTeam: { id: `${m.ext}-a`, name: 'A' } });

// Simulated GOAL: /fixtures/live paginated (pageSize fixtures per page),
// remaining decreases per request; `failAt` makes that request fail.
function goal({ pages, remainingStart = 700, failAt = null }) {
  let remaining = remainingStart;
  let requests = 0;
  return (url) => {
    requests += 1;
    remaining -= 1;
    const headers = { 'x-ratelimit-remaining': String(remaining), 'content-type': 'application/json' };
    if (url.pathname !== '/v1/fixtures/live') {
      return new Response(JSON.stringify({ success: true, data: [] }), { status: 200, headers });
    }
    if (failAt === requests) {
      return new Response(JSON.stringify({ success: false }), { status: 500, headers });
    }
    const offset = Number(url.searchParams.get('offset') ?? 0);
    const index = Math.floor(offset / 100);
    const data = pages[index] ?? [];
    return new Response(JSON.stringify({ success: true, data,
      pagination: { total: pages.flat().length, limit: 100, hasMore: index + 1 < pages.length } }), { status: 200, headers });
  };
}
const liveRows = (db) => db.query(`select status,provider_remaining,metadata from futbeat_private.provider_call_ledger
  where call_kind='live-goal' order by id`).then((r) => r.rows);
const units = (db, kind) => db.query(`select coalesce(sum(futbeat_private.provider_call_units(metadata)),0)::int n
  from futbeat_private.provider_call_ledger where call_kind=$1`, [kind]).then((r) => r.rows[0].n);
const nextPoll = (db) => db.query("update futbeat_private.provider_call_ledger set reserved_at=reserved_at-interval '5 minutes' where call_kind='live-goal'");
const livePath = (w) => w.goalCalls().filter((u) => u.includes('/fixtures/live'));
async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

test('1/2/3. units are real requests: 1 page = 1 unit, 2 pages = 2, two 2-page polls = 2 rows / 4 units', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1);
  let w = worker(db, goal({ pages: [[fixtureOf(m)]] }));
  assert.equal((await w.run('live')).live.status, 'ok');
  assert.equal(livePath(w).length, 1);
  assert.equal((await liveRows(db))[0].metadata.providerRequests, 1);
  assert.equal(await units(db, 'live-goal'), 1);

  await db.query("delete from futbeat_private.provider_call_ledger where call_kind='live-goal'");
  const filler = Array.from({ length: 100 }, (_, i) => ({ ...fixtureOf(m), apiId: `unmapped-${i}` }));
  for (let poll = 0; poll < 2; poll++) {
    w = worker(db, goal({ pages: [filler, [fixtureOf(m)]] }));
    await w.run('live');
    assert.equal(livePath(w).length, 2);
    await nextPoll(db);
  }
  const rows = await liveRows(db);
  assert.equal(rows.length, 2, 'one reservation per poll');
  assert.deepEqual(rows.map((r) => r.metadata.providerRequests), [2, 2]);
  assert.equal(await units(db, 'live-goal'), 4);
  const status = (await db.query('select public.futbeat_provider_quota_status() v')).rows[0].v;
  assert.equal(status.requestUnitsByKind['live-goal'], 4);
  assert.equal(status.callsByKind['live-goal'], 2);
  assert.equal(status.live.pollCyclesToday, 2);
  assert.equal(Number(status.live.providerRequestsToday), 4);
  assert.equal(Number(status.live.averagePagesPerPoll), 2);
  assert.equal(status.live.lastProviderRequests, 2);
}));

test('4. rows without providerRequests (old or non-paginated) count conservatively as 1', () => withDb(async (db) => {
  const v = async (meta) => (await db.query('select futbeat_private.provider_call_units($1::jsonb) n', [meta])).rows[0].n;
  assert.equal(await v('{}'), 1);
  assert.equal(await v(null), 1);
  assert.equal(await v('{"providerRequests":0}'), 1);
  assert.equal(await v('{"providerRequests":"7"}'), 1, 'non-numeric is not trusted');
  assert.equal(await v('{"providerRequests":3}'), 3);
  assert.equal(await v('{"providerRequests":-5}'), 1);
  assert.equal(await v('{"providerRequests":1e9}'), 1000, 'bounded');
  // Clamped as numeric before the integer cast: never "integer out of range".
  assert.equal(await v('{"providerRequests":1e20}'), 1000);
  assert.equal(await v('{"providerRequests":99999999999999999999999999999999999999}'), 1000);
  assert.equal(await v('{"providerRequests":1e300}'), 1000);
  assert.equal(await v('{"providerRequests":-1e300}'), 1);
  // Existing kinds keep their contract: one row = one unit.
  await db.exec(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status)
    select 'goal_api','match-detail','test','SUCCEEDED' from generate_series(1,5)`);
  assert.equal((await db.query("select futbeat_private.quota_decision('goal_api','match-detail','user') v")).rows[0].v.usedToday, 5);
}));

test('5. unknown remaining: the live-goal safety cap is evaluated in request units, not rows', () => withDb(async (db) => {
  await seedLive(db, 1);
  await db.exec(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,reserved_at,metadata)
    select 'goal_api','live-goal','test','SUCCEEDED',now()-interval '10 minutes','{"providerRequests":2}' from generate_series(1,200)`);
  const r = (await db.query("select public.futbeat_reserve_goal_live_call('test') v")).rows[0].v;
  assert.equal(r.allowed, false, '200 rows are 400 units: the cap is reached');
  assert.equal(r.reason, 'kind_daily_cap');
  assert.equal(r.liveUsed, 400);
  // The blind total also counts units for background classes.
  const bg = (await db.query("select futbeat_private.quota_decision('goal_api','match-detail','coverage') v")).rows[0].v;
  assert.equal(bg.totalToday, 400);
}));

test('an in-flight LIVE poll commits its whole page budget; completion releases the unused pages', () => withDb(async (db) => {
  await seedLive(db, 1);
  const decision = async (kind, cls) => (await db.query('select futbeat_private.quota_decision($1,$2,$3) v', ['goal_api', kind, cls])).rows[0].v;
  // Unknown remaining and an empty ledger: room for the full page budget.
  const r = (await db.query("select public.futbeat_reserve_goal_live_call('test') v")).rows[0].v;
  assert.equal(r.allowed, true);
  assert.ok(r.pageBudget > 1, `pageBudget ${r.pageBudget}`);
  assert.equal(r.liveUsed, r.pageBudget);
  // Before completion every other reserver sees every committed unit, not 1.
  assert.equal((await decision('live-goal', 'live')).usedToday, r.pageBudget);
  assert.equal((await decision('match-detail', 'coverage')).totalToday, r.pageBudget);
  // The poll used 2 pages: completion values win, no double counting.
  await db.query(`select public.futbeat_complete_provider_call($1,'SUCCEEDED',null,200,null,'{"providerRequests":2}'::jsonb)`, [r.reservationId]);
  assert.equal((await decision('live-goal', 'live')).usedToday, 2);
  assert.equal((await decision('match-detail', 'coverage')).totalToday, 2);
  assert.equal(await units(db, 'live-goal'), 2);
  const [row] = await liveRows(db);
  assert.equal(row.metadata.providerRequests, 2);
  assert.equal(row.metadata.pageBudget, r.pageBudget, 'the budget stays for observability');
}));

test('6. a failure after several pages keeps every request spent and the reported remaining', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1);
  const filler = Array.from({ length: 100 }, (_, i) => ({ ...fixtureOf(m), apiId: `unmapped-${i}` }));
  const w = worker(db, goal({ pages: [filler, filler, [fixtureOf(m)]], remainingStart: 600, failAt: 3 }));
  assert.equal((await w.run('live')).live.status, 'failed');
  const [row] = await liveRows(db);
  assert.equal(row.status, 'FAILED');
  assert.equal(row.metadata.providerRequests, 3, 'two good pages + the failed one');
  assert.equal(row.provider_remaining, 597, 'remaining from the failed response');
  assert.equal(await units(db, 'live-goal'), 3);
}));

test('7. results-date: the central decision and its background guard count request units', () => withDb(async (db) => {
  await db.exec(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,metadata)
    values('goal_api','results-date','test','SUCCEEDED','{"providerRequests":3}'),
          ('goal_api','results-date','test','FAILED','{"providerRequests":2}')`);
  const d = (await db.query("select futbeat_private.quota_decision('goal_api','results-date','results') v")).rows[0].v;
  assert.equal(d.usedToday, 5, 'failed paginated calls are no longer counted as 1');
  const src = (await db.query("select prosrc from pg_proc where oid='futbeat_private.reserve_goal_results_date(text)'::regprocedure")).rows[0].prosrc;
  assert.match(src, /provider_call_units/);
  assert.doesNotMatch(src, /\(metadata->>'providerRequests'\)::integer/);
}));

test('8. near the floor a poll never pages through the protected LIVE reserve', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1);
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,provider_remaining,reserved_at,completed_at)
    values('goal_api','global-ingest','test','SUCCEEDED',23,now(),now())`);
  const filler = Array.from({ length: 100 }, (_, i) => ({ ...fixtureOf(m), apiId: `unmapped-${i}` }));
  // Five pages needed; remaining goes 22, 21, 20 ... per request.
  const w = worker(db, goal({ pages: [filler, filler, filler, filler, [fixtureOf(m)]], remainingStart: 23 }));
  const result = await w.run('live');
  assert.equal(result.live.status, 'ok');
  assert.equal(result.live.paginationTruncated, true);
  assert.equal(livePath(w).length, 3, 'page budget = remaining 23 - floor 20');
  const [row] = await liveRows(db);
  assert.equal(row.metadata.pageBudget, 3);
  assert.equal(row.metadata.paginationTruncated, true);
  assert.equal(row.metadata.resumeOffset, 300);
  assert.equal(row.provider_remaining, 20, 'stopped at the floor, never below it');
  // At the floor the next poll is refused by the central policy.
  await nextPoll(db);
  assert.equal((await db.query("select public.futbeat_reserve_goal_live_call('test') v")).rows[0].v.reason, 'provider_remaining_reserve');
}));

test('8b. the observed remaining stops paging even inside the page budget', () => withDb(async (db) => {
  const [m] = await seedLive(db, 1);
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,provider_remaining,reserved_at,completed_at)
    values('goal_api','global-ingest','test','SUCCEEDED',500,now(),now())`);
  const filler = Array.from({ length: 100 }, (_, i) => ({ ...fixtureOf(m), apiId: `unmapped-${i}` }));
  // The ledger is stale (500) but the provider now reports 22, 21, 20...
  const w = worker(db, goal({ pages: [filler, filler, filler, filler, [fixtureOf(m)]], remainingStart: 23 }));
  await w.run('live');
  assert.equal(livePath(w).length, 3);
  assert.equal((await liveRows(db))[0].provider_remaining, 20);
}));

test('9. a partial batch never produces a false final/scheduled; the next poll resumes where it stopped', () => withDb(async (db) => {
  const [a, b] = await seedLive(db, 2);
  // Both matches are LIVE from a previous complete poll.
  let w = worker(db, goal({ pages: [[fixtureOf(a), fixtureOf(b)]] }));
  await w.run('live');
  await nextPoll(db);
  const shown = async (m) => (await db.query(`select futbeat_private.match_read_model(payload)->>'status' s
    from futbeat_private.entities where id=$1`, [m.match])).rows[0].s;
  assert.equal(await shown(b), 'LIVE');
  // Truncated batch: only the page with A is read (budget 1 via remaining 21).
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,provider_remaining,reserved_at,completed_at)
    values('goal_api','global-ingest','test','SUCCEEDED',21,now(),now())`);
  const filler = Array.from({ length: 99 }, (_, i) => ({ ...fixtureOf(a), apiId: `unmapped-${i}` }));
  w = worker(db, goal({ pages: [[fixtureOf(a, 'LIVE', 40), ...filler], [fixtureOf(b, 'LIVE', 40)]], remainingStart: 300 }));
  const result = await w.run('live');
  assert.equal(result.live.paginationTruncated, true);
  assert.equal(livePath(w).length, 1);
  // B was not read: its state is untouched (still LIVE, not FT, not SCHEDULED).
  assert.equal(await shown(b), 'LIVE');
  const bState = (await db.query('select status from public.live_match_updates where match_id=$1', [b.match])).rows[0];
  assert.equal(bState.status, 'LIVE');
  // The next reservation resumes at the unread page.
  await nextPoll(db);
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,provider_remaining,reserved_at,completed_at)
    values('goal_api','global-ingest','test','SUCCEEDED',400,now(),now())`);
  const next = (await db.query("select public.futbeat_reserve_goal_live_call('test') v")).rows[0].v;
  assert.equal(next.startOffset, 100);
}));

test('one global request per page: never one call per match', () => withDb(async (db) => {
  const ms = await seedLive(db, 30);
  const w = worker(db, goal({ pages: [ms.map((m) => fixtureOf(m))] }));
  await w.run('live');
  assert.equal(livePath(w).length, 1, '30 matches, one global LIVE request');
  // Any per-match /fixtures/{id} call in the same cron cycle is the separate,
  // quota-accounted detail lane: one match-detail reservation per call.
  const detailCalls = w.goalCalls().filter((u) => u.includes('/fixtures/') && !u.includes('/fixtures/live')).length;
  const detailReservations = (await db.query("select count(*)::int n from futbeat_private.provider_call_ledger where call_kind='match-detail'")).rows[0].n;
  assert.equal(detailCalls, detailReservations);
  assert.ok(detailCalls <= 1, 'the detail lane serves at most one match per cycle');
}));
