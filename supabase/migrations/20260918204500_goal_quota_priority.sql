-- GOAL API quota priority:
-- 1) LIVE keeps an emergency reserve of 20 calls.
-- 2) On-demand Match Center detail keeps 220 calls available for LIVE.
-- 3) Calendar expansion / squads stop first at a configurable low-priority reserve.

create or replace function futbeat_private.futbeat_goal_low_priority_plan(
  p_reserve integer default 350
) returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  v_day_start timestamptz :=
    date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  v_remaining integer;
begin
  if p_reserve < 50 or p_reserve > 900 then
    raise exception 'Invalid GOAL API reserve';
  end if;

  select provider_remaining
  into v_remaining
  from futbeat_private.provider_call_ledger
  where provider='goal_api'
    and provider_remaining is not null
    and reserved_at>=v_day_start
    and reserved_at<v_day_start+interval '1 day'
  order by coalesce(completed_at,reserved_at) desc,id desc
  limit 1;

  if v_remaining is not null and v_remaining<=p_reserve then
    return jsonb_build_object(
      'allowed',false,
      'reason','provider_remaining_reserve',
      'providerRemaining',v_remaining,
      'reserve',p_reserve
    );
  end if;

  return jsonb_build_object(
    'allowed',true,
    'reason',case when v_remaining is null then 'remaining_unknown' else 'quota_available' end,
    'providerRemaining',v_remaining,
    'reserve',p_reserve
  );
end
$$;

create or replace function public.futbeat_goal_low_priority_plan(
  p_reserve integer default 350
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_goal_low_priority_plan(p_reserve)
$$;

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

  -- Fallback only when the provider has not reported remaining quota today.
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

  if v_last is not null and v_last>v_now-interval '5 minutes' then
    return jsonb_build_object(
      'allowed',false,
      'reason','min_interval',
      'usedToday',v_total,
      'liveUsed',v_live,
      'providerRemaining',v_last_remaining,
      'retryAfterSeconds',
      greatest(0,300-extract(epoch from (v_now-v_last))::integer)
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

create or replace function futbeat_private.reserve_match_detail_call(
  p_trigger_source text default 'github-actions'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_day_start timestamptz :=
    date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  v_detail_used integer;
  v_remaining integer;
  v_match_id text;
  v_external text;
  v_reservation bigint;
  v_status text;
  v_fetched timestamptz;
begin
  if p_trigger_source is null or btrim(p_trigger_source)='' then
    raise exception 'trigger_source is required';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('futbeat-provider-quota:goal_api:'||v_day_start::date::text)
  );

  delete from futbeat_private.match_detail_requests
  where expires_at<=now();

  select count(*)::integer
  into v_detail_used
  from futbeat_private.provider_call_ledger
  where provider='goal_api'
    and call_kind='match-detail'
    and reserved_at>=v_day_start
    and reserved_at<v_day_start+interval '1 day';

  select provider_remaining
  into v_remaining
  from futbeat_private.provider_call_ledger
  where provider='goal_api'
    and provider_remaining is not null
    and reserved_at>=v_day_start
    and reserved_at<v_day_start+interval '1 day'
  order by coalesce(completed_at,reserved_at) desc,id desc
  limit 1;

  if v_detail_used>=24 then
    return jsonb_build_object(
      'allowed',false,'reason','detail_daily_limit',
      'detailUsed',v_detail_used,'detailLimit',24,
      'providerRemaining',v_remaining
    );
  end if;

  if v_remaining is not null and v_remaining<=220 then
    return jsonb_build_object(
      'allowed',false,'reason','provider_remaining_reserve',
      'detailUsed',v_detail_used,'providerRemaining',v_remaining,'reserve',220
    );
  end if;

  select
    r.match_id,
    pe.external_id,
    coalesce(l.status,e.payload->>'status'),
    c.fetched_at
  into v_match_id,v_external,v_status,v_fetched
  from futbeat_private.match_detail_requests r
  join futbeat_private.entities e
    on e.id=r.match_id and e.kind='match'
  join futbeat_private.provider_entities pe
    on pe.provider='goal_api'
   and pe.kind='match'
   and pe.canonical_id=r.match_id
  left join public.live_match_updates l
    on l.match_id=r.match_id and l.provider='goal_api'
  left join futbeat_private.match_detail_cache c
    on c.match_id=r.match_id
  where r.expires_at>now()
    and (
      c.fetched_at is null
      or (
        coalesce(l.status,e.payload->>'status') in (
          'LIVE','HALFTIME','EXTRA_TIME','PENALTIES'
        )
        and c.fetched_at<now()-interval '5 minutes'
      )
      or (
        coalesce(l.status,e.payload->>'status') not in (
          'LIVE','HALFTIME','EXTRA_TIME','PENALTIES',
          'FINISHED_PENDING_VERIFICATION','VERIFIED',
          'CANCELLED','ABANDONED','POSTPONED'
        )
        and c.fetched_at<now()-interval '30 minutes'
      )
      or (
        coalesce(l.status,e.payload->>'status') in (
          'FINISHED_PENDING_VERIFICATION','VERIFIED'
        )
        and c.fetched_at<now()-interval '6 hours'
      )
    )
  order by
    case when coalesce(l.status,e.payload->>'status') in (
      'LIVE','HALFTIME','EXTRA_TIME','PENALTIES'
    ) then 0 else 1 end,
    r.requested_at desc
  limit 1;

  if v_match_id is null then
    return jsonb_build_object(
      'allowed',false,'reason','no_detail_due',
      'detailUsed',v_detail_used,'providerRemaining',v_remaining
    );
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at,metadata
  )
  values(
    'goal_api','match-detail',left(p_trigger_source,40),now(),
    jsonb_build_object(
      'matchId',v_match_id,
      'externalMatchId',v_external,
      'status',v_status
    )
  )
  returning id into v_reservation;

  return jsonb_build_object(
    'allowed',true,
    'reservationId',v_reservation,
    'matchId',v_match_id,
    'externalMatchId',v_external,
    'status',v_status,
    'detailUsed',v_detail_used+1,
    'detailLimit',24,
    'providerRemaining',v_remaining,
    'reserve',220
  );
end
$$;

revoke all on function
  futbeat_private.futbeat_goal_low_priority_plan(integer),
  public.futbeat_goal_low_priority_plan(integer)
from public,anon,authenticated;

grant execute on function
  futbeat_private.futbeat_goal_low_priority_plan(integer),
  public.futbeat_goal_low_priority_plan(integer)
to service_role;

notify pgrst,'reload schema';
