-- Public API access for FutBeat 1.0: passive navigation + traffic limits.
--
-- 1. Navigation never creates provider demand (product decision, 2026-11-05:
--    "no GOAL calls caused by browsing", for every client). Every demand
--    entry point the API calls (the public futbeat_request_* functions and
--    the search's futbeat_private.note_player_search_demand) is wrapped
--    behind ONE switch, api_access_policy.navigation_demands, OFF by default.
--    Verified before writing this: no worker, cron or Edge Function other than
--    futbeat-api calls them; workers read their own planners. Off:
--      * futbeat_request_match_detail answers futbeat_read_match_detail
--        (the stored detail, same shape, no demand);
--      * every other request answers {"passive":true,"requested":false}
--        (callers read only enrichmentPending/backfill/pending: all absent,
--        so false: "nothing is being fetched for you");
--      * search never records a player demand (no pendingRemote).
--    Coverage then comes only from the scheduled workers. Turning the switch
--    on restores today's behaviour without a redeploy (the originals are kept
--    as futbeat_private.<name>__ungated).
--    The calendar read still builds snapshots from stored rows and may wake
--    the per-minute worker earlier: that creates no demand and no extra
--    provider call (the worker spends only what its own plans and quota say).
--
-- 2. api_access_policy holds the limits; futbeat_api_admit counts a request
--    against per-identity (minute + hour), per-IP-hash (minute) and global
--    (minute, 8 shards: no single hot row) windows in an UNLOGGED table and
--    says whether to serve it. Only a salted hash of the IP is stored.
--
-- No provider call, cron, quota policy, push or Preview change. Rollback:
-- supabase/manual/20261105100000_public_api_access_rollback.sql

create table if not exists futbeat_private.api_access_policy (
  singleton boolean primary key default true check(singleton),
  navigation_demands boolean not null default false,
  anonymous_per_minute integer not null default 60 check(anonymous_per_minute between 1 and 10000),
  anonymous_per_hour integer not null default 1200 check(anonymous_per_hour between 1 and 100000),
  registered_per_minute integer not null default 120 check(registered_per_minute between 1 and 10000),
  registered_per_hour integer not null default 2400 check(registered_per_hour between 1 and 100000),
  ip_per_minute integer not null default 240 check(ip_per_minute between 1 and 100000),
  global_per_minute integer not null default 6000 check(global_per_minute between 1 and 1000000),
  updated_at timestamptz not null default now(),
  note text
);
insert into futbeat_private.api_access_policy(singleton,note)
values(true,'1.0 defaults: passive navigation; limits are proposals, tune after load tests')
on conflict(singleton) do nothing;

create unlogged table if not exists futbeat_private.api_rate_counters (
  bucket text not null,
  window_start timestamptz not null,
  hits integer not null,
  primary key(bucket,window_start)
);
create index if not exists api_rate_counters_window_idx
  on futbeat_private.api_rate_counters(window_start);

alter table futbeat_private.api_access_policy enable row level security;
alter table futbeat_private.api_rate_counters enable row level security;
revoke all on futbeat_private.api_access_policy,futbeat_private.api_rate_counters
  from public,anon,authenticated;

create or replace function futbeat_private.navigation_demands_enabled()
returns boolean language sql stable security definer set search_path='' as $$
  select coalesce((select navigation_demands from futbeat_private.api_access_policy where singleton),false)
$$;

-- ---------------------------------------------------------------------------
-- 1. Demand gate
-- ---------------------------------------------------------------------------

