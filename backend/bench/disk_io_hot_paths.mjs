// Disk IO of the two hottest worker paths, measured locally (PGlite, no
// network): the calendar snapshot rebuild of a live day and the match detail
// planner. Reports buffer accesses per table (heap + TOAST + index pages,
// 8 KB each), WAL bytes written and time, so optimizations are compared on
// the same data instead of assumed.
//
// Usage: node backend/bench/disk_io_hot_paths.mjs [matchesPerDay] [plannerDays]
// Env: DETAIL_KB (approx detail payload), OBS (observations per match),
//      LIVE_SHARE (0..1 share of today's matches in play), RUNS.
import { openDatabase } from '../storage/database.mjs';

const N = Number(process.argv[2] ?? 300);
const PLANNER_DAYS = Number(process.argv[3] ?? 8);
const DETAIL_KB = Number(process.env.DETAIL_KB ?? 30);
const OBS = Number(process.env.OBS ?? 20);
const LIVE_SHARE = Number(process.env.LIVE_SHARE ?? 0.3);
const RUNS = Number(process.env.RUNS ?? 3);
const TZ = 'America/Costa_Rica';

export async function seedDay(db, prefix, n, dayOffset, liveShare) {
  const q = (sql, params = []) => db.query(sql, params);
  await q(`insert into futbeat_private.entities(id,kind,payload)
    select 'fb_comp_'||$1||'_'||i,'competition',jsonb_build_object('id','fb_comp_'||$1||'_'||i,'name','C'||i,'country','X')
    from generate_series(1,greatest(1,$2::int/8)) i`, [prefix, n]);
  await q(`insert into futbeat_private.entities(id,kind,payload)
    select 'fb_team_'||$1||'_'||i,'team',jsonb_build_object('id','fb_team_'||$1||'_'||i,'name','T'||i)
    from generate_series(1,$2::int*2) i`, [prefix, n]);
  // Kickoffs spread over the day; a share is in play (LIVE, fresh), the rest
  // finished earlier (VERIFIED) or later (SCHEDULED).
  await q(`insert into futbeat_private.entities(id,kind,payload)
    select 'fb_match_'||$1||'_'||i,'match',jsonb_build_object('id','fb_match_'||$1||'_'||i,
      'competitionId','fb_comp_'||$1||'_'||(1+i%greatest(1,$2::int/8)),
      'homeTeamId','fb_team_'||$1||'_'||(2*i-1),'awayTeamId','fb_team_'||$1||'_'||(2*i),
      'startTime',case when i<=$2::int*$4::numeric then now()-interval '40 minutes'
        when i%2=0 then now()-interval '5 hours' else now()+interval '4 hours' end
        +make_interval(days=>$3::int),
      'status',case when i<=$2::int*$4::numeric then 'LIVE' when i%2=0 then 'VERIFIED' else 'SCHEDULED' end,
      'score',jsonb_build_object('home',i%3,'away',i%2),
      'provenance',jsonb_build_object('receivedAt',now()-interval '1 minute'),
      'events','[]'::jsonb,'statistics','[]'::jsonb)
    from generate_series(1,$2::int) i`, [prefix, n, dayOffset, liveShare]);
  await q(`insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
    select 'goal_api','match','ext_'||$1||'_'||i,'fb_match_'||$1||'_'||i from generate_series(1,$2::int) i`, [prefix, n]);
  await q(`insert into futbeat_private.provider_observations(provider,external_match_id,canonical_match_id,received_at,
      status,minute,home_score,away_score,events,payload_hash,raw_payload)
    select 'goal_api','ext_'||$1||'_'||i,'fb_match_'||$1||'_'||i,c.start_time+make_interval(mins=>o),
      'LIVE',least(90,o),o%3,o%2,'[]'::jsonb,md5($1||i||'-'||o)||md5($1||i||'+'||o),
      jsonb_build_object('matchStatus','LIVE','homeTeamScore',o%3,'awayTeamScore',o%2,'filler',(select string_agg(md5($1||i||o||g),'') from generate_series(1,40) g),'minute',o)
    from generate_series(1,$2::int) i
    join futbeat_private.calendar_matches c on c.match_id='fb_match_'||$1||'_'||i
    cross join generate_series(1,$3::int) o
    where c.start_time<now()`, [prefix, n, OBS]);
  // Stored detail: lineups, statistics, events and commentary, poorly
  // compressible (md5 text), ~DETAIL_KB each.
  await q(`insert into futbeat_private.match_detail_cache(match_id,provider,external_match_id,fetched_at,payload)
    select 'fb_match_'||$1||'_'||i,'goal_api','ext_'||$1||'_'||i,greatest(c.start_time,now()-interval '2 minutes'),
      jsonb_build_object('matchStatus',case when c.start_time<now()-interval '3 hours' then 'FINISHED' else 'LIVE' end,
        'matchElapsed',40,'homeTeamScore',i%3,'awayTeamScore',i%2,
        'lineups',(select jsonb_agg(jsonb_build_object('playerId','p'||g,'lineupPlayer',md5($1||i||'p'||g),'position','MF','shirt',g))
          from generate_series(1,44) g),
        'statistics',(select jsonb_agg(jsonb_build_object('type','Stat '||g,'home',g,'away',g+1)) from generate_series(1,40) g),
        'events',(select jsonb_agg(jsonb_build_object('minute',g*6,'type','GOAL')) from generate_series(1,6) g),
        'commentary',(select jsonb_agg(md5($1||i||'c'||g)||md5($1||i||'d'||g)) from generate_series(1,greatest(1,$3::int*12)) g))
    from generate_series(1,$2::int) i
    join futbeat_private.calendar_matches c on c.match_id='fb_match_'||$1||'_'||i
    where c.start_time<now()`, [prefix, n, DETAIL_KB]);
  return (await q(`select ((now() at time zone $1)::date+$2::int)::text d`, [TZ, dayOffset])).rows[0].d;
}

