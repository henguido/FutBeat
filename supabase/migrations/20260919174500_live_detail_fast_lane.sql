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
