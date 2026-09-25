import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { worker, goalOk } from './helpers/worker_harness.mjs';

// Issue #98: the standings demand queue is durable (age never drops pending
// work), fair (fresh demands cannot starve old ones), reconciles demands
// already answered, keeps NO_DATA as a negative cache and never shows a
// table of another (competition, season). Everything synthetic: no real
// league, country, team or season is special-cased. No network.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

const rows = (prefix, points = [9, 6], season) => points.map((pts, i) => ({
  overallLeaguePosition: String(i + 1), overallLeaguePlayed: String(Math.floor(pts / 3) + (pts % 3) + 1),
  overallLeagueW: String(Math.floor(pts / 3)), overallLeagueD: String(pts % 3), overallLeagueL: '1',
  overallLeagueGF: '5', overallLeagueGA: '3', overallLeaguePTS: String(pts),
  team: { id: `${prefix}-team-${i}`, name: `${prefix} Team ${i}`, country: { name: 'Nowhere' } },
  ...(season ? { season } : {}),
}));

let seq = 0;
async function competition(db, { name = 'Shared Name League', season = '2026/2027', mapped = true } = {}) {
  const n = ++seq;
  const id = `fb_comp_dl${n}`, ext = `dl-league-${n}`;
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)",
    [id, JSON.stringify({ id, name, country: 'Nowhere', season })]);
  if (mapped) await db.query("insert into futbeat_private.provider_entities values('goal_api','competition',$1,$2)", [ext, id]);
  return { id, ext, n };
}
async function match(db, comp, { season = '2026/2027', status = 'SCHEDULED', offsetHours = 24 } = {}) {
  const id = `fb_match_dl${++seq}`;
  const teams = [`fb_team_dl${seq}a`, `fb_team_dl${seq}b`];
  for (const t of teams) await db.query("insert into futbeat_private.entities values($1,'team',$2)", [t, JSON.stringify({ id: t, name: t })]);
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [id, JSON.stringify({
    id, competitionId: comp.id, homeTeamId: teams[0], awayTeamId: teams[1], season, status,
    startTime: new Date(Date.now() + offsetHours * 3600e3).toISOString(), events: [], statistics: [] })]);
  return id;
}
const storeTable = (db, comp, season, prefix, points, at = new Date().toISOString()) => db.query(
  'select public.futbeat_store_goal_standings($1,$2,$3,$4,$5) v',
  [comp.id, comp.ext, at, season, JSON.stringify(rows(prefix, points))]);
const context = (db, m) => db.query('select public.futbeat_read_match_context($1) v', [m]).then((r) => r.rows[0].v);
const request = (db, m) => db.query('select public.futbeat_request_match_standings($1) v', [m]).then((r) => r.rows[0].v);
const reserve = (db) => db.query("select public.futbeat_reserve_standings_demand_call('test') v").then((r) => r.rows[0].v);
const complete = (db, id, ok, http = 200) => db.query('select public.futbeat_complete_standings_call($1,$2,$3,null) v', [id, ok, http]).then((r) => r.rows[0].v);
const demands = (db) => db.query(`select competition_id,season_key,status,request_count::int n,failure_count::int f,
  lease_until,next_retry_at from futbeat_private.standings_demands order by competition_id`).then((r) => r.rows);
