-- Match Center data completeness (generic, any match/competition/season).
--
-- Root cause fixed: "a cached detail exists" was treated as "the detail is
-- complete" (read_match_detail -> detailLevel 'full', client never asked
-- again, VERIFIED matches were never due). A detail with events but no lineup
-- or statistics stayed incomplete forever, and nothing recorded that the
-- provider simply has no such section, nor backed off failed fetches.
--
-- Model, per match (match_detail_coverage):
--   lineup_state / statistics_state: UNKNOWN | AVAILABLE | NO_DATA
--     AVAILABLE when the stored detail has that section; NO_DATA once a
--     finished match was fetched MISS_LIMIT times without it (the provider
--     has none: no more polling); UNKNOWN otherwise.
--   failure_count / next_retry_at: exponential backoff after FAILED fetches.
-- A section is only "wanted" when it can exist: lineups from 60 minutes
-- before kickoff, statistics after kickoff; never for cancelled/postponed.
--
-- match_detail_needs_fetch(match) = not in backoff and (the existing freshness
-- rule says due, or a wanted section is still UNKNOWN and the last fetch is
-- older than a retry gap: 5 min live, 15 min within 6 h of kickoff, else 6 h).
-- It replaces match_detail_due in request_match_detail/reserve_match_detail_call,
-- so an incomplete detail is re-requested, deduplicated and prioritized as
-- before, and a complete fresh detail costs 0 provider calls.
--
-- read_match_detail now also returns `coverage` and a precise `pending`:
--   coverage.lineup / coverage.statistics: available | pending | unavailable | missing
--     available   = stored;  pending = a fetch is queued/in flight for it;
--     unavailable = provider has no data (NO_DATA);  missing = none and not
--     being fetched (not wanted yet, backoff, outside horizon, no mapping).
--   coverage.detail: available | pending | missing;  coverage.stale: stored
--   detail is past its freshness window;  pending = any section pending.

create table if not exists futbeat_private.match_detail_coverage(
  match_id text primary key references futbeat_private.entities(id) on delete cascade,
  lineup_state text not null default 'UNKNOWN' check(lineup_state in ('UNKNOWN','AVAILABLE','NO_DATA')),
  statistics_state text not null default 'UNKNOWN' check(statistics_state in ('UNKNOWN','AVAILABLE','NO_DATA')),
  lineup_misses integer not null default 0,
  statistics_misses integer not null default 0,
  last_fetch_at timestamptz,
  failure_count integer not null default 0,
  next_retry_at timestamptz,
  last_error text
);
alter table futbeat_private.match_detail_coverage enable row level security;
revoke all on futbeat_private.match_detail_coverage from public,anon,authenticated;

create or replace function futbeat_private.match_is_finished(p_status text)
returns boolean language sql immutable set search_path='' as $$
  select coalesce(p_status,'') in ('FINISHED_PENDING_VERIFICATION','VERIFIED','ABANDONED')
$$;

-- Section bookkeeping after every stored detail (the cache keeps the richer
-- sections, so NEW.payload is the merged view).
create or replace function futbeat_private.track_match_detail_sections()
returns trigger language plpgsql security definer set search_path='' as $$
declare has_lineup boolean; has_stats boolean; finished boolean; miss_limit constant integer:=2;
begin
  has_lineup:=exists(select 1 from futbeat_private.lineup_rows(new.payload));
  has_stats:=futbeat_private.detail_statistics_count(new.payload->'statistics')>0;
  finished:=futbeat_private.match_is_finished(futbeat_private.match_detail_status(new.match_id));
  insert into futbeat_private.match_detail_coverage as c(
    match_id,lineup_state,statistics_state,lineup_misses,statistics_misses,last_fetch_at)
  values(new.match_id,
    case when has_lineup then 'AVAILABLE' else 'UNKNOWN' end,
    case when has_stats then 'AVAILABLE' else 'UNKNOWN' end,
    case when has_lineup or not finished then 0 else 1 end,
    case when has_stats or not finished then 0 else 1 end,
    new.fetched_at)
  on conflict(match_id) do update set
    lineup_misses=case when has_lineup then 0 when finished then c.lineup_misses+1 else c.lineup_misses end,
    statistics_misses=case when has_stats then 0 when finished then c.statistics_misses+1 else c.statistics_misses end,
    lineup_state=case when has_lineup then 'AVAILABLE'
      when finished and c.lineup_misses+1>=miss_limit then 'NO_DATA' else 'UNKNOWN' end,
    statistics_state=case when has_stats then 'AVAILABLE'
      when finished and c.statistics_misses+1>=miss_limit then 'NO_DATA' else 'UNKNOWN' end,
    last_fetch_at=new.fetched_at,failure_count=0,next_retry_at=null,last_error=null;
  return new;
