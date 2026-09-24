// Cold build benchmark for one calendar day (local PGlite, no network).
// Usage: node backend/bench/calendar_cold_build.mjs [sizes...]
// Seeds one historical day per size with realistic per-match child data
// (provider observations with raw payloads, canonical events, a stored match
// detail with lineups/statistics/commentary, live state, team redirects) and
// times the full build plus its stages, so the dominant cost is measured, not
// assumed. Env: OBS (observations/match), EVENTS, DETAIL_SHARE (0..1),
// DETAIL_KB (approx detail payload size), RUNS.
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

const sizes = process.argv.slice(2).map(Number).filter(Boolean);
const SIZES = sizes.length ? sizes : [50, 200, 1000, 1500];
const OBS = Number(process.env.OBS ?? 30);
const EVENTS = Number(process.env.EVENTS ?? 10);
const DETAIL_SHARE = Number(process.env.DETAIL_SHARE ?? 0.7);
const DETAIL_KB = Number(process.env.DETAIL_KB ?? 30);
const RUNS = Number(process.env.RUNS ?? 3);
const TZ = 'America/Costa_Rica';

const time = async (fn, runs = RUNS) => {
  const samples = [];
  for (let i = 0; i < runs; i++) {
    const t = performance.now();
    await fn();
    samples.push(performance.now() - t);
  }
  samples.sort((a, b) => a - b);
  return +samples[Math.floor(samples.length / 2)].toFixed(0);
};

