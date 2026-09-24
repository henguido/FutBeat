import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// Calendar days are served from prebuilt snapshots (cache-first), rebuilt only
// when their data version changes or a short clock-driven TTL ends, and the
// days around today are warmed in the background. No provider in the path.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const tz = 'America/Costa_Rica';
const localDay = async (db, offset = 0, zone = tz) =>
  (await db.query('select ((now() at time zone $1)::date+$2::int)::text d', [zone, offset])).rows[0].d;

let seq = 0;
async function seedDay(db, day, { hour = 18, status = 'SCHEDULED', zone = tz } = {}) {
  const n = ++seq;
  const ids = { comp: `fb_comp_cs${n}`, home: `fb_team_cs${n}h`, away: `fb_team_cs${n}a`, match: `fb_match_cs${n}` };
  const start = (await db.query("select (($1::date+make_interval(hours=>$2::int))::timestamp at time zone $3) t", [day, hour, zone])).rows[0].t;
  for (const [id, kind, payload] of [
    [ids.comp, 'competition', { id: ids.comp, name: `Liga ${n}`, country: 'Nowhere' }],
    [ids.home, 'team', { id: ids.home, name: `H${n}` }],
    [ids.away, 'team', { id: ids.away, name: `A${n}` }],
    [ids.match, 'match', { id: ids.match, competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away,
      startTime: new Date(start).toISOString(), status, events: [], statistics: [] }],
  ]) await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
  return ids;
}
const read = (db, day, zone = tz) => db.query('select public.futbeat_read_calendar_range($1,$1,$2) v', [day, zone]).then((r) => r.rows[0].v);
const cacheRow = (db, day, zone = tz) => db.query(`select built_at,extract(epoch from expires_at-built_at)::int ttl
  from futbeat_private.compact_calendar_cache where calendar_date=$1 and timezone=$2`, [day, zone]).then((r) => r.rows[0]);

test('1/9. today is served from one snapshot for many readers (dedupe); changes show when its short TTL ends', () => withDb(async (db) => {
  const today = await localDay(db);
  const m = await seedDay(db, today, { hour: 23 });
  await read(db, today);
  const first = await cacheRow(db, today);
  for (let i = 0; i < 25; i++) await read(db, today);
  assert.deepEqual(await cacheRow(db, today), first, 'one build for all readers');
  assert.ok(first.ttl <= 60, 'today: calendarTodaySeconds or calendarLiveSeconds');
  await db.query(`update futbeat_private.entities set payload=payload||'{"status":"POSTPONED"}' where id=$1`, [m.match]);
  await db.query("update futbeat_private.compact_calendar_cache set expires_at=now()-interval '1 second'");
  assert.equal((await read(db, today)).matches[0].status, 'POSTPONED');
}));

test('2/3. yesterday and the day before are cached (no per-request rebuild)', () => withDb(async (db) => {
  for (const offset of [-1, -2]) {
    const day = await localDay(db, offset);
    await seedDay(db, day, { status: 'VERIFIED' });
    await read(db, day);
    const first = await cacheRow(db, day);
    await read(db, day);
    assert.deepEqual(await cacheRow(db, day), first, `offset ${offset}`);
    assert.ok(first.ttl >= 60, `offset ${offset} ttl ${first.ttl}`);
  }
}));

test('4/5. tomorrow and later days keep a long snapshot (not 10 s); an imminent kickoff shortens it', () => withDb(async (db) => {
  const later = await localDay(db, 3);
  await seedDay(db, later);
  await read(db, later);
  assert.ok((await cacheRow(db, later)).ttl > 3600, 'future day: hours, versioned by data changes');
  const today = await localDay(db);
  const soon = new Date(Date.now() + 10 * 60000);
  const ids = await seedDay(db, today, { hour: 23 });
  await db.query(`update futbeat_private.entities set payload=payload||jsonb_build_object('startTime',$2::text) where id=$1`,
    [ids.match, soon.toISOString()]);
  const day = (await db.query('select (($1::timestamptz) at time zone $2)::date::text d', [soon.toISOString(), tz])).rows[0].d;
  await read(db, day);
  assert.equal((await cacheRow(db, day)).ttl, 15, 'imminent kickoff: calendarLiveSeconds');
}));

test('5. background warmer prepares today and the days around it, bounded per call', () => withDb(async (db) => {
  for (const offset of [-2, -1, 0, 1, 2, 3]) await seedDay(db, await localDay(db, offset));
  const warm = async () => (await db.query('select public.futbeat_warm_calendar_window(3) v')).rows[0].v;
  const first = await warm();
  assert.deepEqual(first.built.map((b) => b.date), [await localDay(db, 0), await localDay(db, 1), await localDay(db, -1)]);
  const second = await warm();
  assert.deepEqual(second.built.map((b) => b.date), [await localDay(db, 2), await localDay(db, -2), await localDay(db, 3)]);
  // Everything built so far is fresh: the next call only builds the rest of
  // the window (never a fresh day again).
  const seeded = await Promise.all([-2, -1, 0, 1, 2, 3].map((o) => localDay(db, o)));
  const third = await warm();
  assert.deepEqual(third.built.map((b) => b.date), [await localDay(db, 4), await localDay(db, 5), await localDay(db, 6)]);
  assert.ok(third.built.every((b) => !seeded.includes(b.date)));
  assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 0);
}));

test('warmer follows the timezones readers use (generic, not a fixed country)', () => withDb(async (db) => {
  const zone = 'Asia/Tokyo';
  const day = await localDay(db, 0, zone);
  await seedDay(db, day, { zone, hour: 20 });
  await read(db, day, zone);
  await db.query("delete from futbeat_private.compact_calendar_cache where timezone=$1 and calendar_date<>$2", [zone, day]);
  // The configured default zone is always warmed; reader zones are added.
  const zones = (await db.query('select futbeat_private.calendar_reader_zones() z')).rows[0].z;
  assert.equal(zones.length, 2);
  assert.ok(zones.includes(zone));
  const result = (await db.query('select public.futbeat_warm_calendar_window(30) v')).rows[0].v;
  assert.ok(result.built.some((b) => b.timezone === zone && b.date !== day), 'reader zone window warmed');
}));

test('6/10. a date never opened before is built from stored data; no provider in the request path', () => withDb(async (db) => {
  const day = await localDay(db, 5);
  await seedDay(db, day);
  const snapshot = await read(db, day);
  assert.equal(snapshot.matches.length, 1);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 0);
  const src = (await db.query("select prosrc from pg_proc where oid='public.futbeat_read_calendar_range(date,date,text)'::regprocedure")).rows[0].prosrc;
  // DB-only: no provider ledger or HTTP. (A large cold day may wake the worker,
  // which only drains the DB snapshot queue for it; it never adds provider demand.)
  assert.doesNotMatch(src, /provider_call_ledger|net\.http|provider_quota|reserve_/);
}));

test('security: warmer is service-only', () => withDb(async (db) => {
  for (const role of ['anon', 'authenticated']) {
    assert.equal((await db.query("select has_function_privilege($1,'public.futbeat_warm_calendar_window(integer)','EXECUTE') ok", [role])).rows[0].ok, false);
  }
}));