do $$
declare f record;
begin
  for f in select * from (values
    ('futbeat_request_match_detail','p_match_id text','p_match_id'),
    ('futbeat_request_calendar_date','p_local_date date,p_timezone text','p_local_date,p_timezone'),
    ('futbeat_request_player_profile','p_player_id text','p_player_id'),
    ('futbeat_request_terminal_result','p_match_id text','p_match_id'),
    ('futbeat_request_lineup_hydration','p_starter_ids text[],p_bench_ids text[]','p_starter_ids,p_bench_ids'),
    ('futbeat_request_match_standings','p_match_id text','p_match_id'),
    ('futbeat_request_team_squad','p_team_id text','p_team_id'),
    ('futbeat_request_team_matches','p_team_id text,p_before date','p_team_id,p_before'),
    ('futbeat_request_match_h2h','p_match_id text','p_match_id'),
    ('futbeat_request_match_h2h_history','p_match_id text','p_match_id')
  ) v(name,args,call) loop
    execute format('alter function public.%I(%s) rename to %I',
      f.name,regexp_replace(f.args,'p_[a-z_]+ ','','g'),f.name||'__ungated');
    execute format('alter function public.%I(%s) set schema futbeat_private',
      f.name||'__ungated',regexp_replace(f.args,'p_[a-z_]+ ','','g'));
    execute format('revoke all on function futbeat_private.%I(%s) from public,anon,authenticated,service_role',
      f.name||'__ungated',regexp_replace(f.args,'p_[a-z_]+ ','','g'));
  end loop;
end $$;