const standingsCalls = (db) => db.query("select count(*)::int n from futbeat_private.provider_call_ledger where call_kind='standings'").then((r) => r.rows[0].n);
const points = (ctx) => ctx.standings.map((t) => t.rows.map((r) => r.points));
const setRemaining = (db, value) => db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,provider_remaining)
  values('goal_api','global-ingest','test',now(),now(),'SUCCEEDED',$1)`, [value]);
const age = (db, comp, minutes) => db.query(`update futbeat_private.standings_demands set
  requested_at=requested_at-make_interval(mins=>$2),queued_at=queued_at-make_interval(mins=>$2) where competition_id=$1`, [comp.id, minutes]);

test('1. fresh exact snapshot: available, no demand, no provider call', () => withDb(async (db) => {
  const comp = await competition(db);
  await storeTable(db, comp, '2026/2027', 'f', [6, 3]);
  const m = await match(db, comp);
  const st = await request(db, m);
  assert.deepEqual([st.standings, st.standingsStale, st.standingsPending], ['available', false, false]);
  assert.equal((await reserve(db)).allowed, false);
  assert.equal(await standingsCalls(db), 0);
  assert.deepEqual(await demands(db), []);
}));

test('2. stale snapshot: the table stays visible while exactly one revalidation is queued', () => withDb(async (db) => {
  const comp = await competition(db);
  await storeTable(db, comp, '2026/2027', 's', [6, 3], new Date(Date.now() - 8 * 3600e3).toISOString());
  const m = await match(db, comp);
  for (let i = 0; i < 5; i++) await request(db, m);
  const ctx = await context(db, m);
  assert.deepEqual(points(ctx), [[6, 3]]);
  assert.deepEqual([ctx.coverage.standings, ctx.coverage.standingsStale, ctx.coverage.standingsPending], ['available', true, true]);
  // The stale table never satisfies its own revalidation.
  const r = await reserve(db);
  assert.equal(r.allowed, true);
  assert.equal(r.competitionId, comp.id);
  assert.equal((await reserve(db)).allowed, false, 'one revalidation, leased');
  // A failed revalidation never hides the existing table.
  await complete(db, r.reservationId, true);
  const after = await context(db, m);
  assert.deepEqual([points(after), after.coverage.standings], [[[6, 3]], 'available']);
}));

test('3/4. missing snapshot: 100 opens -> one demand -> one reservation', () => withDb(async (db) => {
  const comp = await competition(db);
  const ms = [];
  for (let i = 0; i < 5; i++) ms.push(await match(db, comp));
  for (let i = 0; i < 100; i++) {
    const st = await request(db, ms[i % 5]);
    assert.deepEqual([st.standings, st.standingsPending], ['pending', true]);
  }
  const [d] = await demands(db);
  assert.deepEqual([d.status, d.n, d.season_key], ['QUEUED', 100, '2026-2027']);
  const plans = [];
  for (let i = 0; i < 20; i++) plans.push(await reserve(db));
  assert.equal(plans.filter((p) => p.allowed).length, 1);
  assert.equal(await standingsCalls(db), 1);
}));

test('5. quota starvation: a demand queued without quota is served hours later, without reopening', () => withDb(async (db) => {
  const comp = await competition(db);
  const m = await match(db, comp);
  await setRemaining(db, 100); // below the user_high floor
  await request(db, m);
  const blocked = await reserve(db);
  assert.equal(blocked.allowed, false);
  assert.equal(blocked.reason, 'provider_remaining_reserve');
  assert.equal(await standingsCalls(db), 0);
  // Two hours later, still pending (never silently dropped).
  await age(db, comp, 120);
  assert.equal((await context(db, m)).coverage.standings, 'pending');
  // Quota comes back: the same demand is processed by the worker alone.
  await db.query("update futbeat_private.provider_call_ledger set provider_remaining=600 where call_kind='global-ingest'");
  const w = worker(db, (url) => {
    assert.equal(url.pathname, `/v1/standings/${comp.ext}`);
    return goalOk(rows('q', [12, 7], '2026/2027'));
  });
  const run = await w.run();
  assert.deepEqual([run.standings.status, run.standings.demand], ['ok', 'AVAILABLE']);
  assert.equal(w.goalCalls().length, 1);
  const ctx = await context(db, m);
  assert.deepEqual([points(ctx), ctx.coverage.standings, ctx.coverage.standingsPending], [[[12, 7]], 'available', false]);
}));

test('6. an old demand is never ineligible only because of its age', () => withDb(async (db) => {
  const comp = await competition(db);
  await request(db, await match(db, comp));
  await age(db, comp, 3 * 24 * 60);
  const r = await reserve(db);
  assert.equal(r.allowed, true);
  assert.equal(r.competitionId, comp.id);
  assert.equal(r.lane, 'aged');
}));

test('7. fairness: a stream of fresh demands never starves older ones (lanes alternate, aged FIFO)', () => withDb(async (db) => {
  const aged = [];
  for (let i = 0; i < 3; i++) {
    const c = await competition(db);
    await request(db, await match(db, c));
    await age(db, c, 240 - i * 30); // aged[0] is the oldest
    aged.push(c.id);
  }
  const served = [];
  for (let i = 0; i < 6; i++) {
    // A new user demand arrives before every worker run.
    const c = await competition(db);
    await request(db, await match(db, c));
    const r = await reserve(db);
    assert.equal(r.allowed, true);
    served.push({ id: r.competitionId, lane: r.lane });
  }
  const agedServed = served.filter((s) => s.lane === 'aged').map((s) => s.id);
  assert.deepEqual(agedServed, aged, 'every aged demand progresses, oldest first');
  assert.deepEqual(served.map((s) => s.lane), ['aged', 'recent', 'aged', 'recent', 'aged', 'recent']);
  // The recent lane serves the newest request first.
  const recent = served.filter((s) => s.lane === 'recent').map((s) => s.id);
  assert.equal(new Set(recent).size, 3);
}));

test('8. lease: an active lease never duplicates; an expired lease (dead worker) is recoverable', () => withDb(async (db) => {
  const comp = await competition(db);
  await request(db, await match(db, comp));
  const first = await reserve(db);
  assert.equal(first.allowed, true);
  assert.equal((await reserve(db)).reason, 'no_standings_demand');
  await db.query("update futbeat_private.standings_demands set lease_until=now()-interval '1 second' where competition_id=$1", [comp.id]);
  const second = await reserve(db);
  assert.equal(second.allowed, true);
  assert.equal(second.competitionId, comp.id);
  assert.equal(await standingsCalls(db), 2);
}));

test('9. a snapshot that lands after the request answers the demand without another call', () => withDb(async (db) => {
  // Through the standings store (archive trigger).
  const a = await competition(db);
  const ma = await match(db, a);
  await request(db, ma);
  await storeTable(db, a, '2026/2027', 'late', [5, 2]);
  assert.equal((await demands(db))[0].status, 'AVAILABLE');
  // Directly archived exact snapshot (no trigger): reconciled before any spend.
  const b = await competition(db);
  const mb = await match(db, b);
  await request(db, mb);
  await db.query(`insert into futbeat_private.standings_snapshots(competition_id,season_key,season,table_payload,fetched_at)
    values($1,'2026-2027','2026/2027','{"rows":[]}',now())`, [b.id]);
  const r = await reserve(db);
  assert.equal(r.allowed, false);
  assert.equal(r.reason, 'no_standings_demand');
  assert.equal(r.reconciled.satisfied, 1);
  assert.equal(await standingsCalls(db), 0);
  assert.equal((await demands(db)).find((d) => d.competition_id === b.id).status, 'AVAILABLE');
}));

test('10. exact identity: another season of the same competition never answers or is shown', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2025/2026' });
  await storeTable(db, comp, '2025/2026', 'old', [30, 20]);
  await db.query("update futbeat_private.entities set payload=payload||'{\"season\":\"2026/2027\"}' where id=$1", [comp.id]);
  const m = await match(db, comp);
  const st = await request(db, m);
  assert.deepEqual([st.standings, st.standingsPending], ['pending', true]);
  assert.deepEqual((await context(db, m)).standings, []);
  const r = await reserve(db);
  assert.deepEqual([r.allowed, r.seasonKey], [true, '2026-2027']);
  const old = await match(db, comp, { season: '2025-26', status: 'VERIFIED', offsetHours: -2000 });
  assert.deepEqual(points(await context(db, old)), [[30, 20]]);
}));

test('11. same name, different competitions: a snapshot of one never answers the other', () => withDb(async (db) => {
  const a = await competition(db, { name: 'Twin League' });
  const b = await competition(db, { name: 'Twin League' });
  await storeTable(db, a, '2026/2027', 'a', [12, 9]);
  const mb = await match(db, b);
  assert.equal((await request(db, mb)).standings, 'pending');
  const r = await reserve(db);
  assert.equal(r.competitionId, b.id);
  assert.deepEqual((await context(db, mb)).standings, []);
}));

test('12. provider season mismatch: NO_DATA, never the other season', () => withDb(async (db) => {
  const comp = await competition(db);
  const m = await match(db, comp);
  await request(db, m);
  const w = worker(db, () => goalOk(rows('prev', [40, 30], '2025/2026')));
  assert.equal((await w.run()).standings.demand, 'NO_DATA');
  const ctx = await context(db, m);
  assert.deepEqual(ctx.standings, []);
  assert.deepEqual([ctx.coverage.standings, ctx.coverage.standingsPending], ['unavailable', false]);
}));

test('13. NO_DATA negative cache: reopening never requeues before next_retry_at', () => withDb(async (db) => {
  const comp = await competition(db);
  const m = await match(db, comp);
  await request(db, m);
  await complete(db, (await reserve(db)).reservationId, false, 404);
  for (let i = 0; i < 10; i++) {
    const st = await request(db, m);
    assert.deepEqual([st.standings, st.standingsPending], ['unavailable', false]);
  }
  const [d] = await demands(db);
  assert.deepEqual([d.status, d.n], ['NO_DATA', 1]);
  assert.equal((await reserve(db)).allowed, false);
  assert.equal(await standingsCalls(db), 1);
  // After the TTL a new open asks again (one new episode).
  await db.query("update futbeat_private.standings_demands set next_retry_at=now()-interval '1 second'");
  assert.equal((await request(db, m)).standings, 'pending');
  assert.equal((await reserve(db)).allowed, true);
}));

test('14. historical non-fetchable season: no demand, no provider call; a leftover demand is closed', () => withDb(async (db) => {
  const comp = await competition(db, { season: '2026/2027' });
  const old = await match(db, comp, { season: '2024/2025', status: 'VERIFIED', offsetHours: -9000 });
  const st = await request(db, old);
  assert.deepEqual([st.standings, st.standingsPending], ['missing', false]);
  assert.deepEqual(await demands(db), []);
  // A demand queued before a season rollover can never be fetched: closed, not pending forever.
  await db.query(`insert into futbeat_private.standings_demands(competition_id,season_key,external_league_id,queued_at)
    values($1,'2025-2026',$2,now()-interval '5 days')`, [comp.id, comp.ext]);
  const r = await reserve(db);
  assert.equal(r.allowed, false);
  assert.equal(r.reconciled.closed, 1);
  assert.equal(await standingsCalls(db), 0);
  assert.equal((await demands(db))[0].status, 'NO_DATA');
}));

test('transient failures stay queued with backoff, then settle as unavailable (no infinite pending)', () => withDb(async (db) => {
  const comp = await competition(db);
  const m = await match(db, comp);
  await request(db, m);
  for (let attempt = 1; attempt <= 5; attempt++) {
    const r = await reserve(db);
    assert.equal(r.allowed, true, `attempt ${attempt}`);
    const done = await complete(db, r.reservationId, false, 500);
    const [d] = await demands(db);
    assert.equal(d.f, attempt);
    assert.ok(new Date(d.next_retry_at) > new Date(), 'backoff');
    if (attempt < 5) {
      assert.equal(done.status, 'QUEUED');
      assert.equal((await reserve(db)).allowed, false, 'backoff respected');
      assert.equal((await context(db, m)).coverage.standings, 'pending');
      await db.query("update futbeat_private.standings_demands set next_retry_at=now()-interval '1 second'");
    } else {
      assert.equal(done.status, 'FETCH_FAILED');
    }
  }
  assert.deepEqual([(await request(db, m)).standings, (await request(db, m)).standingsPending], ['unavailable', false]);
  assert.equal((await reserve(db)).allowed, false);
}));

test('quota regression: the demand lane stays user_high; LIVE and coverage untouched', () => withDb(async (db) => {
  const comp = await competition(db);
  await request(db, await match(db, comp));
  await setRemaining(db, 200);
  const r = await reserve(db);
  assert.deepEqual([r.allowed, r.class], [true, 'user_high']);
  assert.equal((await db.query("select futbeat_private.quota_decision('goal_api','standings','coverage') v")).rows[0].v.allowed, false);
  const live = (await db.query("select futbeat_private.quota_decision('goal_api','live-goal','live') v")).rows[0].v;
  assert.equal(live.floor, 20);
}));

test('mapping changed after queueing: the reservation uses the current external id, same demand', () => withDb(async (db) => {
  const comp = await competition(db);
  const m = await match(db, comp);
  await request(db, m);
  assert.equal((await db.query('select external_league_id e from futbeat_private.standings_demands')).rows[0].e, comp.ext);
  await db.query("update futbeat_private.provider_entities set external_id='dl-league-remapped' where canonical_id=$1", [comp.id]);
  const r = await reserve(db);
  assert.equal(r.allowed, true);
  assert.equal(r.externalLeagueId, 'dl-league-remapped');
  assert.equal(r.reconciled.remapped, 1);
  const stored = await db.query('select external_league_id e,status from futbeat_private.standings_demands');
  assert.deepEqual(stored.rows, [{ e: 'dl-league-remapped', status: 'QUEUED' }], 'updated in place, no second demand');
  const ledger = (await db.query("select metadata->>'externalLeagueId' e from futbeat_private.provider_call_ledger where call_kind='standings'")).rows;
  assert.deepEqual(ledger, [{ e: 'dl-league-remapped' }]);
  // The worker calls GOAL with the current mapping.
  await db.query("update futbeat_private.standings_demands set lease_until=now()-interval '1 second'");
  await db.query("update futbeat_private.provider_entities set external_id='dl-league-v3' where canonical_id=$1", [comp.id]);
  const w = worker(db, (url) => {
    assert.equal(url.pathname, '/v1/standings/dl-league-v3');
    return goalOk(rows('rm', [6, 3], '2026/2027'));
  });
  assert.equal((await w.run()).standings.demand, 'AVAILABLE');
}));

test('mapping removed after queueing: no provider call, the demand stops being pending', () => withDb(async (db) => {
  const comp = await competition(db);
  const m = await match(db, comp);
  assert.equal((await request(db, m)).standings, 'pending');
  await db.query('delete from futbeat_private.provider_entities where canonical_id=$1', [comp.id]);
  const w = worker(db, () => { throw new Error('GOAL must not be called'); });
  const run = await w.run();
  assert.equal(run.standings.status, 'skipped');
  assert.equal(w.goalCalls().filter((u) => u.includes('/standings/')).length, 0);
  assert.equal(await standingsCalls(db), 0, 'no provider_call_ledger row');
  const [d] = await demands(db);
  assert.equal(d.status, 'NO_DATA');
  assert.equal((await db.query('select last_error from futbeat_private.standings_demands')).rows[0].last_error, 'provider mapping unavailable');
  // Stable in Match Center: never pending, reopening does not requeue.
  for (let i = 0; i < 3; i++) {
    const st = await request(db, m);
    assert.equal(st.standingsPending, false);
    assert.ok(['unavailable', 'missing'].includes(st.standings), st.standings);
  }
  const ctx = await context(db, m);
  assert.deepEqual([ctx.standings, ctx.coverage.standingsPending], [[], false]);
  assert.equal((await demands(db))[0].status, 'NO_DATA');
  assert.equal((await reserve(db)).allowed, false);
  assert.equal(await standingsCalls(db), 0);
}));

test('mapping held by an alias redirected to the canonical competition stays fetchable', () => withDb(async (db) => {
  const canonical = await competition(db, { mapped: false });
  const aliasId = `${canonical.id}_alias`;
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)",
    [aliasId, JSON.stringify({ id: aliasId, name: 'Alias Name', country: 'Nowhere', season: '2026/2027' })]);
  await db.query("insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values($1,$2,'competition','test')", [aliasId, canonical.id]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','competition','dl-alias-league',$1)", [aliasId]);
  const m = await match(db, canonical);
  const st = await request(db, m);
  assert.deepEqual([st.standings, st.standingsPending], ['pending', true]);
  const r = await reserve(db);
  assert.deepEqual([r.allowed, r.competitionId, r.externalLeagueId], [true, canonical.id, 'dl-alias-league']);
}));
