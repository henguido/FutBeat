-- Expand the quota-safe LIVE beta to major competitions already present
-- in the canonical GOAL API calendar. API-Football remains the realtime
-- transport; mappings are seeded only when the canonical competition exists.

with desired(external_id, name, country) as (
  values
    ('2',   'UEFA Champions League', 'Europe'),
    ('3',   'UEFA Europa League', 'Europe'),
    ('39',  'Premier League', 'England'),
    ('61',  'Ligue 1', 'France'),
    ('78',  'Bundesliga', 'Germany'),
    ('88',  'Eredivisie', 'Netherlands'),
    ('94',  'Primeira Liga', 'Portugal'),
    ('135', 'Serie A', 'Italy'),
    ('140', 'La Liga', 'Spain'),
    ('253', 'Major League Soccer', 'USA'),
    ('262', 'Liga MX', 'Mexico'),
    ('848', 'UEFA Conference League', 'Europe')
),
resolved as (
  select
    d.external_id,
    min(e.id) as canonical_id
  from desired d
  join futbeat_private.entities e
    on e.kind='competition'
   and lower(extensions.unaccent(coalesce(e.payload->>'name','')))
       = lower(extensions.unaccent(d.name))
   and lower(extensions.unaccent(coalesce(e.payload->>'country','')))
       = lower(extensions.unaccent(d.country))
  group by d.external_id
)
insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
select 'api_football','competition',external_id,canonical_id
from resolved
where canonical_id is not null
on conflict(provider,kind,external_id)
do update set canonical_id=excluded.canonical_id;

create or replace function futbeat_private.futbeat_resolve_live_competition(
  p_external_league_id text
) returns text
language sql
stable
security definer
set search_path=''
as $$
  select case
    when p_external_league_id='162' then 'fb_comp_cr'
    else (
      select canonical_id
      from futbeat_private.provider_entities
      where provider='api_football'
        and kind='competition'
        and external_id=p_external_league_id
        and external_id in (
          '2','3','39','61','78','88','94','135','140','253','262','848'
        )
    )
  end
$$;

create or replace function public.futbeat_resolve_live_competition(
  p_external_league_id text
) returns text
language sql
stable
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_resolve_live_competition(p_external_league_id)
$$;

create or replace function futbeat_private.futbeat_reserve_live_call(
  p_trigger_source text default 'cron'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_now timestamptz:=now();
  v_day_start timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
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
    hashtext('futbeat-provider-quota:api_football:'||v_day_start::date::text)
  );

  select
    count(*)::integer,
    count(*) filter(where call_kind='live')::integer,
    max(reserved_at) filter(where call_kind='live')
  into v_total,v_live,v_last
  from futbeat_private.provider_call_ledger
  where provider='api_football'
    and reserved_at>=v_day_start
    and reserved_at<v_day_start+interval '1 day';

  with beta_matches as (
    select
      e.id,
      (e.payload->>'startTime')::timestamptz start_time,
      coalesce(l.status,e.payload->>'status') status
    from futbeat_private.entities e
    left join public.live_match_updates l on l.match_id=e.id
    where e.kind='match'
      and nullif(e.payload->>'startTime','') is not null
      and (
        e.payload->>'competitionId'='fb_comp_cr'
        or exists(
          select 1
          from futbeat_private.provider_entities p
          where p.provider='api_football'
            and p.kind='competition'
            and p.external_id in (
              '2','3','39','61','78','88','94','135','140','253','262','848'
            )
            and p.canonical_id=e.payload->>'competitionId'
        )
      )
  ), eligible as (
    select *
    from beta_matches
    where status not in (
      'FINISHED_PENDING_VERIFICATION','VERIFIED','CANCELLED',
      'ABANDONED','POSTPONED'
    )
      and (
        v_now between start_time-interval '5 minutes'
                  and start_time+interval '135 minutes'
        or (
          status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
          and v_now<start_time+interval '5 hours'
        )
      )
  )
  select count(*)::integer into v_active from eligible;

  select min((e.payload->>'startTime')::timestamptz)
  into v_next
  from futbeat_private.entities e
  where e.kind='match'
    and (e.payload->>'startTime')::timestamptz>v_now
    and (
      e.payload->>'competitionId'='fb_comp_cr'
      or exists(
        select 1
        from futbeat_private.provider_entities p
        where p.provider='api_football'
          and p.kind='competition'
          and p.external_id in (
            '2','3','39','61','78','88','94','135','140','253','262','848'
          )
          and p.canonical_id=e.payload->>'competitionId'
      )
    );

  if v_total>=95 then
    return jsonb_build_object(
      'allowed',false,'reason','global_daily_limit',
      'usedToday',v_total,'limit',95,'liveUsed',v_live
    );
  end if;

  if v_live>=75 then
    return jsonb_build_object(
      'allowed',false,'reason','live_daily_limit',
      'usedToday',v_total,'liveUsed',v_live,'liveLimit',75
    );
  end if;

  if v_active=0 then
    return jsonb_build_object(
      'allowed',false,'reason','outside_beta_window',
      'usedToday',v_total,'liveUsed',v_live,'nextBetaStart',v_next
    );
  end if;

  if v_last is not null and v_last>v_now-interval '5 minutes' then
    return jsonb_build_object(
      'allowed',false,'reason','min_interval',
      'usedToday',v_total,'liveUsed',v_live,
      'retryAfterSeconds',
      greatest(0,300-extract(epoch from (v_now-v_last))::integer)
    );
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at
  )
  values('api_football','live',left(p_trigger_source,40),v_now)
  returning id into v_id;

  return jsonb_build_object(
    'allowed',true,
    'reservationId',v_id,
    'usedToday',v_total+1,
    'limit',95,
    'liveUsed',v_live+1,
    'liveLimit',75,
    'activeMatches',v_active,
    'nextBetaStart',v_next
  );
end
$$;

create or replace function public.futbeat_reserve_live_call(
  p_trigger_source text default 'cron'
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_reserve_live_call(p_trigger_source)
$$;

revoke all on function
  futbeat_private.futbeat_resolve_live_competition(text),
  public.futbeat_resolve_live_competition(text),
  futbeat_private.futbeat_reserve_live_call(text),
  public.futbeat_reserve_live_call(text)
from public,anon,authenticated;

grant execute on function
  futbeat_private.futbeat_resolve_live_competition(text),
  public.futbeat_resolve_live_competition(text),
  futbeat_private.futbeat_reserve_live_call(text),
  public.futbeat_reserve_live_call(text)
to service_role;

notify pgrst,'reload schema';
