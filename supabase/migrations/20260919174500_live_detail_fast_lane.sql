-- Keep the five-minute LIVE poll on cadence despite scheduler jitter and give
-- on-demand Match Center detail requests a one-minute, quota-safe fast lane.

create or replace function futbeat_private.futbeat_reserve_goal_live_call(
  p_trigger_source text default 'cron'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_now timestamptz:=now();
  v_day_start timestamptz:=
    date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  v_total integer;
  v_live integer;
  v_last timestamptz;
  v_last_remaining integer;
  v_id bigint;
  v_active integer;
  v_next timestamptz;
begin
  if p_trigger_source is null or btrim(p_trigger_source)='' then
    raise exception 'trigger_source is required';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('futbeat-provider-quota:goal_api:'||v_day_start::date::text)
  );

  select
    count(*)::integer,
    count(*) filter(where call_kind='live-goal')::integer,
    max(reserved_at) filter(where call_kind='live-goal')
  into v_total,v_live,v_last
  from futbeat_private.provider_call_ledger
  where provider='goal_api'
    and reserved_at>=v_day_start
    and reserved_at<v_day_start+interval '1 day';

  select provider_remaining
  into v_last_remaining
  from futbeat_private.provider_call_ledger
  where provider='goal_api'
    and provider_remaining is not null
    and reserved_at>=v_day_start
    and reserved_at<v_day_start+interval '1 day'
  order by coalesce(completed_at,reserved_at) desc,id desc
  limit 1;

  select count(*)::integer
  into v_active
  from futbeat_private.entities e
  where e.kind='match'
    and nullif(e.payload->>'startTime','') is not null
    and coalesce(e.payload->>'status','') not in (
      'FINISHED_PENDING_VERIFICATION','VERIFIED','CANCELLED',
      'ABANDONED','POSTPONED'
    )
    and v_now between
      (e.payload->>'startTime')::timestamptz-interval '5 minutes'
      and (e.payload->>'startTime')::timestamptz+interval '135 minutes';

  select min((e.payload->>'startTime')::timestamptz)
  into v_next
  from futbeat_private.entities e
  where e.kind='match'
    and nullif(e.payload->>'startTime','') is not null
    and (e.payload->>'startTime')::timestamptz>v_now
    and coalesce(e.payload->>'status','') not in (
      'FINISHED_PENDING_VERIFICATION','VERIFIED','CANCELLED',
      'ABANDONED','POSTPONED'
    );

  if v_last_remaining is not null and v_last_remaining<=20 then
    return jsonb_build_object(
      'allowed',false,
      'reason','provider_remaining_reserve',
      'providerRemaining',v_last_remaining,
      'reserve',20,
      'usedToday',v_total,
      'liveUsed',v_live,
      'nextStart',v_next
    );
  end if;

  if v_last_remaining is null and v_total>=950 then
    return jsonb_build_object(
      'allowed',false,
      'reason','goal_daily_fallback_limit',
      'usedToday',v_total,
      'limit',1000,
      'reserve',20,
      'providerRemaining',v_last_remaining,
      'liveUsed',v_live
    );
  end if;

  if v_active=0 then
    return jsonb_build_object(
      'allowed',false,
      'reason','outside_live_window',
      'usedToday',v_total,
      'liveUsed',v_live,
      'providerRemaining',v_last_remaining,
      'nextStart',v_next
    );
  end if;

  -- Cron fires every five minutes. Keep a four-minute duplicate guard so
  -- normal scheduler jitter (for example 04:59 between executions) cannot
  -- suppress every second LIVE cycle.
  if v_last is not null and v_last>v_now-interval '4 minutes' then
    return jsonb_build_object(
      'allowed',false,
      'reason','min_interval',
      'usedToday',v_total,
      'liveUsed',v_live,
      'providerRemaining',v_last_remaining,
      'retryAfterSeconds',
      greatest(0,240-extract(epoch from (v_now-v_last))::integer)
    );
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at
  )
  values('goal_api','live-goal',left(p_trigger_source,40),v_now)
  returning id into v_id;

  return jsonb_build_object(
    'allowed',true,
    'reservationId',v_id,
    'usedToday',v_total+1,
    'limit',1000,
    'reserve',20,
    'providerRemaining',v_last_remaining,
    'liveUsed',v_live+1,
    'activeMatches',v_active,
    'nextStart',v_next
  );
end
$$;

create or replace function futbeat_private.enqueue_stale_interested_match_detail()
returns text
language plpgsql
security definer
set search_path=''
as $
declare
  v_match_id text;