const TABLES = ['entities', 'match_detail_cache', 'provider_observations', 'canonical_events',
  'compact_calendar_cache', 'calendar_matches', 'live_match_state', 'match_detail_requests', 'match_detail_coverage'];

async function counters(db) {
  await db.query('select pg_stat_force_next_flush()');
  const rows = (await db.query(`select relname,
      coalesce(heap_blks_hit,0)+coalesce(heap_blks_read,0) heap,
      coalesce(toast_blks_hit,0)+coalesce(toast_blks_read,0) toast,
      coalesce(idx_blks_hit,0)+coalesce(idx_blks_read,0)+coalesce(tidx_blks_hit,0)+coalesce(tidx_blks_read,0) idx
    from pg_statio_all_tables where schemaname in ('futbeat_private','public') and relname=any($1)`, [TABLES])).rows;
  const wal = (await db.query('select pg_current_wal_lsn()::text l')).rows[0].l;
  return { rows: Object.fromEntries(rows.map((r) => [r.relname, r])), wal };
}

export async function measure(db, fn) {
  const before = await counters(db);
  const t = performance.now();
  await fn();
  const ms = performance.now() - t;
  const after = await counters(db);
  const wal = Number((await db.query('select pg_wal_lsn_diff($1,$2)::bigint d', [after.wal, before.wal])).rows[0].d);
  const pages = {};
  let total = 0;
  for (const table of TABLES) {
    const a = after.rows[table], b = before.rows[table];
    if (!a || !b) continue;
    const delta = (Number(a.heap) - Number(b.heap)) + (Number(a.toast) - Number(b.toast)) + (Number(a.idx) - Number(b.idx));
    if (delta) pages[table] = { heap: Number(a.heap) - Number(b.heap), toast: Number(a.toast) - Number(b.toast), idx: Number(a.idx) - Number(b.idx) };
    total += delta;
  }
  return { ms: Math.round(ms), pages: total, walKB: Math.round(wal / 1024), byTable: pages };
}

export async function runCalendar(db, day) {
  const expire = () => db.query('update futbeat_private.compact_calendar_cache set expires_at=now()-interval \'1 second\' where calendar_date=$1', [day]);
  const out = [];
  for (let i = 0; i < RUNS; i++) {
    await expire();
    out.push(await measure(db, () => db.query('select futbeat_private.materialize_calendar_day($1,$2)', [day, TZ])));
  }
  return out;
}

export async function runPlanner(db) {
  const out = [];
  for (let i = 0; i < RUNS; i++) {
    await db.query('delete from futbeat_private.match_detail_requests');
    out.push(await measure(db, () => db.query('select futbeat_private.plan_match_detail_coverage(null)')));
  }
  return out;
}

async function main() {
  const db = await openDatabase();
  const today = await seedDay(db, 'today', N, 0, LIVE_SHARE);
  for (let d = 1; d < PLANNER_DAYS; d++) await seedDay(db, `d${d}`, Math.round(N / 2), -d, 0);
  await db.query('analyze');
  // First build fills the cache (cold); then same-data rebuilds.
  const cold = await measure(db, () => db.query('select futbeat_private.materialize_calendar_day($1,$2)', [today, TZ]));
  console.log(JSON.stringify({ path: 'calendar_cold', matches: N, ...cold }));
  for (const r of await runCalendar(db, today)) console.log(JSON.stringify({ path: 'calendar_rebuild_same_data', ...r }));
  for (const r of await runPlanner(db)) console.log(JSON.stringify({ path: 'detail_planner', windowDays: PLANNER_DAYS, ...r }));
  await db.close();
}

if (import.meta.url === `file://${process.argv[1]}`) await main();
