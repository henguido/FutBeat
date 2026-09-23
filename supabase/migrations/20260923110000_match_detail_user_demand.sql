-- Match detail on user demand.
--
-- Opening Match Center (GET /v1/match-detail) -> request_match_detail:
--   * fresh cached detail -> returned immediately, no demand (cache hit);
--   * missing/stale -> one deduplicated user demand per match, then the worker
--     is woken right away (debounced) instead of waiting for the cron;
--   * already queued/in flight -> counted as deduped, nothing else.
-- The worker still reserves with the per-match in-flight guard, so 500 users
-- opening the same match produce at most one fetch per freshness window.
--
-- Reservation order (lower first) and quota class:
--   1 LIVE opened by a user                 live
--   2 LIVE queued by the system / results   live / results
--   3 upcoming match opened by a user       user_high
--   4 historical match opened (no detail)   user
--   5 editorial prefetch                    coverage
--   6 background/bootstrap                  bootstrap
-- Each candidate must fit its class in the central quota manager; the fixed
-- 24/day + remaining<=80 development limits are gone (safety cap per kind
-- remains in provider_quota_policy).

alter table futbeat_private.match_detail_requests
  add column if not exists source text not null default 'prefetch'
    check(source in ('user','prefetch','bootstrap')),
  add column if not exists user_requested_at timestamptz;

-- The prefetch enqueuer upserts without touching source; over an expired
-- user row it must become a prefetch again (never inherit user priority).
create or replace function futbeat_private.reset_expired_detail_request_source()
returns trigger language plpgsql set search_path='' as $$
begin
  if old.expires_at<=now() and new.user_requested_at is not distinct from old.user_requested_at then
    new.source:='prefetch';
    new.user_requested_at:=null;
  end if;
  return new;
end $$;
drop trigger if exists match_detail_request_source on futbeat_private.match_detail_requests;
create trigger match_detail_request_source before update on futbeat_private.match_detail_requests
for each row execute function futbeat_private.reset_expired_detail_request_source();

-- Single freshness rule shared by request (cache hit) and reservation.
create or replace function futbeat_private.match_detail_due(p_status text,p_fetched_at timestamptz)
returns boolean language sql stable set search_path='' as $$
  select p_fetched_at is null
    or (p_status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
        and p_fetched_at<now()-interval '5 minutes')
    or (p_status='FINISHED_PENDING_VERIFICATION' and p_fetched_at<now()-interval '30 minutes')
    or (coalesce(p_status,'') not in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES',
          'FINISHED_PENDING_VERIFICATION','VERIFIED','CANCELLED','ABANDONED','POSTPONED')
        and p_fetched_at<now()-interval '30 minutes')
$$;

create or replace function futbeat_private.match_detail_status(p_match_id text)
returns text language sql stable set search_path='' as $$
  select coalesce(
    (select l.status from public.live_match_updates l where l.match_id=p_match_id and l.provider='goal_api'),
    (select e.payload->>'status' from futbeat_private.entities e where e.id=p_match_id and e.kind='match'))
$$;

create or replace function futbeat_private.detail_inflight(p_match_id text)
returns boolean language sql stable set search_path='' as $$
  select exists(select 1 from futbeat_private.provider_call_ledger flight
    where flight.provider='goal_api' and flight.call_kind='match-detail'
      and flight.metadata->>'matchId'=p_match_id
      and flight.status='RESERVED' and flight.completed_at is null
      and flight.reserved_at>now()-interval '10 minutes')
$$;

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
  v_fetched timestamptz;
  v_existing futbeat_private.match_detail_requests;
begin
  select nullif(payload->>'startTime','')::timestamptz
  into v_start
  from futbeat_private.entities
  where id=p_match_id and kind='match';

  if p_match_id is null or v_start is null then
    raise exception 'Unknown canonical match';
  end if;

  select exists(
    select 1 from futbeat_private.provider_entities
    where provider='goal_api' and kind='match' and canonical_id=p_match_id
  ) into v_goal_mapped;

  -- Anonymous requests only enqueue trusted canonical matches. Historical
  -- hydration is intentionally bounded to the indexed calendar horizon.
  if v_goal_mapped
     and v_start between now()-interval '90 days' and now()+interval '24 hours'
  then
    -- Serialize opens of the same match so dedupe accounting is exact.
    perform pg_advisory_xact_lock(hashtext('futbeat-match-detail-request'),hashtext(p_match_id));
    select fetched_at into v_fetched from futbeat_private.match_detail_cache where match_id=p_match_id;
    if not futbeat_private.match_detail_due(futbeat_private.match_detail_status(p_match_id),v_fetched) then
      perform futbeat_private.bump_metric('match_detail_cache_hits');
    else
      select * into v_existing from futbeat_private.match_detail_requests
      where match_id=p_match_id and expires_at>now();
      insert into futbeat_private.match_detail_requests(
        match_id,requested_at,expires_at,request_count,source,user_requested_at
      )
      values(p_match_id,now(),now()+interval '15 minutes',1,'user',now())
      on conflict(match_id) do update
        set requested_at=now(),
            expires_at=now()+interval '15 minutes',
            request_count=futbeat_private.match_detail_requests.request_count+1,
            source='user',
            user_requested_at=now();
      if futbeat_private.detail_inflight(p_match_id) then
        perform futbeat_private.bump_metric('deduped_requests');
      else
        if v_existing.match_id is not null and v_existing.source='user'
           and v_existing.user_requested_at>now()-interval '1 minute' then
          perform futbeat_private.bump_metric('deduped_requests');
        else
          perform futbeat_private.bump_metric('match_detail_user_demands');
        end if;
        -- Due and not in flight: wake (debounced), e.g. a LIVE detail that
        -- became stale again while its request row is still open.
        perform futbeat_private.wake_provider_worker('demand');
      end if;
    end if;
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
  v_remaining integer;
  v_cap jsonb;
  v_match_id text;
  v_external text;
  v_reservation bigint;
  v_status text;
  v_class text;
  v_rank integer;
  v_allowed boolean;