begin
  -- Never compete with a detail explicitly requested from Match Center.
  if exists(
    select 1
    from futbeat_private.match_detail_requests
    where expires_at>now()
  ) then
    return null;
  end if;

  select e.id
  into v_match_id
  from futbeat_private.entities e
  join futbeat_private.provider_entities pe
    on pe.provider='goal_api'
   and pe.kind='match'
   and pe.canonical_id=e.id
  left join futbeat_private.live_match_state l
    on l.canonical_match_id=e.id
   and l.provider='goal_api'
  left join futbeat_private.match_detail_cache c
    on c.match_id=e.id
  left join futbeat_private.coverage_interests hi
    on hi.subject_type='team'
   and hi.subject_id=e.payload->>'homeTeamId'
  left join futbeat_private.coverage_interests ai
    on ai.subject_type='team'
   and ai.subject_id=e.payload->>'awayTeamId'
  left join futbeat_private.coverage_interests ci
    on ci.subject_type='competition'
   and ci.subject_id=e.payload->>'competitionId'
  left join futbeat_private.coverage_interests mi
    on mi.subject_type='match'
   and mi.subject_id=e.id
  where e.kind='match'
    and nullif(e.payload->>'startTime','') is not null
    and (e.payload->>'startTime')::timestamptz
      between now()-interval '150 minutes' and now()+interval '10 minutes'
    and coalesce(e.payload->>'status','') not in (
      'FINISHED_PENDING_VERIFICATION','VERIFIED','CANCELLED',
      'ABANDONED','POSTPONED'
    )
    and (
      coalesce(hi.explicit_followers,0)
      +coalesce(hi.temporary_users,0)
      +coalesce(ai.explicit_followers,0)
      +coalesce(ai.temporary_users,0)
      +coalesce(ci.explicit_followers,0)
      +coalesce(ci.temporary_users,0)
      +coalesce(mi.explicit_followers,0)
      +coalesce(mi.temporary_users,0)
    )>0
    and (
      (
        l.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
        and l.changed_at<now()-interval '8 minutes'
      )
      or (
        l.canonical_match_id is null
        and (e.payload->>'startTime')::timestamptz
          < now()-interval '15 minutes'
      )
    )
    and (
      c.fetched_at is null
      or c.fetched_at<now()-interval '8 minutes'
    )
  order by
    case
      when l.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then 0
      else 1
    end,
    (
      coalesce(hi.explicit_followers,0)
      +coalesce(ai.explicit_followers,0)
      +coalesce(ci.explicit_followers,0)
      +coalesce(mi.explicit_followers,0)
    ) desc,
    (
      coalesce(hi.temporary_users,0)
      +coalesce(ai.temporary_users,0)
      +coalesce(ci.temporary_users,0)
      +coalesce(mi.temporary_users,0)
    ) desc,
    coalesce(l.changed_at,'epoch'::timestamptz),
    (e.payload->>'startTime')::timestamptz
  limit 1;

  if v_match_id is null then
    return null;
  end if;

  insert into futbeat_private.match_detail_requests(
    match_id,requested_at,expires_at,request_count
  )
  values(v_match_id,now(),now()+interval '10 minutes',1)
  on conflict(match_id) do update
    set requested_at=excluded.requested_at,
        expires_at=excluded.expires_at,
        request_count=
          futbeat_private.match_detail_requests.request_count+1;

  return v_match_id;
end
$;

create or replace function public.futbeat_enqueue_stale_live_detail()
returns text
language sql
security definer
set search_path=''
as $
  select futbeat_private.enqueue_stale_interested_match_detail()
$;

revoke all on function public.futbeat_enqueue_stale_live_detail()
from public,anon,authenticated;

grant execute on function public.futbeat_enqueue_stale_live_detail()
to service_role;

