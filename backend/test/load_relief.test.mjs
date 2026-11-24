import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

// 20261005090000: same behaviour, less work per minute (see the migration
// header for the production evidence).

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

// match_detail_bucket exactly as production had it before this migration.
const OLD_BUCKET = `create function pg_temp.old_bucket(p_status text, p_start timestamptz) returns text language sql stable as $f$
  select case
    when p_start is null or coalesce(p_status,'') in ('CANCELLED','POSTPONED') then 'none'
    when p_status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then 'live'
    when p_status='FINISHED_PENDING_VERIFICATION'
      and p_start>now()-make_interval(hours=>futbeat_private.quota_setting('goal_api','resultsWindowHours',4)::integer)
      then 'results'
    when p_start>now()+make_interval(mins=>futbeat_private.quota_setting('goal_api','prematchMinutes',90)::integer) then
      case when p_start<=now()+make_interval(hours=>futbeat_private.quota_setting('goal_api','upcomingDetailHours',24)::integer)
        then 'upcoming' else 'future' end
    when p_start>now() then 'prematch'
    when p_start>now()-make_interval(hours=>futbeat_private.quota_setting('goal_api','recentHotHours',6)::integer) then 'recent_hot'
    when p_start>now()-make_interval(hours=>futbeat_private.quota_setting('goal_api','recentFinishedHours',36)::integer) then 'recent'
    when p_start>now()-make_interval(days=>futbeat_private.quota_setting('goal_api','historyCoverageDays',7)::integer) then 'history'
    else 'old' end $f$`;

test('match_detail_bucket keeps every result of the previous definition (grid of statuses x times)', () => withDb(async (db) => {
  await db.exec(OLD_BUCKET);
  const diff = (await db.query(`
    select s.status, m.minutes, futbeat_private.match_detail_bucket(s.status, now()+make_interval(mins=>m.minutes)) new,
      pg_temp.old_bucket(s.status, now()+make_interval(mins=>m.minutes)) old
    from unnest(array[null,'','SCHEDULED','LIVE','HALFTIME','EXTRA_TIME','PENALTIES','FINISHED_PENDING_VERIFICATION',
      'VERIFIED','CANCELLED','POSTPONED','SUSPENDED']) s(status)
    cross join generate_series(-12000,2000,7) m(minutes)
    where futbeat_private.match_detail_bucket(s.status, now()+make_interval(mins=>m.minutes))
      is distinct from pg_temp.old_bucket(s.status, now()+make_interval(mins=>m.minutes))`)).rows;
  assert.deepEqual(diff, []);
  // A null kickoff, and a changed policy setting, behave the same too.
  assert.equal((await db.query("select futbeat_private.match_detail_bucket('LIVE',null) b")).rows[0].b, 'none');
  await db.query(`update futbeat_private.provider_quota_policy set freshness=freshness||'{"recentHotHours":2,"historyCoverageDays":3}' where provider='goal_api'`);
  const changed = (await db.query(`select count(*)::int n from generate_series(-6000,100,11) m(minutes)
    where futbeat_private.match_detail_bucket('SCHEDULED', now()+make_interval(mins=>m.minutes))
      is distinct from pg_temp.old_bucket('SCHEDULED', now()+make_interval(mins=>m.minutes))`)).rows[0].n;
  assert.equal(changed, 0);
}));

test('match_detail_bucket_at is inlined (no per-row function call)', () => withDb(async (db) => {
  const plan = (await db.query(`explain (verbose, format json)
    select futbeat_private.match_detail_bucket_at(w.status, w.start_time, now(),
      interval '4 hours', interval '90 minutes', interval '24 hours', interval '6 hours', interval '36 hours', interval '7 days')
    from (select 'SCHEDULED'::text status, now()+make_interval(mins=>g) start_time from generate_series(1,10) g) w`)).rows;
  const text = JSON.stringify(plan);
  assert.doesNotMatch(text, /match_detail_bucket_at/, 'the CASE is expanded in the plan');
  assert.match(text, /CASE/);
}));

test('the detail planner reads the windows once and never calls match_detail_bucket per window row', async () => {
  const sql = await readFile(new URL('../../supabase/migrations/20261005090000_load_relief.sql', import.meta.url), 'utf8');
  const plan = sql.slice(sql.indexOf('create or replace function futbeat_private.plan_match_detail_coverage'));
  const body = plan.slice(0, plan.indexOf('$function$;'));
  assert.match(body, /match_detail_bucket_at\(w\.status,w\.start_time,now\(\),\s*results_win,prematch,upcoming,recent_hot,recent_fin,history\) bucket/);
  assert.doesNotMatch(body, /match_detail_bucket\(w\.status/);
});

test('is_timezone_name accepts exactly the server tz names (fast path and exact fallback)', () => withDb(async (db) => {
  const check = (name) => db.query('select futbeat_private.is_timezone_name($1) v', [name]).then((r) => r.rows[0].v);
  for (const name of ['America/Costa_Rica', 'UTC', 'Etc/GMT+5', 'Europe/Madrid']) assert.equal(await check(name), true, name);
  for (const name of ['Not/AZone', '', null, 'UTC+3', "x'; drop table x;--"]) assert.equal(await check(name), false, String(name));
  const copied = (await db.query('select count(*)::int n from futbeat_private.timezone_names')).rows[0].n;
  const real = (await db.query('select count(*)::int n from pg_catalog.pg_timezone_names')).rows[0].n;
  assert.equal(copied, real);
  // A name missing from the copy still answers like the original check.
  await db.query("delete from futbeat_private.timezone_names where name='Europe/Madrid'");
  assert.equal(await check('Europe/Madrid'), true);
}));

test('no function left evaluates pg_timezone_names per call', () => withDb(async (db) => {
  const rows = (await db.query(`select n.nspname||'.'||p.proname f from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('public','futbeat_private') and p.prosrc ilike '%pg_timezone_names%'
      and p.proname not in ('is_timezone_name')`)).rows.map((r) => r.f);
  assert.deepEqual(rows, []);
}));

test('the calendar range read still rejects an invalid time zone', () => withDb(async (db) => {
  await assert.rejects(db.query("select public.futbeat_read_calendar_range(current_date,current_date,'Not/AZone')"), /Invalid calendar range/);
  const ok = (await db.query("select public.futbeat_read_calendar_range(current_date,current_date,'America/Costa_Rica') v")).rows[0].v;
  assert.equal(ok.schemaVersion, 1);
}));
