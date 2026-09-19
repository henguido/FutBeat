-- Event/history hydration policy.
-- Keep LIVE as the highest-priority GOAL API consumer, but allow shared on-demand
-- detail hydration for recent historical matches so Match Center can show
-- goals/cards/substitutions after the final whistle.

create or replace function futbeat_private.request_match_detail(
  p_match_id text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_start timestamptz;
  v_goal_mapped boolean;
begin
  select nullif(payload->>'startTime','')::timestamptz
  into v_start
  from futbeat_private.entities
  where id=p_match_id and kind='match';

  if p_match_id is null or v_start is null then
    raise exception 'Unknown canonical match';
  end if;

  select exists(
    select 1
    from futbeat_private.provider_entities
    where provider='goal_api'
      and kind='match'
      and canonical_id=p_match_id
  ) into v_goal_mapped;

  -- Anonymous requests only enqueue trusted canonical matches. Historical
  -- hydration is intentionally bounded to the indexed calendar horizon.
  if v_goal_mapped
     and v_start between now()-interval '90 days' and now()+interval '24 hours'
  then
    insert into futbeat_private.match_detail_requests(
      match_id,requested_at,expires_at,request_count
    )
    values(p_match_id,now(),now()+interval '15 minutes',1)
    on conflict(match_id) do update
      set requested_at=now(),
          expires_at=now()+interval '15 minutes',
          request_count=futbeat_private.match_detail_requests.request_count+1;
  end if;

  return futbeat_private.read_match_detail(p_match_id);
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

  -- LIVE itself keeps a 20-call emergency reserve. Match detail stops much
  -- earlier, leaving an additional 60-call operational cushion.
  if v_remaining is not null and v_remaining<=80 then
    return jsonb_build_object(
      'allowed',false,'reason','provider_remaining_reserve',
      'detailUsed',v_detail_used,'providerRemaining',v_remaining,'reserve',80
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
        coalesce(l.status,e.payload->>'status')='FINISHED_PENDING_VERIFICATION'
        and c.fetched_at<now()-interval '30 minutes'
      )
    )
  order by
    case
      when coalesce(l.status,e.payload->>'status') in (
        'LIVE','HALFTIME','EXTRA_TIME','PENALTIES'
      ) then 0
      when coalesce(l.status,e.payload->>'status')='FINISHED_PENDING_VERIFICATION'
        then 1
      else 2
    end,
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
    'reserve',80
  );
end
$$;

notify pgrst,'reload schema';