async function seed(db, n, dayOffset) {
  const p = `b${n}`;
  const q = (sql, params = []) => db.query(sql, params);
  await q(`insert into futbeat_private.entities(id,kind,payload)
    select 'fb_comp_'||$1||'_'||i,'competition',jsonb_build_object('id','fb_comp_'||$1||'_'||i,'name','C'||i,'country','X')
    from generate_series(1,greatest(1,$2::int/8)) i`, [p, n]);
  await q(`insert into futbeat_private.entities(id,kind,payload)
    select 'fb_team_'||$1||'_'||i,'team',jsonb_build_object('id','fb_team_'||$1||'_'||i,'name','T'||i)
    from generate_series(1,$2::int*2) i`, [p, n]);
  // A tenth of the teams are referenced through a redirect alias.
  await q(`insert into futbeat_private.entities(id,kind,payload)
    select 'fb_team_'||$1||'_alias'||i,'team',jsonb_build_object('id','fb_team_'||$1||'_alias'||i,'name','A'||i)
    from generate_series(1,$2::int*2,10) i`, [p, n]);
  await q(`insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason)
    select 'fb_team_'||$1||'_alias'||i,'fb_team_'||$1||'_'||i,'team','bench'
    from generate_series(1,$2::int*2,10) i`, [p, n]);
  await q(`insert into futbeat_private.entities(id,kind,payload)
    select 'fb_match_'||$1||'_'||i,'match',jsonb_build_object('id','fb_match_'||$1||'_'||i,
      'competitionId','fb_comp_'||$1||'_'||(1+i%greatest(1,$2::int/8)),
      'homeTeamId',case when (2*i-1)%10=1 then 'fb_team_'||$1||'_alias'||(2*i-1) else 'fb_team_'||$1||'_'||(2*i-1) end,
      'awayTeamId','fb_team_'||$1||'_'||(2*i),
      'startTime',(date_trunc('day',now() at time zone $4)+make_interval(days=>$3::int,hours=>8+i%14)) at time zone $4,
      'status','VERIFIED','score',jsonb_build_object('home',i%3,'away',i%2),
      'provenance',jsonb_build_object('receivedAt',now()-make_interval(days=>-$3::int)),
      'events','[]'::jsonb,'statistics','[]'::jsonb)
    from generate_series(1,$2::int) i`, [p, n, dayOffset, TZ]);
  await q(`insert into futbeat_private.provider_observations(provider,external_match_id,canonical_match_id,received_at,
      status,minute,home_score,away_score,events,payload_hash,raw_payload)
    select 'goal_api','ext_'||$1||'_'||i,'fb_match_'||$1||'_'||i,c.start_time+make_interval(mins=>o*3),
      case when o=$3::int then 'FINISHED_PENDING_VERIFICATION' else 'LIVE' end,least(90,o*3),o%3,o%2,'[]'::jsonb,
      md5($1||i||'-'||o)||md5($1||i||'+'||o),jsonb_build_object('matchStatus','LIVE','filler',repeat('x',1200),'minute',o)
    from generate_series(1,$2::int) i
    join futbeat_private.calendar_matches c on c.match_id='fb_match_'||$1||'_'||i
    cross join generate_series(1,$3::int) o`, [p, n, OBS]);
  await q(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,first_seen_at)
    select 'fb_event_'||$1||'_'||i||'_'||e,'fb_match_'||$1||'_'||i,'goal_api',case when e%3=0 then 'GOAL' else 'CARD' end,
      jsonb_build_object('minute',e*8,'team',case when e%2=0 then 'home' else 'away' end,'player','P'||e),
      c.start_time+make_interval(mins=>e*8)
    from generate_series(1,$2::int) i
    join futbeat_private.calendar_matches c on c.match_id='fb_match_'||$1||'_'||i
    cross join generate_series(1,$3::int) e`, [p, n, EVENTS]);
  await q(`insert into futbeat_private.match_detail_cache(match_id,provider,external_match_id,fetched_at,payload)
    select 'fb_match_'||$1||'_'||i,'goal_api','ext_'||$1||'_'||i,c.start_time+interval '3 hours',
      jsonb_build_object('matchStatus','FINISHED','homeTeamScore',i%3,'awayTeamScore',i%2,
        'lineups',(select jsonb_agg(jsonb_build_object('playerId','p'||g,'lineupPlayer','Player '||g,'position','MF','shirt',g))
          from generate_series(1,44) g),
        'statistics',(select jsonb_agg(jsonb_build_object('type','Stat '||g,'home',g,'away',g+1)) from generate_series(1,40) g),
        'events',(select jsonb_agg(jsonb_build_object('minute',g*6,'type','GOAL')) from generate_series(1,12) g),
        'commentary',(select jsonb_agg(repeat('c',200)) from generate_series(1,greatest(1,$3::int*5)) g))
    from generate_series(1,$2::int) i
    join futbeat_private.calendar_matches c on c.match_id='fb_match_'||$1||'_'||i
    where i%100<$4::numeric*100`, [p, n, DETAIL_KB, DETAIL_SHARE]);
  await q(`insert into futbeat_private.live_match_state(provider,external_match_id,canonical_match_id,status,minute,
      home_score,away_score,event_count,last_payload_hash,revision,first_seen_at,last_seen_at,changed_at)
    select 'goal_api','ext_'||$1||'_'||i,'fb_match_'||$1||'_'||i,'FINISHED_PENDING_VERIFICATION',90,i%3,i%2,0,md5('l'||i)||md5('m'||i),1,
      c.start_time,c.start_time+interval '2 hours',c.start_time+interval '2 hours'
    from generate_series(1,$2::int) i
    join futbeat_private.calendar_matches c on c.match_id='fb_match_'||$1||'_'||i`, [p, n]);
  const day = (await q(`select ((now() at time zone $1)::date+$2::int)::text d`, [TZ, dayOffset])).rows[0].d;
  await q(`insert into futbeat_private.calendar_coverage(provider,provider_date,fetched_at,fixtures_complete,results_complete)
    select 'goal_api',d,now(),true,true from generate_series(($1::date::timestamp at time zone $2 at time zone 'UTC')::date,
      ((($1::date+1)::timestamp at time zone $2 - interval '1 microsecond') at time zone 'UTC')::date,interval '1 day') d
    on conflict do nothing`, [day, TZ]);
  return day;
}

// The previous builder, verbatim from its migration, for a same-data "before".
const legacySql = await readFile(new URL('../../supabase/migrations/20260922002909_calendar_cache_explore.sql', import.meta.url), 'utf8');
const legacyBuilder = legacySql.slice(legacySql.indexOf('create or replace function futbeat_private.build_compact_calendar('),
  legacySql.indexOf('revoke all on function futbeat_private.build_compact_calendar'))
  .replace('futbeat_private.build_compact_calendar(', 'futbeat_private.build_compact_calendar_before(');

for (const n of SIZES) {
  // A fresh database per size: no cross-dataset memory effects.
  const db = await openDatabase();
  const q = (sql, params = []) => db.query(sql, params);
  await db.exec(legacyBuilder);
  const day = await seed(db, n, -43);
  await q('analyze');
  const build = () => q('select futbeat_private.build_compact_calendar($1,$1,$2) v', [day, TZ]);
  const before = () => q('select futbeat_private.build_compact_calendar_before($1,$1,$2) v', [day, TZ]);
  const after = (await build()).rows[0].v;
  const previous = (await before()).rows[0].v;
  const row = {
    matches: n,
    beforeBuildMs: await time(before),
    afterBuildMs: await time(build),
    samePayload: JSON.stringify(previous) === JSON.stringify(after),
    payloadKB: +(Buffer.byteLength(JSON.stringify(after)) / 1024).toFixed(0),
  };
  await q('select futbeat_private.materialize_calendar_day($1,$2)', [day, TZ]);
  row.cachedReadMs = await time(() => q('select public.futbeat_read_calendar_range($1,$1,$2) v', [day, TZ]));
  const t = performance.now();
  JSON.parse(JSON.stringify(after));
  row.jsonRoundTripMs = +(performance.now() - t).toFixed(1);
  console.log(JSON.stringify(row));
  await db.close();
}
