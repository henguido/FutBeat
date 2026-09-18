-- GOAL API LIVE transport. The existing canonical realtime read model is reused.

create or replace function futbeat_private.store_goal_api_live_key(p_secret text)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  v_id uuid;
begin
  if p_secret is null or length(btrim(p_secret)) < 20 then
    raise exception 'Invalid GOAL API key';
  end if;

  select id into v_id
  from vault.decrypted_secrets
  where name='futbeat_goal_api_live_key';

  if v_id is null then
    perform vault.create_secret(
      p_secret,
      'futbeat_goal_api_live_key',
      'GOAL API key used by FutBeat server-side LIVE sync'
    );
  else
    perform vault.update_secret(
      v_id,
      p_secret,
      'futbeat_goal_api_live_key',
      'GOAL API key used by FutBeat server-side LIVE sync'
    );
  end if;
end
$$;

create or replace function public.futbeat_store_goal_api_live_key(p_secret text)
returns void
language sql
security definer
set search_path=''
as $$
  select futbeat_private.store_goal_api_live_key(p_secret)
$$;

create or replace function futbeat_private.read_goal_api_live_key()
returns text
language sql
stable
security definer
set search_path=''
as $$
  select decrypted_secret
  from vault.decrypted_secrets
  where name='futbeat_goal_api_live_key'
  limit 1
$$;

create or replace function public.futbeat_read_goal_api_live_key()
returns text
language sql
stable
security definer
set search_path=''
as $$
  select futbeat_private.read_goal_api_live_key()
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

  -- The free GOAL API plan provides 1000 calls/day. Keep at least 180
  -- available for calendar expansion, squads and recovery jobs.
  if v_total>=820 then
    return jsonb_build_object(
      'allowed',false,
      'reason','goal_daily_reserve',
      'usedToday',v_total,
      'limit',1000,
      'reserve',180,
      'liveUsed',v_live
    );
  end if;

  if v_active=0 then
    return jsonb_build_object(
      'allowed',false,
      'reason','outside_live_window',
      'usedToday',v_total,
      'liveUsed',v_live,
      'nextStart',v_next
    );
  end if;

  if v_last is not null and v_last>v_now-interval '5 minutes' then
    return jsonb_build_object(
      'allowed',false,
      'reason','min_interval',
      'usedToday',v_total,
      'liveUsed',v_live,
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
    'reserve',180,
    'liveUsed',v_live+1,
    'activeMatches',v_active,
    'nextStart',v_next
  );
end
$$;

create or replace function public.futbeat_reserve_goal_live_call(
  p_trigger_source text default 'cron'
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_reserve_goal_live_call(p_trigger_source)
$$;

revoke all on function
  futbeat_private.store_goal_api_live_key(text),
  public.futbeat_store_goal_api_live_key(text),
  futbeat_private.read_goal_api_live_key(),
  public.futbeat_read_goal_api_live_key(),
  futbeat_private.futbeat_reserve_goal_live_call(text),
  public.futbeat_reserve_goal_live_call(text)
from public,anon,authenticated;

grant execute on function
  futbeat_private.store_goal_api_live_key(text),
  public.futbeat_store_goal_api_live_key(text),
  futbeat_private.read_goal_api_live_key(),
  public.futbeat_read_goal_api_live_key(),
  futbeat_private.futbeat_reserve_goal_live_call(text),
  public.futbeat_reserve_goal_live_call(text)
to service_role;

notify pgrst,'reload schema';
