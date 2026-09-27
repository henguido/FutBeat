// Synthetic Match Detail planner benchmark. Local PGlite only: no network,
// credentials, provider calls, production data or remote migrations.
//
// Usage:
//   node backend/bench/match_detail_planner_scale.mjs
//   node backend/bench/match_detail_planner_scale.mjs 1000,5000 5
import { openDatabase } from '../storage/database.mjs';

const scales = (process.argv[2] ?? '1000,5000,10000,25000')
  .split(',').map(Number).filter((n) => Number.isInteger(n) && n > 0);
const warmRuns = Math.max(3, Number(process.argv[3] ?? 5));

const round = (n) => +n.toFixed(2);
const summary = (samples) => {
  const sorted = [...samples].sort((a, b) => a - b);
  return {
    firstMs: round(samples[0]),
    medianMs: round(sorted[Math.floor(sorted.length / 2)]),
    p95ApproxMs: round(sorted[Math.ceil(sorted.length * .95) - 1]),
    samplesMs: samples.map(round),
  };
};

async function seed(db, size) {
  await db.exec(`
    insert into futbeat_private.entities(id,kind,payload) values
      ('fb_comp_bench','competition','{"id":"fb_comp_bench","name":"Synthetic League"}'),
      ('fb_team_bench_h','team','{"id":"fb_team_bench_h","name":"Synthetic Home"}'),
      ('fb_team_bench_a','team','{"id":"fb_team_bench_a","name":"Synthetic Away"}')
    on conflict do nothing;

    insert into futbeat_private.entities(id,kind,payload)
    select 'fb_match_bench_'||i,'match',jsonb_build_object(
      'id','fb_match_bench_'||i,
      'competitionId','fb_comp_bench',
      'homeTeamId','fb_team_bench_h',
      'awayTeamId','fb_team_bench_a',
      'startTime',(case
        when i%100<5 then now()-make_interval(mins=>15+(i%180))
        when i%100<10 then now()-make_interval(mins=>120+(i%9960))
        when i%100<40 then now()+make_interval(mins=>1+(i%1440))
        when i%100<70 then now()-make_interval(mins=>120+(i%9960))
        when i%100<90 then now()-make_interval(days=>8+(i%83))
        else now()-make_interval(days=>1+(i%20)) end)::text,
      'status',case
        when i%100<5 then 'LIVE'
        when i%100<10 then 'FINISHED_PENDING_VERIFICATION'
        when i%100<40 then 'SCHEDULED'
        when i%100<90 then 'VERIFIED'
        else 'CANCELLED' end,
      'events','[]'::jsonb,'statistics','[]'::jsonb)
    from generate_series(1,${size}) i;

    insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
    select 'goal_api','match','bench-ext-'||i,'fb_match_bench_'||i
    from generate_series(1,${size}) i;

    insert into futbeat_private.calendar_matches(match_id,start_time,source,updated_at)
    select e.id,(e.payload->>'startTime')::timestamptz,'synthetic',now()
    from futbeat_private.entities e where e.id like 'fb_match_bench_%'
    on conflict(match_id) do update set start_time=excluded.start_time,updated_at=excluded.updated_at;

    insert into futbeat_private.live_match_state(provider,external_match_id,canonical_match_id,status,minute,
      home_score,away_score,event_count,last_payload_hash,revision,first_seen_at,last_seen_at,changed_at)
    select 'goal_api','bench-ext-'||i,'fb_match_bench_'||i,'LIVE',30,1,0,1,repeat('a',64),1,
      now()-interval '40 minutes',case when i%2=0 then now()-interval '20 minutes' else now()-interval '2 minutes' end,
      now()-interval '20 minutes'
    from generate_series(1,${size}) i where i%100<5;

    insert into futbeat_private.match_detail_cache(match_id,provider,external_match_id,fetched_at,payload)
    select 'fb_match_bench_'||i,'goal_api','bench-ext-'||i,
      now()-make_interval(mins=>5+(i%240)),
      case when i%4=0 then jsonb_build_object('statistics',jsonb_build_array(jsonb_build_object('type','Shots','home',3,'away',2)))
        when i%4=1 then jsonb_build_object('lineups',jsonb_build_object('home',jsonb_build_object('startingLineups',jsonb_build_array(jsonb_build_object('playerId','p-'||i)))))
        else '{}'::jsonb end
    from generate_series(1,${size}) i where i%2=0;

    insert into futbeat_private.match_detail_coverage(match_id,lineup_state,statistics_state,lineup_misses,
      statistics_misses,last_fetch_at,failure_count,next_retry_at,last_error)
    select 'fb_match_bench_'||i,
      case when i%5=0 then 'AVAILABLE' when i%5=1 then 'NO_DATA' else 'UNKNOWN' end,
      case when i%6=0 then 'AVAILABLE' when i%6=1 then 'NO_DATA' else 'UNKNOWN' end,
      i%3,i%3,now()-make_interval(mins=>5+(i%240)),0,
      case when i%11=0 then now()+interval '30 minutes' else null end,null
    from generate_series(1,${size}) i where i%5<>4
    on conflict(match_id) do update set
      lineup_state=excluded.lineup_state,statistics_state=excluded.statistics_state,
      lineup_misses=excluded.lineup_misses,statistics_misses=excluded.statistics_misses,
      last_fetch_at=excluded.last_fetch_at,next_retry_at=excluded.next_retry_at;

    insert into futbeat_private.match_detail_requests(match_id,requested_at,expires_at,request_count,source,user_requested_at)
    select 'fb_match_bench_'||i,now()-make_interval(mins=>i%90),
      case when i%3=0 then now()-interval '1 minute' else now()+interval '45 minutes' end,
      1,case when i%10=0 then 'user' when i%2=0 then 'recent' else 'prefetch' end,
      case when i%10=0 then now()-interval '2 minutes' else null end
    from generate_series(1,${size}) i where i%12=0;

    insert into futbeat_private.temporary_interests(user_id,entity_type,entity_id,touched_at,expires_at)
    select md5(i::text)::uuid,'match','fb_match_bench_'||i,now()-interval '5 minutes',now()+interval '25 minutes'
    from generate_series(1,${size}) i where i%33=0;

    insert into futbeat_private.live_terminal_recovery(provider,external_match_id,canonical_match_id,reason,state,
      last_live_status,detected_at,attempts,next_attempt_at,last_attempt_at,resolved_at,resolution)
    select 'goal_api','bench-ext-'||i,'fb_match_bench_'||i,
      case when i%2=0 then 'absent_from_live' else 'overdue_live' end,
      case when i%4=0 then 'PENDING' when i%4=1 then 'RESOLVED' when i%4=2 then 'EXHAUSTED' else 'CANCELLED' end,
      'LIVE',now()-interval '30 minutes',i%4,
      case when i%4=0 then now()-interval '1 minute' else now()+interval '30 minutes' end,
      now()-interval '10 minutes',case when i%4=1 then now()-interval '5 minutes' else null end,
      case when i%4=1 then 'FINISHED' else null end
    from generate_series(1,${size}) i where i%20=0;

    insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,
      provider_remaining,http_status,error_code,metadata)
    select 'goal_api','match-detail','synthetic',now()-make_interval(mins=>i%1440),
      now()-make_interval(mins=>i%1440),'SUCCEEDED',5000,200,null,
      jsonb_build_object('matchId','fb_match_bench_'||i,'source',case when i%10=0 then 'user' else 'planner' end,
        'bucket',case when i%100<5 then 'live' when i%100<10 then 'results' else 'recent' end)
    from generate_series(1,${size}) i where i%25=0;

    analyze futbeat_private.entities;
    analyze futbeat_private.provider_entities;
    analyze futbeat_private.calendar_matches;
    analyze futbeat_private.match_detail_requests;
    analyze futbeat_private.match_detail_cache;
    analyze futbeat_private.match_detail_coverage;
    analyze futbeat_private.provider_call_ledger;
    analyze futbeat_private.live_terminal_recovery;
  `);
}