create function public.futbeat_request_match_detail(p_match_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_match_detail__ungated(p_match_id);
  end if;
  -- Passive: the stored detail, exactly as the read-only path answers it.
  return public.futbeat_read_match_detail(p_match_id);
end $$;

create function public.futbeat_request_calendar_date(p_local_date date,p_timezone text default 'America/Costa_Rica')
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_calendar_date__ungated(p_local_date,p_timezone);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create function public.futbeat_request_player_profile(p_player_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_player_profile__ungated(p_player_id);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create function public.futbeat_request_terminal_result(p_match_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_terminal_result__ungated(p_match_id);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create function public.futbeat_request_lineup_hydration(p_starter_ids text[] default null,p_bench_ids text[] default null)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_lineup_hydration__ungated(p_starter_ids,p_bench_ids);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create function public.futbeat_request_match_standings(p_match_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_match_standings__ungated(p_match_id);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create function public.futbeat_request_team_squad(p_team_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_team_squad__ungated(p_team_id);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create function public.futbeat_request_team_matches(p_team_id text,p_before date default null)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_team_matches__ungated(p_team_id,p_before);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create function public.futbeat_request_match_h2h(p_match_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_match_h2h__ungated(p_match_id);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create function public.futbeat_request_match_h2h_history(p_match_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_match_h2h_history__ungated(p_match_id);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

-- Search: the player-search demand is the only provider side effect.
alter function futbeat_private.note_player_search_demand(text)
  rename to note_player_search_demand__ungated;
create function futbeat_private.note_player_search_demand(p_query text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.note_player_search_demand__ungated(p_query);
  end if;
  return jsonb_build_object('pending',false,'passive',true);
end $$;
revoke all on function futbeat_private.note_player_search_demand__ungated(text),
  futbeat_private.note_player_search_demand(text)
  from public,anon,authenticated,service_role;

do $$
declare s text;
begin
  foreach s in array array[
    'public.futbeat_request_match_detail(text)','public.futbeat_request_calendar_date(date,text)',
    'public.futbeat_request_player_profile(text)','public.futbeat_request_terminal_result(text)',
    'public.futbeat_request_lineup_hydration(text[],text[])','public.futbeat_request_match_standings(text)',
    'public.futbeat_request_team_squad(text)','public.futbeat_request_team_matches(text,date)',
    'public.futbeat_request_match_h2h(text)','public.futbeat_request_match_h2h_history(text)'] loop
    execute format('revoke all on function %s from public,anon,authenticated',s);
    execute format('grant execute on function %s to service_role',s);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Admission (rate limits)
-- ---------------------------------------------------------------------------

create or replace function futbeat_private.api_rate_take(p_bucket text,p_window timestamptz,p_cost integer)
returns integer language sql security definer set search_path='' as $$
  insert into futbeat_private.api_rate_counters as c(bucket,window_start,hits)
  values(p_bucket,p_window,p_cost)
  on conflict(bucket,window_start) do update set hits=c.hits+excluded.hits
  returning hits
$$;

-- p_subject: 'anon:<uuid>' / 'user:<uuid>' from a verified JWT, or null.
-- p_kind: 'anonymous' | 'registered' | 'none'. p_ip_hash: salted hash or null.
create or replace function futbeat_private.futbeat_api_admit(
  p_subject text,p_kind text,p_ip_hash text,p_cost integer default 1
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  pol futbeat_private.api_access_policy;
  v_minute timestamptz:=date_trunc('minute',now());
  v_hour timestamptz:=date_trunc('hour',now());
  v_shard integer; v_hits integer; v_global bigint;
  v_reason text; v_retry integer; v_per_minute integer; v_per_hour integer;
begin
  if p_kind not in ('anonymous','registered','none')
     or (p_kind='none') <> (p_subject is null)
     or (p_subject is not null and p_subject !~ '^(anon|user):[0-9a-f-]{36}$')
     or (p_kind='anonymous' and p_subject !~ '^anon:') or (p_kind='registered' and p_subject !~ '^user:')
     or (p_ip_hash is not null and p_ip_hash !~ '^[0-9a-f]{16,64}$')
     or p_cost is null or p_cost<1 or p_cost>10 then
    raise exception 'Invalid admission request';
  end if;
  select * into pol from futbeat_private.api_access_policy where singleton;
  v_per_minute:=case p_kind when 'anonymous' then pol.anonymous_per_minute else pol.registered_per_minute end;
  v_per_hour:=case p_kind when 'anonymous' then pol.anonymous_per_hour else pol.registered_per_hour end;

  if p_subject is not null then
    v_hits:=futbeat_private.api_rate_take('id:'||p_subject,v_minute,p_cost);
    if v_hits>v_per_minute then
      v_reason:='identity_minute';
      v_retry:=60-extract(second from now())::integer;
    else
      v_hits:=futbeat_private.api_rate_take('idh:'||p_subject,v_hour,p_cost);
      if v_hits>v_per_hour then
        v_reason:='identity_hour';
        v_retry:=ceil(extract(epoch from (v_hour+interval '1 hour'-now())))::integer;
      end if;
    end if;
  end if;

  if v_reason is null and p_ip_hash is not null then
    v_hits:=futbeat_private.api_rate_take('ip:'||p_ip_hash,v_minute,p_cost);
    if v_hits>pol.ip_per_minute then
      v_reason:='ip_minute';
      v_retry:=60-extract(second from now())::integer;
    end if;
  end if;

  if v_reason is null then
    v_shard:=abs(hashtext(coalesce(p_subject,p_ip_hash,'')))%8;
    perform futbeat_private.api_rate_take('global:'||v_shard,v_minute,p_cost);
    select coalesce(sum(hits),0) into v_global from futbeat_private.api_rate_counters
      where window_start=v_minute and bucket like 'global:%';
    if v_global>pol.global_per_minute then
      v_reason:='global_minute';
      v_retry:=60-extract(second from now())::integer;
    end if;
  end if;

  -- Old windows go away a little at a time (never a big delete).
  if random()<0.02 then
    delete from futbeat_private.api_rate_counters
    where ctid in (select ctid from futbeat_private.api_rate_counters
      where window_start<now()-interval '2 hours' limit 500);
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'allowed',v_reason is null,
    'reason',v_reason,
    'retryAfterSeconds',case when v_reason is not null then greatest(1,v_retry) end));
end $$;

create or replace function public.futbeat_api_admit(
  p_subject text,p_kind text,p_ip_hash text,p_cost integer default 1
) returns jsonb language sql security definer set search_path='' as $$
  select futbeat_private.futbeat_api_admit(p_subject,p_kind,p_ip_hash,p_cost)
$$;

revoke all on function futbeat_private.navigation_demands_enabled(),
  futbeat_private.api_rate_take(text,timestamptz,integer),
  futbeat_private.futbeat_api_admit(text,text,text,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.futbeat_api_admit(text,text,text,integer) from public,anon,authenticated;
grant execute on function public.futbeat_api_admit(text,text,text,integer) to service_role;

notify pgrst,'reload schema';
