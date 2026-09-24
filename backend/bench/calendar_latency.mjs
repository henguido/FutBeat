// Calendar latency benchmark (local PGlite, no network, no provider).
// Usage: node backend/bench/calendar_latency.mjs
// Seeds DAYS x PER_DAY matches around today and compares the previous request
// path for today/yesterday (a full build_compact_calendar on EVERY request)
// with the cached snapshot path, plus the warmer and EXPLAIN ANALYZE of a hit.
import { openDatabase } from '../storage/database.mjs';

const DAYS = Number(process.env.DAYS ?? 30);
const PER_DAY = Number(process.env.PER_DAY ?? 400);
const RUNS = Number(process.env.RUNS ?? 10);
const TZ = 'America/Costa_Rica';

const db = await openDatabase();
const q = (sql, p = []) => db.query(sql, p);
const time = async (fn, runs = RUNS) => {
  const samples = [];
  for (let i = 0; i < runs; i++) {
    const t = performance.now();
    await fn();
    samples.push(performance.now() - t);
  }
  samples.sort((a, b) => a - b);
  return { median: +samples[Math.floor(samples.length / 2)].toFixed(1), min: +samples[0].toFixed(1) };
};

await q(`insert into futbeat_private.entities(id,kind,payload)
  select 'fb_comp_bn'||i,'competition',jsonb_build_object('id','fb_comp_bn'||i,'name','C'||i,'country','X') from generate_series(1,1000) i`);
await q(`insert into futbeat_private.entities(id,kind,payload)
  select 'fb_team_bn'||i,'team',jsonb_build_object('id','fb_team_bn'||i,'name','T'||i) from generate_series(1,3000) i`);
await q(`insert into futbeat_private.entities(id,kind,payload)
  select 'fb_match_bn'||i,'match',jsonb_build_object('id','fb_match_bn'||i,'competitionId','fb_comp_bn'||(1+i%1000),
    'homeTeamId','fb_team_bn'||(1+i%3000),'awayTeamId','fb_team_bn'||(1+(i+7)%3000),
    'startTime',(date_trunc('day',now())+make_interval(days=>(i%$1::int)-($1::int/2),hours=>i%24))::text,
    'status',case when (i%$1::int)-($1::int/2)<0 then 'VERIFIED' else 'SCHEDULED' end,'events','[]'::jsonb,'statistics','[]'::jsonb)
  from generate_series(1,$1::int*$2::int) i`, [DAYS, PER_DAY]);
await q('analyze');

const day = async (offset) => (await q('select ((now() at time zone $1)::date+$2::int)::text d', [TZ, offset])).rows[0].d;
const today = await day(0), yesterday = await day(-1), past = await day(-5), future = await day(3);
const read = (d) => q('select public.futbeat_read_calendar_range($1,$1,$2)', [d, TZ]);
const build = (d) => q('select futbeat_private.build_compact_calendar($1,$1,$2)', [d, TZ]);

const results = {
  matches: DAYS * PER_DAY,
  'previous path: today rebuilt per request (build)': await time(() => build(today)),
  'previous path: yesterday rebuilt per request (build)': await time(() => build(yesterday)),
  'new path: today first read (build + store)': await time(async () => {
    await q('delete from futbeat_private.compact_calendar_cache'); await read(today);
  }, 3),
  'new path: today cached read': (await read(today), await time(() => read(today))),
  'new path: yesterday cached read': (await read(yesterday), await time(() => read(yesterday))),
  'new path: past day cached read': (await read(past), await time(() => read(past))),
  'new path: future day cached read': (await read(future), await time(() => read(future))),
  'warmer: 3 missing days': await time(async () => {
    await q('delete from futbeat_private.compact_calendar_cache');
    await q('select public.futbeat_warm_calendar_window(3)');
  }, 3),
  'warmer: window already warm': await time(() => q('select public.futbeat_warm_calendar_window(3)')),
  futureTtlSeconds: (await q(`select extract(epoch from expires_at-built_at)::int s from futbeat_private.compact_calendar_cache
    where calendar_date=$1`, [future])).rows[0]?.s ?? null,
};
console.log(JSON.stringify(results, null, 2));
const plan = (await q(`explain (analyze, costs off) select payload from futbeat_private.compact_calendar_cache
  where calendar_date=$1 and timezone=$2 and version=futbeat_private.calendar_cache_version($1,$2) and expires_at>now()`,
  [today, TZ])).rows.map((r) => r['QUERY PLAN']).join('\n');
console.log('--- cached lookup plan\n' + plan);
await db.close();