create or replace function futbeat_private.futbeat_read_calendar_range(
  p_from_date date,
  p_to_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $
declare
  start_at timestamptz;
  end_at timestamptz;
  provider_from date;
  provider_to date;
  expected_dates integer;
  covered_dates integer;
  matches_json jsonb;
  teams_json jsonb;
  competitions_json jsonb;
  updated_at timestamptz;
begin
  if p_from_date is null
     or p_to_date is null
     or p_from_date > p_to_date
     or p_to_date - p_from_date > 31
     or not exists(
       select 1
       from pg_catalog.pg_timezone_names
       where name=p_timezone
     )
  then
    raise exception 'Invalid calendar range';
  end if;

  start_at := p_from_date::timestamp at time zone p_timezone;
  end_at := (p_to_date + 1)::timestamp at time zone p_timezone;

  select coalesce(
    jsonb_agg(
      case
        when d.status is not null
          and (
            d.status in (
              'FINISHED_PENDING_VERIFICATION','POSTPONED','CANCELLED',
              'SUSPENDED','ABANDONED'
            )
            or c.fetched_at>=now()-interval '15 minutes'
          )
        then e.payload || jsonb_strip_nulls(
          jsonb_build_object(
            'status',d.status,
            'minute',d.minute,
            'score',d.score,
            'liveProvider','goal_api',
            'liveChangedAt',c.fetched_at
          )
        )
        else e.payload
      end
      order by cm.start_time,e.id
    ),
    '[]'::jsonb
  ),
  max(
    greatest(
      coalesce(
        nullif(e.payload->'provenance'->>'receivedAt','')::timestamptz,
        cm.updated_at
      ),
      case
        when d.status is not null
          and (
            d.status in (
              'FINISHED_PENDING_VERIFICATION','POSTPONED','CANCELLED',
              'SUSPENDED','ABANDONED'
            )
            or c.fetched_at>=now()-interval '15 minutes'
          )
        then c.fetched_at
        else '-infinity'::timestamptz
      end
    )
  )
  into matches_json,updated_at
  from futbeat_private.calendar_matches cm
  join futbeat_private.entities e
    on e.id=cm.match_id and e.kind='match'
  left join futbeat_private.match_detail_cache c
    on c.match_id=e.id
  left join lateral (
    select
      case
        when upper(coalesce(c.payload->>'matchStatus',''))='POSTPONED'
          then 'POSTPONED'
        when upper(coalesce(c.payload->>'matchStatus',''))='CANCELLED'
          then 'CANCELLED'
        when upper(coalesce(c.payload->>'matchStatus',''))='SUSPENDED'
          then 'SUSPENDED'
        when upper(coalesce(c.payload->>'matchStatus',''))='ABANDONED'
          then 'ABANDONED'
        when upper(coalesce(c.payload->>'matchStatus',''))='HALF_TIME'
          or upper(coalesce(c.payload->>'matchPeriod',''))='HALF_TIME'
          then 'HALFTIME'
        when upper(coalesce(c.payload->>'matchStatus',''))='LIVE'
          and upper(coalesce(c.payload->>'matchPeriod',''))='EXTRA_TIME'
          then 'EXTRA_TIME'
        when upper(coalesce(c.payload->>'matchStatus',''))='LIVE'
          and upper(coalesce(c.payload->>'matchPeriod',''))='PENALTIES'
          then 'PENALTIES'
        when upper(coalesce(c.payload->>'matchStatus',''))='LIVE'
          then 'LIVE'
        when upper(coalesce(c.payload->>'matchStatus','')) in (
          'FINISHED','AFTER_ET','AFTER_PEN','AWARDED'
        )
          then 'FINISHED_PENDING_VERIFICATION'
        else null
      end as status,
      case
        when coalesce(c.payload->>'matchElapsed',c.payload->>'matchMinute','')
          ~ '^\\d+  v_job_id bigint;
  v_command text;
begin
  if to_regnamespace('vault') is null
     or to_regnamespace('cron') is null
     or to_regnamespace('net') is null then
    return;
  end if;

  if not exists(
    select 1
    from vault.decrypted_secrets
    where name='futbeat_goal_live_cron_token'
      and nullif(decrypted_secret,'') is not null
  ) then
    return;
  end if;

  select jobid into v_job_id
  from cron.job
  where jobname='futbeat-goal-detail-cron';

  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;

  v_command := $cmd$
    select net.http_post(
      url := 'https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-goal-live-sync',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'x-futbeat-cron-token',(
          select decrypted_secret
          from vault.decrypted_secrets
          where name='futbeat_goal_live_cron_token'
          order by updated_at desc nulls last,created_at desc
          limit 1
        )
      ),
      body := jsonb_build_object('trigger','detail-only'),
      timeout_milliseconds := 30000
    );
  $cmd$;

  perform cron.schedule(
    'futbeat-goal-detail-cron',
    '* * * * *',
    v_command
  );
end
$outer$;

notify pgrst,'reload schema';

        then coalesce(
          c.payload->>'matchElapsed',
          c.payload->>'matchMinute'
        )::integer
        else null
      end as minute,
      case
        when coalesce(c.payload->>'homeTeamScore','') ~ '^\\d+  v_job_id bigint;
  v_command text;
begin
  if to_regnamespace('vault') is null
     or to_regnamespace('cron') is null
     or to_regnamespace('net') is null then
    return;
  end if;

  if not exists(
    select 1
    from vault.decrypted_secrets
    where name='futbeat_goal_live_cron_token'
      and nullif(decrypted_secret,'') is not null
  ) then
    return;
  end if;

  select jobid into v_job_id
  from cron.job
  where jobname='futbeat-goal-detail-cron';

  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;

  v_command := $cmd$
    select net.http_post(
      url := 'https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-goal-live-sync',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'x-futbeat-cron-token',(
          select decrypted_secret
          from vault.decrypted_secrets
          where name='futbeat_goal_live_cron_token'
          order by updated_at desc nulls last,created_at desc
          limit 1
        )
      ),
      body := jsonb_build_object('trigger','detail-only'),
      timeout_milliseconds := 30000
    );
  $cmd$;

  perform cron.schedule(
    'futbeat-goal-detail-cron',
    '* * * * *',
    v_command
  );
