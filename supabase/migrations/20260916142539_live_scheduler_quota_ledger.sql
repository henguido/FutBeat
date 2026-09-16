create table futbeat_private.provider_call_ledger (
  id bigint generated always as identity primary key,
  provider text not null,
  call_kind text not null default 'live',
  trigger_source text not null,
  reserved_at timestamptz not null default now(),
  completed_at timestamptz,
  status text not null default 'RESERVED' check (status in ('RESERVED','SUCCEEDED','FAILED')),
  provider_remaining integer check (provider_remaining is null or provider_remaining >= 0),
  http_status integer check (http_status is null or (http_status >= 100 and http_status <= 599)),
  error_code text,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object')
);

create index provider_call_ledger_provider_reserved_idx
  on futbeat_private.provider_call_ledger (provider, reserved_at desc);

alter table futbeat_private.provider_call_ledger enable row level security;
revoke all on futbeat_private.provider_call_ledger from public;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on futbeat_private.provider_call_ledger from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke all on futbeat_private.provider_call_ledger from authenticated;
  end if;
end $$;

create or replace function public.futbeat_reserve_provider_call(
  p_provider text,
  p_call_kind text default 'live',
  p_trigger_source text default 'manual',
  p_daily_limit integer default 95,
  p_min_interval_seconds integer default 120,
  p_force boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := now();
  v_day_start timestamptz := date_trunc('day', now() at time zone 'UTC') at time zone 'UTC';
  v_today integer;
  v_last_reserved timestamptz;
  v_next_start timestamptz;
  v_active_window boolean := false;
  v_id bigint;
begin
  if p_provider is null or btrim(p_provider) = '' then raise exception 'provider is required'; end if;
  if p_call_kind is null or btrim(p_call_kind) = '' then raise exception 'call_kind is required'; end if;
  if p_trigger_source is null or btrim(p_trigger_source) = '' then raise exception 'trigger_source is required'; end if;
  if p_daily_limit < 1 or p_daily_limit > 100 then raise exception 'daily_limit must be between 1 and 100'; end if;
  if p_min_interval_seconds < 0 then raise exception 'min_interval_seconds must be >= 0'; end if;

  perform pg_advisory_xact_lock(hashtext('futbeat-provider-quota:' || p_provider || ':' || v_day_start::date::text));

  select count(*)::integer, max(reserved_at)
    into v_today, v_last_reserved
    from futbeat_private.provider_call_ledger
   where provider = p_provider
     and reserved_at >= v_day_start
     and reserved_at < v_day_start + interval '1 day';

  select min(nullif(payload ->> 'startTime', '')::timestamptz)
    into v_next_start
    from futbeat_private.entities
   where kind = 'match'
     and payload ->> 'competitionId' = 'fb_comp_cr'
     and nullif(payload ->> 'startTime', '') is not null
     and nullif(payload ->> 'startTime', '')::timestamptz >= v_now - interval '3 hours'
     and coalesce(payload ->> 'status', '') not in ('VERIFIED','CANCELLED','ABANDONED','POSTPONED');

  select exists (
    select 1
      from futbeat_private.entities
     where kind = 'match'
       and payload ->> 'competitionId' = 'fb_comp_cr'
       and nullif(payload ->> 'startTime', '') is not null
       and v_now between nullif(payload ->> 'startTime', '')::timestamptz - interval '2 minutes'
                     and nullif(payload ->> 'startTime', '')::timestamptz + interval '3 hours'
       and coalesce(payload ->> 'status', '') not in ('VERIFIED','CANCELLED','ABANDONED','POSTPONED')
  ) into v_active_window;

  if v_today >= p_daily_limit then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'daily_limit',
      'usedToday', v_today,
      'limit', p_daily_limit,
      'nextTrackedStart', v_next_start
    );
  end if;

  if not p_force and not v_active_window then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'outside_tracked_window',
      'usedToday', v_today,
      'limit', p_daily_limit,
      'nextTrackedStart', v_next_start
    );
  end if;

  if not p_force and v_last_reserved is not null
     and v_last_reserved > v_now - make_interval(secs => p_min_interval_seconds) then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'min_interval',
      'usedToday', v_today,
      'limit', p_daily_limit,
      'retryAfterSeconds', greatest(0, p_min_interval_seconds - extract(epoch from (v_now - v_last_reserved))::integer),
      'nextTrackedStart', v_next_start
    );
  end if;

  insert into futbeat_private.provider_call_ledger(provider, call_kind, trigger_source, reserved_at)
  values (p_provider, p_call_kind, p_trigger_source, v_now)
  returning id into v_id;

  return jsonb_build_object(
    'allowed', true,
    'reservationId', v_id,
    'usedToday', v_today + 1,
    'limit', p_daily_limit,
    'activeTrackedWindow', v_active_window,
    'nextTrackedStart', v_next_start
  );
end;
$$;

create or replace function public.futbeat_complete_provider_call(
  p_reservation_id bigint,
  p_status text,
  p_provider_remaining integer default null,
  p_http_status integer default null,
  p_error_code text default null,
  p_metadata jsonb default '{}'::jsonb
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated integer;
begin
  if p_status not in ('SUCCEEDED','FAILED') then raise exception 'invalid status'; end if;
  if p_metadata is null or jsonb_typeof(p_metadata) <> 'object' then raise exception 'metadata must be an object'; end if;

  update futbeat_private.provider_call_ledger
     set completed_at = now(),
         status = p_status,
         provider_remaining = p_provider_remaining,
         http_status = p_http_status,
         error_code = p_error_code,
         metadata = p_metadata
   where id = p_reservation_id
     and status = 'RESERVED';
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end;
$$;

revoke all on function public.futbeat_reserve_provider_call(text,text,text,integer,integer,boolean) from public;
revoke all on function public.futbeat_complete_provider_call(bigint,text,integer,integer,text,jsonb) from public;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on function public.futbeat_reserve_provider_call(text,text,text,integer,integer,boolean) from anon;
    revoke all on function public.futbeat_complete_provider_call(bigint,text,integer,integer,text,jsonb) from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke all on function public.futbeat_reserve_provider_call(text,text,text,integer,integer,boolean) from authenticated;
    revoke all on function public.futbeat_complete_provider_call(bigint,text,integer,integer,text,jsonb) from authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.futbeat_reserve_provider_call(text,text,text,integer,integer,boolean) to service_role;
    grant execute on function public.futbeat_complete_provider_call(bigint,text,integer,integer,text,jsonb) to service_role;
  end if;
end $$;
