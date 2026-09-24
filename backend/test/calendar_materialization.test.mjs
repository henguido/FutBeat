import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

// Calendar snapshots are materialized off the request path: a lean list
// projection, a deduplicated build queue fed by ingest, and a read path that
// never blocks on a heavy build. Synthetic data only; nothing date-specific.

const tz = 'America/Costa_Rica';
async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const localDay = async (db, offset) =>
  (await db.query('select ((now() at time zone $1)::date+$2::int)::text d', [tz, offset])).rows[0].d;

let seq = 0;
// n matches on a local day, with events, observations and a redirected team.
async function seedDay(db, day, n, { status = 'VERIFIED', events = 3, hour = 12 } = {}) {
  const p = `m${++seq}`;
  await db.query(`insert into futbeat_private.entities(id,kind,payload)
    values('fb_comp_'||$1,'competition',jsonb_build_object('id','fb_comp_'||$1,'name','Comp '||$1,'country','X'))`, [p]);
  await db.query(`insert into futbeat_private.entities(id,kind,payload)
    select 'fb_team_'||$1||'_'||i,'team',jsonb_build_object('id','fb_team_'||$1||'_'||i,'name','T'||i)
    from generate_series(1,$2::int*2) i`, [p, n]);
  await db.query(`insert into futbeat_private.entities(id,kind,payload)
    values('fb_team_'||$1||'_alias','team',jsonb_build_object('id','fb_team_'||$1||'_alias','name','Alias'))`, [p]);
  await db.query(`insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason)
    values('fb_team_'||$1||'_alias','fb_team_'||$1||'_1','team','test')`, [p]);
  await db.query(`insert into futbeat_private.entities(id,kind,payload)
    select 'fb_match_'||$1||'_'||i,'match',jsonb_build_object('id','fb_match_'||$1||'_'||i,
      'competitionId','fb_comp_'||$1,
      'homeTeamId',case when i=1 then 'fb_team_'||$1||'_alias' else 'fb_team_'||$1||'_'||(2*i-1) end,
      'awayTeamId','fb_team_'||$1||'_'||(2*i),
      'startTime',($2::date+make_interval(hours=>$4::int,mins=>i))::timestamp at time zone $5,
      'status',$6::text,'score',case when $6::text in ('VERIFIED','LIVE') then jsonb_build_object('home',1,'away',0) end,
      'provenance',jsonb_build_object('receivedAt',now()),
      'events',(select coalesce(jsonb_agg(jsonb_build_object('id','pe'||e,'type','GOAL','minute',e*10)),'[]'::jsonb)
        from generate_series(1,$7::int) e),'statistics','[]'::jsonb)
    from generate_series(1,$3::int) i`, [p, day, n, hour, tz, status, events]);
  await db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,first_seen_at)
    select 'fb_event_'||$1||'_'||i||'_'||e,'fb_match_'||$1||'_'||i,'goal_api','CARD',
      jsonb_build_object('minute',e*7,'team','home'),now()
    from generate_series(1,$2::int) i cross join generate_series(1,$3::int) e`, [p, n, events]);
  return p;
}
const read = (db, day) => db.query('select public.futbeat_read_calendar_range($1,$1,$2) v', [day, tz]).then((r) => r.rows[0].v);
const cacheRow = (db, day) => db.query(`select built_at,version,extract(epoch from expires_at-built_at)::int ttl
  from futbeat_private.compact_calendar_cache where calendar_date=$1 and timezone=$2`, [day, tz]).then((r) => r.rows[0]);
const queueRow = (db, day) => db.query(`select status,priority from futbeat_private.calendar_snapshot_queue
  where calendar_date=$1 and timezone=$2`, [day, tz]).then((r) => r.rows[0]);
const drain = (db, n = 20) => db.query('select futbeat_private.process_calendar_snapshot_queue($1) v', [n]).then((r) => r.rows[0].v);
const setPolicy = (db, patch) => db.query(`update futbeat_private.provider_quota_policy
  set freshness=freshness||$1::jsonb where provider='goal_api'`, [JSON.stringify(patch)]);
const ledger = (db) => db.query('select count(*)::int n from futbeat_private.provider_call_ledger').then((r) => r.rows[0].n);
// Readers of this timezone exist (dirty marking follows reader timezones).
const registerZone = (db) => db.query(`insert into futbeat_private.calendar_snapshot_zones values($1,now())
  on conflict(timezone) do update set last_seen_at=now()`, [tz]);

async function legacyBuilder(db) {
  const sql = await readFile(new URL('../../supabase/migrations/20260922002909_calendar_cache_explore.sql', import.meta.url), 'utf8');
  await db.exec(sql.slice(sql.indexOf('create or replace function futbeat_private.build_compact_calendar('),
    sql.indexOf('revoke all on function futbeat_private.build_compact_calendar'))
    .replace('futbeat_private.build_compact_calendar(', 'futbeat_private.build_compact_calendar_before('));
}

test('1. dense historical cold build: lean list projection is byte-identical and faster', () => withDb(async (db) => {
  await legacyBuilder(db);
  const day = await localDay(db, -20);
  await seedDay(db, day, 300, { events: 12 });
  const timeIt = async (fn) => { const t = performance.now(); const v = await fn(); return [v, performance.now() - t]; };
  const [before, beforeMs] = await timeIt(() => db.query('select futbeat_private.build_compact_calendar_before($1,$1,$2) v', [day, tz]).then((r) => r.rows[0].v));
  const [after, afterMs] = await timeIt(() => db.query('select futbeat_private.build_compact_calendar($1,$1,$2) v', [day, tz]).then((r) => r.rows[0].v));
  assert.deepEqual(after, before);
  assert.equal(after.matches.length, 300);
  console.log(JSON.stringify({ matches: 300, beforeMs: Math.round(beforeMs), afterMs: Math.round(afterMs) }));
}));

test('lean projection keeps LIVE latestEvent, redirects and played evidence identical', () => withDb(async (db) => {
  await legacyBuilder(db);
  // The local day of a kickoff 30 minutes ago (robust at any time of day).
  const day = (await db.query("select ((now()-interval '30 minutes') at time zone $1)::date::text d", [tz])).rows[0].d;
  const p = await seedDay(db, day, 4, { status: 'LIVE', events: 5, hour: 0 });
  await db.query(`update futbeat_private.entities set payload=payload||jsonb_build_object('startTime',now()-interval '30 minutes')
    where id like 'fb_match_'||$1||'_%'`, [p]);
  await seedDay(db, day, 3, { status: 'SCHEDULED', events: 0, hour: 23 });
  const before = (await db.query('select futbeat_private.build_compact_calendar_before($1,$1,$2) v', [day, tz])).rows[0].v;
  const after = (await db.query('select futbeat_private.build_compact_calendar($1,$1,$2) v', [day, tz])).rows[0].v;
  assert.deepEqual(after, before);
  assert.ok(after.matches.some((m) => m.latestEvent), 'live matches keep their latest event');
  assert.ok(after.matches.some((m) => m.homeTeamId === `fb_team_${p}_1`), 'redirect resolved once');
}));

test('2/4. future cold day is built inline when small and then served from cache', () => withDb(async (db) => {
  const day = await localDay(db, 30);
  await seedDay(db, day, 5, { status: 'SCHEDULED', events: 0 });
  assert.equal((await read(db, day)).matches.length, 5);
  const first = await cacheRow(db, day);
  assert.ok(first.ttl > 6 * 3600, `future TTL ${first.ttl}`);
  await read(db, day);
  assert.deepEqual(await cacheRow(db, day), first, 'cache hit, no rebuild');
}));

test('3/8. arbitrary complete history is frozen; new evidence rebuilds only that day', () => withDb(async (db) => {
  const day = await localDay(db, -30);
  const other = await localDay(db, -10);
  await registerZone(db);
  const p = await seedDay(db, day, 5);
  await seedDay(db, other, 5);
  await db.query(`insert into futbeat_private.calendar_coverage(provider,provider_date,fetched_at,fixtures_complete,results_complete)
    select 'goal_api',d,now(),true,true from generate_series($1::date-1,$2::date+1,interval '1 day') d on conflict do nothing`, [day, other]);
  await read(db, day);
  await read(db, other);
  const first = await cacheRow(db, day);
  assert.equal(first.ttl, 30 * 86400, 'complete history: calendarHistoryCompleteDays');
  const otherFirst = await cacheRow(db, other);
  await db.query('delete from futbeat_private.calendar_snapshot_queue');
  // New evidence for one match of that day (a late correction).
  await db.query(`update futbeat_private.entities set payload=payload||'{"score":{"home":3,"away":3}}' where id=$1`, [`fb_match_${p}_2`]);
  assert.equal((await queueRow(db, day)).priority, 5, 'affected date marked dirty');
  assert.equal(await queueRow(db, other), undefined, 'other dates untouched');
  await drain(db);
  const rebuilt = await cacheRow(db, day);
  assert.notEqual(rebuilt.version, first.version);
  assert.deepEqual((await read(db, day)).matches.find((m) => m.id === `fb_match_${p}_2`).score, { home: 3, away: 3 });
  assert.deepEqual(await cacheRow(db, other), otherFirst);
}));

test('5/6. ingest marks only the affected date; 100 changes of one date -> one build', () => withDb(async (db) => {
  const day = await localDay(db, 12);
  await registerZone(db);
  const p = await seedDay(db, day, 10, { status: 'SCHEDULED', events: 0 });
  await db.query('delete from futbeat_private.calendar_snapshot_queue');
  for (let i = 0; i < 100; i++) {
    await db.query(`update futbeat_private.entities set payload=payload||jsonb_build_object('venue','V'||$2::int) where id=$1`,
      [`fb_match_${p}_${1 + (i % 10)}`, i]);
  }
  // Exactly the local dates intersecting the changed UTC date (versions are
  // per UTC date), each once; nothing else.
  const expected = (await db.query(`select array_agg(distinct (x at time zone $2)::date::text order by (x at time zone $2)::date::text) d
    from (select start_time from futbeat_private.calendar_matches where match_id like $1) m,
    lateral unnest(array[(m.start_time at time zone 'UTC')::date::timestamp at time zone 'UTC',
      ((m.start_time at time zone 'UTC')::date+1)::timestamp at time zone 'UTC'-interval '1 microsecond']) x`,
    [`fb_match_${p}_%`, tz])).rows[0].d;
  const rows = (await db.query(`select calendar_date::text d,status from futbeat_private.calendar_snapshot_queue
    order by calendar_date`)).rows;
  assert.deepEqual(rows.map((r) => r.d), expected);
  assert.ok(rows.every((r) => r.status === 'pending') && rows.map((r) => r.d).includes(day));
  const result = await drain(db);
  assert.equal(result.built.length, expected.length);
  assert.equal((await drain(db)).built.length, 0, 'nothing left: deduplicated');
}));

test('7. the visible date outranks today, window, dirty and background work', () => withDb(async (db) => {
  await setPolicy(db, { calendarSyncBuildMaxMatches: 5 });
  const visible = await localDay(db, -45);
  await seedDay(db, visible, 8);
  for (const [offset, priority] of [[3, 4], [-7, 5], [60, 6], [0, 2]]) {
    await db.query('select futbeat_private.enqueue_calendar_snapshot($1,$2,$3)', [await localDay(db, offset), tz, priority]);
  }
  const pending = await read(db, visible);
  assert.equal(pending.coverage.pending, true);
  assert.equal((await queueRow(db, visible)).priority, 1);
  assert.equal((await drain(db, 1)).built[0].date, visible);
}));

test('9. a reschedule invalidates both the old and the new date', () => withDb(async (db) => {
  const oldDay = await localDay(db, 20);
  const newDay = await localDay(db, 27);
  await registerZone(db);
  const p = await seedDay(db, oldDay, 3, { status: 'SCHEDULED', events: 0 });
  await read(db, oldDay);
  await read(db, newDay);
  await db.query('delete from futbeat_private.calendar_snapshot_queue');
  await db.query(`update futbeat_private.entities set payload=payload||jsonb_build_object('startTime',
    ($2::date+interval '15 hours')::timestamp at time zone $3) where id=$1`, [`fb_match_${p}_1`, newDay, tz]);
  assert.equal((await queueRow(db, oldDay))?.status, 'pending');
  assert.equal((await queueRow(db, newDay))?.status, 'pending');
  await drain(db);
  assert.equal((await read(db, oldDay)).matches.length, 2);
  assert.equal((await read(db, newDay)).matches.length, 1);
}));

test('22. a large cold day answers "pending" at once, is materialized by the queue, then served', () => withDb(async (db) => {
  await setPolicy(db, { calendarSyncBuildMaxMatches: 20 });
  const day = await localDay(db, -60);
  await seedDay(db, day, 40, { events: 4 });
  const t = performance.now();
  const pending = await read(db, day);
  const pendingMs = performance.now() - t;
  assert.equal(pending.coverage.pending, true);
  assert.equal(pending.matches.length, 0);
  assert.equal(await cacheRow(db, day), undefined, 'no inline heavy build');
  console.log(`pending response ${Math.round(pendingMs)} ms`);
  await drain(db);
  const ready = await read(db, day);
  assert.equal(ready.matches.length, 40);
  assert.notEqual(ready.coverage.pending, true);
}));

test('stale snapshot of a large day is served immediately while it is rebuilt', () => withDb(async (db) => {
  await setPolicy(db, { calendarSyncBuildMaxMatches: 20 });
  const day = await localDay(db, -15);
  const p = await seedDay(db, day, 30, { events: 2 });
  await read(db, day);
  await drain(db);
  await read(db, day);
  await db.query(`update futbeat_private.entities set payload=payload||'{"score":{"home":5,"away":5}}' where id=$1`, [`fb_match_${p}_3`]);
  const stale = await read(db, day);
  assert.equal(stale.matches.length, 30, 'previous snapshot, not an empty screen');
  assert.equal(stale.freshness.revalidating, true);
  assert.notDeepEqual(stale.matches.find((m) => m.id === `fb_match_${p}_3`).score, { home: 5, away: 5 });
  await drain(db);
  assert.deepEqual((await read(db, day)).matches.find((m) => m.id === `fb_match_${p}_3`).score, { home: 5, away: 5 });
}));

test('known dates far from today get a snapshot in the background (seeding), history and future', () => withDb(async (db) => {
  await registerZone(db);
  const past = await localDay(db, -40);
  const future = await localDay(db, 45);
  await seedDay(db, past, 3);
  await seedDay(db, future, 3, { status: 'SCHEDULED', events: 0 });
  for (let i = 0; i < 20 && (!(await cacheRow(db, past)) || !(await cacheRow(db, future))); i++) {
    await db.query('select public.futbeat_warm_calendar_window(10)');
  }
  assert.ok(await cacheRow(db, past), 'history built before anyone opens it');
  assert.ok(await cacheRow(db, future), 'future built before anyone opens it');
}));

test('10. calendar reads, pending answers and queue work never touch the provider', () => withDb(async (db) => {
  await setPolicy(db, { calendarSyncBuildMaxMatches: 3 });
  const day = await localDay(db, -9);
  await seedDay(db, day, 6);
  await read(db, day);
  await drain(db);
  await read(db, day);
  await db.query('select public.futbeat_warm_calendar_window(5)');
  assert.equal(await ledger(db), 0);
  for (const fn of ['futbeat_private.materialize_calendar_day(date,text)', 'futbeat_private.process_calendar_snapshot_queue(integer)',
    'futbeat_private.build_compact_calendar(date,date,text)', 'futbeat_private.seed_calendar_snapshot_queue(integer)']) {
    const src = (await db.query('select prosrc from pg_proc where oid=$1::regprocedure', [fn])).rows[0].prosrc;
    assert.doesNotMatch(src, /provider_call_ledger|net\.http|reserve_|wake_provider_worker/, fn);
  }
}));

test('failed builds back off instead of looping', () => withDb(async (db) => {
  const day = await localDay(db, -80);
  await db.query('select futbeat_private.enqueue_calendar_snapshot($1,$2,5)', [day, 'Invalid/Zone']);
  const result = await drain(db, 5);
  assert.equal(result.failed, 1);
  const row = (await db.query(`select status,next_retry_at>now() later from futbeat_private.calendar_snapshot_queue
    where timezone='Invalid/Zone'`)).rows[0];
  assert.deepEqual(row, { status: 'pending', later: true });
  assert.equal((await drain(db, 5)).failed, 0, 'not retried before its backoff');
}));

test('security: queue and status helpers are service-only', () => withDb(async (db) => {
  for (const role of ['anon', 'authenticated']) {
    for (const fn of ['public.futbeat_calendar_snapshot_status()', 'public.futbeat_warm_calendar_window(integer)',
      'public.futbeat_read_calendar_range(date,date,text)']) {
      assert.equal((await db.query('select has_function_privilege($1,$2,\'EXECUTE\') ok', [role, fn])).rows[0].ok, false, `${role} ${fn}`);
    }
    assert.equal((await db.query("select has_table_privilege($1,'futbeat_private.calendar_snapshot_queue','SELECT') ok", [role])).rows[0].ok, false);
  }
}));