end
$outer$;

notify pgrst,'reload schema';

         and coalesce(c.payload->>'awayTeamScore','') ~ '^\\d+  v_job_id bigint;
  v_command text;
begin
  if to_regnamespace('vault') is null
     or to_regnamespace('cron') is null
     or to_regnamespace('net') is null then
    return;
  end if;

  if not exists(
    select 1
    from vault.decrypted_secrets
    where name='futbeat_goal_live_cron_token'
      and nullif(decrypted_secret,'') is not null
  ) then
    return;
  end if;

  select jobid into v_job_id
  from cron.job
  where jobname='futbeat-goal-detail-cron';

  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;

  v_command := $cmd$
    select net.http_post(
      url := 'https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-goal-live-sync',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'x-futbeat-cron-token',(
          select decrypted_secret
          from vault.decrypted_secrets
          where name='futbeat_goal_live_cron_token'
          order by updated_at desc nulls last,created_at desc
          limit 1
        )
      ),
      body := jsonb_build_object('trigger','detail-only'),
      timeout_milliseconds := 30000
    );
  $cmd$;

  perform cron.schedule(
    'futbeat-goal-detail-cron',
    '* * * * *',
    v_command
  );
end
$outer$;

notify pgrst,'reload schema';

        then jsonb_build_object(
          'home',(c.payload->>'homeTeamScore')::integer,
          'away',(c.payload->>'awayTeamScore')::integer
        )
        else null
      end as score
  ) d on c.payload is not null
  where cm.start_time >= start_at
    and cm.start_time < end_at;

  select coalesce(
    jsonb_agg(e.payload order by e.payload->>'name',e.id),
    '[]'::jsonb
  )
  into teams_json
  from futbeat_private.entities e
  where e.kind='team'
    and e.id in (
      select value->>'homeTeamId'
      from jsonb_array_elements(matches_json)
      union
      select value->>'awayTeamId'
      from jsonb_array_elements(matches_json)
    );

  select coalesce(
    jsonb_agg(e.payload order by e.payload->>'country',e.payload->>'name',e.id),
    '[]'::jsonb
  )
  into competitions_json
  from futbeat_private.entities e
  where e.kind='competition'
    and e.id in (
      select value->>'competitionId'
      from jsonb_array_elements(matches_json)
      union
      select value->>'competitionId'
      from jsonb_array_elements(teams_json)
      where nullif(value->>'competitionId','') is not null
    );

  provider_from := (start_at at time zone 'UTC')::date;
  provider_to := ((end_at - interval '1 microsecond') at time zone 'UTC')::date;
  expected_dates := provider_to - provider_from + 1;

  select count(*)::integer
  into covered_dates
  from futbeat_private.calendar_coverage
  where provider='goal_api'
    and provider_date between provider_from and provider_to;

  return jsonb_build_object(
    'schemaVersion',1,
    'demo',false,
    'updatedAt',coalesce(updated_at,now()),
    'freshness',jsonb_build_object('stale',false),
    'coverage',jsonb_build_object(
      'source','FutBeat',
      'partial',covered_dates < expected_dates,
      'live',false,
      'developmentOnly',false,
      'sources',jsonb_build_array('GOAL API'),
      'calendar',jsonb_build_object(
        'from',p_from_date,
        'to',p_to_date,
        'timezone',p_timezone,
        'complete',covered_dates >= expected_dates
      )
    ),
    'competitions',competitions_json,
    'teams',teams_json,
    'players','[]'::jsonb,
    'matches',matches_json,
    'standings','[]'::jsonb
  );
end;
$;

do $outer$
declare
  v_job_id bigint;
  v_command text;
begin
  if to_regnamespace('vault') is null
     or to_regnamespace('cron') is null
     or to_regnamespace('net') is null then
    return;
  end if;

  if not exists(
    select 1
    from vault.decrypted_secrets
    where name='futbeat_goal_live_cron_token'
      and nullif(decrypted_secret,'') is not null
  ) then
    return;
  end if;

  select jobid into v_job_id
  from cron.job
  where jobname='futbeat-goal-detail-cron';

  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;

  v_command := $cmd$
    select net.http_post(
      url := 'https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-goal-live-sync',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'x-futbeat-cron-token',(
          select decrypted_secret
          from vault.decrypted_secrets
          where name='futbeat_goal_live_cron_token'
          order by updated_at desc nulls last,created_at desc
          limit 1
        )
      ),
      body := jsonb_build_object('trigger','detail-only'),
      timeout_milliseconds := 30000
    );
  $cmd$;

  perform cron.schedule(
    'futbeat-goal-detail-cron',
    '* * * * *',
    v_command
  );
end
$outer$;

notify pgrst,'reload schema';