end $$;
drop trigger if exists match_detail_sections on futbeat_private.match_detail_cache;
drop trigger if exists match_detail_sections_update on futbeat_private.match_detail_cache;
create trigger match_detail_sections after insert on futbeat_private.match_detail_cache
for each row execute function futbeat_private.track_match_detail_sections();
-- Only a newer fetch counts as an answer (misses are never double-counted).
create trigger match_detail_sections_update after update of payload,fetched_at
on futbeat_private.match_detail_cache
for each row when (new.fetched_at>old.fetched_at)
execute function futbeat_private.track_match_detail_sections();

-- Failed fetches back off exponentially (2 min * 2^n, max 6 h): no retry loop.
create or replace function futbeat_private.track_match_detail_failure()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_match text:=coalesce(new.metadata->>'matchId',old.metadata->>'matchId'); failures integer;
begin
  if v_match is null or not exists(select 1 from futbeat_private.entities e where e.id=v_match) then return new; end if;
  insert into futbeat_private.match_detail_coverage as c(match_id,failure_count,next_retry_at,last_error)
  values(v_match,1,now()+interval '2 minutes',left(coalesce(new.error_code,'failed'),120))
  on conflict(match_id) do update set failure_count=c.failure_count+1,last_error=excluded.last_error
  returning c.failure_count into failures;
  update futbeat_private.match_detail_coverage c
  set next_retry_at=now()+least(interval '6 hours',interval '2 minutes'*power(2,least(failures-1,8)))
  where c.match_id=v_match;
  return new;
end $$;
drop trigger if exists match_detail_failure on futbeat_private.provider_call_ledger;
create trigger match_detail_failure after update of status on futbeat_private.provider_call_ledger
for each row when (new.call_kind='match-detail' and new.status='FAILED' and old.status='RESERVED')
execute function futbeat_private.track_match_detail_failure();

-- Backfill section state from what is already stored (no provider calls).
insert into futbeat_private.match_detail_coverage(match_id,lineup_state,statistics_state,last_fetch_at)
select c.match_id,
  case when exists(select 1 from futbeat_private.lineup_rows(c.payload)) then 'AVAILABLE' else 'UNKNOWN' end,
  case when futbeat_private.detail_statistics_count(c.payload->'statistics')>0 then 'AVAILABLE' else 'UNKNOWN' end,
  c.fetched_at
from futbeat_private.match_detail_cache c
on conflict(match_id) do nothing;

create or replace function futbeat_private.match_detail_sections(p_match_id text)
returns jsonb language sql stable set search_path='' as $$
  with m as (
    select nullif(e.payload->>'startTime','')::timestamptz start_time,
      futbeat_private.match_detail_status(e.id) status
    from futbeat_private.entities e where e.id=p_match_id and e.kind='match'
  )
  select jsonb_build_object(
    'lineupWanted',coalesce(m.status,'') not in ('CANCELLED','POSTPONED')
      and now()>=m.start_time-interval '60 minutes',
    'statisticsWanted',coalesce(m.status,'') not in ('CANCELLED','POSTPONED')
      and now()>=m.start_time,
    'retryGap',extract(epoch from case
      when m.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then interval '5 minutes'
      when m.start_time>now()-interval '6 hours' then interval '15 minutes'
      else interval '6 hours' end))
  from m
$$;

create or replace function futbeat_private.match_detail_needs_fetch(p_match_id text)
returns boolean language plpgsql stable set search_path='' as $$
declare status text:=futbeat_private.match_detail_status(p_match_id); fetched timestamptz;
  cov futbeat_private.match_detail_coverage; sections jsonb;