async function rollbackMeasure(db, sql) {
  await db.exec('begin');
  try {
    await db.exec("set local statement_timeout='8s'");
    await db.exec("update futbeat_private.detail_planner_state set last_planned_at=now()-interval '2 minutes'");
    const before = performance.now();
    const result = await db.query(sql);
    return { ms: performance.now() - before, value: result.rows[0]?.value };
  } finally {
    await db.exec('rollback');
  }
}

async function explain(db, sql) {
  await db.exec('begin');
  try {
    await db.exec("set local statement_timeout='8s'");
    await db.exec("update futbeat_private.detail_planner_state set last_planned_at=now()-interval '2 minutes'");
    const result = await db.query(`explain (analyze, buffers, format json) ${sql}`);
    return result.rows[0]['QUERY PLAN'];
  } catch (error) {
    return { unsupported: error.message };
  } finally {
    await db.exec('rollback');
  }
}

const phaseSql = {
  queueCleanupEligibility: `select count(*) from futbeat_private.match_detail_requests r
    where r.source<>'user' and (
      not exists(select 1 from futbeat_private.provider_entities pe
        where pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=r.match_id)
      or futbeat_private.match_detail_planner_due(r.match_id,futbeat_private.match_detail_bucket(
        futbeat_private.match_detail_status(r.match_id),
        (select nullif(e.payload->>'startTime','')::timestamptz
          from futbeat_private.entities e where e.id=r.match_id))) is not true)`,
  queueDepthClassification: `select count(*) from futbeat_private.match_detail_requests r
    where r.expires_at>now() and r.source<>'user'
      and futbeat_private.match_detail_bucket(futbeat_private.match_detail_status(r.match_id),
        (select nullif(e.payload->>'startTime','')::timestamptz
          from futbeat_private.entities e where e.id=r.match_id)) not in ('live','results')`,
  candidateLimit: `with window_matches as (
      select cm.match_id,nullif(x.payload->>'startTime','')::timestamptz start_time,
        futbeat_private.match_detail_status(cm.match_id) status
      from futbeat_private.calendar_matches cm
      join futbeat_private.entities x on x.id=cm.match_id and x.kind='match'
      where cm.start_time between now()-interval '7 days' and now()+interval '24 hours'
    ), profiled as (
      select w.*,futbeat_private.match_detail_bucket(w.status,w.start_time) bucket from window_matches w
    )
    select p.match_id,p.bucket,p.start_time,coalesce(meta.relevance_score,0) relevance
    from profiled p
    join futbeat_private.provider_entities pe
      on pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=p.match_id
    left join futbeat_private.entities e on e.id=p.match_id
    left join futbeat_private.competition_editorial_metadata meta
      on meta.competition_id=e.payload->>'competitionId'
    left join futbeat_private.match_detail_coverage c on c.match_id=p.match_id
    left join futbeat_private.match_detail_cache d on d.match_id=p.match_id
    where p.bucket in ('live','results','prematch','upcoming','recent_hot','recent','history')
      and coalesce(c.next_retry_at,'-infinity')<=now()
      and (p.bucket<>'upcoming' or d.match_id is null)
      and not (p.bucket in ('recent_hot','recent','history')
        and d.fetched_at>=nullif(e.payload->>'startTime','')::timestamptz+interval '120 minutes'
        and coalesce(c.lineup_state,'UNKNOWN')<>'UNKNOWN'
        and coalesce(c.statistics_state,'UNKNOWN')<>'UNKNOWN'
        and coalesce(c.lineup_recheck_at,'infinity')>now()
        and coalesce(c.statistics_recheck_at,'infinity')>now())
      and not exists(select 1 from futbeat_private.match_detail_requests r
        where r.match_id=p.match_id and r.expires_at>now())
    order by futbeat_private.match_detail_bucket_rank(p.bucket),coalesce(meta.relevance_score,0) desc,
      abs(extract(epoch from p.start_time-now())),p.match_id limit 400`,
};

