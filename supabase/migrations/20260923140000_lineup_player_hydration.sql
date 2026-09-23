-- Lineup player hydration on match-detail demand. Match Center already
-- resolves each lineup player's canonicalId and available media via
-- futbeat_read_lineup_player_media (preserve_match_detail_and_lineup_identity
-- .sql:114, player_media_squad_coverage.sql:232). When a canonical player is
-- missing a verified photo, this reuses the existing player on-demand
-- pipeline (player_on_demand.sql) instead of one call per lineup player: one
-- RPC call from futbeat-api registers up to 60 canonical ids at once,
-- deduped per player, leased, and drained by the same
-- futbeat_reserve_player_call the worker already runs every demand cycle.
-- Starters are prioritized over bench so the most visible photos land first.

alter table futbeat_private.player_profile_coverage
  add column if not exists priority smallint not null default 100;

create or replace function public.futbeat_request_lineup_hydration(
  p_starter_ids text[] default null,
  p_bench_ids text[] default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  pid text; v_priority smallint; ext text; due jsonb;
  previous timestamptz; lease_at timestamptz;
  any_pending boolean:=false; should_wake boolean:=false;
begin
  for pid,v_priority in
    select s.player_id,s.priority from (
      select unnest(coalesce(p_starter_ids,array[]::text[])) player_id,1::smallint priority
      union all
      select unnest(coalesce(p_bench_ids,array[]::text[])),2::smallint
    ) s
    where s.player_id is not null and s.player_id<>''
    limit 60
  loop
    select external_id into ext from futbeat_private.provider_entities
    where provider='goal_api' and kind='player' and canonical_id=pid
    order by external_id limit 1;
    if ext is null then continue; end if;

    due:=futbeat_private.player_hydration_due(pid);
    if not coalesce((due->>'profileDue')::boolean,false) then continue; end if;
    if not coalesce((futbeat_private.quota_decision('goal_api','player-profile','user')->>'allowed')::boolean,false) then
      continue;
    end if;

    -- Still due and quota-allowed: pending regardless of whether THIS call
    -- deduped against an earlier request for the same player (matching
    -- futbeat_request_player_profile's own pending semantics) — otherwise
    -- the client's bounded refresh sees enrichmentPending:false and stops
    -- retrying while the player is still genuinely queued.
    any_pending:=true;

    select requested_at,lease_until into previous,lease_at
    from futbeat_private.player_profile_coverage where player_id=pid;
    insert into futbeat_private.player_profile_coverage(player_id,external_id,requested_at,request_count,priority)
    values(pid,ext,now(),1,v_priority)
    on conflict(player_id) do update set
      requested_at=now(),
      external_id=excluded.external_id,
      request_count=futbeat_private.player_profile_coverage.request_count+1,
      priority=least(futbeat_private.player_profile_coverage.priority,excluded.priority);

    if lease_at>now() or previous>now()-interval '1 minute' then
      perform futbeat_private.bump_metric('deduped_requests');
    else
      perform futbeat_private.bump_metric('lineup_player_hydration_demands');
      should_wake:=true;
    end if;
  end loop;

  if should_wake then perform futbeat_private.wake_provider_worker('demand'); end if;
  return jsonb_build_object('enrichmentPending',any_pending);
end
$$;

-- A user actively viewing a player's own screen always outranks lineup
-- hydration for the same player (priority 0 < lineup's 1/2 < default 100),
-- so direct profile visits are never starved by up to 60 lineup demands
-- sharing the same player-profile worker cycle (futbeat_reserve_player_call,
-- 20 rows per pass, priority-ordered below).
create or replace function public.futbeat_request_player_profile(p_player_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ext text; due jsonb; previous timestamptz; lease timestamptz; pending boolean;
begin
  select external_id into ext from futbeat_private.provider_entities
  where provider='goal_api' and kind='player' and canonical_id=p_player_id
  order by external_id limit 1;
  if ext is null then return jsonb_build_object('enrichmentPending',false,'reason','unmapped'); end if;
  due:=futbeat_private.player_hydration_due(p_player_id);
  -- Only promise enrichment that the quota manager would allow today.
  pending:=((due->>'profileDue')::boolean
      and (futbeat_private.quota_decision('goal_api','player-profile','user')->>'allowed')::boolean)
    or ((due->>'statsDue')::boolean
      and (futbeat_private.quota_decision('goal_api','player-stats','user')->>'allowed')::boolean);
  if not pending then
    perform futbeat_private.bump_metric('player_profile_cache_hits');
    return jsonb_build_object('enrichmentPending',false)||due;
  end if;
  select requested_at,lease_until into previous,lease from futbeat_private.player_profile_coverage
  where player_id=p_player_id;
  insert into futbeat_private.player_profile_coverage(player_id,external_id,requested_at,request_count,priority)
  values(p_player_id,ext,now(),1,0)
  on conflict(player_id) do update set requested_at=now(),external_id=excluded.external_id,
    request_count=futbeat_private.player_profile_coverage.request_count+1,priority=0;
  if lease>now() or previous>now()-interval '1 minute' then
    perform futbeat_private.bump_metric('deduped_requests');
  else
    perform futbeat_private.bump_metric('player_profile_demands');
    perform futbeat_private.wake_provider_worker('demand');
  end if;
  return jsonb_build_object('enrichmentPending',true)||due;
end $$;

-- Direct profile visits (priority 0) first, then starters (1), then bench
-- (2), then freshest demand at the shared default priority (100).
create or replace function public.futbeat_reserve_player_call(p_trigger_source text default 'supabase-cron')
returns jsonb language plpgsql security definer set search_path='' as $$
declare window_start timestamptz:=now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','demandWindowMinutes',30)::integer);
  lease interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','leaseMinutes',10)::integer);
  decision jsonb; last_decision jsonb; demand futbeat_private.player_search_demands; player record; id bigint;
begin
  if nullif(btrim(p_trigger_source),'') is null then raise exception 'trigger_source is required'; end if;
  perform futbeat_private.lock_provider_quota('goal_api');

  delete from futbeat_private.player_search_demands where query_key in (
    select query_key from futbeat_private.player_search_demands
    where (status='QUEUED' and last_attempt_at is null and requested_at<=window_start)
       or (status<>'QUEUED' and coalesce(next_retry_at,last_attempt_at,requested_at)<now()-interval '30 days')
    limit 500);

  decision:=futbeat_private.quota_decision('goal_api','player-search','user');
  last_decision:=decision;
  if (decision->>'allowed')::boolean then
    select * into demand from futbeat_private.player_search_demands
    where status='QUEUED' and requested_at>window_start and coalesce(lease_until,'-infinity')<=now()
      and coalesce(next_retry_at,'-infinity')<=now()
    order by requested_at>now()-interval '1 minute' desc,least(request_count,5) desc,requested_at desc,query_key
    limit 1 for update skip locked;
    if demand.query_key is not null then
      update futbeat_private.player_search_demands set lease_until=now()+lease,last_attempt_at=now()
      where query_key=demand.query_key;
      insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
      values('goal_api','player-search',left(p_trigger_source,40),now(),
        jsonb_build_object('queryKey',demand.query_key,'query',demand.query_text))
      returning provider_call_ledger.id into id;
      return decision||jsonb_build_object('allowed',true,'reservationId',id,'kind','player-search',
        'query',demand.query_text,'queryKey',demand.query_key);
    end if;
  end if;

  for player in
    select c.player_id,c.external_id,(d->>'profileDue')::boolean profile_due,(d->>'statsDue')::boolean stats_due
    from futbeat_private.player_profile_coverage c
    cross join lateral futbeat_private.player_hydration_due(c.player_id) d
    where c.requested_at>window_start and coalesce(c.lease_until,'-infinity')<=now()
      and ((d->>'profileDue')::boolean or (d->>'statsDue')::boolean)
    order by c.priority,c.requested_at desc,c.player_id
    limit 20
  loop
    decision:=futbeat_private.quota_decision('goal_api',
      case when player.profile_due then 'player-profile' else 'player-stats' end,'user');
    last_decision:=decision;
    if not (decision->>'allowed')::boolean then continue; end if;
    update futbeat_private.player_profile_coverage set lease_until=now()+lease where player_id=player.player_id;
    insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
    values('goal_api',decision->>'kind',left(p_trigger_source,40),now(),
      jsonb_build_object('playerId',player.player_id,'externalPlayerId',player.external_id))
    returning provider_call_ledger.id into id;
    return decision||jsonb_build_object('allowed',true,'reservationId',id,'kind',decision->>'kind',
      'playerId',player.player_id,'externalPlayerId',player.external_id);
  end loop;

  return jsonb_build_object('allowed',false,'reason',
    case when last_decision->>'reason' is not null and not (last_decision->>'allowed')::boolean
      then last_decision->>'reason' else 'no_player_demand' end,
    'providerRemaining',last_decision->'providerRemaining');
end $$;

revoke all on function public.futbeat_request_lineup_hydration(text[],text[])
from public,anon,authenticated;
grant execute on function public.futbeat_request_lineup_hydration(text[],text[]) to service_role;

notify pgrst,'reload schema';
