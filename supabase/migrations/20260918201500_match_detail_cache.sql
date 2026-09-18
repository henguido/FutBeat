-- On-demand Match Center detail cache.
-- Opening a match creates only an aggregate request keyed by canonical match id;
-- no anonymous user/device identifier is stored.

create table if not exists futbeat_private.match_detail_requests (
  match_id text primary key references futbeat_private.entities(id) on delete cascade,
  requested_at timestamptz not null default now(),
  expires_at timestamptz not null,
  request_count bigint not null default 1 check(request_count>0)
);

create table if not exists futbeat_private.match_detail_cache (
  match_id text primary key references futbeat_private.entities(id) on delete cascade,
  provider text not null,
  external_match_id text not null,
  fetched_at timestamptz not null,
  payload jsonb not null check(jsonb_typeof(payload)='object')
);

create index if not exists match_detail_requests_due_idx
  on futbeat_private.match_detail_requests(expires_at,requested_at desc);

alter table futbeat_private.match_detail_requests enable row level security;
alter table futbeat_private.match_detail_cache enable row level security;
revoke all on futbeat_private.match_detail_requests,
  futbeat_private.match_detail_cache from public,anon,authenticated;

create or replace function futbeat_private.read_match_detail(
  p_match_id text
) returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  v_cache futbeat_private.match_detail_cache%rowtype;
  v_live jsonb;
  v_payload jsonb;
  v_level text := 'none';
  v_requested timestamptz;
begin
  if not exists(
    select 1 from futbeat_private.entities
    where id=p_match_id and kind='match'
  ) then
    return null;
  end if;

  select * into v_cache
  from futbeat_private.match_detail_cache
  where match_id=p_match_id;

  select po.raw_payload
  into v_live
  from futbeat_private.provider_observations po
  where po.provider='goal_api'
    and po.canonical_match_id=p_match_id
  order by po.received_at desc
  limit 1;

  select requested_at into v_requested
  from futbeat_private.match_detail_requests
  where match_id=p_match_id;

  if v_cache.match_id is not null then
    v_payload:=v_cache.payload;
    v_level:='full';
  elsif v_live is not null then
    v_payload:=v_live;
    v_level:='live';
  else
    v_payload:='{}'::jsonb;
  end if;

  return jsonb_build_object(
    'matchId',p_match_id,
    'available',v_level<>'none',
    'detailLevel',v_level,
    'requestedAt',v_requested,
    'fetchedAt',v_cache.fetched_at,
    'provider',coalesce(v_cache.provider,case when v_live is not null then 'goal_api' end),
    'externalMatchId',coalesce(
      v_cache.external_match_id,
      (
        select external_id
        from futbeat_private.provider_entities
        where provider='goal_api' and kind='match' and canonical_id=p_match_id
        limit 1
      )
    ),
    'payload',v_payload
  );
end
$$;

create or replace function futbeat_private.request_match_detail(
  p_match_id text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $
declare
  v_start timestamptz;
  v_cached boolean;
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
    from futbeat_private.match_detail_cache
    where match_id=p_match_id
  ) into v_cached;

  select exists(
    select 1
    from futbeat_private.provider_entities
    where provider='goal_api'
      and kind='match'
      and canonical_id=p_match_id
  ) into v_goal_mapped;

  -- Anonymous Match Center requests may only enqueue provider work for
  -- near-term/recent matches that already have a trusted GOAL mapping.
  -- Cached data remains readable outside this window without spending quota.
  -- A cached near-term match may be queued again; the reservation function
  -- still enforces the 5m/30m/6h freshness windows before spending quota.
  if v_goal_mapped
     and v_start between now()-interval '24 hours' and now()+interval '6 hours'
  then
    insert into futbeat_private.match_detail_requests(
      match_id,requested_at,expires_at,request_count
    )
    values(p_match_id,now(),now()+interval '10 minutes',1)
    on conflict(match_id) do update
      set requested_at=now(),
          expires_at=now()+interval '10 minutes',
          request_count=futbeat_private.match_detail_requests.request_count+1;
  end if;

  return futbeat_private.read_match_detail(p_match_id);
end
$;

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

  if v_remaining is not null and v_remaining<=140 then
    return jsonb_build_object(
      'allowed',false,'reason','provider_remaining_reserve',
      'detailUsed',v_detail_used,'providerRemaining',v_remaining,'reserve',140
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
    'reserve',140
  );
end
$$;

create or replace function futbeat_private.store_match_detail(
  p_match_id text,
  p_external_match_id text,
  p_fetched_at timestamptz,
  p_payload jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
begin
  if p_fetched_at is null
     or p_payload is null
     or jsonb_typeof(p_payload)<>'object'
     or not exists(
       select 1
       from futbeat_private.provider_entities
       where provider='goal_api'
         and kind='match'
         and external_id=p_external_match_id
         and canonical_id=p_match_id
     ) then
    raise exception 'Invalid match detail payload';
  end if;

  insert into futbeat_private.match_detail_cache(
    match_id,provider,external_match_id,fetched_at,payload
  )
  values(
    p_match_id,'goal_api',p_external_match_id,p_fetched_at,p_payload
  )
  on conflict(match_id) do update
    set provider=excluded.provider,
        external_match_id=excluded.external_match_id,
        fetched_at=excluded.fetched_at,
        payload=excluded.payload
  where futbeat_private.match_detail_cache.fetched_at<=excluded.fetched_at;

  return futbeat_private.read_match_detail(p_match_id);
end
$$;

create or replace function public.futbeat_request_match_detail(
  p_match_id text
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.request_match_detail(p_match_id)
$$;

create or replace function public.futbeat_read_match_detail(
  p_match_id text
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  select futbeat_private.read_match_detail(p_match_id)
$$;

create or replace function public.futbeat_reserve_match_detail_call(
  p_trigger_source text default 'github-actions'
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.reserve_match_detail_call(p_trigger_source)
$$;

create or replace function public.futbeat_store_match_detail(
  p_match_id text,
  p_external_match_id text,
  p_fetched_at timestamptz,
  p_payload jsonb
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.store_match_detail(
    p_match_id,p_external_match_id,p_fetched_at,p_payload
  )
$$;

revoke all on function
  futbeat_private.read_match_detail(text),
  futbeat_private.request_match_detail(text),
  futbeat_private.reserve_match_detail_call(text),
  futbeat_private.store_match_detail(text,text,timestamptz,jsonb),
  public.futbeat_request_match_detail(text),
  public.futbeat_read_match_detail(text),
  public.futbeat_reserve_match_detail_call(text),
  public.futbeat_store_match_detail(text,text,timestamptz,jsonb)
from public,anon,authenticated;

grant execute on function
  public.futbeat_request_match_detail(text),
  public.futbeat_read_match_detail(text),
  public.futbeat_reserve_match_detail_call(text),
  public.futbeat_store_match_detail(text,text,timestamptz,jsonb)
to service_role;

notify pgrst,'reload schema';
