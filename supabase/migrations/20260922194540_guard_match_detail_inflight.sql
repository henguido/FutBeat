-- Guard the provider attempt, not only queue insertion.
-- A valid flight is RESERVED, not completed, and younger than 10 minutes.
-- The lease exceeds the worker's bounded HTTP/RPC timeouts; an abandoned
-- reservation stops blocking after 10 minutes without deleting its quota row.
-- FAILED/SUCCEEDED rows do not hold a lease. Existing cache eligibility,
-- quota limits/reserve, request expiry/order and completion handling remain
-- unchanged. Runtime RPC transactions use READ COMMITTED, as before.
-- No worker/store/request-table changes and no remote execution.

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
    -- In-flight candidates do not block another match in the existing queue.
    and not exists (
      select 1 from futbeat_private.provider_call_ledger flight
      where flight.provider='goal_api' and flight.call_kind='match-detail'
        and flight.metadata->>'matchId'=r.match_id
        and flight.status='RESERVED' and flight.completed_at is null
        and flight.reserved_at>now()-interval '10 minutes'
    )
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

  -- Preserve the existing quota lock above; add no new global lock.
  -- Always acquire quota then match lock. Recheck in a separate statement
  -- (fresh READ COMMITTED snapshot) after acquiring the transaction lock.
  perform pg_advisory_xact_lock(
    hashtext('futbeat-match-detail-inflight'),hashtext(v_match_id)
  );
  if exists (
    select 1 from futbeat_private.provider_call_ledger flight
    where flight.provider='goal_api' and flight.call_kind='match-detail'
      and flight.metadata->>'matchId'=v_match_id
      and flight.status='RESERVED' and flight.completed_at is null
      and flight.reserved_at>now()-interval '10 minutes'
  ) then
    return jsonb_build_object(
      'allowed',false,'reason','detail_inflight','matchId',v_match_id,
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