begin
  if p_trigger_source is null or btrim(p_trigger_source)='' then
    raise exception 'trigger_source is required';
  end if;

  perform futbeat_private.lock_provider_quota('goal_api');

  delete from futbeat_private.match_detail_requests
  where expires_at<=now();

  -- Safety cap per kind; the class is checked per candidate below.
  v_cap:=futbeat_private.quota_decision('goal_api','match-detail','live');
  v_remaining:=(v_cap->>'providerRemaining')::integer;
  if v_cap->>'reason'='kind_daily_cap' then
    return v_cap||jsonb_build_object('allowed',false);
  end if;

  with candidates as (
    select
      r.match_id,
      pe.external_id,
      futbeat_private.match_detail_status(r.match_id) status,
      c.fetched_at,
      r.source,
      r.requested_at,
      nullif(e.payload->>'startTime','')::timestamptz start_time
    from futbeat_private.match_detail_requests r
    join futbeat_private.entities e on e.id=r.match_id and e.kind='match'
    join futbeat_private.provider_entities pe
      on pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=r.match_id
    left join futbeat_private.match_detail_cache c on c.match_id=r.match_id
    where r.expires_at>now()
      and not futbeat_private.detail_inflight(r.match_id)
  ), ranked as (
    select *,
      case
        when status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then case when source='user' then 1 else 2 end
        when status='FINISHED_PENDING_VERIFICATION' then 2
        when source='user' and coalesce(status,'SCHEDULED') not in ('VERIFIED','CANCELLED','ABANDONED','POSTPONED')
          and start_time>now()-interval '3 hours' then 3
        when source='user' then 4
        when source='prefetch' then 5
        else 6
      end rank_value,
      case
        when status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then 'live'
        when status='FINISHED_PENDING_VERIFICATION' then 'results'
        when source='user' and coalesce(status,'SCHEDULED') not in ('VERIFIED','CANCELLED','ABANDONED','POSTPONED')
          and start_time>now()-interval '3 hours' then 'user_high'
        when source='user' then 'user'
        when source='prefetch' then 'coverage'
        else 'bootstrap'
      end quota_class
    from candidates
    where futbeat_private.match_detail_due(status,fetched_at)
  )
  -- Best allowed candidate first; if none fits its class, the best due one
  -- explains the refusal.
  select match_id,external_id,status,quota_class,rank_value,
    futbeat_private.quota_class_allowed('goal_api',quota_class,v_remaining)
  into v_match_id,v_external,v_status,v_class,v_rank,v_allowed
  from ranked
  order by 6 desc,rank_value,requested_at desc,match_id
  limit 1;

  if v_match_id is null or not v_allowed then
    return jsonb_build_object(
      'allowed',false,
      'reason',case when v_match_id is null then 'no_detail_due' else 'provider_remaining_reserve' end,
      'quotaClass',v_class,
      'detailUsed',(v_cap->>'usedToday')::integer,'providerRemaining',v_remaining
    );
  end if;

  -- Always acquire quota then match lock; recheck in a fresh statement.
  perform pg_advisory_xact_lock(
    hashtext('futbeat-match-detail-inflight'),hashtext(v_match_id)
  );
  if futbeat_private.detail_inflight(v_match_id) then
    return jsonb_build_object(
      'allowed',false,'reason','detail_inflight','matchId',v_match_id,
      'detailUsed',(v_cap->>'usedToday')::integer,'providerRemaining',v_remaining
    );
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at,metadata
  )
  values(
    'goal_api','match-detail',left(p_trigger_source,40),now(),
    jsonb_build_object('matchId',v_match_id,'externalMatchId',v_external,
      'status',v_status,'quotaClass',v_class,'priority',v_rank)
  )
  returning id into v_reservation;

  return jsonb_build_object(
    'allowed',true,
    'reservationId',v_reservation,
    'matchId',v_match_id,
    'externalMatchId',v_external,
    'status',v_status,
    'quotaClass',v_class,
    'priority',v_rank,
    'detailUsed',(v_cap->>'usedToday')::integer+1,
    'safetyCap',(v_cap->>'safetyCap')::integer,
    'providerRemaining',v_remaining
  );
end
$$;

revoke all on function
  futbeat_private.reset_expired_detail_request_source(),
  futbeat_private.match_detail_due(text,timestamptz),
  futbeat_private.match_detail_status(text),
  futbeat_private.detail_inflight(text)
from public,anon,authenticated,service_role;

notify pgrst,'reload schema';