begin
  select * into cov from futbeat_private.match_detail_coverage where match_id=p_match_id;
  if cov.next_retry_at>now() then return false; end if;
  select fetched_at into fetched from futbeat_private.match_detail_cache where match_id=p_match_id;
  if futbeat_private.match_detail_due(status,fetched) then return true; end if;
  sections:=futbeat_private.match_detail_sections(p_match_id);
  if sections is null then return false; end if;
  return fetched<now()-make_interval(secs=>(sections->>'retryGap')::double precision)
    and (((sections->>'lineupWanted')::boolean and coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN')
      or ((sections->>'statisticsWanted')::boolean and coalesce(cov.statistics_state,'UNKNOWN')='UNKNOWN'));
end $$;

create or replace function futbeat_private.match_detail_completeness(p_match_id text)
returns jsonb language plpgsql stable set search_path='' as $$
declare payload jsonb; fetched timestamptz; cov futbeat_private.match_detail_coverage; sections jsonb;
  active boolean; has_lineup boolean; has_stats boolean; lineup text; stats text; detail text;
begin
  select c.payload,c.fetched_at into payload,fetched from futbeat_private.match_detail_cache c where c.match_id=p_match_id;
  select * into cov from futbeat_private.match_detail_coverage where match_id=p_match_id;
  sections:=coalesce(futbeat_private.match_detail_sections(p_match_id),'{}');
  -- A fetch will actually happen: in flight, or needed and requested.
  active:=futbeat_private.detail_inflight(p_match_id)
    or (futbeat_private.match_detail_needs_fetch(p_match_id)
      and exists(select 1 from futbeat_private.match_detail_requests r where r.match_id=p_match_id and r.expires_at>now()));
  has_lineup:=payload is not null and exists(select 1 from futbeat_private.lineup_rows(payload));
  has_stats:=payload is not null and futbeat_private.detail_statistics_count(payload->'statistics')>0;
  lineup:=case when has_lineup then 'available' when cov.lineup_state='NO_DATA' then 'unavailable'
    when active and coalesce((sections->>'lineupWanted')::boolean,false) then 'pending' else 'missing' end;
  stats:=case when has_stats then 'available' when cov.statistics_state='NO_DATA' then 'unavailable'
    when active and coalesce((sections->>'statisticsWanted')::boolean,false) then 'pending' else 'missing' end;
  detail:=case when payload is not null then 'available' when active then 'pending' else 'missing' end;
  return jsonb_build_object(
    'detail',detail,'lineup',lineup,'statistics',stats,
    'stale',payload is not null and futbeat_private.match_detail_due(futbeat_private.match_detail_status(p_match_id),fetched),
    'pending','pending' in (detail,lineup,stats),
    'retryAt',case when cov.next_retry_at>now() then cov.next_retry_at end);
end $$;

-- read_match_detail keeps its exact previous output and adds coverage and a
-- precise pending flag (the API/client no longer infer completeness from
-- "a cached row exists").
alter function futbeat_private.read_match_detail(text) rename to read_match_detail_base;
create function futbeat_private.read_match_detail(p_match_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare base jsonb:=futbeat_private.read_match_detail_base(p_match_id); coverage jsonb;
begin
  if base is null then return null; end if;
  coverage:=futbeat_private.match_detail_completeness(p_match_id);
  return base||jsonb_build_object('coverage',coverage,'pending',(coverage->>'pending')::boolean);
end $$;

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
    if not futbeat_private.match_detail_needs_fetch(p_match_id) then
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
    where futbeat_private.match_detail_needs_fetch(match_id)
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
  futbeat_private.match_is_finished(text),
  futbeat_private.track_match_detail_sections(),
  futbeat_private.track_match_detail_failure(),
  futbeat_private.match_detail_sections(text),
  futbeat_private.match_detail_needs_fetch(text),
  futbeat_private.match_detail_completeness(text),
  futbeat_private.read_match_detail_base(text),
  futbeat_private.read_match_detail(text)
from public,anon,authenticated,service_role;

notify pgrst,'reload schema';