for (const size of scales) {
  const db = await openDatabase();
  try {
    const seededAt = performance.now();
    await seed(db, size);
    const seedMs = performance.now() - seededAt;
    const counts = (await db.query(`select
      (select count(*)::int from futbeat_private.calendar_matches where match_id like 'fb_match_bench_%') matches,
      (select count(*)::int from futbeat_private.match_detail_requests) requests,
      (select count(*)::int from futbeat_private.match_detail_coverage) coverage,
      (select count(*)::int from futbeat_private.live_terminal_recovery) recovery,
      (select count(*)::int from futbeat_private.temporary_interests) interests`)).rows[0];
    const routes = {
      planner: 'select futbeat_private.plan_match_detail_coverage(null) value',
      enqueue: 'select futbeat_private.enqueue_stale_interested_match_detail() value',
      rpc: 'select public.futbeat_enqueue_stale_live_detail() value',
    };
    const measurements = {};
    for (const [name, sql] of Object.entries(routes)) {
      const samples = [];
      const outputs = [];
      for (let i = 0; i < warmRuns + 1; i++) {
        const measured = await rollbackMeasure(db, sql);
        samples.push(measured.ms);
        outputs.push(measured.value);
      }
      measurements[name] = { ...summary(samples), output: outputs.at(-1) };
    }
    const plans = {};
    for (const [name, sql] of Object.entries(routes)) plans[name] = await explain(db, sql);
    const phases = {};
    if (process.env.DIAGNOSE === '1') {
      for (const [name, sql] of Object.entries(phaseSql)) phases[name] = await explain(db, sql);
    }
    console.log(JSON.stringify({ scale: size, statementTimeoutMs: 8000, seedMs: round(seedMs), counts, measurements, plans, phases }));
  } finally {
    await db.close();
  }
}
