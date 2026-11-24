-- FutBeat 1.0: declarative reconstruction of the confirmed operational chain.
-- No operational ledger writes, historical data repairs, merges, secrets or push activation.
-- Existing production must ADOPT verified migration history; do not blindly replay this file there.
-- PID indexes use transactional CREATE INDEX for reconstruction, not CONCURRENTLY.

-- Confirmed prerequisite: recovery-03/m2-17/deploy/apply_m2_sql.sql
-- LF SHA-256: 32c595bc7e991322adb0034b67b1287d38dcbda02aefec75391fff873c105fbd
-- Worker lane lease (FREE-PLAN-RECOVERY-16, M2).
--
-- futbeat-goal-live-sync is invoked by pg_net every minute (detail-only),
-- every 5 minutes (full live cycle) and on demand wake-ups (~1.35/min in
-- total). pg_net gives up after 30 s but the Edge invocation keeps running, so
-- a slow invocation overlaps the next one: the same lane runs twice at once
-- and both compete for the same rows and quota locks on a saturated instance.
--
-- A lease per lane: an invocation that cannot take its lane answers "busy" at
-- once and does no work; the lease is released when the invocation ends and
-- expires by itself (p_ttl_seconds) if the invocation dies. One row per lane,
-- no history. Only service_role (the Edge worker) may call the functions.
-- Rollback: rollback_m2.sql (drops the two functions and the table); the Edge
-- worker treats a missing function as "no lease" and keeps working.

create table if not exists futbeat_private.worker_lane_leases (
  lane text primary key check (lane ~ '^[a-z][a-z0-9:_-]{1,63}$'),
  token uuid,
  holder text,
  acquired_at timestamptz,
  leased_until timestamptz not null default '-infinity'
);

alter table futbeat_private.worker_lane_leases enable row level security;

revoke all on futbeat_private.worker_lane_leases from public,anon,authenticated,service_role;

create or replace function public.futbeat_try_worker_lease(
  p_lane text,p_ttl_seconds integer,p_holder text default null
) returns uuid
language plpgsql
volatile security definer
set search_path to ''
as $$
declare v_token uuid:=gen_random_uuid();
begin
  if p_lane is null or p_lane !~ '^[a-z][a-z0-9:_-]{1,63}$'
     or p_ttl_seconds is null or p_ttl_seconds<5 or p_ttl_seconds>900 then
    raise exception 'Invalid worker lease request' using errcode='22023';
  end if;
  insert into futbeat_private.worker_lane_leases as l(lane,token,holder,acquired_at,leased_until)
  values(p_lane,v_token,left(p_holder,120),now(),now()+make_interval(secs=>p_ttl_seconds))
  on conflict(lane) do update set
    token=excluded.token,holder=excluded.holder,
    acquired_at=excluded.acquired_at,leased_until=excluded.leased_until
  where l.leased_until<=now();
  if found then return v_token; end if;
  return null;
end
$$;

create or replace function public.futbeat_release_worker_lease(p_lane text,p_token uuid)
returns boolean
language sql
volatile security definer
set search_path to ''
as $$
  with released as (
    update futbeat_private.worker_lane_leases
    set leased_until=now()
    where lane=p_lane and token=p_token and leased_until>now()
    returning 1
  )
  select exists(select 1 from released)
$$;

revoke all on function public.futbeat_try_worker_lease(text,integer,text) from public,anon,authenticated;

revoke all on function public.futbeat_release_worker_lease(text,uuid) from public,anon,authenticated;

grant execute on function public.futbeat_try_worker_lease(text,integer,text) to service_role;

grant execute on function public.futbeat_release_worker_lease(text,uuid) to service_role;

-- Confirmed prerequisite: 2962db5e:supabase/migrations/20261109080000_prod_function_baseline.sql
-- LF SHA-256: 323e6901838dc7caf6dd01bd887a61f8d36f576400105b4376a5619893d2a5f2
-- PROD FUNCTION BASELINE (BE12 Agent G, 2026-11-09). REPO RECORD ONLY.
-- NEVER APPLY THIS MIGRATION TO PRODUCTION: production already runs every body below
-- (pg_get_functiondef read 2026-11-09 07:5xZ, recovery-03/be12/f/prod_defs_drift.json).
-- It exists so that a fresh local/CI database built from supabase/migrations runs the
-- same function bodies as production. If it is ever pushed to prod it must be a no-op
-- (identical bodies); mark it applied with `supabase migration repair --status applied`
-- instead of executing it.
-- Scope: functions whose prod body is newer than (or absent from) the repo AND whose
-- dependencies exist in the repo schema. Excluded (not here): bodies the repo
-- supersedes with a pending migration, vault/cron functions, functions that reference
-- objects missing in the repo. Attribution: recovery-03/be12/g/attribution.json.
-- New functions (absent from the repo before) get fail-closed ACLs reconstructed from
-- their source commits; production ACLs were not read.
-- Rollback (local only): supabase/manual/20261109080000_prod_function_baseline_rollback.sql

-- futbeat_private.futbeat_identity_key(p_value text)
--   prod source: 1c53872daa supabase/migrations/20260918011500_global_schedule_collector.sql
--   absent from repo: only in the original 20260918011500 of origin/feat/backend-global-collector (1c53872d); main carries a different version of that file; prod still has it
CREATE OR REPLACE FUNCTION futbeat_private.futbeat_identity_key(p_value text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select regexp_replace(
    translate(lower(coalesce(p_value,'')), 'áéíóúüñç', 'aeiouunc'),
    '[^a-z0-9]+', '', 'g'
  )
$function$;

revoke all on function futbeat_private.futbeat_identity_key(text) from public, anon, authenticated;

-- futbeat_private.futbeat_resolve_global_match(p_provider text, p_external text, p_home_team text, p_away_team text, p_start_time timestamp with time zone)
--   prod source: 1c53872daa supabase/migrations/20260918011500_global_schedule_collector.sql
--   absent from repo: only in the original 20260918011500 of origin/feat/backend-global-collector (1c53872d); main carries a different version of that file; prod still has it
CREATE OR REPLACE FUNCTION futbeat_private.futbeat_resolve_global_match(p_provider text, p_external text, p_home_team text, p_away_team text, p_start_time timestamp with time zone)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_result text;
  v_candidates text[];
begin
  if p_provider <> 'sofascore'
     or nullif(btrim(p_external),'') is null
     or nullif(btrim(p_home_team),'') is null
     or nullif(btrim(p_away_team),'') is null
     or p_home_team = p_away_team
     or p_start_time is null
  then
    raise exception 'Invalid global match identity';
  end if;

  select canonical_id into v_result
  from futbeat_private.provider_entities
  where provider = p_provider
    and kind = 'match'
    and external_id = p_external;

  if v_result is not null then
    return v_result;
  end if;

  select array_agg(e.id order by e.id)
    into v_candidates
  from futbeat_private.entities e
  where e.kind = 'match'
    and e.payload->>'homeTeamId' = p_home_team
    and e.payload->>'awayTeamId' = p_away_team
    and nullif(e.payload->>'startTime','') is not null
    and abs(extract(epoch from ((e.payload->>'startTime')::timestamptz - p_start_time))) <= 300;

  if cardinality(v_candidates) = 1 then
    v_result := v_candidates[1];
  else
    v_result := 'fb_match_' || replace(gen_random_uuid()::text,'-','');
    insert into futbeat_private.entities(id,kind,payload)
    values(v_result,'match',jsonb_build_object('id',v_result));
  end if;

  insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
  values(p_provider,'match',p_external,v_result)
  on conflict (provider,kind,external_id)
  do update set canonical_id = excluded.canonical_id;

  return v_result;
end
$function$;

revoke all on function futbeat_private.futbeat_resolve_global_match(text,text,text,text,timestamp with time zone) from public, anon, authenticated;

-- public.futbeat_resolve_global_match(p_provider text, p_external text, p_home_team text, p_away_team text, p_start_time timestamp with time zone)
--   prod source: 1c53872daa supabase/migrations/20260918011500_global_schedule_collector.sql
--   absent from repo: only in the original 20260918011500 of origin/feat/backend-global-collector (1c53872d); main carries a different version of that file; prod still has it
CREATE OR REPLACE FUNCTION public.futbeat_resolve_global_match(p_provider text, p_external text, p_home_team text, p_away_team text, p_start_time timestamp with time zone)
 RETURNS text
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select futbeat_private.futbeat_resolve_global_match(
    p_provider,p_external,p_home_team,p_away_team,p_start_time
  )
$function$;

revoke all on function public.futbeat_resolve_global_match(text,text,text,text,timestamp with time zone) from public, anon, authenticated;

grant execute on function public.futbeat_resolve_global_match(text,text,text,text,timestamp with time zone) to service_role;

-- public.futbeat_resolve_global_entities(p_provider text, p_items jsonb)
--   prod source: 54f04e6fd8 supabase/migrations/20260918052123_batch_global_entity_resolution.sql (body also in HEAD)
--   same body as repo; prod adds SET statement_timeout '30s' (applied out of band)
CREATE OR REPLACE FUNCTION public.futbeat_resolve_global_entities(p_provider text, p_items jsonb)
 RETURNS TABLE(entity_kind text, external_id text, canonical_id text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '30s'
AS $function$
  select *
  from futbeat_private.futbeat_resolve_global_entities(p_provider,p_items)
$function$;

-- futbeat_private.apply_entity_redirects_before_player_scope(p_snapshot jsonb)
--   prod source: 256bd71137 supabase/migrations/20261010020000_snapshot_redirect_map.sql
--   prod = snapshot redirect map (night/snapshot-redirect-map, kit deploy-05); repo has the per-row resolve version
CREATE OR REPLACE FUNCTION futbeat_private.apply_entity_redirects_before_player_scope(p_snapshot jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with
  redirect_json as (
    select coalesce(
      jsonb_object_agg(alias_id,canonical_id order by alias_id),
      '{}'::jsonb
    ) as value
    from futbeat_private.entity_redirects
  ),
  -- Each alias resolved once with the same function (transitive, cycle-safe).
  -- A value that is not an alias of that kind resolves to itself, exactly like
  -- futbeat_resolve_entity_id(kind, value); NULL stays NULL.
  resolved_json as (
    select coalesce(
      jsonb_object_agg(
        r.kind||chr(31)||r.alias_id,
        futbeat_private.futbeat_resolve_entity_id(r.kind,r.alias_id)
      ),
      '{}'::jsonb
    ) as m
    from futbeat_private.entity_redirects r
  ),
  competition_candidates as (
    select
      x.ordinality::integer as ord,
      x.item,
      coalesce(r.canonical_id,x.item->>'id') as resolved_id,
      r.alias_id is null as is_canonical
    from jsonb_array_elements(
      coalesce(p_snapshot->'competitions','[]'::jsonb)
    ) with ordinality x(item,ordinality)
    left join futbeat_private.entity_redirects r
      on r.kind='competition' and r.alias_id=x.item->>'id'
  ),
  competition_ranked as (
    select
      c.resolved_id,
      c.ord,
      case
        when c.is_canonical then c.item
        else coalesce(
          e.payload,
          jsonb_set(c.item,'{id}',to_jsonb(c.resolved_id),true)
        )
      end as payload,
      row_number() over(
        partition by c.resolved_id
        order by case when c.is_canonical then 0 else 1 end,c.ord
      ) as rn
    from competition_candidates c
    left join futbeat_private.entities e
      on e.id=c.resolved_id and e.kind='competition'
  ),
  competitions as (
    select coalesce(
      jsonb_agg(payload order by ord),
      '[]'::jsonb
    ) as value
    from competition_ranked
    where rn=1
  ),
  team_candidates as (
    select
      x.ordinality::integer as ord,
      x.item,
      coalesce(r.canonical_id,x.item->>'id') as resolved_id,
      r.alias_id is null as is_canonical
    from jsonb_array_elements(
      coalesce(p_snapshot->'teams','[]'::jsonb)
    ) with ordinality x(item,ordinality)
    left join futbeat_private.entity_redirects r
      on r.kind='team' and r.alias_id=x.item->>'id'
  ),
  team_ranked as (
    select
      t.resolved_id,
      t.ord,
      case
        when t.is_canonical then t.item
        else coalesce(
          e.payload,
          jsonb_set(t.item,'{id}',to_jsonb(t.resolved_id),true)
        )
      end as payload,
      row_number() over(
        partition by t.resolved_id
        order by case when t.is_canonical then 0 else 1 end,t.ord
      ) as rn
    from team_candidates t
    left join futbeat_private.entities e
      on e.id=t.resolved_id and e.kind='team'
  ),
  teams as (
    select coalesce(
      jsonb_agg(payload order by ord),
      '[]'::jsonb
    ) as value
    from team_ranked
    where rn=1
  ),
  matches as (
    select coalesce(
      jsonb_agg(
        jsonb_set(
          jsonb_set(
            jsonb_set(
              x.item,
              '{competitionId}',
              to_jsonb(
                coalesce(rj.m->>('competition'||chr(31)||(x.item->>'competitionId')),x.item->>'competitionId')
              ),
              true
            ),
            '{homeTeamId}',
            to_jsonb(
              coalesce(rj.m->>('team'||chr(31)||(x.item->>'homeTeamId')),x.item->>'homeTeamId')
            ),
            true
          ),
          '{awayTeamId}',
          to_jsonb(
            coalesce(rj.m->>('team'||chr(31)||(x.item->>'awayTeamId')),x.item->>'awayTeamId')
          ),
          true
        )
        order by x.ordinality
      ),
      '[]'::jsonb
    ) as value
    from jsonb_array_elements(
      coalesce(p_snapshot->'matches','[]'::jsonb)
    ) with ordinality x(item,ordinality)
    cross join resolved_json rj
  ),
  players as (
    select coalesce(
      jsonb_agg(
        case
          when nullif(x.item->>'teamId','') is null then x.item
          else jsonb_set(
            x.item,
            '{teamId}',
            to_jsonb(
              coalesce(rj.m->>('team'||chr(31)||(x.item->>'teamId')),x.item->>'teamId')
            ),
            true
          )
        end
        order by x.ordinality
      ),
      '[]'::jsonb
    ) as value
    from jsonb_array_elements(
      coalesce(p_snapshot->'players','[]'::jsonb)
    ) with ordinality x(item,ordinality)
    cross join resolved_json rj
  ),
  standings_candidates as (
    select
      x.ordinality::integer as ord,
      coalesce(rj.m->>('competition'||chr(31)||(x.item->>'competitionId')),x.item->>'competitionId') as competition_id,
      jsonb_set(
        x.item,
        '{competitionId}',
        to_jsonb(
          coalesce(rj.m->>('competition'||chr(31)||(x.item->>'competitionId')),x.item->>'competitionId')
        ),
        true
      ) as payload
    from jsonb_array_elements(
      coalesce(p_snapshot->'standings','[]'::jsonb)
    ) with ordinality x(item,ordinality)
    cross join resolved_json rj
  ),
  standings_normalized as (
    select
      s.ord,
      s.competition_id,
      jsonb_set(
        s.payload,
        '{rows}',
        coalesce((
          select jsonb_agg(
            case
              when nullif(row.value->>'teamId','') is null then row.value
              else jsonb_set(
                row.value,
                '{teamId}',
                to_jsonb(
                  coalesce(rj.m->>('team'||chr(31)||(row.value->>'teamId')),row.value->>'teamId')
                ),
                true
              )
            end
            order by row.ordinality
          )
          from jsonb_array_elements(
            coalesce(s.payload->'rows','[]'::jsonb)
          ) with ordinality row(value,ordinality)
        ),'[]'::jsonb),
        true
      ) as payload
    from standings_candidates s
    cross join resolved_json rj
  ),
  standings_ranked as (
    select
      ord,
      competition_id,
      payload,
      row_number() over(
        partition by competition_id
        order by jsonb_array_length(
          coalesce(payload->'rows','[]'::jsonb)
        ) desc,ord
      ) as rn
    from standings_normalized
  ),
  standings as (
    select coalesce(
      jsonb_agg(payload order by ord),
      '[]'::jsonb
    ) as value
    from standings_ranked
    where rn=1
  )
  select
    (
      p_snapshot
      -'competitions'
      -'teams'
      -'players'
      -'matches'
      -'standings'
      -'entityRedirects'
    )
    || jsonb_build_object(
      'competitions',competitions.value,
      'teams',teams.value,
      'players',players.value,
      'matches',matches.value,
      'standings',standings.value,
      'entityRedirects',redirect_json.value
    )
  from competitions,teams,players,matches,standings,redirect_json
$function$;

-- futbeat_private.futbeat_store_global_fixture_entities(p_snapshot jsonb)
--   prod source: 42761532c1 supabase/migrations/20261031090000_store_global_fixture_entities.sql
--   absent from repo: PRO152 (20261031090000 on night230/*), applied in prod 2026-10-29
CREATE OR REPLACE FUNCTION futbeat_private.futbeat_store_global_fixture_entities(p_snapshot jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_competitions integer;
  v_teams integer;
  v_matches integer;
begin
  if p_snapshot->>'demo' <> 'false'
     or p_snapshot->>'schemaVersion' <> '1'
     or jsonb_typeof(p_snapshot->'competitions') <> 'array'
     or jsonb_typeof(p_snapshot->'teams') <> 'array'
     or jsonb_typeof(p_snapshot->'matches') <> 'array'
     or jsonb_array_length(p_snapshot->'matches') > 500
  then
    raise exception 'Invalid global fixture entity batch';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_snapshot->'matches') m
    where m->'provenance'->>'source' not in ('SofaScore','ESPN','GOAL API')
  ) then
    raise exception 'Unexpected global fixture source';
  end if;

  update futbeat_private.entities e
  set payload=x.item
  from jsonb_array_elements(p_snapshot->'competitions') x(item)
  where e.id=x.item->>'id'
    and e.kind='competition'
    and (e.payload-'relevanceScore'-'relevanceSource') is distinct from
      (x.item-'relevanceScore'-'relevanceSource');
  get diagnostics v_competitions=row_count;

  update futbeat_private.entities e
  set payload=x.item
  from jsonb_array_elements(p_snapshot->'teams') x(item)
  where e.id=x.item->>'id'
    and e.kind='team'
    and e.payload is distinct from x.item;
  get diagnostics v_teams=row_count;

  update futbeat_private.entities e
  set payload=futbeat_private.merge_calendar_match_payload(e.payload,x.item)
  from jsonb_array_elements(p_snapshot->'matches') x(item)
  where e.id=x.item->>'id'
    and e.kind='match'
    -- An identical payload is a no-op of the merge too: skip the call.
    and e.payload is distinct from x.item
    and e.payload is distinct from
      futbeat_private.merge_calendar_match_payload(e.payload,x.item);
  get diagnostics v_matches=row_count;

  return jsonb_build_object(
    'competitions',v_competitions,
    'teams',v_teams,
    'matches',v_matches
  );
end;
$function$;

revoke all on function futbeat_private.futbeat_store_global_fixture_entities(jsonb) from public, anon, authenticated;

-- public.futbeat_store_global_fixture_entities(p_snapshot jsonb)
--   prod source: 42761532c1 supabase/migrations/20261031090000_store_global_fixture_entities.sql
--   absent from repo: PRO152 wrapper, applied in prod 2026-10-29
CREATE OR REPLACE FUNCTION public.futbeat_store_global_fixture_entities(p_snapshot jsonb)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '30s'
AS $function$
  select futbeat_private.futbeat_store_global_fixture_entities(p_snapshot)
$function$;

revoke all on function public.futbeat_store_global_fixture_entities(jsonb) from public, anon, authenticated;

grant execute on function public.futbeat_store_global_fixture_entities(jsonb) to service_role;

-- futbeat_private.futbeat_store_global_fixture_window(p_job_id uuid, p_received_at timestamp with time zone, p_from_date date, p_to_date date, p_raw jsonb, p_snapshot jsonb)
--   prod source: 2cef261f41 supabase/manual/20261030130000_global_fixture_window_no_spill_rollback.sql
--   prod = PRO152 window (entities split out); repo stops at 20260922233000
CREATE OR REPLACE FUNCTION futbeat_private.futbeat_store_global_fixture_window(p_job_id uuid, p_received_at timestamp with time zone, p_from_date date, p_to_date date, p_raw jsonb, p_snapshot jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  previous jsonb;
  merged jsonb;
  merged_competitions jsonb;
  merged_teams jsonb;
  merged_matches jsonb;
  window_from timestamptz:=p_from_date::timestamp at time zone 'America/Costa_Rica';
  window_to timestamptz:=(p_to_date + 1)::timestamp at time zone 'America/Costa_Rica';
begin
  if p_from_date > p_to_date
     or p_snapshot->>'demo' <> 'false'
     or p_snapshot->>'schemaVersion' <> '1'
     or jsonb_typeof(p_snapshot->'competitions') <> 'array'
     or jsonb_typeof(p_snapshot->'teams') <> 'array'
     or jsonb_typeof(p_snapshot->'matches') <> 'array'
  then
    raise exception 'Invalid global fixture snapshot';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_snapshot->'matches') m
    where m->'provenance'->>'source' not in ('SofaScore','ESPN','GOAL API')
  ) then
    raise exception 'Unexpected global fixture source';
  end if;

  if exists(
    select 1
    from futbeat_private.imports
    where job_id=p_job_id::text
  ) then
    return '{"duplicate":true}'::jsonb;
  end if;

  if exists(
    select 1
    from futbeat_private.imports
    where received_at >= p_received_at
  ) then
    raise exception 'Out-of-order import';
  end if;

  select snapshot
  into previous
  from futbeat_private.imports
  order by received_at desc,job_id desc
  limit 1;

  previous := coalesce(
    previous,
    '{"competitions":[],"teams":[],"players":[],"matches":[],"standings":[],"news":[],"transfers":[]}'::jsonb
  );

  -- relevanceScore/relevanceSource are owned by apply_competition_relevance.
  update futbeat_private.entities e
  set payload=x.item
  from jsonb_array_elements(p_snapshot->'competitions') x(item)
  where e.id=x.item->>'id'
    and e.kind='competition'
    and (e.payload-'relevanceScore'-'relevanceSource') is distinct from
      (x.item-'relevanceScore'-'relevanceSource');

  update futbeat_private.entities e
  set payload=x.item
  from jsonb_array_elements(p_snapshot->'teams') x(item)
  where e.id=x.item->>'id'
    and e.kind='team'
    and e.payload is distinct from x.item;

  -- Never degrade stored terminal evidence of the same fixture.
  update futbeat_private.entities e
  set payload=futbeat_private.merge_calendar_match_payload(e.payload,x.item)
  from jsonb_array_elements(p_snapshot->'matches') x(item)
  where e.id=x.item->>'id'
    and e.kind='match'
    -- An identical payload is a no-op of the merge too: skip the call.
    and e.payload is distinct from x.item
    and e.payload is distinct from
      futbeat_private.merge_calendar_match_payload(e.payload,x.item);

  -- A section none of whose incoming items differs from the previous entry of
  -- the same id is reused as is; otherwise old entries are overlaid by id.
  if exists(
    select 1
    from jsonb_array_elements(p_snapshot->'competitions') n
    left join jsonb_array_elements(coalesce(previous->'competitions','[]'::jsonb)) o
      on o->>'id'=n->>'id'
    where o is distinct from n
  ) then
    with items as (
      select value,ordinality,0 as layer
      from jsonb_array_elements(coalesce(previous->'competitions','[]'::jsonb))
        with ordinality
      union all
      select value,ordinality,1
      from jsonb_array_elements(p_snapshot->'competitions') with ordinality
    ), winners as (
      select distinct on (value->>'id') value
      from items
      order by value->>'id',layer desc,ordinality desc
    )
    select coalesce(
      jsonb_agg(value order by value->>'country',value->>'name'),
      '[]'::jsonb
    )
    into merged_competitions
    from winners;
  else
    merged_competitions := coalesce(previous->'competitions','[]'::jsonb);
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_snapshot->'teams') n
    left join jsonb_array_elements(coalesce(previous->'teams','[]'::jsonb)) o
      on o->>'id'=n->>'id'
    where o is distinct from n
  ) then
    with items as (
      select value,ordinality,0 as layer
      from jsonb_array_elements(coalesce(previous->'teams','[]'::jsonb))
        with ordinality
      union all
      select value,ordinality,1
      from jsonb_array_elements(p_snapshot->'teams') with ordinality
    ), winners as (
      select distinct on (value->>'id') value
      from items
      order by value->>'id',layer desc,ordinality desc
    )
    select coalesce(
      jsonb_agg(value order by value->>'name',value->>'id'),
      '[]'::jsonb
    )
    into merged_teams
    from winners;
  else
    merged_teams := coalesce(previous->'teams','[]'::jsonb);
  end if;

  -- Old global-source rows inside the window are replaced by the batch.
  with items as (
    select value,ordinality,0 as layer
    from jsonb_array_elements(coalesce(previous->'matches','[]'::jsonb))
      with ordinality
    where not (
      value->'provenance'->>'source' in ('SofaScore','ESPN','GOAL API')
      and (value->>'startTime')::timestamptz >= window_from
      and (value->>'startTime')::timestamptz < window_to
    )
    union all
    select value,ordinality,1
    from jsonb_array_elements(p_snapshot->'matches') with ordinality
  ), winners as (
    select distinct on (value->>'id') value
    from items
    order by value->>'id',layer desc,ordinality desc
  )
  select coalesce(
    jsonb_agg(value order by value->>'startTime',value->>'id'),
    '[]'::jsonb
  )
  into merged_matches
  from winners;

  -- The batch's own sections are replaced below; copying them first is wasted work.
  merged := (p_snapshot - array['coverage','competitions','teams','players',
      'matches','standings','news','transfers']) || jsonb_build_object(
    'coverage',
    jsonb_build_object(
      'source','FutBeat Global',
      'partial',true,
      'live',coalesce((previous->'coverage'->>'live')::boolean,false),
      'developmentOnly',true,
      'description','Cobertura global de partidos',
      'sources',jsonb_build_array(
        'TheSportsDB','API-Football','SofaScore','ESPN','GOAL API'
      )
    ),
    'competitions',merged_competitions,
    'teams',merged_teams,
    'players',coalesce(previous->'players','[]'::jsonb),
    'matches',merged_matches,
    'standings',coalesce(previous->'standings','[]'::jsonb),
    'news',coalesce(previous->'news','[]'::jsonb),
    'transfers',coalesce(previous->'transfers','[]'::jsonb)
  );

  insert into futbeat_private.imports(
    job_id,received_at,raw_payload,snapshot
  )
  values(
    p_job_id::text,p_received_at,p_raw,merged
  );

  return jsonb_build_object(
    'duplicate',false,
    'competitions',jsonb_array_length(merged->'competitions'),
    'teams',jsonb_array_length(merged->'teams'),
    'matches',jsonb_array_length(merged->'matches')
  );
end;
$function$;

-- public.futbeat_store_global_fixture_window(p_job_id uuid, p_received_at timestamp with time zone, p_from_date date, p_to_date date, p_raw jsonb, p_snapshot jsonb)
--   prod source: 13de0e3a00 supabase/migrations/20260918023000_global_fixture_collector.sql (body also in HEAD)
--   same body as repo; prod adds SET statement_timeout '30s'
CREATE OR REPLACE FUNCTION public.futbeat_store_global_fixture_window(p_job_id uuid, p_received_at timestamp with time zone, p_from_date date, p_to_date date, p_raw jsonb, p_snapshot jsonb)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '30s'
AS $function$
  select futbeat_private.futbeat_store_global_fixture_window(
    p_job_id,p_received_at,p_from_date,p_to_date,p_raw,p_snapshot
  )
$function$;

-- public.futbeat_store_calendar_entities(p_provider text, p_snapshot jsonb)
--   prod source: d29576b597 supabase/migrations/20261030030000_calendar_store_entities.sql (body also in HEAD)
--   same body as repo; prod adds SET statement_timeout '30s'
CREATE OR REPLACE FUNCTION public.futbeat_store_calendar_entities(p_provider text, p_snapshot jsonb)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '30s'
AS $function$
  select futbeat_private.futbeat_store_calendar_entities(p_provider,p_snapshot)
$function$;

-- public.futbeat_store_calendar_range(p_provider text, p_received_at timestamp with time zone, p_coverage jsonb, p_snapshot jsonb)
--   prod source: 49bb610765 supabase/migrations/20260918113000_calendar_range_catalog.sql (body also in HEAD)
--   same body as repo; prod adds SET statement_timeout '30s'
CREATE OR REPLACE FUNCTION public.futbeat_store_calendar_range(p_provider text, p_received_at timestamp with time zone, p_coverage jsonb, p_snapshot jsonb)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '30s'
AS $function$
  select futbeat_private.futbeat_store_calendar_range(
    p_provider,p_received_at,p_coverage,p_snapshot
  )
$function$;

-- futbeat_private.invalidate_calendar_cache()
--   prod source: 8e76365d1b supabase/migrations/20261030100000_calendar_invalidation_ignore_observation_time.sql
--   prod = BE-181 (ignore provenance.receivedAt / updated_at rewrites), applied 2026-10-30
CREATE OR REPLACE FUNCTION futbeat_private.invalidate_calendar_cache()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o jsonb; n jsonb; d date; v_match_id text;
begin
  if TG_OP<>'INSERT' then o:=to_jsonb(old); end if;
  if TG_OP<>'DELETE' then n:=to_jsonb(new); end if;
  -- BE-181: a re-ingest that only refreshes the observation time is not a
  -- calendar change. Team fixtures re-send known matches with a new
  -- provenance.receivedAt, which also rewrites calendar_matches.updated_at;
  -- bumping every such date queued ~130 dirty rebuilds for two teams. The
  -- rows themselves are still written (provenance stays current).
  if TG_TABLE_NAME='entities' then
    o:=o #- '{payload,provenance,receivedAt}'; n:=n #- '{payload,provenance,receivedAt}';
  elsif TG_TABLE_NAME='calendar_matches' then
    o:=o-'updated_at'; n:=n-'updated_at';
  end if;
  if o is not distinct from n then return null; end if;
  if TG_TABLE_NAME='entities' then
    if coalesce(n->>'kind',o->>'kind')='match' then
      select (start_time at time zone 'UTC')::date into d
        from futbeat_private.calendar_matches where match_id=coalesce(n->>'id',o->>'id');
      if d is not null then perform futbeat_private.bump_calendar_date(d); end if;
      -- Activity changes affect suggestions; score/minute changes do not.
      if ((o->'payload')-array['score','status','minute','events','statistics','provenance'])
        is distinct from ((n->'payload')-array['score','status','minute','events','statistics','provenance']) then
        update futbeat_private.catalog_cache_version set revision=revision+1 where singleton;
      end if;
    elsif coalesce(n->>'kind',o->>'kind') in ('team','competition') then
      update futbeat_private.catalog_cache_version set revision=revision+1 where singleton;
    end if;
  elsif TG_TABLE_NAME='competition_editorial_metadata' then
    -- Ingestion may touch updated_at without changing the editorial contract.
    if (o-'updated_at') is distinct from (n-'updated_at') then
      update futbeat_private.catalog_cache_version set revision=revision+1 where singleton;
    end if;
  elsif TG_TABLE_NAME='entity_redirects' then
    update futbeat_private.catalog_cache_version set revision=revision+1 where singleton;
  elsif TG_TABLE_NAME='calendar_coverage' then
    for d in select distinct v::date from unnest(array[o->>'provider_date',n->>'provider_date']) v
      where v is not null order by 1 loop
      perform futbeat_private.bump_calendar_date(d);
    end loop;
  elsif TG_TABLE_NAME='calendar_matches' then
    for d in select distinct (v::timestamptz at time zone 'UTC')::date
      from unnest(array[o->>'start_time',n->>'start_time']) v
      where v is not null order by 1 loop
      perform futbeat_private.bump_calendar_date(d);
    end loop;
  else
    for v_match_id in select distinct v from unnest(array[
      o->>'canonical_match_id',n->>'canonical_match_id',o->>'match_id',n->>'match_id']) v
      where v is not null order by 1 loop
      select (start_time at time zone 'UTC')::date into d
        from futbeat_private.calendar_matches c where c.match_id=v_match_id;
      if d is not null then perform futbeat_private.bump_calendar_date(d); end if;
    end loop;
  end if;
  return null;
end $function$;

-- futbeat_private.next_goal_results_candidate()
--   prod source: kit recovery-03/b10/rcand/.apply.sql
--   prod = b10-rcand fast candidate (39 s -> 0.37 s), applied 2026-11-07
CREATE OR REPLACE FUNCTION futbeat_private.next_goal_results_candidate()
 RETURNS date
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_today date := (now() at time zone 'UTC')::date;
  v_date date;
begin
  for v_date in
    select d.provider_date
    from (select g::date provider_date
          from generate_series(v_today-14, v_today-1, interval '1 day') g) d
    left join futbeat_private.results_date_attempts a
      on a.provider='goal_api' and a.provider_date=d.provider_date
    where a.next_retry_at is null or a.next_retry_at<=now()
    order by coalesce(a.attempt_count,0), coalesce(a.last_attempt_at,'epoch'::timestamptz),
      d.provider_date desc
  loop
    if exists (
      select 1
      from futbeat_private.calendar_matches cm
      join futbeat_private.entities e on e.id=cm.match_id and e.kind='match'
      left join futbeat_private.match_result_reconciliation mr on mr.match_id=cm.match_id
      where cm.start_time>=v_date::timestamp at time zone 'UTC'
        and cm.start_time<(v_date+1)::timestamp at time zone 'UTC'
        and (mr.match_id is null or mr.state='unresolved'
          or mr.canonical_payload_hash is distinct from md5(e.payload::text)
          or mr.provider_date<>(cm.start_time at time zone 'UTC')::date
          or exists(select 1 from futbeat_private.provider_observations o
            where o.provider='goal_api' and o.canonical_match_id=cm.match_id
              and o.received_at>coalesce(mr.evidence_at,'-infinity'::timestamptz))
          or exists(select 1 from futbeat_private.canonical_events ce
            where ce.match_id=cm.match_id and not coalesce(e.payload->'events','[]'::jsonb)
              @> jsonb_build_array(ce.payload)))) then
      return v_date;
    end if;
  end loop;
  return null;
end
$function$;

-- futbeat_private.complete_results_date_attempt(p_provider_date date, p_outcome text, p_result_count integer, p_unmatched_count integer)
--   prod source: 7ff6f26f80 supabase/migrations/20261031030000_results_retry_after_date_end.sql
--   prod = R226 retry-after-date-end cap, applied 2026-10-31
CREATE OR REPLACE FUNCTION futbeat_private.complete_results_date_attempt(p_provider_date date, p_outcome text, p_result_count integer, p_unmatched_count integer)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if p_outcome not in ('SUCCEEDED','FAILED','PARTIAL') then raise exception 'Invalid outcome'; end if;
  update futbeat_private.results_date_attempts set last_outcome=p_outcome,
    last_result_count=greatest(coalesce(p_result_count,0),0),
    last_unmatched_count=greatest(coalesce(p_unmatched_count,0),0),updated_at=now(),
    next_retry_at=case when p_outcome='SUCCEEDED' then next_retry_at
      when now()<((provider_date+1)::timestamp+interval '1 hour') at time zone 'UTC' then
        least(now()+futbeat_private.results_retry_delay(provider_date,attempt_count+1),
          ((provider_date+1)::timestamp+interval '1 hour') at time zone 'UTC')
      else now()+futbeat_private.results_retry_delay(provider_date,attempt_count+1) end
  where provider='goal_api' and provider_date=p_provider_date;
end $function$;

-- futbeat_private.try_link_api_football_match(obs jsonb)
--   prod source: no source found in git or recovery-03
--   comment-only difference (repo comment edited in place after apply)
CREATE OR REPLACE FUNCTION futbeat_private.try_link_api_football_match(obs jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_fixture text := nullif(obs ->> 'externalMatchId', '');
  v_home_external text := nullif(obs #>> '{homeTeam,externalId}', '');
  v_away_external text := nullif(obs #>> '{awayTeam,externalId}', '');
  v_home_name text := nullif(obs #>> '{homeTeam,name}', '');
  v_away_name text := nullif(obs #>> '{awayTeam,name}', '');
  v_start timestamptz := nullif(obs ->> 'startTime', '')::timestamptz;
  v_competition text := nullif(obs ->> 'competitionId', '');
  v_home_canonical text;
  v_away_canonical text;
  v_match text;
begin
  if v_fixture is null then return null; end if;

  select canonical_id into v_match
  from futbeat_private.provider_entities
  where provider='api_football' and kind='match' and external_id=v_fixture;
  if v_match is not null then return v_match; end if;

  -- For now auto-link only competitions FutBeat explicitly tracks.
  if v_competition is null then return null; end if;

  if v_home_external is not null then
    select canonical_id into v_home_canonical
    from futbeat_private.provider_entities
    where provider='api_football' and kind='team' and external_id=v_home_external;
  end if;
  if v_away_external is not null then
    select canonical_id into v_away_canonical
    from futbeat_private.provider_entities
    where provider='api_football' and kind='team' and external_id=v_away_external;
  end if;

  if v_home_canonical is null and v_home_name is not null then
    select e.id into v_home_canonical
    from futbeat_private.entities e
    where e.kind='team'
      and e.payload ->> 'competitionId' = v_competition
      and futbeat_private.normalize_team_name(e.payload ->> 'name') = futbeat_private.normalize_team_name(v_home_name)
    limit 1;
  end if;
  if v_away_canonical is null and v_away_name is not null then
    select e.id into v_away_canonical
    from futbeat_private.entities e
    where e.kind='team'
      and e.payload ->> 'competitionId' = v_competition
      and futbeat_private.normalize_team_name(e.payload ->> 'name') = futbeat_private.normalize_team_name(v_away_name)
    limit 1;
  end if;

  if v_home_canonical is null or v_away_canonical is null or v_start is null then return null; end if;

  select e.id into v_match
  from futbeat_private.entities e
  where e.kind='match'
    and e.payload ->> 'competitionId' = v_competition
    and e.payload ->> 'homeTeamId' = v_home_canonical
    and e.payload ->> 'awayTeamId' = v_away_canonical
    and abs(extract(epoch from ((e.payload ->> 'startTime')::timestamptz - v_start))) <= 10800
  order by abs(extract(epoch from ((e.payload ->> 'startTime')::timestamptz - v_start)))
  limit 1;

  if v_match is null then return null; end if;

  if v_home_external is not null then
    insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
    values ('api_football','team',v_home_external,v_home_canonical)
    on conflict (provider,kind,external_id) do update set canonical_id=excluded.canonical_id;
  end if;
  if v_away_external is not null then
    insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
    values ('api_football','team',v_away_external,v_away_canonical)
    on conflict (provider,kind,external_id) do update set canonical_id=excluded.canonical_id;
  end if;
  insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
  values ('api_football','match',v_fixture,v_match)
  on conflict (provider,kind,external_id) do update set canonical_id=excluded.canonical_id;
  return v_match;
end;
$function$;

-- futbeat_private.validate_live_observation(obs jsonb)
--   prod source: no source found in git or recovery-03
--   comment-only difference (repo comment added in place after apply)
CREATE OR REPLACE FUNCTION futbeat_private.validate_live_observation(obs jsonb)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare evt jsonb; v_minute integer; v_home integer; v_away integer; v_event_minute integer; v_observed timestamptz;
begin
 if nullif(obs->>'externalMatchId','') is null then raise exception 'externalMatchId is required'; end if;
 if nullif(obs->>'payloadHash','') is null or obs->>'payloadHash' !~ '^[0-9a-f]{64}$' then raise exception 'invalid payloadHash'; end if;
 if nullif(obs->>'status','') is null then raise exception 'status is required'; end if;
 v_minute:=nullif(obs->>'minute','')::integer;
 v_home:=nullif(obs#>>'{score,home}','')::integer;
 v_away:=nullif(obs#>>'{score,away}','')::integer;
 v_observed:=nullif(obs->>'providerObservedAt','')::timestamptz;
 if v_minute<0 or v_home<0 or v_away<0 then
  raise exception 'minute and score must be non-negative' using errcode='23514';
 end if;
 if jsonb_typeof(coalesce(obs->'events','[]'::jsonb))<>'array' then raise exception 'events must be an array'; end if;
 for evt in select value from jsonb_array_elements(coalesce(obs->'events','[]'::jsonb)) loop
  if nullif(evt->>'eventKey','') is null then raise exception 'eventKey is required'; end if;
  v_event_minute:=nullif(evt->>'minute','')::integer;
  if v_event_minute<0 then raise exception 'event minute must be non-negative' using errcode='23514'; end if;
 end loop;
end $function$;

-- public.futbeat_search_catalog_local(p_query text, p_country text, p_limit integer)
--   prod source: 7d8fb0f206 supabase/migrations/20260923010000_player_search_typo_guard.sql (body also in HEAD)
--   absent from repo: only in the overnight/player-data-ui variant of 20260923010000 (7d8fb0f2); prod still has it
CREATE OR REPLACE FUNCTION public.futbeat_search_catalog_local(p_query text DEFAULT ''::text, p_country text DEFAULT NULL::text, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET "pg_trgm.strict_word_similarity_threshold" TO '0.5'
AS $function$
-- qr/pr: previous raw query (teams, competitions). qf/pf: folded (players).
declare qr text:=lower(btrim(coalesce(p_query,''))); pr text; qf text; pf text; v_result jsonb;
begin
 if length(qr)>80 then raise exception 'Invalid search query'; end if;
 if qr='' then return public.futbeat_read_explore(); end if;
 if length(qr)<2 then return futbeat_private.catalog_snapshot('[]','[]'); end if;
 pr:=replace(replace(replace(qr,E'\\',E'\\\\'),'%',E'\\%'),'_',E'\\_');
 qf:=futbeat_private.search_fold(qr);
 if length(qf)<2 then qf:=null; end if;
 pf:=replace(replace(replace(qf,E'\\',E'\\\\'),'%',E'\\%'),'_',E'\\_');
 with hits as materialized (
   select s.kind,s.entity_id,s.term from futbeat_private.entity_search_index s
   where (s.kind<>'player' and ((length(qr)=2 and s.term like pr||'%')
       or (length(qr)>=3 and (s.term like '%'||pr||'%' or s.term operator(extensions.%) qr))))
      or (s.kind='player' and qf is not null and ((length(qf)=2 and s.term like pf||'%')
       or (length(qf)>=3 and (s.term like '%'||pf||'%' or qf operator(extensions.<<%) s.term))))
 ), matches as materialized (
   select h.kind,futbeat_private.futbeat_resolve_entity_id(h.kind,h.entity_id) id,
     max(case when h.kind<>'player' then
       case when h.term=qr then 3 when h.term like pr||'%' then 2
         when h.term like '%'||pr||'%' then 1 else 0 end
     else case
       when h.term=qf and n.is_name then 6
       when n.is_name and h.term like pf||'%' then 5
       when n.is_name and h.term like '% '||pf||'%' then 4
       when h.term=qf then 3
       when h.term like pf||'%' or h.term like '% '||pf||'%' then 2
       when h.term like '%'||pf||'%' then 1 else 0 end end) quality,
     max(case when h.kind<>'player' then extensions.similarity(h.term,qr)
       else extensions.strict_word_similarity(qf,h.term) end) similarity,
     -- Multi-word fuzzy is judged per term, so similarity and the word guard
     -- always come from the same name/alias.
     bool_or(h.kind='player' and position(' ' in qf)>0
       and extensions.strict_word_similarity(qf,h.term)>=0.5
       and futbeat_private.search_word_guard(qf,h.term)>=0.35) multiword_fuzzy
   from hits h join futbeat_private.entities src on src.id=h.entity_id
   cross join lateral (select h.kind='player' and h.term in (lower(btrim(coalesce(src.payload->>'name',''))),
     coalesce(futbeat_private.search_fold(src.payload->>'name'),''),
     coalesce(futbeat_private.search_compact_fold(src.payload->>'name'),'')) is_name) n
   group by h.kind,2
 ), scored as (
   select e.id,e.kind,e.payload,h.quality,h.similarity,coalesce(meta.relevance_score,100) relevance
   from matches h join futbeat_private.entities e on e.id=h.id and e.kind=h.kind
   left join futbeat_private.entities team on e.kind='player' and team.id=e.payload->>'teamId'
   left join futbeat_private.competition_editorial_metadata meta on meta.competition_id=
     case when e.kind='competition' then e.id else futbeat_private.futbeat_resolve_entity_id(
       'competition',coalesce(e.payload->>'competitionId',team.payload->>'competitionId')) end
   -- Players need a reasonable match: exact/prefix/word/alias, an infix of
   -- at least 4 characters, or a whole-word fuzzy match. Otherwise: none.
   -- Multi-word fuzzy also needs every query word to resemble a term word:
   -- one shared word ("lionel messi" vs "lionel scaloni") is not a typo.
   where e.kind<>'player' or h.quality>=2 or (h.quality=1 and length(qf)>=4)
     or (position(' ' in qf)=0 and h.similarity>=0.5)
     or h.multiword_fuzzy
 ), ranked as (
   select *,row_number() over(partition by kind order by quality desc,similarity desc,relevance desc,
     lower(payload->>'name'),id) rn from scored
 ), bounded as (
   select * from ranked where rn<=greatest(1,least(coalesce(p_limit,50),75))
 )
 select futbeat_private.catalog_snapshot(
   coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance) order by rn) filter(where kind='competition'),'[]'),
   coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance) order by rn) filter(where kind='team'),'[]'),
   coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance) order by rn) filter(where kind='player'),'[]')
 ) into v_result from bounded;
 return v_result;
end $function$;

revoke all on function public.futbeat_search_catalog_local(text,text,integer) from public, anon, authenticated;

grant execute on function public.futbeat_search_catalog_local(text,text,integer) to service_role;

-- Preserve the confirmed stored CRLF body using escapes; the Git file remains LF.
-- public.futbeat_read_qa_stored_calendar(p_local_date date, p_timezone text)
--   prod source: 2696527fdd supabase/manual/20261031_qa_stored_reads_candidate.sql
--   absent from repo: manual candidate 20261031_qa_stored_reads_candidate (feat/passive-read-api-244), present in prod
CREATE OR REPLACE FUNCTION public.futbeat_read_qa_stored_calendar(p_local_date date, p_timezone text DEFAULT 'America/Costa_Rica'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS E'\r\ndeclare v_row futbeat_private.compact_calendar_cache;\r\nbegin\r\n -- Exact key lookup: an unknown timezone is a miss, no validation needed.\r\n select * into v_row from futbeat_private.compact_calendar_cache\r\n   where calendar_date=p_local_date and timezone=p_timezone;\r\n if not found then return null; end if;\r\n return v_row.payload||jsonb_build_object(''freshness'',jsonb_build_object(\r\n   ''stale'',v_row.expires_at<=now()\r\n     or v_row.version<>futbeat_private.calendar_cache_version(p_local_date,p_timezone),\r\n   ''revalidating'',false));\r\nend ';

revoke all on function public.futbeat_read_qa_stored_calendar(date,text) from public, anon, authenticated;

grant execute on function public.futbeat_read_qa_stored_calendar(date,text) to service_role;

-- Preserve the confirmed stored CRLF body using escapes; the Git file remains LF.
-- public.futbeat_read_qa_stored_explore(p_country text)
--   prod source: 2696527fdd supabase/manual/20261031_qa_stored_reads_candidate.sql
--   absent from repo: manual candidate 20261031_qa_stored_reads_candidate, present in prod
CREATE OR REPLACE FUNCTION public.futbeat_read_qa_stored_explore(p_country text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS E'\r\ndeclare v_revision bigint; v_payload jsonb; v_version bigint; v_expires timestamptz;\r\nbegin\r\n if length(coalesce(p_country,''''))>8 then raise exception ''Invalid country''; end if;\r\n select c.payload,c.version,c.expires_at into v_payload,v_version,v_expires\r\n   from futbeat_private.explore_country_cache c\r\n   where c.country_code=upper(btrim(coalesce(p_country,'''')));\r\n if not found then\r\n   select c.payload,c.version,c.expires_at into v_payload,v_version,v_expires\r\n     from futbeat_private.explore_cache c where c.singleton;\r\n end if;\r\n if v_payload is null then return futbeat_private.catalog_snapshot(''[]'',''[]''); end if;\r\n select revision into v_revision from futbeat_private.catalog_cache_version;\r\n return v_payload||jsonb_build_object(''freshness'',jsonb_build_object(\r\n   ''stale'',v_expires<=now() or v_version<>v_revision,''revalidating'',false));\r\nend ';

revoke all on function public.futbeat_read_qa_stored_explore(text) from public, anon, authenticated;

grant execute on function public.futbeat_read_qa_stored_explore(text) to service_role;

-- Preserve the confirmed stored CRLF body using escapes; the Git file remains LF.
-- public.futbeat_read_qa_stored_national_teams()
--   prod source: 2696527fdd supabase/manual/20261031_qa_stored_reads_candidate.sql
--   absent from repo: manual candidate 20261031_qa_stored_reads_candidate, present in prod
CREATE OR REPLACE FUNCTION public.futbeat_read_qa_stored_national_teams()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS E'\r\n  select coalesce((select c.payload from futbeat_private.national_team_cache c where c.singleton),\r\n    ''{"schemaVersion":1,"teams":{}}''::jsonb)\r\n';

revoke all on function public.futbeat_read_qa_stored_national_teams() from public, anon, authenticated;

grant execute on function public.futbeat_read_qa_stored_national_teams() to service_role;

-- Preserve the confirmed stored CRLF body using escapes; the Git file remains LF.
-- public.futbeat_read_qa_stored_search(p_query text, p_country text, p_limit integer)
--   prod source: 2696527fdd supabase/manual/20261031_qa_stored_reads_candidate.sql
--   absent from repo: manual candidate 20261031_qa_stored_reads_candidate, present in prod
CREATE OR REPLACE FUNCTION public.futbeat_read_qa_stored_search(p_query text DEFAULT ''::text, p_country text DEFAULT NULL::text, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS E'\r\ndeclare qr text:=lower(btrim(coalesce(p_query,''''))); pr text; qf text; pf text;\r\n vc text:=upper(btrim(coalesce(p_country,''''))); v_result jsonb;\r\nbegin\r\n if length(qr)>80 or length(vc)>8 then raise exception ''Invalid search query''; end if;\r\n if length(qr)<2 then return futbeat_private.catalog_snapshot(''[]'',''[]''); end if;\r\n pr:=replace(replace(replace(qr,E''\\\\'',E''\\\\\\\\''),''%'',E''\\\\%''),''_'',E''\\\\_'');\r\n qf:=futbeat_private.search_fold(qr);\r\n if length(qf)<2 then qf:=null; end if;\r\n pf:=replace(replace(replace(qf,E''\\\\'',E''\\\\\\\\''),''%'',E''\\\\%''),''_'',E''\\\\_'');\r\n with hits as materialized (\r\n   select s.kind,s.entity_id,s.term from futbeat_private.entity_search_index s\r\n   where (s.kind<>''player'' and ((length(qr)=2 and s.term like pr||''%'')\r\n       or (length(qr)>=3 and (s.term like ''%''||pr||''%'' or s.term operator(extensions.%) qr))))\r\n      or (s.kind=''player'' and qf is not null and ((length(qf)=2 and s.term like pf||''%'')\r\n       or (length(qf)>=3 and (s.term like ''%''||pf||''%'' or qf operator(extensions.<<%) s.term))))\r\n ), matches as materialized (\r\n   select h.kind,futbeat_private.futbeat_resolve_entity_id(h.kind,h.entity_id) id,\r\n     max(case when h.kind<>''player'' then\r\n       case when h.term=qr then 3 when h.term like pr||''%'' then 2\r\n         when h.term like ''%''||pr||''%'' then 1 else 0 end\r\n     else case\r\n       when h.term=qf and n.is_name then 6\r\n       when n.is_name and h.term like pf||''%'' then 5\r\n       when n.is_name and h.term like ''% ''||pf||''%'' then 4\r\n       when h.term=qf then 3\r\n       when h.term like pf||''%'' or h.term like ''% ''||pf||''%'' then 2\r\n       when h.term like ''%''||pf||''%'' then 1 else 0 end end) quality,\r\n     max(case when h.kind<>''player'' then extensions.similarity(h.term,qr)\r\n       else extensions.strict_word_similarity(qf,h.term) end) similarity,\r\n     bool_or(h.kind=''player'' and position('' '' in qf)>0\r\n       and extensions.strict_word_similarity(qf,h.term)>=0.5\r\n       and futbeat_private.search_word_guard(qf,h.term)>=0.35) multiword_fuzzy\r\n   from hits h join futbeat_private.entities src on src.id=h.entity_id\r\n   cross join lateral (select h.kind=''player'' and h.term in (lower(btrim(coalesce(src.payload->>''name'',''''))),\r\n     coalesce(futbeat_private.search_fold(src.payload->>''name''),''''),\r\n     coalesce(futbeat_private.search_compact_fold(src.payload->>''name''),'''')) is_name) n\r\n   group by h.kind,2\r\n ), scored as (\r\n   select e.id,e.kind,e.payload,h.quality,h.similarity,h.multiword_fuzzy,\r\n     coalesce(meta.relevance_score,100) relevance,\r\n     case when vc<>'''' and (canonical.country_code=vc\r\n       or canonical.country_code like vc||''-%'') then 1 else 0 end country_priority\r\n   from matches h join futbeat_private.entities e on e.id=h.id and e.kind=h.kind\r\n   left join futbeat_private.entities team on e.kind=''player'' and team.id=\r\n     futbeat_private.futbeat_resolve_entity_id(''team'',e.payload->>''teamId'')\r\n   left join futbeat_private.competition_editorial_metadata meta on meta.competition_id=\r\n     case when e.kind=''competition'' then e.id else futbeat_private.futbeat_resolve_entity_id(\r\n       ''competition'',coalesce(e.payload->>''competitionId'',team.payload->>''competitionId'')) end\r\n   cross join lateral (select case e.kind\r\n     when ''competition'' then coalesce(meta.country_code,\r\n       futbeat_private.resolve_country_code(e.payload->>''countryCode''),\r\n       futbeat_private.resolve_country_code(e.payload->>''country''))\r\n     when ''team'' then coalesce(\r\n       futbeat_private.resolve_country_code(e.payload->>''countryCode''),\r\n       futbeat_private.resolve_country_code(e.payload->>''country''),meta.country_code)\r\n     when ''player'' then coalesce(\r\n       futbeat_private.resolve_country_code(e.payload->>''countryCode''),\r\n       futbeat_private.resolve_country_code(e.payload->>''country''),\r\n       futbeat_private.resolve_country_code(team.payload->>''countryCode''),\r\n       futbeat_private.resolve_country_code(team.payload->>''country''),meta.country_code)\r\n     end country_code) canonical\r\n   where e.kind<>''player'' or h.quality>=2 or (h.quality=1 and length(qf)>=4)\r\n     or (position('' '' in qf)=0 and h.similarity>=0.5)\r\n     or h.multiword_fuzzy\r\n ), ranked as (\r\n   select *,row_number() over(partition by kind order by quality desc,country_priority desc,\r\n     similarity desc,relevance desc,lower(payload->>''name''),id) rn from scored\r\n ), bounded as (\r\n   select * from ranked where rn<=greatest(1,least(coalesce(p_limit,50),75))\r\n )\r\n select futbeat_private.catalog_snapshot(\r\n   coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance) order by rn) filter(where kind=''competition''),''[]''),\r\n   coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance) order by rn) filter(where kind=''team''),''[]''),\r\n   coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance) order by rn) filter(where kind=''player''),''[]'')\r\n ) into v_result from bounded;\r\n return v_result;\r\nend ';

revoke all on function public.futbeat_read_qa_stored_search(text,text,integer) from public, anon, authenticated;

grant execute on function public.futbeat_read_qa_stored_search(text,text,integer) to service_role;

-- Confirmed prerequisite: s275-passive/supabase/manual/20261104_passive_api_policy_candidate.sql
-- LF SHA-256: fcb1ba9dd445416e610ca3e81a9e0f920d614c5591031f724dc4154bbe03b22d
-- CANDIDATE, NOT APPLIED (API275). Manual on purpose: outside supabase/migrations so no
-- build, db push or kit picks it up. Requires owner authorization. Apply AFTER
-- 20261031_qa_stored_reads_candidate.sql. Rollback: 20261104_passive_api_policy_candidate_rollback.sql
--
-- Kill switch and client revocation for futbeat-passive-api. One row; the function reads
-- it at most every 30 s per isolate and fails closed (no row, disabled or unreadable = off).
-- client_keys holds lowercase hex SHA-256 of the X-FutBeat-Client-Key each build sends;
-- it cannot be enabled with no key. Created DISABLED: turning it on is a separate, explicit update.

create table if not exists futbeat_private.passive_api_policy (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  client_keys text[] not null default '{}'
    check (array_position(client_keys, null) is null),
  per_client_per_minute integer not null default 60 check (per_client_per_minute between 1 and 600),
  per_isolate_per_minute integer not null default 600 check (per_isolate_per_minute between 1 and 10000),
  note text,
  updated_at timestamptz not null default now(),
  -- Enabled always means gated: at least one client key, so revoking is always possible.
  constraint passive_api_policy_enabled_needs_key check (not enabled or cardinality(client_keys) > 0)
);

alter table futbeat_private.passive_api_policy enable row level security;

revoke all on table futbeat_private.passive_api_policy from public, anon, authenticated;

insert into futbeat_private.passive_api_policy(singleton, enabled, note)
values (true, false, 'API275 created disabled') on conflict (singleton) do nothing;

create or replace function public.futbeat_read_passive_api_policy()
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce((select jsonb_build_object('enabled', p.enabled, 'clientKeys', to_jsonb(p.client_keys),
      'perClientPerMinute', p.per_client_per_minute, 'perIsolatePerMinute', p.per_isolate_per_minute)
    from futbeat_private.passive_api_policy p where p.singleton), '{"enabled":false}'::jsonb)
$$;

revoke all on function public.futbeat_read_passive_api_policy() from public, anon, authenticated;

grant execute on function public.futbeat_read_passive_api_policy() to service_role;

-- Previously deployed prerequisite: pub1/sql/20261105100000_public_api_access.sql
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
    if to_regprocedure(format('futbeat_private.%I(%s)',f.name||'__ungated',regexp_replace(f.args,'p_[a-z_]+ ','','g'))) is null then
    execute format('alter function public.%I(%s) rename to %I',
      f.name,regexp_replace(f.args,'p_[a-z_]+ ','','g'),f.name||'__ungated');
    execute format('alter function public.%I(%s) set schema futbeat_private',
      f.name||'__ungated',regexp_replace(f.args,'p_[a-z_]+ ','','g'));
    execute format('revoke all on function futbeat_private.%I(%s) from public,anon,authenticated,service_role',
      f.name||'__ungated',regexp_replace(f.args,'p_[a-z_]+ ','','g'));
    end if;
  end loop;
end $$;

create or replace function public.futbeat_request_match_detail(p_match_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_match_detail__ungated(p_match_id);
  end if;
  -- Passive: the stored detail, exactly as the read-only path answers it.
  return public.futbeat_read_match_detail(p_match_id);
end $$;

create or replace function public.futbeat_request_calendar_date(p_local_date date,p_timezone text default 'America/Costa_Rica')
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_calendar_date__ungated(p_local_date,p_timezone);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create or replace function public.futbeat_request_player_profile(p_player_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_player_profile__ungated(p_player_id);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create or replace function public.futbeat_request_terminal_result(p_match_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_terminal_result__ungated(p_match_id);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create or replace function public.futbeat_request_lineup_hydration(p_starter_ids text[] default null,p_bench_ids text[] default null)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_lineup_hydration__ungated(p_starter_ids,p_bench_ids);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create or replace function public.futbeat_request_match_standings(p_match_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_match_standings__ungated(p_match_id);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create or replace function public.futbeat_request_team_squad(p_team_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_team_squad__ungated(p_team_id);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create or replace function public.futbeat_request_team_matches(p_team_id text,p_before date default null)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_team_matches__ungated(p_team_id,p_before);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create or replace function public.futbeat_request_match_h2h(p_match_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_match_h2h__ungated(p_match_id);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

create or replace function public.futbeat_request_match_h2h_history(p_match_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_match_h2h_history__ungated(p_match_id);
  end if;
  return jsonb_build_object('passive',true,'requested',false);
end $$;

do $gate$ begin if to_regprocedure('futbeat_private.note_player_search_demand__ungated(text)') is null then alter function futbeat_private.note_player_search_demand(text)
  rename to note_player_search_demand__ungated; end if; end $gate$;

create or replace function futbeat_private.note_player_search_demand(p_query text)
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

-- Previously deployed prerequisite: pub1/sql/20261105110000_guest_account_merge.sql
-- Guest -> account: favourites and preferences survive signing in.
--
-- Guests are Supabase anonymous users (product decision, 2026-11-05). Two
-- ways out of guest mode:
--   1. The guest CREATES an account (email, Google) by linking it to the
--      anonymous user: Supabase keeps the same user id, so follows,
--      temporary interests and preferences stay where they are. Nothing to do
--      here.
--   2. The guest signs in to an EXISTING account (e.g. created on another
--      phone): the session switches to another user id. Before switching,
--      the guest session asks for a one-time ticket; after signing in, the
--      account session redeems it and the guest's data is merged:
--        * follows: union (the account's rows are kept as they are);
--        * temporary interests: union, the later expiry wins;
--        * preferences: the account's values win; only empty account
--          fields (or a missing row) take the guest's;
--        * the guest's push devices are disabled (the app registers the
--          device again under the account), so nobody is notified twice.
--      The guest's own rows are not deleted (Supabase's anonymous-user
--      cleanup, or account deletion, removes them).
-- A ticket is 256 random bits, stored only as a SHA-256 hash, valid for 10
-- minutes, single use, issued only to an anonymous session and redeemable
-- only by a non-anonymous one, never into the same user.
--
-- No provider call, cron, quota, push dispatch or Preview change.
-- Rollback: supabase/manual/20261105110000_guest_account_merge_rollback.sql

create table if not exists futbeat_private.guest_merge_tickets (
  ticket_hash text primary key check(ticket_hash ~ '^[0-9a-f]{64}$'),
  guest_user_id uuid not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  redeemed_at timestamptz,
  redeemed_by uuid,
  check(expires_at>created_at)
);

create index if not exists guest_merge_tickets_guest_idx
  on futbeat_private.guest_merge_tickets(guest_user_id,created_at desc);

create table if not exists futbeat_private.guest_account_merges (
  id bigint generated always as identity primary key,
  guest_user_id uuid not null,
  account_user_id uuid not null,
  merged_at timestamptz not null default now(),
  follows integer not null,
  interests integer not null,
  preferences text not null check(preferences in ('copied','filled','kept')),
  devices_disabled integer not null,
  check(guest_user_id<>account_user_id)
);

alter table futbeat_private.guest_merge_tickets enable row level security;

alter table futbeat_private.guest_account_merges enable row level security;

revoke all on futbeat_private.guest_merge_tickets,futbeat_private.guest_account_merges
  from public,anon,authenticated;

-- plpgsql: auth.jwt() is resolved at call time (Supabase provides it).
create or replace function futbeat_private.session_is_anonymous()
returns boolean language plpgsql stable set search_path='' as $$
begin
  return coalesce((auth.jwt()->>'is_anonymous')::boolean,false);
end $$;

create or replace function public.futbeat_issue_guest_merge_ticket()
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); v_ticket text; v_expires timestamptz:=now()+interval '10 minutes';
begin
  if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if not futbeat_private.session_is_anonymous() then
    raise exception 'Only a guest session can issue a merge ticket' using errcode='42501';
  end if;
  if (select count(*) from futbeat_private.guest_merge_tickets
      where guest_user_id=uid and redeemed_at is null and expires_at>now())>=3 then
    raise exception 'Too many open merge tickets' using errcode='54000';
  end if;
  v_ticket:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  insert into futbeat_private.guest_merge_tickets(ticket_hash,guest_user_id,expires_at)
  values(encode(sha256(convert_to(v_ticket,'UTF8')),'hex'),uid,v_expires);
  return jsonb_build_object('ticket',v_ticket,'expiresAt',v_expires);
end $$;

create or replace function public.futbeat_redeem_guest_merge_ticket(p_ticket text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  uid uuid:=auth.uid(); t futbeat_private.guest_merge_tickets;
  n_follows integer; n_interests integer; n_devices integer; v_prefs text;
begin
  if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if futbeat_private.session_is_anonymous() then
    raise exception 'Sign in to an account to redeem a merge ticket' using errcode='42501';
  end if;
  if coalesce(p_ticket,'') !~ '^[0-9a-f]{64}$' then raise exception 'Invalid merge ticket'; end if;
  select * into t from futbeat_private.guest_merge_tickets
    where ticket_hash=encode(sha256(convert_to(p_ticket,'UTF8')),'hex') for update;
  if not found or t.redeemed_at is not null or t.expires_at<=now() or t.guest_user_id=uid then
    raise exception 'Invalid merge ticket';
  end if;
  update futbeat_private.guest_merge_tickets set redeemed_at=now(),redeemed_by=uid
    where ticket_hash=t.ticket_hash;

  insert into futbeat_private.push_follows(user_id,entity_type,entity_id,created_at)
  select uid,f.entity_type,f.entity_id,f.created_at from futbeat_private.push_follows f
  where f.user_id=t.guest_user_id
  on conflict do nothing;
  get diagnostics n_follows=row_count;

  insert into futbeat_private.temporary_interests as ti(user_id,entity_type,entity_id,touched_at,expires_at)
  select uid,i.entity_type,i.entity_id,i.touched_at,i.expires_at from futbeat_private.temporary_interests i
  where i.user_id=t.guest_user_id and i.expires_at>now()
  on conflict(user_id,entity_type,entity_id) do update set
    touched_at=greatest(ti.touched_at,excluded.touched_at),
    expires_at=greatest(ti.expires_at,excluded.expires_at);
  get diagnostics n_interests=row_count;

  if not exists(select 1 from futbeat_private.user_preferences where user_id=t.guest_user_id) then
    v_prefs:='kept';
  elsif not exists(select 1 from futbeat_private.user_preferences where user_id=uid) then
    insert into futbeat_private.user_preferences
    select (jsonb_populate_record(null::futbeat_private.user_preferences,
      to_jsonb(g)||jsonb_build_object('user_id',uid,'updated_at',now()))).*
    from futbeat_private.user_preferences g where g.user_id=t.guest_user_id;
    v_prefs:='copied';
  else
    -- The account's choices win; only its empty fields take the guest's.
    update futbeat_private.user_preferences a set
      selected_country=coalesce(a.selected_country,g.selected_country),
      detected_country=coalesce(a.detected_country,g.detected_country),
      updated_at=now()
    from futbeat_private.user_preferences g
    where a.user_id=uid and g.user_id=t.guest_user_id
      and ((a.selected_country is null and g.selected_country is not null)
        or (a.detected_country is null and g.detected_country is not null));
    v_prefs:=case when found then 'filled' else 'kept' end;
  end if;

  update futbeat_private.push_devices set enabled=false,disabled_at=now(),disabled_reason='merged_into_account'
  where user_id=t.guest_user_id and enabled;
  get diagnostics n_devices=row_count;

  insert into futbeat_private.guest_account_merges(guest_user_id,account_user_id,follows,interests,preferences,devices_disabled)
  values(t.guest_user_id,uid,n_follows,n_interests,v_prefs,n_devices);

  return jsonb_build_object('merged',true,'follows',n_follows,'interests',n_interests,
    'preferences',v_prefs,'devicesDisabled',n_devices);
end $$;

revoke all on function futbeat_private.session_is_anonymous() from public,anon,authenticated,service_role;

revoke all on function public.futbeat_issue_guest_merge_ticket(),
  public.futbeat_redeem_guest_merge_ticket(text) from public,anon;

grant execute on function public.futbeat_issue_guest_merge_ticket(),
  public.futbeat_redeem_guest_merge_ticket(text) to authenticated;

-- CAL-IDLE cached timezone lookup: no user or provider data is seeded.
create table if not exists futbeat_private.timezone_names(name text primary key);
alter table futbeat_private.timezone_names enable row level security;
revoke all on futbeat_private.timezone_names from public,anon,authenticated;
insert into futbeat_private.timezone_names(name) select name from pg_catalog.pg_timezone_names on conflict do nothing;


CREATE OR REPLACE FUNCTION futbeat_private.is_timezone_name(p_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin
  if p_name is null or p_name='' then return false; end if;
  if exists(select 1 from futbeat_private.timezone_names where name=p_name) then
    return true;
  end if;
  -- Unknown here (a tz database newer than the copy, or not a zone): the
  -- exact original check decides.
  return exists(select 1 from pg_catalog.pg_timezone_names where name=p_name);
end $function$;

CREATE OR REPLACE FUNCTION futbeat_private.match_detail_bucket_at(p_status text, p_start timestamp with time zone, p_now timestamp with time zone, p_results interval, p_prematch interval, p_upcoming interval, p_recent_hot interval, p_recent interval, p_history interval)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  select case
    when p_start is null or coalesce(p_status,'') in ('CANCELLED','POSTPONED') then 'none'
    when p_status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then 'live'
    when p_status='FINISHED_PENDING_VERIFICATION' and p_start>p_now-p_results then 'results'
    when p_start>p_now+p_prematch then
      case when p_start<=p_now+p_upcoming then 'upcoming' else 'future' end
    when p_start>p_now then 'prematch'
    when p_start>p_now-p_recent_hot then 'recent_hot'
    when p_start>p_now-p_recent then 'recent'
    when p_start>p_now-p_history then 'history'
    else 'old' end
$function$;

-- Source: be11/q1/fix_b11_q1.sql
-- SHA-256: 7b148971ef5de4e0e7be33840823bac53cbb2e26195ce750d60603de8a5cc658
-- B11-Q1: GOAL detail budget protects LIVE, finals and favorites.
-- Replay of the real ledger 11-06..11-08 (be11/q1/simulate.out): -79..-175 detail calls/day
-- (12-26 %), same matches covered per bucket, results detail untouched, favorites unchanged.
-- Function bodies = production definitions 2026-11-08 (md5 plan a7ffe1fa..., due 747e60f7...)
-- except the B11-Q1 lines. Rollback: supabase/manual/20261108120000_b11_q1_detail_budget_rollback.sql.
-- B11-Q1 helper: interest of a match = highest coverage_interests priority among its
-- teams and competition with a real follower or temporary interest (0 = none).
-- Indexed PK lookups on a tiny table; country rows are ignored.
create or replace function futbeat_private.match_interest_score(p_match_id text)
returns integer language sql stable security definer set search_path to '' as $f$
  select coalesce((select max(ci.priority_score)
    from futbeat_private.entities e
    join futbeat_private.coverage_interests ci
      on (ci.subject_type='team' and ci.subject_id in (e.payload->>'homeTeamId',e.payload->>'awayTeamId'))
      or (ci.subject_type='competition' and ci.subject_id=e.payload->>'competitionId')
    where e.id=p_match_id and e.kind='match'
      and (ci.explicit_followers>0 or ci.temporary_users>0)),0)
$f$;

revoke all on function futbeat_private.match_interest_score(text) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION futbeat_private.plan_match_detail_coverage(p_limit integer, p_full boolean)
 RETURNS text[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare band jsonb:=futbeat_private.detail_planner_band();
  high integer:=futbeat_private.quota_setting('goal_api','plannerQueueHighWater',12)::integer;
  low integer:=futbeat_private.quota_setting('goal_api','plannerQueueLowWater',4)::integer;
  urgent_lim integer:=greatest(1,least(coalesce(p_limit,4),20));
  bg_lim integer; depth integer; paused boolean; queued text[]:='{}'; bg_queued integer:=0;
  bg_open boolean:=futbeat_private.detail_share_open('background');
  live_open boolean:=futbeat_private.detail_share_open('live');
  floor_ok boolean:=futbeat_private.detail_planner_floor_ok();
  urgent_queued integer:=0; cand record; extra integer;
  prematch interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','prematchMinutes',90)::integer);
  upcoming interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','upcomingDetailHours',24)::integer);
  history interval:=make_interval(days=>futbeat_private.quota_setting('goal_api','historyCoverageDays',7)::integer);
  -- Bucket windows read once per run (match_detail_bucket read them per row).
  results_win interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','resultsWindowHours',4)::integer);
  recent_hot interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','recentHotHours',6)::integer);
  recent_fin interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','recentFinishedHours',36)::integer);
  live_max interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','liveMaxHours',4)::integer);
  final_after interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','finalFetchAfterMinutes',120)::integer);
  row_ttl interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','plannerRowTtlMinutes',60)::integer);
  -- Hot run (p_full=false): only the buckets that change minute to minute
  -- (live, results, prematch, recent_hot). Every row such a bucket can hold
  -- starts after now-hot_back (live: liveMaxHours; results: resultsWindowHours;
  -- recent_hot: recentHotHours) and, like the full window, before now+upcoming
  -- (a LIVE/results row may carry a later kickoff). Those buckets rank first,
  -- so the hot run plans exactly the hot part of a full run.
  hot_back interval:=greatest(results_win,recent_hot,live_max);
begin
  perform pg_advisory_xact_lock(hashtext('futbeat-match-detail-enqueue'));
  delete from futbeat_private.match_detail_requests where expires_at<=now();
  with dropped as (
    delete from futbeat_private.match_detail_requests r
    where r.source<>'user' and (
      not exists(select 1 from futbeat_private.provider_entities pe
        where pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=r.match_id)
      or futbeat_private.match_detail_planner_due(r.match_id,futbeat_private.match_detail_bucket(
        futbeat_private.match_detail_status(r.match_id),
        (select nullif(e.payload->>'startTime','')::timestamptz from futbeat_private.entities e where e.id=r.match_id)))
        is not true)
    returning r.source
  )
  insert into futbeat_private.match_detail_queue_log(event,source) select 'dropped',source from dropped;
  select count(*) into depth from futbeat_private.match_detail_requests r
  where r.expires_at>now() and r.source<>'user'
    and futbeat_private.match_detail_bucket(futbeat_private.match_detail_status(r.match_id),
      (select nullif(e.payload->>'startTime','')::timestamptz from futbeat_private.entities e where e.id=r.match_id))
      not in ('live','results');
  select background_paused into paused from futbeat_private.detail_planner_state for update;
  if not paused and depth>=high then
    paused:=true;
    update futbeat_private.detail_planner_state set background_paused=true,paused_changed_at=now() where singleton;
  elsif paused and depth<=low then
    paused:=false;
    update futbeat_private.detail_planner_state set background_paused=false,paused_changed_at=now() where singleton;
  end if;
  bg_lim:=case when paused then 0 else greatest(0,least(coalesce(p_limit,(band->>'batch')::integer),high-depth)) end;
  for cand in
    with window_matches as materialized (
      select cm.match_id,nullif(x.payload->>'startTime','')::timestamptz start_time,
        x.payload->>'competitionId' competition_id,
        case
          when coalesce(l.status,x.payload->>'status') in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
            and nullif(x.payload->>'startTime','')::timestamptz<now()-live_max then null
          else coalesce(l.status,x.payload->>'status')
        end status
      from futbeat_private.calendar_matches cm
      join futbeat_private.entities x on x.id=cm.match_id and x.kind='match'
      left join public.live_match_updates l on l.match_id=cm.match_id and l.provider='goal_api'
      where cm.start_time between now()-case when p_full then history else hot_back end
        and now()+upcoming
    ), profiled as materialized (
      select w.match_id,w.start_time,w.competition_id,
        futbeat_private.match_detail_bucket_at(w.status,w.start_time,now(),
          results_win,prematch,upcoming,recent_hot,recent_fin,history) bucket
      from window_matches w
    )
    select p.match_id,p.bucket,p.start_time,coalesce(meta.relevance_score,0) relevance,
      -- B11-Q1: followed/temporary interest (coverage_interests) ranks right after the bucket.
      futbeat_private.match_interest_score(p.match_id) interest
    from profiled p
    join futbeat_private.provider_entities pe on pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=p.match_id
    left join futbeat_private.competition_editorial_metadata meta on meta.competition_id=p.competition_id
    left join futbeat_private.match_detail_coverage c on c.match_id=p.match_id
    left join futbeat_private.match_detail_cache d on d.match_id=p.match_id
    where p.bucket in ('live','results','prematch','upcoming','recent_hot','recent','history')
      and (p_full or p.bucket in ('live','results','prematch','recent_hot'))
      and coalesce(c.next_retry_at,'-infinity')<=now()
      and (p.bucket<>'upcoming' or d.match_id is null)
      and not (p.bucket in ('recent_hot','recent','history')
        and d.fetched_at>=p.start_time+final_after
        and coalesce(c.lineup_state,'UNKNOWN')<>'UNKNOWN' and coalesce(c.statistics_state,'UNKNOWN')<>'UNKNOWN'
        and coalesce(c.lineup_recheck_at,'infinity')>now() and coalesce(c.statistics_recheck_at,'infinity')>now())
      and not exists(select 1 from futbeat_private.match_detail_requests r
        where r.match_id=p.match_id and r.expires_at>now())
    order by futbeat_private.match_detail_bucket_rank(p.bucket),interest desc,coalesce(meta.relevance_score,0) desc,
      abs(extract(epoch from p.start_time-now())),p.match_id
    limit 400
  loop
    exit when urgent_queued>=urgent_lim and bg_queued>=bg_lim;
    if cand.bucket in ('live','results') then
      continue when urgent_queued>=urgent_lim or not live_open;
      continue when cand.bucket='live' and not floor_ok;
    else
      continue when bg_queued>=bg_lim or not bg_open or not floor_ok;
      continue when cand.bucket='history' and not (band->>'history')::boolean;
      continue when cand.bucket in ('recent','upcoming') and not (band->>'recent')::boolean;
    end if;
    continue when futbeat_private.match_detail_planner_due(cand.match_id,cand.bucket) is not true
      or futbeat_private.detail_inflight(cand.match_id);
    extra:=(select count(*) from futbeat_private.match_detail_requests r
        where r.expires_at>now() and r.source<>'user'
          and futbeat_private.match_detail_bucket(futbeat_private.match_detail_status(r.match_id),
            (select nullif(x.payload->>'startTime','')::timestamptz from futbeat_private.entities x where x.id=r.match_id))
            =cand.bucket);
    continue when not futbeat_private.detail_bucket_budget_open(cand.bucket,extra);
    insert into futbeat_private.match_detail_requests(match_id,requested_at,expires_at,request_count,source)
    values(cand.match_id,now(),now()+row_ttl,1,
      case cand.bucket when 'live' then 'prefetch' when 'results' then 'recent' when 'prematch' then 'prematch'
        when 'recent_hot' then 'recent' when 'recent' then 'recent' when 'upcoming' then 'prefetch'
        else 'bootstrap' end)
    on conflict(match_id) do nothing;
    if not found then continue; end if;
    insert into futbeat_private.match_detail_queue_log(event,bucket,source) values('enqueued',cand.bucket,'planner');
    if cand.bucket in ('live','results') then urgent_queued:=urgent_queued+1; else bg_queued:=bg_queued+1; end if;
    queued:=array_append(queued,cand.match_id);
  end loop;
  if cardinality(queued)>0 then perform futbeat_private.bump_metric('detail_planner_queued',cardinality(queued)); end if;
  delete from futbeat_private.match_detail_queue_log where at<now()-interval '2 days';
  return queued;
end $function$;

CREATE OR REPLACE FUNCTION futbeat_private.match_detail_planner_due(p_match_id text, p_bucket text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare cov futbeat_private.match_detail_coverage; fetched timestamptz; kickoff timestamptz;
  sections jsonb; gap interval; final_after interval; phase text; used integer;
begin
  if p_bucket is null or p_bucket not in ('live','results','prematch','upcoming','recent_hot','recent','history') then
    return false;
  end if;
  select * into cov from futbeat_private.match_detail_coverage where match_id=p_match_id;
  if coalesce(cov.next_retry_at>now(),false) then return false; end if;
  select c.fetched_at into fetched from futbeat_private.match_detail_cache c where c.match_id=p_match_id;
  -- Hard bound on background work per match and phase (user opens are not
  -- counted): pre-match, LIVE and results attempts never eat the post-match
  -- fetch, and each phase has its own cap.
  phase:=case p_bucket when 'prematch' then 'prematch' when 'live' then 'live'
    when 'results' then 'results' else 'finished' end;
  select count(*) into used from futbeat_private.provider_call_ledger l
  where l.call_kind='match-detail' and l.metadata->>'matchId'=p_match_id
    and l.reserved_at>now()-interval '1 day' and coalesce(l.metadata->>'source','')<>'user'
    and case coalesce(l.metadata->>'bucket','') when 'prematch' then 'prematch' when 'live' then 'live'
      when 'results' then 'results' when 'recovery' then 'recovery' else 'finished' end=phase;
  -- B11-Q1: followed matches (coverage_interests) keep the deeper per-phase limits.
  if used>=(case phase
      when 'prematch' then case when futbeat_private.match_interest_score(p_match_id)>0
        then futbeat_private.quota_setting('goal_api','plannerMaxPrematchFetchesFollowed',3)
        else futbeat_private.quota_setting('goal_api','plannerMaxPrematchFetches',3) end
      when 'live' then case when futbeat_private.match_interest_score(p_match_id)>0
        then futbeat_private.quota_setting('goal_api','plannerMaxLiveFetchesFollowed',6)
        else futbeat_private.quota_setting('goal_api','plannerMaxLiveFetches',6) end
      when 'results' then futbeat_private.quota_setting('goal_api','plannerMaxResultFetches',2)
      else futbeat_private.quota_setting('goal_api','plannerMaxFetchesPerMatchDay',4) end) then
    return false;
  end if;
  if fetched is null then return true; end if;
  if p_bucket='results' then
    return futbeat_private.match_detail_due('FINISHED_PENDING_VERIFICATION',fetched);
  end if;
  if p_bucket='upcoming' then return false; end if;
  if p_bucket='live' then
    return coalesce((coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN'
        and fetched<now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','liveRetryMinutes',5)::integer))
      -- Periodic refresh only while the provider budget is comfortable.
      or (fetched<now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','plannerLiveRefreshMinutes',30)::integer)
        and futbeat_private.detail_planner_band()->>'band' in ('abundant','normal')),false);
  end if;
  sections:=futbeat_private.match_detail_sections(p_match_id);
  if sections is null then return false; end if;
  gap:=make_interval(secs=>(sections->>'retryGap')::double precision);
  if p_bucket='prematch' then
    return coalesce((sections->>'lineupWanted')::boolean and coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN'
      and fetched<now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','prematchRetryMinutes',20)::integer),false);
  end if;
  -- Finished: one post-match fetch, then only missing sections / due rechecks.
  select nullif(e.payload->>'startTime','')::timestamptz into kickoff
  from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
  final_after:=make_interval(mins=>futbeat_private.quota_setting('goal_api','finalFetchAfterMinutes',120)::integer);
  if kickoff is not null and now()>=kickoff+final_after and fetched<kickoff+final_after then
    return true;
  end if;
  return coalesce(fetched<now()-gap and (
    coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN' or coalesce(cov.statistics_state,'UNKNOWN')='UNKNOWN'
    -- A NO_DATA without a recheck time (older rows) is never rechecked.
    or (cov.lineup_state='NO_DATA' and coalesce(cov.lineup_recheck_at,'infinity')<=now())
    or (cov.statistics_state='NO_DATA' and coalesce(cov.statistics_recheck_at,'infinity')<=now())),false);
end $function$;

-- B11-Q1 limits (data). Followed matches keep 6 LIVE / 3 prematch detail calls.
update futbeat_private.provider_quota_policy
set kind_daily_caps=kind_daily_caps||'{"match-detail":550}'::jsonb,
    freshness=freshness||'{"plannerMaxLiveFetches":3,"plannerMaxPrematchFetches":1,"plannerMaxLiveFetchesFollowed":6,"plannerMaxPrematchFetchesFollowed":3,"terminalRecoveryAbsentDetailAttempts":1}'::jsonb,
    updated_at=now()
where provider='goal_api';

-- Source: be11/q2/fix_b11_q2.sql
-- SHA-256: 616fe237bb1f8e5a28c7e8b0f097f737ef7c66c94369e4f055485d3d26fcbf08
-- B11-Q2: category budget inside the b11-q1 match-detail cap (550): recovery 200 / favourites+LIVE+results 250 /
-- general 100, lending without exceeding the cap, recent recoveries before historical ones, historical paced.
-- Bodies = production 2026-11-09 (planner = b11-q1 d014caf8..., reserve = be11/q2/prod_reserve.sql) + B11-Q2 lines.

-- B11-Q2 helpers. Budget categories inside the daily match-detail cap (kind_daily_caps):
--   R = terminal recovery (sub: recent = detected <= recoveryRecentHours ago, hist = older)
--   F = favourite match (match_interest_score>0), live/results bucket or user open
--   G = everything else (general coverage)
-- A category under its reserve always passes; above it, it may borrow only what the other
-- categories do not hold (F and G hold their unused reserve until detailBudgetReleaseHourUtc;
-- R holds only what due recent recoveries need). Historical recovery never borrows and is paced.
-- Priority (b11-q2 r2): LIVE/results detail and RECENT finals before secondary stats, favourites included:
--   * detailBudgetLiveHold (250) = LIVE/results room not yet used, held until the release hour;
--   * recent recovery above its reserve borrows everything except that hold;
--   * secondary calls (G, or F outside the live/results buckets) leave the hold and every due recent final.
-- detailBudgetEnabled=0 turns everything back into b11-q1 behaviour (kill switch, no DDL).
create or replace function futbeat_private.detail_budget_usage()
returns jsonb language sql stable security definer set search_path to '' as $f$
  with l as (
    select l.metadata m,l.reserved_at t from futbeat_private.provider_call_ledger l
    where l.provider='goal_api' and l.call_kind='match-detail'
      and l.reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'
  ), c as (
    select case when m->>'bucket'='recovery' then 'R'
      when m->>'bucket' in ('live','results') or m->>'source'='user' then 'F'
      when futbeat_private.match_interest_score(m->>'matchId')>0 then 'F' else 'G' end k,
      m->>'bucket'='recovery' and m->>'recoveryAge'='hist' hist,t,
      m->>'bucket' in ('live','results') or m->>'source'='user' lv from l
  )
  select jsonb_build_object('R',count(*) filter (where k='R'),'F',count(*) filter (where k='F'),
    'G',count(*) filter (where k='G'),'hist',count(*) filter (where hist),
    'L',count(*) filter (where lv),
    'hist_hour',count(*) filter (where hist and t>=date_trunc('hour',now())),'total',count(*)) from c
$f$;

revoke all on function futbeat_private.detail_budget_usage() from public,anon,authenticated;

create or replace function futbeat_private.detail_budget_pending_recent()
returns integer language sql stable security definer set search_path to '' as $f$
  select count(*)::integer from (select 1 from futbeat_private.live_terminal_recovery t
    where t.provider='goal_api' and t.state='PENDING'
      and t.detected_at>now()-make_interval(hours=>futbeat_private.quota_setting('goal_api','recoveryRecentHours',12)::integer)
      and not (t.reason='absent_from_live' and t.attempts>=
        futbeat_private.quota_setting('goal_api','terminalRecoveryAbsentDetailAttempts',2)::integer)
    limit 1000) x
$f$;

revoke all on function futbeat_private.detail_budget_pending_recent() from public,anon,authenticated;

create or replace function futbeat_private.detail_category_allowed(p_cat text,p_sub text,p_usage jsonb,p_pending_recent integer)
returns boolean language plpgsql stable security definer set search_path to '' as $f$
declare cap integer; res jsonb; used integer; held integer:=0; k text; lh integer; total integer:=coalesce((p_usage->>'total')::integer,0);
  rel boolean:=extract(hour from now() at time zone 'UTC')>=futbeat_private.quota_setting('goal_api','detailBudgetReleaseHourUtc',21)::integer;
begin
  if futbeat_private.quota_setting('goal_api','detailBudgetEnabled',0)<>1 then return true; end if;
  select (p.kind_daily_caps->>'match-detail')::integer into cap from futbeat_private.provider_quota_policy p where p.provider='goal_api';
  if cap is null then return true; end if;   -- no cap: quota_decision stays the only gate (b11-q1 behaviour)
  if total>=cap then return false; end if;
  res:=jsonb_build_object('R',futbeat_private.quota_setting('goal_api','detailBudgetRecovery',200)::integer,
    'F',futbeat_private.quota_setting('goal_api','detailBudgetFavLive',250)::integer,
    'G',futbeat_private.quota_setting('goal_api','detailBudgetGeneral',100)::integer);
  if p_sub='hist' and (coalesce((p_usage->>'hist_hour')::integer,0)>=futbeat_private.quota_setting('goal_api','recoveryHistPerHour',8)::integer
      or coalesce((p_usage->>'hist')::integer,0)>=futbeat_private.quota_setting('goal_api','recoveryHistDailyMax',100)::integer) then
    return false;
  end if;
  -- LIVE hold: unused LIVE/results room kept until the release hour (nobody else may take it).
  lh:=case when rel then 0 else greatest(0,futbeat_private.quota_setting('goal_api','detailBudgetLiveHold',250)::integer
    -coalesce((p_usage->>'L')::integer,0)) end;
  -- Secondary stats (G, F outside live/results) leave the LIVE hold and every due recent final, even under their reserve.
  if p_cat<>'R' and p_sub<>'live' and total+lh+greatest(0,coalesce(p_pending_recent,0))>=cap then return false; end if;
  used:=coalesce((p_usage->>p_cat)::integer,0);
  if used<(res->>p_cat)::integer then return true; end if;
  if p_sub='hist' then return false; end if;
  -- Recent finals above their reserve: everything except the LIVE hold.
  if p_cat='R' then return total+lh<cap; end if;
  foreach k in array array['R','F','G'] loop
    continue when k=p_cat;
    held:=held+case when k='R' then least(greatest(0,(res->>'R')::integer-coalesce((p_usage->>'R')::integer,0)),greatest(0,coalesce(p_pending_recent,0)))
      when rel then 0 else greatest(0,(res->>k)::integer-coalesce((p_usage->>k)::integer,0)) end;
  end loop;
  return total+held<cap;
end $f$;

revoke all on function futbeat_private.detail_category_allowed(text,text,jsonb,integer) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION futbeat_private.plan_match_detail_coverage(p_limit integer, p_full boolean)
 RETURNS text[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare band jsonb:=futbeat_private.detail_planner_band();
  high integer:=futbeat_private.quota_setting('goal_api','plannerQueueHighWater',12)::integer;
  low integer:=futbeat_private.quota_setting('goal_api','plannerQueueLowWater',4)::integer;
  urgent_lim integer:=greatest(1,least(coalesce(p_limit,4),20));
  bg_lim integer; depth integer; paused boolean; queued text[]:='{}'; bg_queued integer:=0;
  bg_open boolean:=futbeat_private.detail_share_open('background');
  live_open boolean:=futbeat_private.detail_share_open('live');
  floor_ok boolean:=futbeat_private.detail_planner_floor_ok();
  urgent_queued integer:=0; cand record; extra integer;
  -- B11-Q2: category budget (bud read once per run, then counted locally).
  budget_on boolean:=futbeat_private.quota_setting('goal_api','detailBudgetEnabled',0)=1;
  bud jsonb; pend_recent integer; cat text;
  prematch interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','prematchMinutes',90)::integer);
  upcoming interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','upcomingDetailHours',24)::integer);
  history interval:=make_interval(days=>futbeat_private.quota_setting('goal_api','historyCoverageDays',7)::integer);
  -- Bucket windows read once per run (match_detail_bucket read them per row).
  results_win interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','resultsWindowHours',4)::integer);
  recent_hot interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','recentHotHours',6)::integer);
  recent_fin interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','recentFinishedHours',36)::integer);
  live_max interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','liveMaxHours',4)::integer);
  final_after interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','finalFetchAfterMinutes',120)::integer);
  row_ttl interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','plannerRowTtlMinutes',60)::integer);
  -- Hot run (p_full=false): only the buckets that change minute to minute
  -- (live, results, prematch, recent_hot). Every row such a bucket can hold
  -- starts after now-hot_back (live: liveMaxHours; results: resultsWindowHours;
  -- recent_hot: recentHotHours) and, like the full window, before now+upcoming
  -- (a LIVE/results row may carry a later kickoff). Those buckets rank first,
  -- so the hot run plans exactly the hot part of a full run.
  hot_back interval:=greatest(results_win,recent_hot,live_max);
begin
  perform pg_advisory_xact_lock(hashtext('futbeat-match-detail-enqueue'));
  delete from futbeat_private.match_detail_requests where expires_at<=now();
  with dropped as (
    delete from futbeat_private.match_detail_requests r
    where r.source<>'user' and (
      not exists(select 1 from futbeat_private.provider_entities pe
        where pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=r.match_id)
      or futbeat_private.match_detail_planner_due(r.match_id,futbeat_private.match_detail_bucket(
        futbeat_private.match_detail_status(r.match_id),
        (select nullif(e.payload->>'startTime','')::timestamptz from futbeat_private.entities e where e.id=r.match_id)))
        is not true)
    returning r.source
  )
  insert into futbeat_private.match_detail_queue_log(event,source) select 'dropped',source from dropped;
  select count(*) into depth from futbeat_private.match_detail_requests r
  where r.expires_at>now() and r.source<>'user'
    and futbeat_private.match_detail_bucket(futbeat_private.match_detail_status(r.match_id),
      (select nullif(e.payload->>'startTime','')::timestamptz from futbeat_private.entities e where e.id=r.match_id))
      not in ('live','results');
  select background_paused into paused from futbeat_private.detail_planner_state for update;
  if not paused and depth>=high then
    paused:=true;
    update futbeat_private.detail_planner_state set background_paused=true,paused_changed_at=now() where singleton;
  elsif paused and depth<=low then
    paused:=false;
    update futbeat_private.detail_planner_state set background_paused=false,paused_changed_at=now() where singleton;
  end if;
  if budget_on then
    bud:=futbeat_private.detail_budget_usage();
    pend_recent:=futbeat_private.detail_budget_pending_recent();
  end if;
  bg_lim:=case when paused then 0 else greatest(0,least(coalesce(p_limit,(band->>'batch')::integer),high-depth)) end;
  for cand in
    with window_matches as materialized (
      select cm.match_id,nullif(x.payload->>'startTime','')::timestamptz start_time,
        x.payload->>'competitionId' competition_id,
        case
          when coalesce(l.status,x.payload->>'status') in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
            and nullif(x.payload->>'startTime','')::timestamptz<now()-live_max then null
          else coalesce(l.status,x.payload->>'status')
        end status
      from futbeat_private.calendar_matches cm
      join futbeat_private.entities x on x.id=cm.match_id and x.kind='match'
      left join public.live_match_updates l on l.match_id=cm.match_id and l.provider='goal_api'
      where cm.start_time between now()-case when p_full then history else hot_back end
        and now()+upcoming
    ), profiled as materialized (
      select w.match_id,w.start_time,w.competition_id,
        futbeat_private.match_detail_bucket_at(w.status,w.start_time,now(),
          results_win,prematch,upcoming,recent_hot,recent_fin,history) bucket
      from window_matches w
    )
    select p.match_id,p.bucket,p.start_time,coalesce(meta.relevance_score,0) relevance,
      -- B11-Q1: followed/temporary interest (coverage_interests) ranks right after the bucket.
      futbeat_private.match_interest_score(p.match_id) interest
    from profiled p
    join futbeat_private.provider_entities pe on pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=p.match_id
    left join futbeat_private.competition_editorial_metadata meta on meta.competition_id=p.competition_id
    left join futbeat_private.match_detail_coverage c on c.match_id=p.match_id
    left join futbeat_private.match_detail_cache d on d.match_id=p.match_id
    where p.bucket in ('live','results','prematch','upcoming','recent_hot','recent','history')
      and (p_full or p.bucket in ('live','results','prematch','recent_hot'))
      and coalesce(c.next_retry_at,'-infinity')<=now()
      and (p.bucket<>'upcoming' or d.match_id is null)
      and not (p.bucket in ('recent_hot','recent','history')
        and d.fetched_at>=p.start_time+final_after
        and coalesce(c.lineup_state,'UNKNOWN')<>'UNKNOWN' and coalesce(c.statistics_state,'UNKNOWN')<>'UNKNOWN'
        and coalesce(c.lineup_recheck_at,'infinity')>now() and coalesce(c.statistics_recheck_at,'infinity')>now())
      and not exists(select 1 from futbeat_private.match_detail_requests r
        where r.match_id=p.match_id and r.expires_at>now())
    order by futbeat_private.match_detail_bucket_rank(p.bucket),interest desc,coalesce(meta.relevance_score,0) desc,
      abs(extract(epoch from p.start_time-now())),p.match_id
    limit 400
  loop
    exit when urgent_queued>=urgent_lim and bg_queued>=bg_lim;
    if cand.bucket in ('live','results') then
      continue when urgent_queued>=urgent_lim or not live_open;
      continue when cand.bucket='live' and not floor_ok;
    else
      continue when bg_queued>=bg_lim or not bg_open or not floor_ok;
      continue when cand.bucket='history' and not (band->>'history')::boolean;
      continue when cand.bucket in ('recent','upcoming') and not (band->>'recent')::boolean;
    end if;
    continue when futbeat_private.match_detail_planner_due(cand.match_id,cand.bucket) is not true
      or futbeat_private.detail_inflight(cand.match_id);
    extra:=(select count(*) from futbeat_private.match_detail_requests r
        where r.expires_at>now() and r.source<>'user'
          and futbeat_private.match_detail_bucket(futbeat_private.match_detail_status(r.match_id),
            (select nullif(x.payload->>'startTime','')::timestamptz from futbeat_private.entities x where x.id=r.match_id))
            =cand.bucket);
    continue when not futbeat_private.detail_bucket_budget_open(cand.bucket,extra);
    cat:=case when cand.bucket in ('live','results') or cand.interest>0 then 'F' else 'G' end;
    continue when budget_on and not futbeat_private.detail_category_allowed(cat,
      case when cand.bucket in ('live','results') then 'live' else '' end,bud,pend_recent);
    insert into futbeat_private.match_detail_requests(match_id,requested_at,expires_at,request_count,source)
    values(cand.match_id,now(),now()+row_ttl,1,
      case cand.bucket when 'live' then 'prefetch' when 'results' then 'recent' when 'prematch' then 'prematch'
        when 'recent_hot' then 'recent' when 'recent' then 'recent' when 'upcoming' then 'prefetch'
        else 'bootstrap' end)
    on conflict(match_id) do nothing;
    if not found then continue; end if;
    insert into futbeat_private.match_detail_queue_log(event,bucket,source) values('enqueued',cand.bucket,'planner');
    if cand.bucket in ('live','results') then urgent_queued:=urgent_queued+1; else bg_queued:=bg_queued+1; end if;
    queued:=array_append(queued,cand.match_id);
    if budget_on then
      bud:=bud||jsonb_build_object(cat,coalesce((bud->>cat)::integer,0)+1,'total',coalesce((bud->>'total')::integer,0)+1,
        'L',coalesce((bud->>'L')::integer,0)+(cand.bucket in ('live','results'))::integer);
    end if;
  end loop;
  if cardinality(queued)>0 then perform futbeat_private.bump_metric('detail_planner_queued',cardinality(queued)); end if;
  delete from futbeat_private.match_detail_queue_log where at<now()-interval '2 days';
  return queued;
end $function$;

CREATE OR REPLACE FUNCTION futbeat_private.reserve_terminal_recovery_call(p_trigger_source text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r futbeat_private.live_terminal_recovery;
  v_decision jsonb;
  v_reservation bigint;
  v_provider_remaining integer;
  v_effective_remaining integer;
  v_committed_units integer:=0;
  v_protected_floor integer;
  -- B11-Q2
  v_recent_h integer:=futbeat_private.quota_setting('goal_api','recoveryRecentHours',12)::integer;
  v_age text; v_usage jsonb;
begin
  if p_trigger_source is null or btrim(p_trigger_source)='' then
    raise exception 'trigger_source is required';
  end if;

  perform futbeat_private.lock_provider_quota('goal_api');
  perform futbeat_private.settle_terminal_recovery();

  select (p.class_floors->>'user_high')::integer
    into v_protected_floor
  from futbeat_private.provider_quota_policy p
  where p.provider='goal_api';

  if v_protected_floor is null then
    return jsonb_build_object(
      'allowed',false,
      'reason','protected_floor_unknown',
      'quotaClass','recovery'
    );
  end if;

  v_provider_remaining:=futbeat_private.provider_remaining('goal_api');
  if v_provider_remaining is null then
    return jsonb_build_object(
      'allowed',false,
      'reason','provider_remaining_unknown',
      'providerRemaining',null,
      'effectiveProviderRemaining',null,
      'committedUnits',0,
      'floor',v_protected_floor,
      'quotaClass','recovery'
    );
  end if;

  select coalesce(sum(futbeat_private.provider_call_units(l.metadata)),0)::integer
    into v_committed_units
  from futbeat_private.provider_call_ledger l
  where l.provider='goal_api'
    and l.completed_at is null
    and l.reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';

  v_effective_remaining:=greatest(0,v_provider_remaining-v_committed_units);
  if v_effective_remaining<=v_protected_floor then
    return jsonb_build_object(
      'allowed',false,
      'reason','provider_remaining_reserve',
      'providerRemaining',v_provider_remaining,
      'effectiveProviderRemaining',v_effective_remaining,
      'committedUnits',v_committed_units,
      'floor',v_protected_floor,
      'quotaClass','recovery'
    );
  end if;

  select t.* into r
  from futbeat_private.live_terminal_recovery t
  join futbeat_private.provider_entities pe
    on pe.provider='goal_api' and pe.kind='match'
    and pe.external_id=t.external_match_id
    and pe.canonical_id=t.canonical_match_id
  where t.provider='goal_api'
    and t.state='PENDING'
    and t.next_attempt_at<=now()
    and not futbeat_private.detail_inflight(t.canonical_match_id)
    -- GOAL-QUOTA-36: a match that left the live feed gets at most N detail
    -- calls; it stays PENDING so the per-date results call (settle) resolves it.
    and not (t.reason='absent_from_live' and t.attempts>=
      futbeat_private.quota_setting('goal_api','terminalRecoveryAbsentDetailAttempts',2)::integer)
  -- CHANGED: today's games first; old stuck matches use what is left.
  -- B11-Q2: recent recoveries (detected <= recoveryRecentHours ago) before historical ones.
  order by (t.reason='stuck_nonterminal'),(t.detected_at<=now()-make_interval(hours=>v_recent_h)),t.next_attempt_at,t.external_match_id
  limit 1
  for update of t skip locked;

  if not found then
    return jsonb_build_object('allowed',false,'reason','no_recovery_due');
  end if;

  v_age:=case when r.detected_at>now()-make_interval(hours=>v_recent_h) then 'recent' else 'hist' end;
  if futbeat_private.quota_setting('goal_api','detailBudgetEnabled',0)=1 then
    -- Cheap path first: recovery under its reserve and not historical needs no classification.
    select jsonb_build_object('R',count(*) filter (where l.metadata->>'bucket'='recovery'),
        'hist',count(*) filter (where l.metadata->>'recoveryAge'='hist'),
        'hist_hour',count(*) filter (where l.metadata->>'recoveryAge'='hist' and l.reserved_at>=date_trunc('hour',now())),
        'total',count(*))
      into v_usage from futbeat_private.provider_call_ledger l
      where l.provider='goal_api' and l.call_kind='match-detail'
        and l.reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
    if not (v_age='recent' and (v_usage->>'R')::integer<futbeat_private.quota_setting('goal_api','detailBudgetRecovery',200)::integer) then
      if v_age='recent' then v_usage:=futbeat_private.detail_budget_usage(); end if;
      if not futbeat_private.detail_category_allowed('R',v_age,v_usage,futbeat_private.detail_budget_pending_recent()) then
        return jsonb_build_object('allowed',false,'reason','recovery_budget','matchId',r.canonical_match_id,
          'recoveryAge',v_age,'bud',v_usage,'quotaClass','recovery');
      end if;
    end if;
  end if;

  v_decision:=futbeat_private.quota_decision('goal_api','match-detail','results');
  if not (v_decision->>'allowed')::boolean then
    return v_decision||jsonb_build_object(
      'allowed',false,
      'matchId',r.canonical_match_id,
      'quotaClass','recovery'
    );
  end if;

  perform pg_advisory_xact_lock(
    hashtext('futbeat-match-detail-inflight'),
    hashtext(r.canonical_match_id)
  );
  if futbeat_private.detail_inflight(r.canonical_match_id) then
    return jsonb_build_object(
      'allowed',false,
      'reason','detail_inflight',
      'matchId',r.canonical_match_id
    );
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at,metadata
  )
  values(
    'goal_api',
    'match-detail',
    left(p_trigger_source,40),
    now(),
    jsonb_build_object(
      'matchId',r.canonical_match_id,
      'externalMatchId',r.external_match_id,
      'status',r.last_live_status,
      'quotaClass','results',
      'bucket','recovery',
      'source','recovery',
      'recoveryReason',r.reason,
      'recoveryAge',v_age,
      'attempt',r.attempts+1,
      'providerRequests',1
    )
  )
  returning id into v_reservation;

  update futbeat_private.live_terminal_recovery t
  set attempts=t.attempts+1,
      last_attempt_at=now(),
      -- CHANGED: a stuck row's next call is hours, not minutes, away.
      next_attempt_at=now()+case when t.reason='stuck_nonterminal'
        then make_interval(mins=>futbeat_private.quota_setting('goal_api','stuckDetailRetryMinutes',180)::integer)
        else futbeat_private.recovery_backoff(t.attempts+1) end
  where t.provider=r.provider
    and t.external_match_id=r.external_match_id;

  return jsonb_build_object(
    'allowed',true,
    'reservationId',v_reservation,
    'matchId',r.canonical_match_id,
    'externalMatchId',r.external_match_id,
    'reason',r.reason,
    'attempt',r.attempts+1,
    'quotaClass','results',
    'bucket','recovery',
    'recoveryAge',v_age,
    'providerRemaining',v_provider_remaining,
    'effectiveProviderRemaining',v_effective_remaining,
    'committedUnits',v_committed_units,
    'protectedFloor',v_protected_floor
  );
end $function$;

-- B11-Q2 budget (data). Reserves sum to the 550 cap; kill switch detailBudgetEnabled.
update futbeat_private.provider_quota_policy
set freshness=freshness||'{"detailBudgetEnabled":1,"detailBudgetRecovery":200,"detailBudgetFavLive":250,"detailBudgetGeneral":100,"detailBudgetReleaseHourUtc":21,"recoveryRecentHours":12,"recoveryHistPerHour":8,"recoveryHistDailyMax":100,"detailBudgetLiveHold":250}'::jsonb,
    updated_at=now()
where provider='goal_api';

-- Source: be11/a1/settle/fix_settle_terminal_recovery.sql
-- SHA-256: c76831f9c987e9b62bce3251bb43e3958171d8df673d79a778d0dfeed86f37ea
-- BE11-A1: settle_terminal_recovery() must not cost O(PENDING x read model).
--
-- Evidence (production, read-only, 2026-11-07):
--   * live_terminal_recovery held 583 PENDING rows (581 absent_from_live) at
--     18:06Z, all attempts=0: GOAL /fixtures/live answers at most 100 rows
--     (providerTotal=100, reachedEnd=true) while 587-815 matches were active,
--     so every live poll marks dozens of matches "absent"; and no recovery
--     call could be reserved after 12:10Z (quota live reserve, then the
--     user_high floor 150: remaining 101 at 18:06Z).
--   * settle_terminal_recovery() runs first in every
--     reserve_terminal_recovery_call (each detail-lane run, every minute),
--     INSIDE the global provider quota lock, and evaluates
--     match_effectively_terminal() = match_read_model_core() for EVERY
--     pending row. Measured: 20 rows = 1.7 s warm / 3.8 s cold
--     (87-190 ms per row) -> 583 rows = 50-110 s, above the 8 s statement
--     timeout. Since ~17:30Z every reservation failed with 57014: no
--     settlement (86 rows past the 6 h window still PENDING at 18:48Z, last
--     resolved_at 17:30:14Z), no results-date demand refresh, and each
--     failed call held the quota lock ~8 s (reserve_match_detail_call
--     max 7.98 s; 0 successful reserve_goal_results_date since 17:02Z).
--
-- Fix: the read model can only answer a terminal status when the match has
-- terminal evidence somewhere. match_may_be_terminal() checks exactly those
-- sources (the ones match_read_model_core reads) with indexed lookups; the
-- read model runs only for matches that pass. Same result as before
-- (necessary condition, see function comment), no quota/policy change, no
-- GOAL call. Base of settle: production definition 2026-11-07 (=
-- 20261002110000) verbatim except the marked line.

create or replace function futbeat_private.match_may_be_terminal(p_match_id text)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
  -- match_read_model_core returns a terminal status
  -- (is_terminal_match_status: FINISHED_PENDING_VERIFICATION, VERIFIED,
  -- POSTPONED, ABANDONED, CANCELLED) only if (a) the stored payload status is
  -- terminal, or (b) its evidence union yields VERIFIED,
  -- FINISHED_PENDING_VERIFICATION or ABANDONED from provider_observations,
  -- live_match_state, match_detail_cache (mapped matchStatus) or a FULL_TIME
  -- canonical event. Any of them -> true; none -> the read model cannot be
  -- terminal.
  return exists(select 1 from futbeat_private.entities e
      where e.id=p_match_id and e.kind='match'
        and futbeat_private.is_terminal_match_status(e.payload->>'status'))
    or exists(select 1 from futbeat_private.provider_observations o
      where o.canonical_match_id=p_match_id
        and o.status in ('VERIFIED','FINISHED_PENDING_VERIFICATION','ABANDONED'))
    or exists(select 1 from futbeat_private.live_match_state l
      where l.canonical_match_id=p_match_id
        and l.status in ('VERIFIED','FINISHED_PENDING_VERIFICATION','ABANDONED'))
    or exists(select 1 from futbeat_private.match_detail_cache c
      where c.match_id=p_match_id
        and upper(c.payload->>'matchStatus') in ('FINISHED','AFTER_ET','AFTER_PEN','AWARDED',
          'VERIFIED','FINISHED_PENDING_VERIFICATION','ABANDONED'))
    or exists(select 1 from futbeat_private.canonical_events ce
      where ce.match_id=p_match_id and ce.event_type='FULL_TIME');
end $$;

revoke all on function futbeat_private.match_may_be_terminal(text) from public,anon,authenticated;

create or replace function futbeat_private.settle_terminal_recovery()
returns void language plpgsql security definer set search_path='' as $$
declare v_max integer:=futbeat_private.quota_setting('goal_api','terminalRecoveryMaxAttempts',6)::integer;
  -- CHANGED: stuck rows (see header).
  v_stuck_max integer:=futbeat_private.quota_setting('goal_api','stuckDetailMaxAttempts',2)::integer;
  v_stuck_window interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','stuckDetailWindowHours',24)::integer);
  v_demanded integer:=0;
begin
  update futbeat_private.live_terminal_recovery r
  set state='RESOLVED',resolved_at=now(),resolution='terminal_evidence'
  where r.state='PENDING' and r.canonical_match_id is not null
    -- BE11-A1: CASE fixes the evaluation order (the read model only after
    -- the cheap evidence check).
    and case when futbeat_private.match_may_be_terminal(r.canonical_match_id)
      then futbeat_private.match_effectively_terminal(r.canonical_match_id) else false end;
  update futbeat_private.live_terminal_recovery r
  set state='EXHAUSTED',resolved_at=now(),resolution='max_attempts'
  where r.state='PENDING'
    and r.attempts>=case when r.reason='stuck_nonterminal' then v_stuck_max else v_max end;

  -- A recovery still pending after 10 minutes: one results call for its
  -- provider date resolves every final of that date. Same queue, quota
  -- class, caps and per-date backoff as a user opening the match; refreshed
  -- at most hourly per date.
  with dates as (
    select distinct futbeat_private.match_provider_date(r.canonical_match_id) d
    from futbeat_private.live_terminal_recovery r
    where r.provider='goal_api' and r.state='PENDING' and r.canonical_match_id is not null
      and r.detected_at<now()-interval '10 minutes'
      -- CHANGED: a stuck row's date was already answered (or given up).
      and r.reason<>'stuck_nonterminal'
  ), asked as (
    insert into futbeat_private.results_date_user_demand as q(provider,provider_date,requested_at,request_count)
    select 'goal_api',d,now(),1 from dates where d is not null
    on conflict(provider,provider_date) do update
      set requested_at=excluded.requested_at,request_count=q.request_count+1
      where q.requested_at<now()-interval '1 hour'
    returning 1
  )
  select count(*) into v_demanded from asked;
  if v_demanded>0 then
    perform futbeat_private.bump_metric('terminal_recovery_results_demands',v_demanded);
    begin
      perform futbeat_private.wake_provider_worker('results-only');
    exception when others then
      -- The periodic results lane still serves the demand.
      null;
    end;
  end if;

  -- A row that can no longer be served (mapping relinked or removed) expires.
  update futbeat_private.live_terminal_recovery r
  set state='EXHAUSTED',resolved_at=now(),resolution='expired'
  where r.state='PENDING' and r.detected_at<now()-case when r.reason='stuck_nonterminal' then v_stuck_window
    else make_interval(hours=>futbeat_private.quota_setting('goal_api','terminalRecoveryWindowHours',6)::integer) end;
  delete from futbeat_private.live_terminal_recovery
  where state<>'PENDING' and coalesce(resolved_at,detected_at)<now()-interval '3 days';
end $$;

-- Source: be11/cal/fix_cal_idle.sql
-- SHA-256: 6913568ea4da6a402465e10f9a0feea42b3142679383c4b6ec80dd6910e7fa27
-- CAL-IDLE (b11-cal-idle): fewer identical proactive rebuilds of today's calendar snapshot.
-- Bodies = production 2026-11-09 04:2xZ (plan a6347f5f, materialize 647135c3) + CAL-IDLE lines.
-- Readers are untouched (stale-while-revalidate and priority-1 rebuilds on read). LIVE snapshots keep 120 s.
-- Kill switch: calendarWarmMinRebuildTodayIdleSeconds=0 (b11 behaviour, no DDL).
alter table futbeat_private.compact_calendar_cache add column if not exists payload_changed_at timestamptz;

CREATE OR REPLACE FUNCTION futbeat_private.materialize_calendar_day(p_date date, p_timezone text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_version text; v_payload jsonb; v_expiry timestamptz; v_today date;
 v_utc_today date; v_first_utc date; v_last_utc date; v_unversioned boolean; v_live boolean;
 live_ttl interval:=make_interval(secs=>futbeat_private.quota_setting('goal_api','calendarLiveSeconds',15));
begin
 v_today:=(now() at time zone p_timezone)::date;
 v_utc_today:=(now() at time zone 'UTC')::date;
 v_first_utc:=(p_date::timestamp at time zone p_timezone at time zone 'UTC')::date;
 v_last_utc:=(((p_date+1)::timestamp at time zone p_timezone-interval '1 microsecond') at time zone 'UTC')::date;
 v_unversioned:=v_utc_today between v_first_utc and v_last_utc;
 -- One build per date/timezone; version is read AFTER the lock.
 perform pg_catalog.pg_advisory_xact_lock(hashtextextended('calendar:'||p_date||':'||p_timezone,0));
 v_version:=futbeat_private.calendar_cache_version(p_date,p_timezone);
 select payload into v_payload from futbeat_private.compact_calendar_cache
   where calendar_date=p_date and timezone=p_timezone and version=v_version and expires_at>now();
 if found then return v_payload; end if;
 v_payload:=futbeat_private.build_compact_calendar(p_date,p_date,p_timezone);
 v_live:=exists(select 1 from jsonb_array_elements(v_payload->'matches') m
   where m->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
     or (m->>'startTime')::timestamptz between now()-interval '3 hours' and now()+interval '30 minutes');
 if v_unversioned then
   v_expiry:=now()+case when v_live then live_ttl
     else make_interval(secs=>futbeat_private.quota_setting('goal_api','calendarTodaySeconds',60)) end;
 elsif p_date<v_today then
   -- Complete history is effectively frozen; new evidence bumps its version.
   v_expiry:=now()+case when not (v_payload#>>'{coverage,partial}')::boolean
     and not exists(select 1 from futbeat_private.calendar_coverage c where c.provider='goal_api'
       and c.provider_date between v_first_utc and v_last_utc and not c.results_complete)
     then make_interval(days=>futbeat_private.quota_setting('goal_api','calendarHistoryCompleteDays',30)::integer)
     else make_interval(mins=>futbeat_private.quota_setting('goal_api','calendarHistoryIncompleteMinutes',10)::integer) end;
 else
   v_expiry:=now()+make_interval(hours=>futbeat_private.quota_setting('goal_api','calendarFutureHours',24)::integer);
   -- Re-evaluated when the day enters the UTC-today (short TTL) window.
   v_expiry:=least(v_expiry,v_first_utc::timestamp at time zone 'UTC');
 end if;
 if v_live then v_expiry:=least(v_expiry,now()+live_ttl); end if;
 -- CAP65-C1: an identical rebuild only renews version/built_at/expires_at. The
 -- payload column is not assigned, so its TOAST chunks are kept (no rewrite of
 -- 280-640 KB and its WAL). jsonb equality is exact; any material change goes on
 -- to the full upsert below.
 update futbeat_private.compact_calendar_cache
   set version=v_version,built_at=now(),expires_at=v_expiry,
     -- CAL-IDLE: first identical rebuild stamps when the payload last changed (old built_at).
     payload_changed_at=coalesce(payload_changed_at,built_at)
   where calendar_date=p_date and timezone=p_timezone and payload=v_payload;
 if found then
   perform futbeat_private.bump_metric('calendar_snapshot_unchanged',1);
   return v_payload;
 end if;
 insert into futbeat_private.compact_calendar_cache(calendar_date,timezone,version,payload,built_at,expires_at,payload_changed_at)
 values(p_date,p_timezone,v_version,v_payload,now(),v_expiry,now())
 on conflict(calendar_date,timezone) do update set version=excluded.version,payload=excluded.payload,
   built_at=excluded.built_at,expires_at=excluded.expires_at,payload_changed_at=excluded.payload_changed_at;
 return v_payload;
end $function$;

CREATE OR REPLACE FUNCTION public.futbeat_plan_calendar_snapshots()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare back integer:=futbeat_private.quota_setting('goal_api','calendarWarmBackDays',2)::integer;
  forward integer:=futbeat_private.quota_setting('goal_api','calendarWarmForwardDays',7)::integer;
  seed_back integer:=futbeat_private.quota_setting('goal_api','calendarSeedBackDays',90)::integer;
  seed_forward integer:=futbeat_private.quota_setting('goal_api','calendarSeedForwardDays',120)::integer;
  tz text; offs integer; rank integer; d date; checked integer:=0; dirty integer:=0; seeded integer;
  c record;
  -- Minimum interval between PROACTIVE rebuilds of one date (seconds, 0..3600;
  -- 0 = previous behaviour). Readers are unaffected: an expired/changed day is
  -- still served stale-while-revalidate (or built inline when small) and its
  -- rebuild queued at priority 1 by the read path.
  min_today integer:=least(greatest(coalesce(futbeat_private.quota_setting('goal_api','calendarWarmMinRebuildTodaySeconds',0),0),0),3600)::integer;
  min_window integer:=least(greatest(coalesce(futbeat_private.quota_setting('goal_api','calendarWarmMinRebuildWindowSeconds',0),0),0),3600)::integer;
  min_dirty integer:=least(greatest(coalesce(futbeat_private.quota_setting('goal_api','calendarWarmMinRebuildDirtySeconds',0),0),0),3600)::integer;
  live_ttl interval:=make_interval(secs=>futbeat_private.quota_setting('goal_api','calendarLiveSeconds',15))+interval '1 second';
  built timestamptz; was_live boolean;
  -- CAL-IDLE: today's proactive rebuild waits calendarWarmMinRebuildTodayIdleSeconds (0 = off) when its last
  -- rebuild was identical (payload_changed_at < built_at), it is not a LIVE snapshot and its version is current.
  min_idle integer:=least(greatest(coalesce(futbeat_private.quota_setting('goal_api','calendarWarmMinRebuildTodayIdleSeconds',0),0),0),3600)::integer;
  was_idle boolean;
begin
  foreach tz in array futbeat_private.calendar_reader_zones() loop
    if not futbeat_private.is_timezone_name(tz) then continue; end if;
    -- Hot window: today, +1, -1, +2, -2, ...
    for offs,rank in select g,abs(g)*2-case when g>0 then 1 else 0 end from generate_series(-back,forward) g loop
      d:=(now() at time zone tz)::date+offs;
      checked:=checked+1;
      if exists(select 1 from futbeat_private.compact_calendar_cache s where s.calendar_date=d and s.timezone=tz
          and s.version=futbeat_private.calendar_cache_version(d,tz) and s.expires_at>now()+interval '5 seconds') then
        continue;
      end if;
      -- Expired or changed, but rebuilt recently: wait (readers still
      -- revalidate). A day whose snapshot is a LIVE one keeps the short
      -- interval wherever it sits in the window.
      if min_today>0 or min_window>0 then
        built:=null;
        select s.built_at,s.expires_at<=s.built_at+live_ttl,
            s.payload_changed_at<s.built_at and s.version=futbeat_private.calendar_cache_version(d,tz)
          into built,was_live,was_idle
          from futbeat_private.compact_calendar_cache s where s.calendar_date=d and s.timezone=tz;
        if built is not null and built>now()-make_interval(secs=>
            case when was_live then min_today
              when offs=0 then case when coalesce(was_idle,false) then greatest(min_today,min_idle) else min_today end
              else min_window end) then
          continue;
        end if;
      end if;
      perform futbeat_private.enqueue_calendar_snapshot(d,tz,
        case when offs=0 then 2 when abs(offs)=1 then 3 else 4 end,rank);
    end loop;
    -- Dirty: the day's own data changed (per-date part of the version). A
    -- catalog-only change is rebuilt lazily by the next read.
    for c in select s.calendar_date,s.built_at,
        split_part(s.version,':',2) is distinct from
          split_part(futbeat_private.calendar_cache_version(s.calendar_date,tz),':',2) changed
      from futbeat_private.compact_calendar_cache s
      where s.timezone=tz and s.calendar_date between (now() at time zone tz)::date-seed_back
        and (now() at time zone tz)::date+seed_forward loop
      continue when not c.changed;
      continue when min_dirty>0 and c.built_at>now()-make_interval(secs=>min_dirty);
      perform futbeat_private.enqueue_calendar_snapshot(c.calendar_date,tz,5,
        abs(c.calendar_date-(now() at time zone tz)::date));
      dirty:=dirty+1;
    end loop;
  end loop;
  seeded:=futbeat_private.seed_calendar_snapshot_queue(null);
  -- Bounded retention.
  delete from futbeat_private.compact_calendar_cache where built_at<now()-make_interval(
    days=>futbeat_private.quota_setting('goal_api','calendarRetentionDays',120)::integer);
  delete from futbeat_private.calendar_snapshot_queue
  where (status='done' and built_at<now()-interval '1 day')
     or (status='failed' and requested_at<now()-interval '1 day');
  return jsonb_build_object('checked',checked,'dirty',dirty,'seeded',seeded,
    'batch',futbeat_private.quota_setting('goal_api','calendarBuildBatch',4)::integer,
    'budgetMs',futbeat_private.quota_setting('goal_api','calendarBuildBudgetMs',20000)::integer);
end $function$;

update futbeat_private.provider_quota_policy
set freshness=freshness||'{"calendarWarmMinRebuildTodayIdleSeconds":360}'::jsonb,updated_at=now()
where provider='goal_api';

-- Source: be12/r05/.apply.sql
-- SHA-256: f02d5e37beabde984593d0616d2c3fe2e0b41c1f8899d7e376905cb5132a4e7f
-- R05: durable, queryable account-deletion receipts (FutBeat 1.0).
--
-- Problem: the app deletes the account with futbeat-delete-account and only
-- then writes its local confirmation. If the ACK is lost (network, process
-- killed) and the access token expires, a reopened app only sees 401s, which
-- never prove a deletion. The server now keeps a receipt the app can query
-- WITHOUT a session.
--
-- Contract (packages/contracts/account-deletion-v1.md):
--   * the app generates a random deletion id (UUID v4), stores it durably
--     with the uid BEFORE calling the function, and sends it as
--     X-FutBeat-Deletion-Id;
--   * the function records the receipt (pending) before deleting anything,
--     and marks it deleted once the Auth record is gone;
--   * futbeat_account_deletion_status(id) answers deleted | pending | unknown
--     to anyone holding the id (a 122-bit random capability; it reveals no
--     user data).
--
-- Privacy: only the SHA-256 of the deletion id is stored. The account uid is
-- kept while the receipt is pending (the account still exists then) and is
-- erased when the deletion completes; afterwards only SHA-256(uid) remains,
-- to bind retries to the same subject. No email, IP or device data.
-- Receipts older than 30 days are purged. Idempotent: replaying an id for the
-- same subject returns its state; for another subject it is a conflict.

create table if not exists futbeat_private.account_deletion_receipts (
  deletion_hash bytea primary key,
  subject uuid,
  subject_hash bytea not null,
  status text not null check (status in ('pending', 'deleted')),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  check ((status = 'pending') = (subject is not null))
);

create index if not exists account_deletion_receipts_created
  on futbeat_private.account_deletion_receipts (created_at);

alter table futbeat_private.account_deletion_receipts enable row level security;

revoke all on futbeat_private.account_deletion_receipts from public, anon, authenticated;

create or replace function futbeat_private.deletion_digest(p_value text)
returns bytea language sql immutable strict set search_path = '' as $$
  select pg_catalog.sha256(pg_catalog.convert_to(p_value, 'UTF8'))
$$;

-- Edge function only (service_role): record the receipt before deleting.
create or replace function public.futbeat_account_deletion_begin(p_deletion_id uuid, p_subject uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_hash bytea := futbeat_private.deletion_digest(lower(p_deletion_id::text));
  v_subject_hash bytea := futbeat_private.deletion_digest(lower(p_subject::text));
  v_row futbeat_private.account_deletion_receipts;
begin
  delete from futbeat_private.account_deletion_receipts where created_at < now() - interval '30 days';
  insert into futbeat_private.account_deletion_receipts (deletion_hash, subject, subject_hash, status)
  values (v_hash, p_subject, v_subject_hash, 'pending')
  on conflict (deletion_hash) do nothing;
  select * into v_row from futbeat_private.account_deletion_receipts where deletion_hash = v_hash;
  if v_row.subject_hash <> v_subject_hash then
    return jsonb_build_object('status', 'conflict');
  end if;
  return jsonb_build_object('status', v_row.status);
end;
$$;

-- Edge function only (service_role): the Auth record is gone.
create or replace function public.futbeat_account_deletion_finish(p_deletion_id uuid, p_subject uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_count int;
begin
  update futbeat_private.account_deletion_receipts
     set status = 'deleted', subject = null, completed_at = coalesce(completed_at, now())
   where deletion_hash = futbeat_private.deletion_digest(lower(p_deletion_id::text))
     and subject_hash = futbeat_private.deletion_digest(lower(p_subject::text));
  get diagnostics v_count = row_count;
  return jsonb_build_object('status', case when v_count = 1 then 'deleted' else 'unknown' end);
end;
$$;

-- Anyone holding the id (the app, with only the publishable key): the state.
-- A pending receipt whose account no longer exists is completed here, so a
-- lost ACK after a successful delete still reads as deleted.
create or replace function public.futbeat_account_deletion_status(p_deletion_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_hash bytea := futbeat_private.deletion_digest(lower(p_deletion_id::text));
  v_row futbeat_private.account_deletion_receipts;
begin
  select * into v_row from futbeat_private.account_deletion_receipts where deletion_hash = v_hash;
  if not found then
    return jsonb_build_object('status', 'unknown');
  end if;
  if v_row.status = 'pending' and not exists (select 1 from auth.users u where u.id = v_row.subject) then
    update futbeat_private.account_deletion_receipts
       set status = 'deleted', subject = null, completed_at = now()
     where deletion_hash = v_hash and status = 'pending';
    v_row.status := 'deleted';
    v_row.completed_at := now();
  end if;
  return jsonb_build_object('status', v_row.status,
    'completedAt', case when v_row.status = 'deleted' then v_row.completed_at end);
end;
$$;

revoke all on function futbeat_private.deletion_digest(text) from public;

revoke all on function public.futbeat_account_deletion_begin(uuid, uuid) from public, anon, authenticated;

revoke all on function public.futbeat_account_deletion_finish(uuid, uuid) from public, anon, authenticated;

revoke all on function public.futbeat_account_deletion_status(uuid) from public;

grant execute on function public.futbeat_account_deletion_begin(uuid, uuid) to service_role;

grant execute on function public.futbeat_account_deletion_finish(uuid, uuid) to service_role;

grant execute on function public.futbeat_account_deletion_status(uuid) to anon, authenticated, service_role;

-- BE11-A5: account deletion leaves no uid behind in the guest-merge tables.
--
-- Deleting the Auth record cascades to every per-user table except the two
-- guest-merge tables of 20261105110000_guest_account_merge (applied in
-- production 2026-11-05; its source is on claude/futbeat-backend-local-d2nnav):
--   guest_merge_tickets.guest_user_id / redeemed_by and
--   guest_account_merges.guest_user_id / account_user_id
-- have no foreign key, so a deleted account's uid stayed there forever.
-- Now:
--   * tickets: removed with the guest; redeemed_by is cleared with the account;
--   * merge audit rows: removed when either side is deleted.
-- Production check 2026-11-07 (read-only): 1 ticket, 1 merge, 0 orphans, so
-- validation cannot fail today. NOT VALID + VALIDATE keeps the lock on
-- auth.users to the brief ADD (lock_timeout bounded by the launcher).
-- Guarded: a database without the guest-merge tables is left unchanged.
-- Rollback: supabase/manual/20261107120000_account_deletion_residue_rollback.sql

do $$
begin
  if to_regclass('auth.users') is not null and to_regclass('futbeat_private.guest_merge_tickets') is not null then
    if not exists (select 1 from pg_constraint where conname = 'guest_merge_tickets_guest_user_fk') then
      alter table futbeat_private.guest_merge_tickets
        add constraint guest_merge_tickets_guest_user_fk foreign key (guest_user_id)
        references auth.users(id) on delete cascade not valid;
    end if;
    if not exists (select 1 from pg_constraint where conname = 'guest_merge_tickets_redeemed_by_fk') then
      alter table futbeat_private.guest_merge_tickets
        add constraint guest_merge_tickets_redeemed_by_fk foreign key (redeemed_by)
        references auth.users(id) on delete set null not valid;
    end if;
    alter table futbeat_private.guest_merge_tickets validate constraint guest_merge_tickets_guest_user_fk;
    alter table futbeat_private.guest_merge_tickets validate constraint guest_merge_tickets_redeemed_by_fk;
  end if;

  if to_regclass('auth.users') is not null and to_regclass('futbeat_private.guest_account_merges') is not null then
    if not exists (select 1 from pg_constraint where conname = 'guest_account_merges_guest_user_fk') then
      alter table futbeat_private.guest_account_merges
        add constraint guest_account_merges_guest_user_fk foreign key (guest_user_id)
        references auth.users(id) on delete cascade not valid;
    end if;
    if not exists (select 1 from pg_constraint where conname = 'guest_account_merges_account_user_fk') then
      alter table futbeat_private.guest_account_merges
        add constraint guest_account_merges_account_user_fk foreign key (account_user_id)
        references auth.users(id) on delete cascade not valid;
    end if;
    alter table futbeat_private.guest_account_merges validate constraint guest_account_merges_guest_user_fk;
    alter table futbeat_private.guest_account_merges validate constraint guest_account_merges_account_user_fk;
  end if;
end;
$$;

-- BE12-D (R05): receipts are purged without waiting for the next deletion,
-- and a purge never turns a completed deletion into "unknown".
--
-- Requires 20261106120000_account_deletion_receipts. Contract unchanged
-- (packages/contracts/account-deletion-v1.md): same functions, arguments,
-- grants and answers.
--
-- Fixes (BE11-A5 D5 and one defect found reviewing it):
--   * the 30-day purge only ran inside begin(), so receipts (and the live uid
--     of a pending one) outlived 30 days whenever no new deletion followed;
--   * that purge removed a PENDING receipt whose account was already gone
--     (delete done, finish lost, status never asked): the app then read
--     "unknown", which the contract defines as "nothing was deleted".
-- Now futbeat_private.account_deletion_receipts_purge():
--   1. completes old pending receipts whose account no longer exists
--      (status deleted, uid erased, kept 30 more days from completion);
--   2. removes receipts created more than 30 days ago that are either pending
--      with a live account (nothing was deleted: "unknown" is true) or
--      completed more than 30 days ago.
-- Both statements are bounded by the created_at index. It runs from begin,
-- finish and status, and daily from pg_cron when the extension exists.
-- Idempotent. Rollback: supabase/manual/20261109070000_account_deletion_receipts_purge_rollback.sql
-- (run inside one transaction).

create or replace function futbeat_private.account_deletion_receipts_purge()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_cutoff timestamptz := now() - interval '30 days';
  v_count integer;
begin
  update futbeat_private.account_deletion_receipts r
     set status = 'deleted', subject = null, completed_at = now()
   where r.created_at < v_cutoff and r.status = 'pending'
     and not exists (select 1 from auth.users u where u.id = r.subject);
  delete from futbeat_private.account_deletion_receipts r
   where r.created_at < v_cutoff
     and (r.status = 'pending' or r.completed_at < v_cutoff);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Edge function only (service_role): record the receipt before deleting.
create or replace function public.futbeat_account_deletion_begin(p_deletion_id uuid, p_subject uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_hash bytea := futbeat_private.deletion_digest(lower(p_deletion_id::text));
  v_subject_hash bytea := futbeat_private.deletion_digest(lower(p_subject::text));
  v_row futbeat_private.account_deletion_receipts;
begin
  perform futbeat_private.account_deletion_receipts_purge();
  insert into futbeat_private.account_deletion_receipts (deletion_hash, subject, subject_hash, status)
  values (v_hash, p_subject, v_subject_hash, 'pending')
  on conflict (deletion_hash) do nothing;
  select * into v_row from futbeat_private.account_deletion_receipts where deletion_hash = v_hash;
  if v_row.subject_hash <> v_subject_hash then
    return jsonb_build_object('status', 'conflict');
  end if;
  return jsonb_build_object('status', v_row.status);
end;
$$;

-- Edge function only (service_role): the Auth record is gone.
create or replace function public.futbeat_account_deletion_finish(p_deletion_id uuid, p_subject uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_count int;
begin
  perform futbeat_private.account_deletion_receipts_purge();
  update futbeat_private.account_deletion_receipts
     set status = 'deleted', subject = null, completed_at = coalesce(completed_at, now())
   where deletion_hash = futbeat_private.deletion_digest(lower(p_deletion_id::text))
     and subject_hash = futbeat_private.deletion_digest(lower(p_subject::text));
  get diagnostics v_count = row_count;
  return jsonb_build_object('status', case when v_count = 1 then 'deleted' else 'unknown' end);
end;
$$;

-- Anyone holding the id (the app, with only the publishable key): the state.
-- A pending receipt whose account no longer exists is completed here, so a
-- lost ACK after a successful delete still reads as deleted.
create or replace function public.futbeat_account_deletion_status(p_deletion_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_hash bytea := futbeat_private.deletion_digest(lower(p_deletion_id::text));
  v_row futbeat_private.account_deletion_receipts;
begin
  perform futbeat_private.account_deletion_receipts_purge();
  select * into v_row from futbeat_private.account_deletion_receipts where deletion_hash = v_hash;
  if not found then
    return jsonb_build_object('status', 'unknown');
  end if;
  if v_row.status = 'pending' and not exists (select 1 from auth.users u where u.id = v_row.subject) then
    update futbeat_private.account_deletion_receipts
       set status = 'deleted', subject = null, completed_at = now()
     where deletion_hash = v_hash and status = 'pending';
    v_row.status := 'deleted';
    v_row.completed_at := now();
  end if;
  return jsonb_build_object('status', v_row.status,
    'completedAt', case when v_row.status = 'deleted' then v_row.completed_at end);
end;
$$;

revoke all on function futbeat_private.account_deletion_receipts_purge() from public, anon, authenticated;

grant execute on function futbeat_private.account_deletion_receipts_purge() to service_role;

-- create or replace keeps the existing ACLs of begin/finish/status; restated
-- so this file alone leaves the contract grants exact.
revoke all on function public.futbeat_account_deletion_begin(uuid, uuid) from public, anon, authenticated;

revoke all on function public.futbeat_account_deletion_finish(uuid, uuid) from public, anon, authenticated;

revoke all on function public.futbeat_account_deletion_status(uuid) from public;

grant execute on function public.futbeat_account_deletion_begin(uuid, uuid) to service_role;

grant execute on function public.futbeat_account_deletion_finish(uuid, uuid) to service_role;

grant execute on function public.futbeat_account_deletion_status(uuid) to anon, authenticated, service_role;

-- Daily purge (04:17 UTC) when pg_cron is installed; cron.schedule with a
-- job name replaces an existing job of that name, so this is idempotent.
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule('futbeat-account-deletion-receipts-purge', '17 4 * * *',
      'select futbeat_private.account_deletion_receipts_purge()');
  end if;
end;
$$;

-- Source: be12/rd57/fix_rd57.sql
-- SHA-256: 9666e8efce93a797b69f0761b38abfa0d561f84bf84cdcafac6d5656e94c6bb7
-- RD57: results-date reservation no longer rescans unchanged clean dates (57014 at 02:43Z/14:43Z, 2026-11-09).
-- Base: production next_goal_results_candidate() read 2026-11-09 (b10-rcand). Readers of the per-date
-- calendar revision only; calendar functions and GOAL policy untouched. Rollback restores the body verbatim.
create table if not exists futbeat_private.results_candidate_clean(
  provider_date date primary key,
  revision bigint not null,
  checked_at timestamptz not null);

alter table futbeat_private.results_candidate_clean enable row level security;

revoke all on futbeat_private.results_candidate_clean from public, anon, authenticated;

CREATE OR REPLACE FUNCTION futbeat_private.next_goal_results_candidate()
 RETURNS date
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_today date := (now() at time zone 'UTC')::date;
  v_date date;
  v_rev bigint;
begin
  for v_date in
    select d.provider_date
    from (select g::date provider_date
          from generate_series(v_today-14, v_today-1, interval '1 day') g) d
    left join futbeat_private.results_date_attempts a
      on a.provider='goal_api' and a.provider_date=d.provider_date
    where a.next_retry_at is null or a.next_retry_at<=now()
    order by coalesce(a.attempt_count,0), coalesce(a.last_attempt_at,'epoch'::timestamptz),
      d.provider_date desc
  loop
    -- RD57: a date found with nothing due keeps that answer while its per-date calendar
    -- revision (bumped by the invalidate_calendar_cache triggers on matches, observations,
    -- events and details) is unchanged. Only answers taken after the UTC day ended count:
    -- bump_calendar_date skips the current UTC day.
    v_rev:=coalesce((select v.revision from futbeat_private.calendar_cache_versions v where v.utc_date=v_date),0);
    if exists(select 1 from futbeat_private.results_candidate_clean c where c.provider_date=v_date
        and c.revision=v_rev and c.checked_at>=(v_date+1)::timestamp at time zone 'UTC'+interval '5 minutes') then
      continue;
    end if;
    if exists (
      select 1
      from futbeat_private.calendar_matches cm
      join futbeat_private.entities e on e.id=cm.match_id and e.kind='match'
      left join futbeat_private.match_result_reconciliation mr on mr.match_id=cm.match_id
      where cm.start_time>=v_date::timestamp at time zone 'UTC'
        and cm.start_time<(v_date+1)::timestamp at time zone 'UTC'
        and (mr.match_id is null or mr.state='unresolved'
          or mr.canonical_payload_hash is distinct from md5(e.payload::text)
          or mr.provider_date<>(cm.start_time at time zone 'UTC')::date
          or exists(select 1 from futbeat_private.provider_observations o
            where o.provider='goal_api' and o.canonical_match_id=cm.match_id
              and o.received_at>coalesce(mr.evidence_at,'-infinity'::timestamptz))
          or exists(select 1 from futbeat_private.canonical_events ce
            where ce.match_id=cm.match_id and not coalesce(e.payload->'events','[]'::jsonb)
              @> jsonb_build_array(ce.payload)))) then
      return v_date;
    end if;
    if now()>=(v_date+1)::timestamp at time zone 'UTC'+interval '5 minutes' then
      insert into futbeat_private.results_candidate_clean(provider_date,revision,checked_at) values(v_date,v_rev,now())
      on conflict(provider_date) do update set revision=excluded.revision,checked_at=excluded.checked_at;
    end if;
  end loop;
  return null;
end
$function$;

-- Source: be16/fix_be16.sql
-- SHA-256: b960bee41a9cb0e7d4f499ca6b37d1b868d637d038680cc8c032d8356bb4d9dc
-- BE16 (results recovery): GOAL finals left as FINISHED_PENDING_VERIFICATION, bounded reconcile, retry tick,
-- no request spent on a capped date the fallback cannot read. Base: production bodies 2026-11-11 22:5xZ.
-- Promotion evidence: the newest GOAL observation of the match is a final (the worker maps FINISHED, AFTER_ET,
-- AFTER_PEN and AWARDED to FINISHED_PENDING_VERIFICATION), observed >= 90 min after kickoff, with a complete
-- score equal to the payload score. The GOAL calendar writer (backend/providers/goal_api.mjs) already stores the
-- same evidence as VERIFIED. Status only: no score, event, live_match_state or outbox write.
create or replace function futbeat_private.goal_final_promotable(p_match_id text, p_payload jsonb)
 returns boolean language sql stable set search_path to '' as $$
  select coalesce(p_payload->>'status'='FINISHED_PENDING_VERIFICATION'
    and o.status='FINISHED_PENDING_VERIFICATION'
    and futbeat_private.try_timestamptz(p_payload->>'startTime') is not null
    and coalesce(o.provider_observed_at,o.received_at)
        >=futbeat_private.try_timestamptz(p_payload->>'startTime')+interval '90 minutes'
    and (o.sc->>'home') is not null and (o.sc->>'away') is not null
    and o.sc=p_payload->'score',false)
  from (select 1) seed left join lateral (
    select ob.status,ob.received_at,ob.provider_observed_at,
      futbeat_private.observation_score(ob.provider,ob.home_score,ob.away_score,ob.raw_payload) sc
    from futbeat_private.provider_observations ob
    where ob.provider='goal_api' and ob.canonical_match_id=p_match_id
    order by ob.received_at desc,ob.id desc limit 1) o on true
$$;

revoke all on function futbeat_private.goal_final_promotable(text,jsonb) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION futbeat_private.reconcile_goal_results_local(p_provider_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare r record; v_original jsonb; v_payload jsonb; v_events jsonb;
  v_changed integer:=0; v_events_changed integer:=0; v_state text;
  v_complete boolean; v_kickoff timestamptz; v_canonical_at timestamptz;
  v_attempts integer; v_current_start timestamptz;
  -- BE16: at most v_limit due rows per call (one short transaction); the rest waits for the next call.
  v_limit constant integer:=250; v_seen integer:=0; v_more boolean:=false; v_promoted integer:=0;
begin
  if p_provider_date is null then raise exception 'Invalid result date'; end if;
  select coalesce(a.attempt_count,0) into v_attempts
    from (select 1) seed left join futbeat_private.results_date_attempts a
      on a.provider='goal_api' and a.provider_date=p_provider_date;
  for r in
    select cm.match_id,cm.start_time,cm.updated_at as calendar_updated_at,o.status,o.minute,o.home_score,o.away_score,
      o.received_at,o.provider_observed_at,o.raw_payload,
      futbeat_private.observation_score(o.provider,o.home_score,o.away_score,o.raw_payload) score,
      t.status t_status,t.minute t_minute,
      futbeat_private.observation_score(t.provider,t.home_score,t.away_score,t.raw_payload) t_score,
      t.received_at t_received_at,t.provider_observed_at t_observed_at
    from (
      -- BE16: only rows whose inputs changed since their last reconciliation (the same test as
      -- next_goal_results_candidate) or that hold a promotable GOAL final. A skipped row would be
      -- rewritten with identical values: reconcile is a function of exactly these inputs.
      select c.match_id,c.start_time,c.updated_at from futbeat_private.calendar_matches c
      join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
      left join futbeat_private.match_result_reconciliation mr on mr.match_id=c.match_id
      where c.start_time>=p_provider_date::timestamp at time zone 'UTC'
        and c.start_time<(p_provider_date+1)::timestamp at time zone 'UTC'
        and (mr.match_id is null or mr.state='unresolved'
          or mr.canonical_payload_hash is distinct from md5(e.payload::text)
          or mr.provider_date<>(c.start_time at time zone 'UTC')::date
          or exists(select 1 from futbeat_private.provider_observations o
            where o.provider='goal_api' and o.canonical_match_id=c.match_id
              and o.received_at>coalesce(mr.evidence_at,'-infinity'::timestamptz))
          or exists(select 1 from futbeat_private.canonical_events ce
            where ce.match_id=c.match_id and not coalesce(e.payload->'events','[]'::jsonb)
              @> jsonb_build_array(ce.payload))
          or case when e.payload->>'status'='FINISHED_PENDING_VERIFICATION'
            then futbeat_private.goal_final_promotable(c.match_id,e.payload) else false end)
      order by c.start_time,c.match_id limit v_limit+1
    ) cm
    left join lateral (
      select observation.* from futbeat_private.provider_observations observation
      where observation.provider='goal_api' and observation.canonical_match_id=cm.match_id
      order by observation.received_at desc,observation.id desc limit 1
    ) o on true
    -- Newest real terminal observation, even if not the newest observation
    -- overall (a lagging LIVE feed can follow the final whistle).
    left join lateral (
      select observation.* from futbeat_private.provider_observations observation
      where observation.provider='goal_api' and observation.canonical_match_id=cm.match_id
        and observation.status in ('VERIFIED','FINISHED_PENDING_VERIFICATION')
      order by observation.received_at desc,observation.id desc limit 1
    ) t on true
    where cm.start_time>=p_provider_date::timestamp at time zone 'UTC'
      and cm.start_time<(p_provider_date+1)::timestamp at time zone 'UTC'
  loop
    v_seen:=v_seen+1;
    if v_seen>v_limit then v_more:=true; exit; end if;
    select payload into v_original from futbeat_private.entities
      where id=r.match_id and kind='match' for update;
    if v_original is null then continue; end if;
    v_payload:=v_original;
    select coalesce(jsonb_agg(payload order by
      coalesce(futbeat_private.safe_result_integer(payload->>'minute'),-1),
      coalesce(futbeat_private.safe_result_integer(payload->>'extraMinute'),0),first_seen_at,id),'[]'::jsonb)
      into v_events from futbeat_private.canonical_events where match_id=r.match_id;
    if jsonb_array_length(v_events)>0
       and coalesce(v_payload->'events','[]'::jsonb) is distinct from v_events then
      v_payload:=jsonb_set(v_payload,'{events}',v_events,true);
      v_events_changed:=v_events_changed+1;
    end if;
    v_canonical_at:=coalesce(
      futbeat_private.try_timestamptz(v_payload#>>'{provenance,receivedAt}'),
      r.calendar_updated_at);
    v_kickoff:=futbeat_private.try_timestamptz(r.raw_payload->>'kickoffUtc');
    if r.received_at is not null
       and coalesce(r.provider_observed_at,r.received_at)>=v_canonical_at then
      if v_payload->>'status' not in ('VERIFIED','FINISHED_PENDING_VERIFICATION','CANCELLED')
         and v_kickoff is not null and v_kickoff is distinct from
         futbeat_private.try_timestamptz(v_payload->>'startTime') then
        v_payload:=jsonb_set(v_payload,'{startTime}',to_jsonb(v_kickoff),true);
      end if;
      if coalesce(v_payload->>'status','') not in ('VERIFIED','FINISHED_PENDING_VERIFICATION','CANCELLED')
         and (
           r.status in ('VERIFIED','FINISHED_PENDING_VERIFICATION','POSTPONED','CANCELLED','SUSPENDED','ABANDONED')
           or (r.status in ('SCHEDULED','PRE_MATCH','LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
             and v_payload->>'status' in ('POSTPONED','SUSPENDED','ABANDONED')
             and (r.status not in ('SCHEDULED','PRE_MATCH') or v_kickoff is not null))
         ) then
        v_payload:=v_payload||jsonb_strip_nulls(jsonb_build_object(
          'status',r.status,
          'score',coalesce(r.score,v_payload->'score'),
          'minute',coalesce(to_jsonb(r.minute),v_payload->'minute'),
          'provenance',coalesce(v_payload->'provenance','{}'::jsonb)||jsonb_build_object(
            'receivedAt',r.received_at,'verificationStatus','VERIFIED','reconciledLocally',true)
        ));
      elsif v_payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
        and r.status in ('FINISHED_PENDING_VERIFICATION','VERIFIED') then
        -- A final score can be corrected by newer real evidence, but finished
        -- status never regresses and CANCELLED remains a strong terminal state.
        v_payload:=v_payload||jsonb_strip_nulls(jsonb_build_object(
          'status',case when v_payload->>'status'='VERIFIED' or r.status='VERIFIED'
            then 'VERIFIED' else 'FINISHED_PENDING_VERIFICATION' end,
          'score',coalesce(r.score,v_payload->'score')));
        if v_payload is distinct from v_original then
          v_payload:=jsonb_set(v_payload,'{provenance}',
            coalesce(v_payload->'provenance','{}'::jsonb)||jsonb_build_object(
              'receivedAt',r.received_at,'reconciledLocally',true),true);
        end if;
      end if;
    end if;
    -- A real terminal observation after the CURRENT kickoff closes a pre-match
    -- (or expired LIVE) payload even when a calendar re-ingest made
    -- payload.receivedAt newer. Same rule as match_read_model; a fresh LIVE
    -- and SUSPENDED/ABANDONED/POSTPONED/CANCELLED are never converted here.
    v_current_start:=futbeat_private.try_timestamptz(v_payload->>'startTime');
    if r.t_received_at is not null and v_current_start is not null
       and coalesce(r.t_observed_at,r.t_received_at)>=v_current_start
       and (coalesce(v_payload->>'status','') in ('DISCOVERED','SCHEDULED','PRE_MATCH')
         or (v_payload->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
           and coalesce(futbeat_private.try_timestamptz(v_payload#>>'{provenance,receivedAt}'),
             '-infinity'::timestamptz)<now()-interval '15 minutes')) then
      v_payload:=v_payload||jsonb_strip_nulls(jsonb_build_object(
        'status',r.t_status,
        'score',coalesce(r.t_score,v_payload->'score'),
        'minute',coalesce(to_jsonb(r.t_minute),v_payload->'minute'),
        'provenance',coalesce(v_payload->'provenance','{}'::jsonb)||jsonb_build_object(
          'receivedAt',r.t_received_at,'verificationStatus','VERIFIED','reconciledLocally',true)
      ));
    end if;
    -- BE16: provider final with the same score -> VERIFIED (status only, see goal_final_promotable).
    if v_payload->>'status'='FINISHED_PENDING_VERIFICATION'
       and futbeat_private.goal_final_promotable(r.match_id,v_payload) then
      v_payload:=jsonb_set(v_payload||jsonb_build_object('status','VERIFIED'),'{provenance}',
        coalesce(v_payload->'provenance','{}'::jsonb)||jsonb_build_object(
          'verificationStatus','VERIFIED',
          -- previous verificationStatus, kept so rollback_data_be16.sql can restore the payload exactly
          'promotedFromPending',coalesce(v_payload#>>'{provenance,verificationStatus}','')),true);
      v_promoted:=v_promoted+1;
    end if;
    if v_payload is distinct from v_original then
      -- BE16: hash what was stored (BEFORE triggers may normalise events), so a row is never due forever.
      update futbeat_private.entities set payload=v_payload where id=r.match_id returning payload into v_payload;
      v_changed:=v_changed+1;
    end if;
    v_state:=case
      when (futbeat_private.try_timestamptz(v_payload->>'startTime') at time zone 'UTC')::date<>p_provider_date
        then 'rescheduled'
      when v_payload->>'status' in
        ('VERIFIED','FINISHED_PENDING_VERIFICATION','POSTPONED','CANCELLED','SUSPENDED','ABANDONED')
        then 'resolved'
      when v_attempts>=4 and r.start_time<now()-interval '48 hours'
        then 'missing_from_provider'
      else 'unresolved' end;
    insert into futbeat_private.match_result_reconciliation(
      match_id,state,provider,provider_date,evidence_at,canonical_payload_hash,updated_at)
    values(r.match_id,v_state,'goal_api',p_provider_date,r.received_at,md5(v_payload::text),now())
    on conflict(match_id) do update set state=excluded.state,provider_date=excluded.provider_date,
      evidence_at=excluded.evidence_at,canonical_payload_hash=excluded.canonical_payload_hash,updated_at=excluded.updated_at
    where (futbeat_private.match_result_reconciliation.state,
           futbeat_private.match_result_reconciliation.provider_date,
           futbeat_private.match_result_reconciliation.evidence_at,
           futbeat_private.match_result_reconciliation.canonical_payload_hash)
       is distinct from (excluded.state,excluded.provider_date,excluded.evidence_at,excluded.canonical_payload_hash);
  end loop;
  select not exists(select 1 from futbeat_private.match_result_reconciliation mr
    where mr.provider='goal_api' and mr.provider_date=p_provider_date and mr.state='unresolved')
    into v_complete;
  v_complete:=v_complete and not v_more;
  update futbeat_private.calendar_coverage set results_complete=v_complete,
    results_checked_at=now() where provider='goal_api' and provider_date=p_provider_date
      and results_complete is distinct from v_complete;
  return jsonb_build_object('date',p_provider_date,'updated',v_changed,
    'eventsUpdated',v_events_changed,'resultsComplete',v_complete,'more',v_more,'promoted',v_promoted,
    'unresolved',(select count(*) from futbeat_private.match_result_reconciliation mr
      where mr.provider='goal_api' and mr.provider_date=p_provider_date and mr.state='unresolved'));
end $function$
;

CREATE OR REPLACE FUNCTION futbeat_private.reserve_goal_results_date(p_trigger_source text DEFAULT 'supabase-cron'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_date date; v_id bigint; v_remaining integer; v_used integer;
  v_results_used integer; v_local jsonb; v_attempt integer; v_user_priority boolean:=false;
begin
  perform pg_advisory_xact_lock(hashtext('futbeat-provider-quota:goal_api:'||(now() at time zone 'UTC')::date::text));
  -- Retain 90 days, well beyond the 14-day automatic window. Primary key
  -- supports deletion by provider/date; old evidence remains in observations.
  delete from futbeat_private.results_date_attempts
    where provider='goal_api' and provider_date<(now() at time zone 'UTC')::date-90;
  -- Indexed by (provider,provider_date,state); never scans JSON.
  delete from futbeat_private.match_result_reconciliation
    where provider='goal_api' and provider_date<(now() at time zone 'UTC')::date-90;
  delete from futbeat_private.results_date_user_demand
    where provider='goal_api' and requested_at<now()-interval '90 days';

  -- A date a user opened in the last 24h, not yet reserved since that
  -- request and not in provider backoff, jumps the background planner --
  -- but only while the central 'results' quota class allows it, so a flood
  -- of user opens cannot outrun the budget everything else shares.
  select d.provider_date into v_date
  from futbeat_private.results_date_user_demand d
  left join futbeat_private.results_date_attempts a
    on a.provider='goal_api' and a.provider_date=d.provider_date
  where d.provider='goal_api' and d.requested_at>now()-interval '24 hours'
    -- Outside the 90-day retention window, results_date_attempts rows for
    -- this date are deleted every call below, so no backoff could ever
    -- stick and a single stale request would win every reservation.
    and d.provider_date>=(now() at time zone 'UTC')::date-90
    and (a.next_retry_at is null or a.next_retry_at<=now())
    and (a.updated_at is null or a.updated_at<d.requested_at)
  order by d.requested_at desc limit 1;
  if v_date is not null then
    v_user_priority:=true;
    if not coalesce((futbeat_private.quota_decision('goal_api','results-date','results')->>'allowed')::boolean,false) then
      v_date:=null;
      v_user_priority:=false;
    end if;
  end if;

  if v_date is null then
    v_date:=futbeat_private.next_goal_results_candidate();
  end if;
  if v_date is null then return jsonb_build_object('allowed',false,'reason','no_results_due'); end if;
  v_local:=futbeat_private.reconcile_goal_results_local(v_date);
  -- BE16: a partial local pass ('more') finishes locally over the next calls before any provider request.
  if coalesce((v_local->>'resultsComplete')::boolean,false) or coalesce((v_local->>'more')::boolean,false) then
    insert into futbeat_private.results_date_attempts(provider,provider_date,last_outcome,next_retry_at,updated_at)
    values('goal_api',v_date,'LOCAL_REPAIRED',now(),now())
    on conflict(provider,provider_date) do update set last_outcome='LOCAL_REPAIRED',
      next_retry_at=now(),updated_at=now();
    return jsonb_build_object('allowed',false,'reason','reconciled_locally','date',v_date,'localRepair',v_local);
  end if;
  select provider_remaining into v_remaining from futbeat_private.provider_call_ledger
    where provider='goal_api' and provider_remaining is not null
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'
    order by coalesce(completed_at,reserved_at) desc,id desc limit 1;
  -- Provider request units of every call (failed paginated calls included).
  select coalesce(sum(futbeat_private.provider_call_units(metadata)),0)::integer
    into v_used from futbeat_private.provider_call_ledger where provider='goal_api'
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  select coalesce(sum(futbeat_private.provider_call_units(metadata)),0)::integer into v_results_used
    from futbeat_private.provider_call_ledger
    where provider='goal_api' and call_kind='results-date'
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  -- A user-priority date already cleared the central 'results' quota class
  -- above; it is not re-gated by the legacy fixed thresholds below, which
  -- remain exactly as they were for the unmodified background path.
  if not v_user_priority and (v_results_used>=60 or v_used>=880 or (v_remaining is not null and v_remaining<=120)) then
    insert into futbeat_private.results_date_attempts(provider,provider_date,last_outcome,next_retry_at)
    values('goal_api',v_date,'QUOTA_DEFERRED',now()+interval '30 minutes')
    on conflict(provider,provider_date) do update set last_outcome='QUOTA_DEFERRED',
      next_retry_at=now()+interval '30 minutes',updated_at=now();
    return jsonb_build_object('allowed',false,'reason','results_quota_guard','localRepair',v_local,
      'usedToday',v_used,'resultsUsedToday',v_results_used,'providerRemaining',v_remaining);
  end if;
  -- BE16: once /results/date capped this date (500 rows, no pagination) only the worker's /fixtures/date
  -- fallback can add results, and the worker skips it at <= 300 remaining. Below that, a call re-reads the
  -- same 500 rows: no request, retry in 30 min (the quota resets at 00:00 UTC).
  if v_remaining is not null and v_remaining<=301 and exists(
      select 1 from futbeat_private.provider_call_ledger l
      where l.provider='goal_api' and l.reserved_at>now()-interval '14 days' and l.call_kind='results-date'
        and l.metadata->>'date'=v_date::text
        and l.metadata->>'truncatedBy' in ('results_cap','fallback_quota')) then
    insert into futbeat_private.results_date_attempts(provider,provider_date,last_outcome,next_retry_at)
    values('goal_api',v_date,'QUOTA_DEFERRED',now()+interval '30 minutes')
    on conflict(provider,provider_date) do update set last_outcome='QUOTA_DEFERRED',
      next_retry_at=now()+interval '30 minutes',updated_at=now();
    return jsonb_build_object('allowed',false,'reason','results_cap_fallback_quota','date',v_date,
      'localRepair',v_local,'providerRemaining',v_remaining);
  end if;
  insert into futbeat_private.results_date_attempts(
    provider,provider_date,last_attempt_at,attempt_count,last_outcome,next_retry_at,updated_at)
  values('goal_api',v_date,now(),1,'RESERVED',now()+futbeat_private.results_retry_delay(v_date,1),now())
  on conflict(provider,provider_date) do update set last_attempt_at=now(),
    attempt_count=futbeat_private.results_date_attempts.attempt_count+1,
    last_outcome='RESERVED',next_retry_at=now()+futbeat_private.results_retry_delay(
      v_date,futbeat_private.results_date_attempts.attempt_count+1),updated_at=now()
  returning attempt_count into v_attempt;
  insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
  values('goal_api','results-date',left(p_trigger_source,40),now(),
    jsonb_build_object('date',v_date,'attempt',v_attempt,'userPriority',v_user_priority)) returning id into v_id;
  return jsonb_build_object('allowed',true,'reservationId',v_id,'date',v_date,
    'attempt',v_attempt,'localRepair',v_local,'providerRemaining',v_remaining,'userPriority',v_user_priority);
end $function$
;

CREATE OR REPLACE FUNCTION futbeat_private.next_goal_results_candidate()
 RETURNS date
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_today date := (now() at time zone 'UTC')::date;
  v_date date;
  v_rev bigint;
begin
  for v_date in
    select d.provider_date
    from (select g::date provider_date
          from generate_series(v_today-14, v_today-1, interval '1 day') g) d
    left join futbeat_private.results_date_attempts a
      on a.provider='goal_api' and a.provider_date=d.provider_date
    -- BE16: retries are stored as now()+k*2h from a :43 tick and land ~1 s after the next one; 2 min of
    -- tolerance stops each date losing a full cycle.
    where a.next_retry_at is null or a.next_retry_at<=now()+interval '2 minutes'
    order by coalesce(a.attempt_count,0), coalesce(a.last_attempt_at,'epoch'::timestamptz),
      d.provider_date desc
  loop
    -- RD57: a date found with nothing due keeps that answer while its per-date calendar
    -- revision (bumped by the invalidate_calendar_cache triggers on matches, observations,
    -- events and details) is unchanged. Only answers taken after the UTC day ended count:
    -- bump_calendar_date skips the current UTC day.
    v_rev:=coalesce((select v.revision from futbeat_private.calendar_cache_versions v where v.utc_date=v_date),0);
    if exists(select 1 from futbeat_private.results_candidate_clean c where c.provider_date=v_date
        and c.revision=v_rev and c.checked_at>=(v_date+1)::timestamp at time zone 'UTC'+interval '5 minutes') then
      continue;
    end if;
    if exists (
      select 1
      from futbeat_private.calendar_matches cm
      join futbeat_private.entities e on e.id=cm.match_id and e.kind='match'
      left join futbeat_private.match_result_reconciliation mr on mr.match_id=cm.match_id
      where cm.start_time>=v_date::timestamp at time zone 'UTC'
        and cm.start_time<(v_date+1)::timestamp at time zone 'UTC'
        and (mr.match_id is null or mr.state='unresolved'
          or mr.canonical_payload_hash is distinct from md5(e.payload::text)
          or mr.provider_date<>(cm.start_time at time zone 'UTC')::date
          or exists(select 1 from futbeat_private.provider_observations o
            where o.provider='goal_api' and o.canonical_match_id=cm.match_id
              and o.received_at>coalesce(mr.evidence_at,'-infinity'::timestamptz))
          or exists(select 1 from futbeat_private.canonical_events ce
            where ce.match_id=cm.match_id and not coalesce(e.payload->'events','[]'::jsonb)
              @> jsonb_build_array(ce.payload))
          -- BE16: a provider final not yet promoted is due (time-independent, so the memo stays valid).
          or case when e.payload->>'status'='FINISHED_PENDING_VERIFICATION'
            then futbeat_private.goal_final_promotable(cm.match_id,e.payload) else false end)) then
      return v_date;
    end if;
    if now()>=(v_date+1)::timestamp at time zone 'UTC'+interval '5 minutes' then
      insert into futbeat_private.results_candidate_clean(provider_date,revision,checked_at) values(v_date,v_rev,now())
      on conflict(provider_date) do update set revision=excluded.revision,checked_at=excluded.checked_at;
    end if;
  end loop;
  return null;
end
$function$
;

-- Source: be14/contract/fix_contract.sql
-- SHA-256: 1b3170635774e94a01da89e5865a238f35a2ab140f4ca1339c9ca5fa1776ad22
CREATE OR REPLACE FUNCTION futbeat_private.read_match_detail_base(p_match_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cache futbeat_private.match_detail_cache%rowtype;
  v_live jsonb;
  v_live_at timestamptz;
  v_payload jsonb;
  v_level text := 'none';
  v_requested timestamptz;
  v_rt public.live_match_updates%rowtype;
  v_sections jsonb := '{}'::jsonb;
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

  select po.raw_payload, po.received_at
  into v_live, v_live_at
  from futbeat_private.provider_observations po
  where po.provider='goal_api'
    and po.canonical_match_id=p_match_id
  order by po.received_at desc
  limit 1;

  select requested_at into v_requested
  from futbeat_private.match_detail_requests
  where match_id=p_match_id;

  select * into v_rt from public.live_match_updates where match_id=p_match_id;

  if v_cache.match_id is not null then
    v_payload:=v_cache.payload;
    v_level:='full';
  elsif v_live is not null then
    v_payload:=v_live;
    v_level:='live';
  else
    v_payload:='{}'::jsonb;
  end if;

  -- Section hashes: only for sections the payload carries (omitted != deleted).
  if v_payload ?| array['events','cards','substitutions'] then
    v_sections:=v_sections||jsonb_build_object('events',md5(jsonb_build_array(
      v_payload->'events',v_payload->'cards',v_payload->'substitutions')::text));
  end if;
  if v_payload ? 'lineups' then
    v_sections:=v_sections||jsonb_build_object('lineup',md5((v_payload->'lineups')::text));
  end if;
  if v_payload ? 'statistics' then
    v_sections:=v_sections||jsonb_build_object('statistics',md5((v_payload->'statistics')::text));
  end if;

  return jsonb_build_object(
    'matchId',p_match_id,
    'available',v_level<>'none',
    'detailLevel',v_level,
    'requestedAt',v_requested,
    'fetchedAt',v_cache.fetched_at,
    'observedAt',case v_level when 'full' then v_cache.fetched_at when 'live' then v_live_at end,
    'live',case when v_rt.match_id is null then null else jsonb_build_object(
      'provider',v_rt.provider,'revision',v_rt.revision,'changedAt',v_rt.changed_at,'status',v_rt.status) end,
    'sections',v_sections,
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
$function$;

CREATE OR REPLACE FUNCTION futbeat_private.republish_verified_realtime(p_limit integer default 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record; n integer:=0;
begin
  perform set_config('futbeat.republish_verified','on',true);
  for r in
    select s.provider, s.external_match_id, e.payload->>'status' st,
           (e.payload#>>'{score,home}')::int h, (e.payload#>>'{score,away}')::int a
    from public.live_match_updates l
    join futbeat_private.entities e on e.id=l.match_id and e.kind='match'
    join futbeat_private.live_match_state s on s.provider=l.provider and s.external_match_id=l.external_match_id
    where e.payload->>'status'='VERIFIED'
      and jsonb_typeof(e.payload#>'{score,home}')='number' and jsonb_typeof(e.payload#>'{score,away}')='number'
      and l.status in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
      and (l.home_score,l.away_score) is distinct from
          ((e.payload#>>'{score,home}')::int,(e.payload#>>'{score,away}')::int)
    order by l.changed_at desc
    limit greatest(p_limit,0)
    for update of s skip locked
  loop
    update futbeat_private.live_match_state
       set status=r.st, home_score=r.h, away_score=r.a,
           revision=revision+1, changed_at=greatest(now(),changed_at+interval '1 millisecond')
     where provider=r.provider and external_match_id=r.external_match_id;
    perform public.futbeat_publish_live_state(r.provider, r.external_match_id);
    n:=n+1;
  end loop;
  perform set_config('futbeat.republish_verified','',true);
  return jsonb_build_object('republished',n);
end $function$;

REVOKE ALL ON FUNCTION futbeat_private.republish_verified_realtime(integer) FROM PUBLIC;

DO $$ BEGIN IF EXISTS(select 1 from pg_roles where rolname='anon') THEN EXECUTE 'REVOKE ALL ON FUNCTION futbeat_private.republish_verified_realtime(integer) FROM anon, authenticated'; END IF; END $$;

CREATE OR REPLACE FUNCTION futbeat_private.synthesize_goal_from_score_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  m jsonb;
  ev jsonb;
  baseline boolean;
  v_raw jsonb;
  v_side text;
  v_old integer;
  v_new integer;
  v_team text;
  v_explained integer;
  v_ordinal integer;
  v_retract record;
begin
  if new.provider<>'goal_api'
     or new.canonical_match_id is null
     or (
       new.home_score is not distinct from old.home_score
       and new.away_score is not distinct from old.away_score
     )
  then
    return new;
  end if;

  select payload into m
  from futbeat_private.entities
  where id=new.canonical_match_id and kind='match';

  if m is null then
    return new;
  end if;

  -- Review P1-1: a (known) score decrease retracts the provisional goals it
  -- no longer supports, so they never absorb or silence a later real goal.
  if new.home_score is not null and new.away_score is not null then
    foreach v_side in array array['home','away'] loop
      v_new:=case v_side when 'home' then new.home_score else new.away_score end;
      v_old:=case v_side when 'home' then coalesce(old.home_score,0) else coalesce(old.away_score,0) end;
      continue when v_new>=v_old;
      for v_retract in select c.id from futbeat_private.canonical_events c
        where c.match_id=new.canonical_match_id and c.provider='goal_api'
          and c.retracted_at is null and futbeat_private.is_synthetic_event(c.payload)
          and c.payload->>'teamId'=m->>(v_side||'TeamId')
          and coalesce(futbeat_private.event_team_ordinal(c.payload,m->>'homeTeamId',m->>'awayTeamId'),0)>v_new
      loop
        perform futbeat_private.retract_canonical_event(v_retract.id,new.changed_at,
          -- BE14: an official correction is not an annulled goal (enqueue_goal_annulled ignores this reason).
          case when coalesce(current_setting('futbeat.republish_verified',true),'')='on'
            then 'official_correction' else 'score_decrease' end);
      end loop;
    end loop;
  end if;

  -- BE14: an official correction republished by republish_verified_realtime is not a goal (no synthetic
  -- GOAL, no push). Transaction-local flag; the LIVE path never sets it.
  if coalesce(current_setting('futbeat.republish_verified',true),'')='on' then
    return new;
  end if;

  if coalesce(new.home_score,0)<=coalesce(old.home_score,0)
     and coalesce(new.away_score,0)<=coalesce(old.away_score,0) then
    return new;
  end if;

  select exists(
    select 1
    from futbeat_private.event_baselines
    where match_id=new.canonical_match_id
  ) into baseline;

  select raw_payload into v_raw
  from futbeat_private.provider_observations
  where provider=new.provider
    and external_match_id=new.external_match_id
    and payload_hash=new.last_payload_hash;

  foreach v_side in array array['home','away'] loop
    v_old:=case v_side when 'home' then coalesce(old.home_score,0) else coalesce(old.away_score,0) end;
    v_new:=case v_side when 'home' then coalesce(new.home_score,0) else coalesce(new.away_score,0) end;
    if v_new<=v_old then
      continue;
    end if;
    v_team:=m->>(v_side||'TeamId');

    -- Active rich goals of this side (any observation).
    select count(*) into v_explained
    from futbeat_private.live_events le
    where le.provider=new.provider
      and le.external_match_id=new.external_match_id
      and le.event_type='GOAL'
      and le.retracted_at is null
      and (
        le.team_external_id=coalesce(
          v_raw#>>array[v_side||'Team','id'],v_raw->>(v_side||'TeamId'))
        or exists(
          select 1 from futbeat_private.provider_entities pe
          where pe.provider=new.provider and pe.kind='team'
            and pe.external_id=le.team_external_id and pe.canonical_id=v_team)
      );

    for v_ordinal in greatest(v_old,v_explained)+1..v_new loop
      ev:=jsonb_build_object(
        -- The top ordinal keeps the historical id formula.
        'id','fb_event_'||md5(concat_ws(
          '|',new.canonical_match_id,'goal_api','GOAL',v_side,
          new.revision,new.minute,new.home_score,new.away_score,
          case when v_ordinal<>v_new then v_ordinal end
        )),
        'matchId',new.canonical_match_id,
        'type','GOAL',
        'minute',new.minute,
        'teamId',v_team,
        'score',jsonb_build_object(
          'home',case when v_side='home' then v_ordinal else new.home_score end,
          'away',case when v_side='away' then v_ordinal else new.away_score end
        ),
        -- Internal audit text; the visible projection never shows it.
        'detail','Marcador actualizado',
        'synthetic',true
      );
      perform futbeat_private.store_canonical_event(
        ev,'goal_api',baseline,new.changed_at,m
      );
    end loop;
  end loop;

  return new;
end
$function$
;

-- Source: be18-results/fix_be18.sql
-- SHA-256: be84e7cbb08565f6294464572d9592ecc559d0afc7682bf0b633a3fe97d93f2d
CREATE OR REPLACE FUNCTION futbeat_private.reserve_goal_results_date(p_trigger_source text DEFAULT 'supabase-cron'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
declare v_date date; v_id bigint; v_remaining integer; v_used integer;
  v_results_used integer; v_local jsonb; v_attempt integer; v_user_priority boolean:=false;
begin
  perform pg_advisory_xact_lock(hashtext('futbeat-provider-quota:goal_api:'||(now() at time zone 'UTC')::date::text));
  -- Retain 90 days, well beyond the 14-day automatic window. Primary key
  -- supports deletion by provider/date; old evidence remains in observations.
  delete from futbeat_private.results_date_attempts
    where provider='goal_api' and provider_date<(now() at time zone 'UTC')::date-90;
  -- Indexed by (provider,provider_date,state); never scans JSON.
  delete from futbeat_private.match_result_reconciliation
    where provider='goal_api' and provider_date<(now() at time zone 'UTC')::date-90;
  delete from futbeat_private.results_date_user_demand
    where provider='goal_api' and requested_at<now()-interval '90 days';

  -- A date a user opened in the last 24h, not yet reserved since that
  -- request and not in provider backoff, jumps the background planner --
  -- but only while the central 'results' quota class allows it, so a flood
  -- of user opens cannot outrun the budget everything else shares.
  select d.provider_date into v_date
  from futbeat_private.results_date_user_demand d
  left join futbeat_private.results_date_attempts a
    on a.provider='goal_api' and a.provider_date=d.provider_date
  where d.provider='goal_api' and d.requested_at>now()-interval '24 hours'
    -- Outside the 90-day retention window, results_date_attempts rows for
    -- this date are deleted every call below, so no backoff could ever
    -- stick and a single stale request would win every reservation.
    and d.provider_date>=(now() at time zone 'UTC')::date-90
    and (a.next_retry_at is null or a.next_retry_at<=now())
    and (a.updated_at is null or a.updated_at<d.requested_at)
  order by d.requested_at desc limit 1;
  if v_date is not null then
    v_user_priority:=true;
    if not coalesce((futbeat_private.quota_decision('goal_api','results-date','results')->>'allowed')::boolean,false) then
      v_date:=null;
      v_user_priority:=false;
    end if;
  end if;

  if v_date is null then
    v_date:=futbeat_private.next_goal_results_candidate();
  end if;
  if v_date is null then return jsonb_build_object('allowed',false,'reason','no_results_due'); end if;
  v_local:=futbeat_private.reconcile_goal_results_local(v_date);
  -- BE16: a partial local pass ('more') finishes locally over the next calls before any provider request.
  -- BE18: 'more' defers the provider request only while the local pass makes progress (rows rewritten
  -- or promoted). Unresolved rows need provider evidence: with no progress, the date goes to GOAL.
  if coalesce((v_local->>'resultsComplete')::boolean,false)
     or (coalesce((v_local->>'more')::boolean,false)
       and coalesce((v_local->>'updated')::integer,0)+coalesce((v_local->>'promoted')::integer,0)>0) then
    insert into futbeat_private.results_date_attempts(provider,provider_date,last_outcome,next_retry_at,updated_at)
    values('goal_api',v_date,'LOCAL_REPAIRED',now(),now())
    on conflict(provider,provider_date) do update set last_outcome='LOCAL_REPAIRED',
      next_retry_at=now(),updated_at=now();
    return jsonb_build_object('allowed',false,'reason','reconciled_locally','date',v_date,'localRepair',v_local);
  end if;
  select provider_remaining into v_remaining from futbeat_private.provider_call_ledger
    where provider='goal_api' and provider_remaining is not null
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'
    order by coalesce(completed_at,reserved_at) desc,id desc limit 1;
  -- Provider request units of every call (failed paginated calls included).
  select coalesce(sum(futbeat_private.provider_call_units(metadata)),0)::integer
    into v_used from futbeat_private.provider_call_ledger where provider='goal_api'
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  select coalesce(sum(futbeat_private.provider_call_units(metadata)),0)::integer into v_results_used
    from futbeat_private.provider_call_ledger
    where provider='goal_api' and call_kind='results-date'
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  -- A user-priority date already cleared the central 'results' quota class
  -- above; it is not re-gated by the legacy fixed thresholds below, which
  -- remain exactly as they were for the unmodified background path.
  if not v_user_priority and (v_results_used>=60 or v_used>=880 or (v_remaining is not null and v_remaining<=120)) then
    insert into futbeat_private.results_date_attempts(provider,provider_date,last_outcome,next_retry_at)
    values('goal_api',v_date,'QUOTA_DEFERRED',now()+interval '30 minutes')
    on conflict(provider,provider_date) do update set last_outcome='QUOTA_DEFERRED',
      next_retry_at=now()+interval '30 minutes',updated_at=now();
    return jsonb_build_object('allowed',false,'reason','results_quota_guard','localRepair',v_local,
      'usedToday',v_used,'resultsUsedToday',v_results_used,'providerRemaining',v_remaining);
  end if;
  -- BE16: once /results/date capped this date (500 rows, no pagination) only the worker's /fixtures/date
  -- fallback can add results, and the worker skips it at <= 300 remaining. Below that, a call re-reads the
  -- same 500 rows: no request, retry in 30 min (the quota resets at 00:00 UTC).
  if v_remaining is not null and v_remaining<=301 and exists(
      select 1 from futbeat_private.provider_call_ledger l
      where l.provider='goal_api' and l.reserved_at>now()-interval '14 days' and l.call_kind='results-date'
        and l.metadata->>'date'=v_date::text
        and l.metadata->>'truncatedBy' in ('results_cap','fallback_quota')) then
    insert into futbeat_private.results_date_attempts(provider,provider_date,last_outcome,next_retry_at)
    values('goal_api',v_date,'QUOTA_DEFERRED',now()+interval '30 minutes')
    on conflict(provider,provider_date) do update set last_outcome='QUOTA_DEFERRED',
      next_retry_at=now()+interval '30 minutes',updated_at=now();
    return jsonb_build_object('allowed',false,'reason','results_cap_fallback_quota','date',v_date,
      'localRepair',v_local,'providerRemaining',v_remaining);
  end if;
  insert into futbeat_private.results_date_attempts(
    provider,provider_date,last_attempt_at,attempt_count,last_outcome,next_retry_at,updated_at)
  values('goal_api',v_date,now(),1,'RESERVED',now()+futbeat_private.results_retry_delay(v_date,1),now())
  on conflict(provider,provider_date) do update set last_attempt_at=now(),
    attempt_count=futbeat_private.results_date_attempts.attempt_count+1,
    last_outcome='RESERVED',next_retry_at=now()+futbeat_private.results_retry_delay(
      v_date,futbeat_private.results_date_attempts.attempt_count+1),updated_at=now()
  returning attempt_count into v_attempt;
  insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
  values('goal_api','results-date',left(p_trigger_source,40),now(),
    jsonb_build_object('date',v_date,'attempt',v_attempt,'userPriority',v_user_priority)) returning id into v_id;
  return jsonb_build_object('allowed',true,'reservationId',v_id,'date',v_date,
    'attempt',v_attempt,'localRepair',v_local,'providerRemaining',v_remaining,'userPriority',v_user_priority);
end $$
;

-- Source: live-pro/n1_apply.sql
-- SHA-256: f62d4e6f93d8fbd51beb4d32a52c7159ed310b611dfa5067728afcb2c9465cbd
-- Preferences per scope. '{}' (every existing user) = the legacy switches, i.e. exactly today's behaviour;
-- categories that did not push before (halftime, yellow cards, missed penalties, team/match substitutions)
-- default to OFF and only an explicit true enables them.
alter table futbeat_private.user_preferences add column if not exists notification_scopes jsonb not null default '{}'::jsonb;

alter table futbeat_private.user_preferences drop constraint if exists user_preferences_notification_scopes_object;

alter table futbeat_private.user_preferences add constraint user_preferences_notification_scopes_object
  check (jsonb_typeof(notification_scopes)='object');

-- Supported kinds per scope with the coverage measured on production (GOAL Pro, 2026-10-16..11-15):
-- available = always present when the event exists; partial = player identified on a share of events;
-- rare = supported by the normalizer, not seen in 30 days. Unsupported kinds are not listed (rejected).
create or replace function futbeat_private.notification_kind_catalog()
returns jsonb language sql immutable set search_path to '' as $f$
  select '{
    "player":{"starter":"available","bench":"available","goal":"partial","penalty_goal":"partial","assist":"partial",
      "sub_in":"partial","sub_out":"partial","yellow_card":"partial","red_card":"partial","penalty_missed":"rare",
      "goal_annulled":"available"},
    "team":{"kickoff":"available","halftime":"available","final":"available","goal_for":"available","goal_against":"available",
      "red_card":"available","penalty_missed":"rare","goal_annulled":"available"},
    "match":{"kickoff":"available","halftime":"available","final":"available","goal":"available","red_card":"available",
      "penalty_missed":"rare","goal_annulled":"available","yellow_card":"available","substitution":"available"},
    "unsupported":["penalty_won","penalty_committed","second_yellow","injury","player_of_the_match","own_goal"]
  }'::jsonb
$f$;

create or replace function futbeat_private.notify_allowed_p(p jsonb,p_scope text,p_kind text)
returns boolean language sql immutable set search_path to '' as $f$
  select p_kind is not null and futbeat_private.notification_kind_catalog()->p_scope ? p_kind and coalesce(
    case when jsonb_typeof(p->'notification_scopes'->p_scope->p_kind)='boolean'
      then (p->'notification_scopes'->p_scope->>p_kind)::boolean end,
    case p_scope||':'||p_kind
      when 'player:goal' then coalesce((p->>'notify_goals')::boolean,true)
      when 'player:penalty_goal' then coalesce((p->>'notify_goals')::boolean,true)
      when 'player:assist' then coalesce((p->>'notify_goals')::boolean,true)
      when 'player:red_card' then coalesce((p->>'notify_red_cards')::boolean,true) and coalesce((p->>'notify_cards')::boolean,true)
      when 'player:sub_in' then coalesce((p->>'notify_player_sub_in')::boolean,true)
      when 'player:sub_out' then coalesce((p->>'notify_player_sub_out')::boolean,true)
      when 'player:starter' then coalesce((p->>'notify_lineups')::boolean,true) and coalesce((p->>'notify_player_starter')::boolean,true)
      when 'player:bench' then coalesce((p->>'notify_lineups')::boolean,true) and coalesce((p->>'notify_player_bench')::boolean,true)
      when 'player:goal_annulled' then coalesce((p->>'notify_goal_annulled')::boolean,true)
      when 'team:kickoff' then coalesce((p->>'notify_kickoff')::boolean,true)
      when 'team:goal_for' then coalesce((p->>'notify_goals')::boolean,true)
      when 'team:goal_against' then coalesce((p->>'notify_goals')::boolean,true)
      when 'team:final' then coalesce((p->>'notify_final')::boolean,true)
      when 'team:red_card' then coalesce((p->>'notify_red_cards')::boolean,true) and coalesce((p->>'notify_cards')::boolean,true)
      when 'team:goal_annulled' then coalesce((p->>'notify_goal_annulled')::boolean,true)
      when 'match:kickoff' then coalesce((p->>'notify_kickoff')::boolean,true)
      when 'match:goal' then coalesce((p->>'notify_goals')::boolean,true)
      when 'match:final' then coalesce((p->>'notify_final')::boolean,true)
      when 'match:red_card' then coalesce((p->>'notify_red_cards')::boolean,true) and coalesce((p->>'notify_cards')::boolean,true)
      when 'match:goal_annulled' then coalesce((p->>'notify_goal_annulled')::boolean,true)
    end,false)
$f$;

-- Claim-time revalidation of a scoped row: at least one authorising scope is still followed and still on.
create or replace function futbeat_private.notification_scopes_ok(p_user uuid,p_msg jsonb,p_match jsonb)
returns boolean language sql stable security definer set search_path to '' as $f$
  select exists(
    select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_msg->'scopes')='array' then p_msg->'scopes' else '[]' end) s
    left join futbeat_private.user_preferences p on p.user_id=p_user
    where futbeat_private.notify_allowed_p(to_jsonb(p),s,p_msg->'scopeKinds'->>s)
      and case s
        when 'player' then exists(select 1 from futbeat_private.push_follows f where f.user_id=p_user
          and f.entity_type='player' and f.entity_id=p_msg->>'playerId')
        when 'team' then exists(select 1 from futbeat_private.push_follows f where f.user_id=p_user
          and f.entity_type='team' and f.entity_id in (p_match->>'homeTeamId',p_match->>'awayTeamId'))
        when 'match' then exists(select 1 from futbeat_private.push_follows f where f.user_id=p_user
          and f.entity_type='match' and f.entity_id=p_msg->>'matchId')
        else false end)
$f$;

revoke all on function futbeat_private.notification_scopes_ok(uuid,jsonb,jsonb) from public,anon,authenticated;

-- Android: read the effective matrix (catalog, coverage, explicit choice, effective value).
create or replace function public.futbeat_read_notification_scopes()
returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare uid uuid:=auth.uid(); p jsonb; c jsonb:=futbeat_private.notification_kind_catalog(); out jsonb:='{}'; s text; k text;
begin
  if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
  select to_jsonb(u) into p from futbeat_private.user_preferences u where u.user_id=uid;
  foreach s in array array['player','team','match'] loop
    out:=out||jsonb_build_object(s,(select jsonb_object_agg(kk,jsonb_build_object(
      'enabled',futbeat_private.notify_allowed_p(p,s,kk),
      'explicit',case when jsonb_typeof(p->'notification_scopes'->s->kk)='boolean' then p->'notification_scopes'->s->kk end,
      'coverage',c->s->>kk)) from jsonb_object_keys(c->s) kk));
  end loop;
  return jsonb_build_object('version',1,'scopes',out,'unsupported',c->'unsupported');
end $f$;

-- Android: update (merge) explicit choices. Only catalogued scope/kind pairs and booleans; null removes the
-- explicit choice (back to the default). Never creates follows; never touches the legacy columns.
create or replace function public.futbeat_set_notification_scopes(p_scopes jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare uid uuid:=auth.uid(); c jsonb:=futbeat_private.notification_kind_catalog(); cur jsonb; s text; k text; v jsonb;
begin
  if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if jsonb_typeof(p_scopes) is distinct from 'object' then raise exception 'Invalid notification scopes'; end if;
  insert into futbeat_private.user_preferences(user_id) values(uid) on conflict(user_id) do nothing;
  select notification_scopes into cur from futbeat_private.user_preferences where user_id=uid for update;
  for s in select jsonb_object_keys(p_scopes) loop
    if s not in ('player','team','match') or jsonb_typeof(p_scopes->s)<>'object' then raise exception 'Invalid notification scopes'; end if;
    for k,v in select key,value from jsonb_each(p_scopes->s) loop
      if not (c->s ? k) or jsonb_typeof(v) not in ('boolean','null') then raise exception 'Invalid notification scopes'; end if;
      cur:=case when jsonb_typeof(v)='null' then jsonb_set(cur,array[s],coalesce(cur->s,'{}')-k)
        else jsonb_set(cur,array[s],coalesce(cur->s,'{}')||jsonb_build_object(k,v)) end;
    end loop;
  end loop;
  update futbeat_private.user_preferences set notification_scopes=cur,updated_at=now() where user_id=uid;
  return public.futbeat_read_notification_scopes();
end $f$;

revoke all on function public.futbeat_read_notification_scopes(),public.futbeat_set_notification_scopes(jsonb) from public,anon;

do $r$ begin
  if exists(select 1 from pg_roles where rolname='authenticated') then
    grant execute on function public.futbeat_read_notification_scopes(),public.futbeat_set_notification_scopes(jsonb) to authenticated;
  end if;
end $r$;

CREATE OR REPLACE FUNCTION futbeat_private.store_canonical_event(ev jsonb, p_provider text, p_notify boolean, p_at timestamp with time zone, m jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  inserted integer;
  msg jsonb;
  pmsg jsonb;
  involved record;
  v_old futbeat_private.canonical_events%rowtype;
  v_new jsonb;
  v_twin text;
  -- LIVE-PRO N1
  v_penalty boolean; v_own boolean; v_kp text; v_ka text; v_km text; v_kt text; v_pm1 jsonb; v_pm2 jsonb;
begin
  select * into v_old from futbeat_private.canonical_events where id=ev->>'id' for update;
  if found then
    -- Phase and synthetic rows keep their first observation (#121).
    if futbeat_private.is_phase_event(ev->>'type')
      or futbeat_private.is_synthetic_event(ev)
      or futbeat_private.is_synthetic_event(v_old.payload) then
      return;
    end if;
    v_new:=futbeat_private.normalize_event_minutes(ev);
    if (jsonb_strip_nulls(v_new)-'observedAt') is distinct from (jsonb_strip_nulls(v_old.payload)-'observedAt')
      or v_old.retracted_at is not null then
      insert into futbeat_private.canonical_event_revisions(event_id,match_id,revised_at,action,reason,previous_payload,payload)
      values(v_old.id,v_old.match_id,p_at,
        case when v_old.retracted_at is not null then 'restore' else 'update' end,
        'provider_observation',v_old.payload,v_new);
      update futbeat_private.canonical_events
         set payload=ev,event_type=ev->>'type',retracted_at=null,retraction_reason=null,
             updated_at=p_at,revision=revision+1
       where id=v_old.id;
    end if;
    -- A correction / restoration is never a new push.
    return;
  end if;

  insert into futbeat_private.canonical_events
  values(ev->>'id',ev->>'matchId',p_provider,ev->>'type',ev,p_notify,p_at)
  on conflict(id) do nothing;

  get diagnostics inserted=row_count;
  if inserted=0 then return; end if;

  -- P0-A: the same observation retracted the row this one replaces (a
  -- re-keyed or corrected upstream row): one push per logical occurrence.
  -- Resolved even when this row may not notify, so the twin's push is never
  -- cancelled at claim time.
  v_twin:=futbeat_private.event_correction_twin(ev,p_at);
  if v_twin is not null then
    -- The twin's push (sent or pending) stands for this occurrence.
    update futbeat_private.canonical_events set retraction_reason='corrected' where id=v_twin;
    update futbeat_private.canonical_events set notify_candidate=false where id=ev->>'id';
    return;
  end if;
  if not p_notify then return; end if;
  -- #121: a re-keyed copy of an active row never pushes again.
  if nullif(ev->>'duplicateOf','') is not null then
    update futbeat_private.canonical_events set notify_candidate=false where id=ev->>'id';
    return;
  end if;

  -- #121: one push per logical occurrence. A new event equivalent to one
  -- already stored for the match (a rich GOAL after its provisional
  -- synthetic, the same goal from another provider, a re-keyed event) is
  -- kept for audit but never notified again.
  if futbeat_private.event_already_known(ev,m) then
    update futbeat_private.canonical_events set notify_candidate=false where id=ev->>'id';
    return;
  end if;

  -- LIVE-PRO N1: an unattributable provider GOAL (no team, no scorer) never pushes a second time for the goal
  -- already notified in this match within unattributedGoalWindowMinutes (normally its score-change synthetic).
  -- Only a nearby goal that KNOWS its team (synthetic or attributed) and is not already matched by another
  -- notified unattributable goal absorbs it: two genuine anonymous goals still push twice.
  if ev->>'type'='GOAL' and nullif(ev->>'teamId','') is null and nullif(ev->>'playerId','') is null
     and (select count(*) filter (where nullif(x.payload->>'teamId','') is not null)
               >count(*) filter (where nullif(x.payload->>'teamId','') is null and nullif(x.payload->>'playerId','') is null)
          from futbeat_private.canonical_events x
          where x.match_id=ev->>'matchId' and x.id<>ev->>'id' and x.event_type='GOAL'
            and x.retracted_at is null and x.notify_candidate
            and abs(coalesce((x.payload->>'minute')::integer,-1000)-coalesce((ev->>'minute')::integer,1000))
              <=futbeat_private.quota_setting('goal_api','unattributedGoalWindowMinutes',3)) then
    update futbeat_private.canonical_events set notify_candidate=false where id=ev->>'id';
    return;
  end if;

  msg:=futbeat_private.event_message(ev,m);
  if msg is null then return; end if;

  -- LIVE-PRO N1: one decision per device over three independent scopes, each with its own preferences
  -- (futbeat_private.notify_allowed_p): PLAYER = only events the followed player took part in (primary:
  -- scorer / carded / goes off / missed penalty; assist: assist / comes on), TEAM = the followed team's
  -- matches, MATCH = that match. One row per (event,user,device); the player copy wins; message.scopes and
  -- message.scopeKinds record which follows authorised it (claim-time revalidation uses them).
  v_penalty:=ev->>'type'='GOAL' and exists(select 1 from futbeat_private.live_events le
    where le.provider=p_provider and le.canonical_match_id=ev->>'matchId'
      and (le.event_key=ev->>'providerEventKey' or le.payload->>'providerEventId'=ev->>'providerEventKey')
      and upper(btrim(coalesce(le.payload#>>'{payload,info}','')))='PENALTY');
  v_own:=coalesce((ev->>'ownGoal')::boolean,false);
  v_kp:=case ev->>'type' when 'GOAL' then case when v_own then null when v_penalty then 'penalty_goal' else 'goal' end
    when 'RED_CARD' then 'red_card' when 'YELLOW_CARD' then 'yellow_card' when 'SUBSTITUTION' then 'sub_out'
    when 'MISSED_PENALTY' then 'penalty_missed' end;
  v_ka:=case ev->>'type' when 'GOAL' then case when v_own then null else 'assist' end when 'SUBSTITUTION' then 'sub_in' end;
  v_km:=case ev->>'type' when 'KICKOFF' then 'kickoff' when 'HALFTIME' then 'halftime' when 'FULL_TIME' then 'final'
    when 'GOAL' then 'goal' when 'RED_CARD' then 'red_card' when 'MISSED_PENALTY' then 'penalty_missed'
    when 'YELLOW_CARD' then 'yellow_card' when 'SUBSTITUTION' then 'substitution' end;
  v_kt:=case ev->>'type' when 'KICKOFF' then 'kickoff' when 'HALFTIME' then 'halftime' when 'FULL_TIME' then 'final'
    when 'GOAL' then 'goal' when 'RED_CARD' then 'red_card' when 'MISSED_PENALTY' then 'penalty_missed' end;
  if v_penalty then
    msg:=msg||jsonb_build_object('title',regexp_replace(msg->>'title','Gol','Gol de penal'),'penalty',true);
  end if;
  if not futbeat_private.player_event_is_stale(ev) then
    if v_kp is not null and nullif(ev->>'playerId','') is not null then
      v_pm1:=futbeat_private.player_event_message(ev,msg,ev->>'playerId','primary');
      if v_pm1 is not null and v_penalty then
        v_pm1:=v_pm1||jsonb_build_object('title',regexp_replace(v_pm1->>'title','Gol de','Gol de penal de'));
      end if;
    end if;
    if v_ka is not null and nullif(ev->>'assistPlayerId','') is not null then
      v_pm2:=futbeat_private.player_event_message(ev,msg,ev->>'assistPlayerId','assist');
    end if;
  end if;

  insert into futbeat_private.notification_outbox(event_id,device_id,user_id,message)
  select ev->>'id',x.device_id,x.user_id,
    case when x.p1 then v_pm1 when x.p2 then v_pm2 else msg end
    ||jsonb_build_object(
      'scopes',to_jsonb(array_remove(array[case when x.p1 or x.p2 then 'player' end,
        case when x.tk is not null then 'team' end,case when x.mk then 'match' end],null)),
      'scopeKinds',jsonb_strip_nulls(jsonb_build_object(
        'player',case when x.p1 then v_kp when x.p2 then v_ka end,'team',x.tk,'match',case when x.mk then v_km end)))
  from (
    select d.id device_id,d.user_id,
      v_pm1 is not null and futbeat_private.notify_allowed_p(j.pj,'player',v_kp) and exists(
        select 1 from futbeat_private.push_follows f where f.user_id=d.user_id and f.created_at<=p_at
          and f.entity_type='player' and f.entity_id=ev->>'playerId') p1,
      v_pm2 is not null and futbeat_private.notify_allowed_p(j.pj,'player',v_ka) and exists(
        select 1 from futbeat_private.push_follows f where f.user_id=d.user_id and f.created_at<=p_at
          and f.entity_type='player' and f.entity_id=ev->>'assistPlayerId') p2,
      (select k.kind from futbeat_private.push_follows f
        cross join lateral (select case when v_kt='goal'
          then case when f.entity_id=ev->>'teamId' then 'goal_for' else 'goal_against' end else v_kt end kind) k
        where f.user_id=d.user_id and f.created_at<=p_at and f.entity_type='team'
          and f.entity_id in (m->>'homeTeamId',m->>'awayTeamId') and v_kt is not null
          and futbeat_private.notify_allowed_p(j.pj,'team',k.kind)
        order by k.kind limit 1) tk,
      v_km is not null and futbeat_private.notify_allowed_p(j.pj,'match',v_km) and exists(
        select 1 from futbeat_private.push_follows f where f.user_id=d.user_id and f.created_at<=p_at
          and f.entity_type='match' and f.entity_id=ev->>'matchId') mk
    from futbeat_private.push_devices d
    left join futbeat_private.user_preferences p on p.user_id=d.user_id
    cross join lateral (select to_jsonb(p) pj) j
    where d.enabled and d.registered_at<=p_at
  ) x
  where x.p1 or x.p2 or x.tk is not null or x.mk
  on conflict(event_id,user_id,device_id) do nothing;
end;
$function$;

CREATE OR REPLACE FUNCTION futbeat_private.note_lineup_alerts(p_match_id text, p_payload jsonb, p_fetched_at timestamp with time zone)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_match jsonb; v_kickoff timestamptz; v_official_window boolean;
  v_complete text[]; r record; v_pid text; v_state futbeat_private.lineup_player_alerts;
  v_official boolean; v_name text; v_team text; v_key text; v_msg jsonb; v_sent integer:=0;
begin
  select payload into v_match from futbeat_private.entities where id=p_match_id and kind='match';
  v_kickoff:=nullif(v_match->>'startTime','')::timestamptz;
  if v_kickoff is null or p_payload is null then return 0; end if;
  -- Official only inside the lineup window, for a fresh observation of a
  -- match that is not over. Earlier = probable; later / replayed = history.
  v_official_window:=p_fetched_at>=v_kickoff-make_interval(mins=>futbeat_private.quota_setting(
      'goal_api','officialLineupMinutes',75)::integer)
    and p_fetched_at<=v_kickoff+make_interval(mins=>futbeat_private.quota_setting(
      'goal_api','lineupAlertLateMinutes',20)::integer)
    and p_fetched_at>=now()-interval '30 minutes'
    and not futbeat_private.match_effectively_terminal(p_match_id);
  -- A side is official only with a complete XI.
  select coalesce(array_agg(side),'{}') into v_complete from (
    select side from futbeat_private.lineup_player_roles(p_payload)
    where role='starter' and side in ('home','away') and external_id is not null
    group by side having count(distinct external_id)>=11) s;

  for r in
    select distinct on (x.external_id) x.side,x.role,x.external_id
    from futbeat_private.lineup_player_roles(p_payload) x
    where x.external_id is not null and x.side in ('home','away')
    order by x.external_id,(x.role='starter') desc
  loop
    -- Canonical identity only (never a name).
    select futbeat_private.futbeat_resolve_entity_id('player',pe.canonical_id) into v_pid
    from futbeat_private.provider_entities pe
    where pe.provider='goal_api' and pe.kind='player' and pe.external_id=r.external_id;
    continue when v_pid is null
      or not exists(select 1 from futbeat_private.entities e where e.id=v_pid and e.kind='player');
    v_official:=v_official_window and r.side=any(v_complete);

    insert into futbeat_private.lineup_player_alerts as a(
      match_id,player_id,role,official,first_seen_at,updated_at)
    values(p_match_id,v_pid,r.role,v_official,p_fetched_at,p_fetched_at)
    on conflict(match_id,player_id) do update set
      role=excluded.role,
      official=a.official or excluded.official,
      updated_at=greatest(a.updated_at,excluded.updated_at)
    where excluded.updated_at>=a.updated_at
    returning * into v_state;
    continue when v_state is null or not v_official;
    -- Once per role, and at most one correction (starter/bench storms).
    continue when r.role=any(v_state.notified_roles) or cardinality(v_state.notified_roles)>=2;

    select nullif(btrim(payload->>'name'),'') into v_name
    from futbeat_private.entities where id=v_pid and kind='player';
    continue when v_name is null;
    select payload->>'name' into v_team from futbeat_private.entities
    where id=futbeat_private.futbeat_resolve_entity_id('team',
      v_match->>case r.side when 'home' then 'homeTeamId' else 'awayTeamId' end);
    v_key:='lineup:'||p_match_id||':'||v_pid||':'||r.role;
    v_msg:=jsonb_build_object(
      'type','LINEUP',
      'title','📋 '||case r.role when 'starter' then v_name||' es titular'
        else v_name||' empieza en el banquillo' end||coalesce(' — '||v_team,''),
      'matchId',p_match_id,'playerId',v_pid,'playerRole',r.role,
      'subjectRefs',jsonb_build_array(jsonb_build_object('type','player','id',v_pid)))
      -- NOTIFICATIONS V2: body and one notification slot per player / match.
      ||jsonb_build_object('body','Alineación confirmada','collapseKey','lineup:'||p_match_id||':'||v_pid)
      ||jsonb_build_object('scopes',jsonb_build_array('player'),'scopeKinds',jsonb_build_object('player',r.role));
    insert into futbeat_private.notification_outbox(notification_key,device_id,user_id,message)
    select v_key,d.id,d.user_id,v_msg
    from futbeat_private.push_devices d
    left join futbeat_private.user_preferences p on p.user_id=d.user_id
    where d.enabled and d.registered_at<=p_fetched_at
      -- LIVE-PRO N1: player-scope switches (legacy notify_lineups / notify_player_starter|bench by default).
      and futbeat_private.notify_allowed_p(to_jsonb(p),'player',case r.role when 'starter' then 'starter' else 'bench' end)
      and exists(select 1 from futbeat_private.push_follows f
        where f.user_id=d.user_id and f.entity_type='player' and f.entity_id=v_pid
          and f.created_at<=p_fetched_at)
    on conflict(notification_key,user_id,device_id) do nothing;
    update futbeat_private.lineup_player_alerts
    set notified_roles=array_append(notified_roles,r.role)
    where match_id=p_match_id and player_id=v_pid;
    v_sent:=v_sent+1;
  end loop;
  return v_sent;
end $function$;

CREATE OR REPLACE FUNCTION futbeat_private.enqueue_goal_annulled(p_event_id text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c futbeat_private.canonical_events%rowtype; m jsonb; v_team text; v_home text; v_away text;
  v_score jsonb; v_body text; v_msg jsonb; v_n integer:=0;
  v_delay interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','matchPushMaxDelayMinutes',10)::integer);
  v_window interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','goalAnnulledMaxMinutes',30)::integer);
begin
  select * into c from futbeat_private.canonical_events where id=p_event_id;
  if not found or c.event_type<>'GOAL' or c.retracted_at is null
     or coalesce(c.retraction_reason,'') not in ('provider_retracted','absent_from_snapshot','score_decrease')
     or c.retracted_at<now()-v_delay then
    return 0;
  end if;
  select payload into m from futbeat_private.entities where id=c.match_id and kind='match';
  if m is null then return 0; end if;
  select payload->>'name' into v_team from futbeat_private.entities where id=c.payload->>'teamId' and kind='team';
  select payload->>'name' into v_home from futbeat_private.entities where id=m->>'homeTeamId';
  select payload->>'name' into v_away from futbeat_private.entities where id=m->>'awayTeamId';
  select jsonb_build_object('home',s.home_score,'away',s.away_score) into v_score
  from futbeat_private.live_match_state s where s.canonical_match_id=c.match_id
  order by s.last_seen_at desc limit 1;
  if v_home is not null and v_away is not null then
    v_body:=v_home||coalesce(' '||(v_score->>'home')||'-'||(v_score->>'away')||' ',' vs ')||v_away;
  end if;
  v_msg:=jsonb_strip_nulls(jsonb_build_object('type','GOAL_ANNULLED',
    'title','❌ Gol anulado'||coalesce(' — '||v_team,''),'body',v_body,
    'eventId',c.id,'annulsEventId',c.id,'matchId',c.match_id,'collapseKey',c.id));
  insert into futbeat_private.notification_outbox(event_id,notification_key,device_id,user_id,message)
  select null,'annul:'||c.id,o.device_id,o.user_id,
    v_msg||case when o.message->>'playerRole' in ('primary','assist') then
      jsonb_strip_nulls(jsonb_build_object('playerId',o.message->>'playerId',
        'playerRole',o.message->>'playerRole','subjectRefs',o.message->'subjectRefs'))
      else '{}'::jsonb end
      ||case when o.message->>'playerRole'='primary' and pl.name is not null then
        jsonb_build_object('title','❌ Anulado el gol de '||pl.name) else '{}'::jsonb end
      -- LIVE-PRO N1: the annulment travels with the scopes that authorised the goal.
      ||case when o.message ? 'scopes' then jsonb_build_object('scopes',o.message->'scopes',
        'scopeKinds',(select jsonb_object_agg(s,'goal_annulled') from jsonb_array_elements_text(o.message->'scopes') s))
        else '{}'::jsonb end
  from futbeat_private.notification_outbox o
  join futbeat_private.push_devices d on d.id=o.device_id and d.user_id=o.user_id
  left join futbeat_private.user_preferences p on p.user_id=o.user_id
  left join lateral (select nullif(btrim(e.payload->>'name'),'') name from futbeat_private.entities e
    where e.id=o.message->>'playerId' and e.kind='player') pl on true
  where o.event_id=c.id
    and o.state in ('sent','simulated','uncertain','sending')
    and coalesce(o.attempt_at,o.created_at)>=now()-v_window
    and d.enabled
    and case when o.message ? 'scopes' then exists(select 1 from jsonb_array_elements_text(o.message->'scopes') s
        where futbeat_private.notify_allowed_p(to_jsonb(p),s,'goal_annulled'))
      else coalesce(p.notify_goal_annulled,true) end
  on conflict(notification_key,user_id,device_id) do nothing;
  get diagnostics v_n=row_count;
  return v_n;
end $function$;

CREATE OR REPLACE FUNCTION public.futbeat_claim_notifications_v2(p_mode text DEFAULT 'dry_run'::text, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  row record;
  rows jsonb:='[]';
  attempt uuid;
  still_following boolean;
  -- NOTIFICATIONS V2
  v_reason text;
  v_annul boolean;
  v_scanned integer:=0;
  v_push_mode text;
  v_delay interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','matchPushMaxDelayMinutes',10)::integer);
  v_late interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','lineupAlertLateMinutes',20)::integer);
begin
  if p_mode not in ('dry_run','live') then
    raise exception 'Invalid mode';
  end if;
  select mode into v_push_mode from futbeat_private.push_settings where id=true;

  update futbeat_private.notification_outbox
  set state=case when transport_started_at is null then 'pending' else 'uncertain' end,
    finished_at=case when transport_started_at is null then null else now() end,
    attempt_id=case when transport_started_at is null then null else attempt_id end,
    attempt_token=case when transport_started_at is null then null else attempt_token end,
    attempt_at=case when transport_started_at is null then now() else attempt_at end,
    provider_receipt=case when transport_started_at is null then 'VALIDATION_RETRY' else provider_receipt end
  where state='sending'
    and attempt_at<now()-interval '5 minutes';

  for row in
    select
      o.*,
      d.transport,
      d.token,
      d.enabled,
      p.notify_kickoff,p.notify_goals,p.notify_final,p.notify_cards,p.notify_red_cards,
      p.notify_player_sub_out,p.notify_player_sub_in,p.notify_lineups,
      p.notify_player_starter,p.notify_player_bench,p.notify_goal_annulled,
      p.notify_news,p.notify_transfers,
      m.payload as match,
      e.retracted_at as event_retracted_at,
      e.retraction_reason as event_retraction_reason
    from futbeat_private.notification_outbox o
    join futbeat_private.push_devices d
      on d.id=o.device_id and d.user_id=o.user_id
    left join futbeat_private.user_preferences p on p.user_id=o.user_id
    left join futbeat_private.canonical_events e
      -- NOTIFICATIONS V2: a GOAL_ANNULLED row reads its goal.
      on e.id=coalesce(o.event_id,o.message->>'annulsEventId')
    left join futbeat_private.entities m
      on m.id=e.match_id
    where o.state='pending'
      and (o.attempt_at is null or o.attempt_at<now()-interval '1 minute')
      and (d.transport='test' or (p_mode='live' and v_push_mode='live'))
      and not exists(select 1 from futbeat_private.notification_outbox active
        where active.device_id=o.device_id and active.id<>o.id and active.state='sending'
          and o.message ? 'collapseKey'
          and active.message->>'collapseKey'=o.message->>'collapseKey')
    order by o.created_at,o.id
    for update of o,d skip locked
    limit least(greatest(p_limit,1),100)
  loop
    v_scanned:=v_scanned+1;
    -- Any subject carried by the message (#106 player alerts, news,
    -- transfers, lineups) that is still followed keeps the row.
    select exists(
      select 1
      from futbeat_private.push_follows f
      join lateral jsonb_array_elements(
        coalesce(row.message->'subjectRefs','[]'::jsonb)
      ) ref on true
      where f.user_id=row.user_id
        and f.entity_type=ref->>'type'
        and f.entity_id=ref->>'id'
    )
    into still_following;

    -- NOTIFICATIONS V2: a GOAL_ANNULLED row follows its match like the goal.
    v_annul:=row.event_id is null and row.message ? 'annulsEventId';
    if (row.event_id is not null or v_annul) and not still_following then
      select exists(
        select 1
        from futbeat_private.push_follows f
        where f.user_id=row.user_id
          and (
            f.entity_id=row.message->>'matchId'
            or (
              row.match is not null
              and f.entity_id in (
                row.match->>'homeTeamId',
                row.match->>'awayTeamId'
              )
            )
          )
      )
      into still_following;
    end if;

    -- LIVE-PRO N1: scoped rows are revalidated per scope (still followed AND that scope's switch on).
    if row.message ? 'scopes' then
      still_following:=futbeat_private.notification_scopes_ok(row.user_id,row.message,row.match);
    end if;

    -- P0-A: an event retracted before dispatch (annulled goal, deleted card,
    -- score decrease) is never sent; a correction's twin keeps its push.
    -- NOTIFICATIONS V2: one cancellation decision with its reason (receipt).
    v_reason:=case
      when not row.enabled then 'device_disabled'
      when not coalesce(still_following,false) then 'unfollowed'
      when not (row.message ? 'scopes') and row.message->>'type'='KICKOFF' and not coalesce(row.notify_kickoff,true) then 'preference_disabled'
      when not (row.message ? 'scopes') and row.message->>'type'='GOAL' and not coalesce(row.notify_goals,true) then 'preference_disabled'
      when not (row.message ? 'scopes') and row.message->>'type'='FULL_TIME' and not coalesce(row.notify_final,true) then 'preference_disabled'
      when not (row.message ? 'scopes') and row.message->>'type'='RED_CARD' and not (coalesce(row.notify_red_cards,true) and coalesce(row.notify_cards,true)) then 'preference_disabled'
      when not (row.message ? 'scopes') and row.message->>'type'='SUBSTITUTION' and row.message->>'playerRole'='primary'
        and not coalesce(row.notify_player_sub_out,true) then 'preference_disabled'
      when not (row.message ? 'scopes') and row.message->>'type'='SUBSTITUTION' and row.message->>'playerRole'='assist'
        and not coalesce(row.notify_player_sub_in,true) then 'preference_disabled'
      when not (row.message ? 'scopes') and row.message->>'type'='LINEUP' and not (coalesce(row.notify_lineups,true)
        and case row.message->>'playerRole' when 'starter' then coalesce(row.notify_player_starter,true)
          when 'bench' then coalesce(row.notify_player_bench,true) else false end) then 'preference_disabled'
      when not (row.message ? 'scopes') and row.message->>'type'='GOAL_ANNULLED' and not coalesce(row.notify_goal_annulled,true) then 'preference_disabled'
      when row.message->>'type'='NEWS' and not coalesce(row.notify_news,true) then 'preference_disabled'
      when row.message->>'type'='TRANSFER' and not coalesce(row.notify_transfers,true) then 'preference_disabled'
      when row.event_id is not null and row.event_retracted_at is not null
         and coalesce(row.event_retraction_reason,'') not in ('corrected','superseded','legacy_superseded') then 'retracted'
      -- Types no longer pushed (rows queued before this migration).
      when row.event_id is not null and not (row.message ? 'scopes') and not (row.message->>'type' in ('KICKOFF','GOAL','RED_CARD','FULL_TIME')
         or (row.message->>'type'='SUBSTITUTION' and row.message ? 'playerRole')) then 'type_disabled'
      when row.event_id is not null and not (row.message ? 'scopes') and row.message->>'type'='RED_CARD' and row.message ? 'playerRole'
         and row.message->>'playerRole'<>'primary' then 'type_disabled'
      -- An annulment whose goal came back, or whose goal push never left.
      when v_annul and row.event_retracted_at is null then 'restored'
      when v_annul and not exists(select 1 from futbeat_private.notification_outbox g
         where g.event_id=row.message->>'annulsEventId' and g.user_id=row.user_id and g.device_id=row.device_id
           and g.state in ('sent','simulated','uncertain','sending')) then 'goal_not_delivered'
      -- Send-time age: a late match push is worse than none.
      when (row.event_id is not null or v_annul) and row.created_at<now()-v_delay then 'expired'
      when row.notification_key like 'lineup:%' and now()>coalesce((
         select futbeat_private.try_timestamptz(x.payload->>'startTime') from futbeat_private.entities x
         where x.id=row.message->>'matchId' and x.kind='match'),'infinity'::timestamptz)+v_late then 'expired'
    end;
    if v_reason is not null then
      update futbeat_private.notification_outbox
      set state='cancelled',finished_at=now(),provider_receipt=v_reason
      where id=row.id;
      continue;
    end if;

    attempt:=gen_random_uuid();
    update futbeat_private.notification_outbox
    set state='sending',attempt_id=attempt,attempt_at=now(),
      attempt_token=row.token,transport_started_at=null
    where id=row.id;

    rows:=rows||jsonb_build_array(
      jsonb_build_object(
        'id',row.id,
        'deviceId',row.device_id,
        'attemptId',attempt,
        'retryCount',row.retry_count,
        'transport',row.transport,
        'token',row.token,
        'message',row.message
      )
    );
  end loop;

  return jsonb_build_object('rows',rows,'scanned',v_scanned);
end
$function$;

-- Source: live-pro/pl1_apply.sql
-- SHA-256: 7da17c7dc934742f4caf5b9c0361883ff9527b0b0b2eb0ff9f4b9dbece437b8a
alter table futbeat_private.push_settings drop constraint if exists push_settings_mode_check;

alter table futbeat_private.push_settings add constraint push_settings_mode_check check (mode in ('dry_run','pilot','live'));

create table if not exists futbeat_private.push_pilot_devices(
  device_id uuid primary key references futbeat_private.push_devices(id) on delete cascade,
  user_id uuid not null,
  added_at timestamptz not null default now(),
  note text not null check (length(note) between 3 and 120));

alter table futbeat_private.push_pilot_devices enable row level security;

revoke all on futbeat_private.push_pilot_devices from public, anon, authenticated;

-- Deliverable now? test transport always (simulated); real transports only when sending live AND
-- (global live OR pilot + allowlisted device of that same user).
create or replace function futbeat_private.push_deliverable(p_device uuid, p_user uuid, p_transport text, p_mode text)
returns boolean language sql stable security definer set search_path to '' as $f$
  select p_transport = 'test' or (p_mode = 'live' and coalesce((
    select s.mode = 'live' or (s.mode = 'pilot' and exists(select 1 from futbeat_private.push_pilot_devices pp
      where pp.device_id = p_device and pp.user_id = p_user))
    from futbeat_private.push_settings s where s.id), false))
$f$;

revoke all on function futbeat_private.push_deliverable(uuid,uuid,text,text) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.futbeat_claim_notifications_v2(p_mode text DEFAULT 'dry_run'::text, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  row record;
  rows jsonb:='[]';
  attempt uuid;
  still_following boolean;
  -- NOTIFICATIONS V2
  v_reason text;
  v_annul boolean;
  v_scanned integer:=0;
  v_push_mode text;
  v_delay interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','matchPushMaxDelayMinutes',10)::integer);
  v_late interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','lineupAlertLateMinutes',20)::integer);
begin
  if p_mode not in ('dry_run','live') then
    raise exception 'Invalid mode';
  end if;
  select mode into v_push_mode from futbeat_private.push_settings where id=true;

  update futbeat_private.notification_outbox
  set state=case when transport_started_at is null then 'pending' else 'uncertain' end,
    finished_at=case when transport_started_at is null then null else now() end,
    attempt_id=case when transport_started_at is null then null else attempt_id end,
    attempt_token=case when transport_started_at is null then null else attempt_token end,
    attempt_at=case when transport_started_at is null then now() else attempt_at end,
    provider_receipt=case when transport_started_at is null then 'VALIDATION_RETRY' else provider_receipt end
  where state='sending'
    and attempt_at<now()-interval '5 minutes';

  for row in
    select
      o.*,
      d.transport,
      d.token,
      d.enabled,
      p.notify_kickoff,p.notify_goals,p.notify_final,p.notify_cards,p.notify_red_cards,
      p.notify_player_sub_out,p.notify_player_sub_in,p.notify_lineups,
      p.notify_player_starter,p.notify_player_bench,p.notify_goal_annulled,
      p.notify_news,p.notify_transfers,
      m.payload as match,
      e.retracted_at as event_retracted_at,
      e.retraction_reason as event_retraction_reason
    from futbeat_private.notification_outbox o
    join futbeat_private.push_devices d
      on d.id=o.device_id and d.user_id=o.user_id
    left join futbeat_private.user_preferences p on p.user_id=o.user_id
    left join futbeat_private.canonical_events e
      -- NOTIFICATIONS V2: a GOAL_ANNULLED row reads its goal.
      on e.id=coalesce(o.event_id,o.message->>'annulsEventId')
    left join futbeat_private.entities m
      on m.id=e.match_id
    where o.state='pending'
      and (o.attempt_at is null or o.attempt_at<now()-interval '1 minute')
      and futbeat_private.push_deliverable(d.id,d.user_id,d.transport,p_mode)
      and not exists(select 1 from futbeat_private.notification_outbox active
        where active.device_id=o.device_id and active.id<>o.id and active.state='sending'
          and o.message ? 'collapseKey'
          and active.message->>'collapseKey'=o.message->>'collapseKey')
    order by o.created_at,o.id
    for update of o,d skip locked
    limit least(greatest(p_limit,1),100)
  loop
    v_scanned:=v_scanned+1;
    -- Any subject carried by the message (#106 player alerts, news,
    -- transfers, lineups) that is still followed keeps the row.
    select exists(
      select 1
      from futbeat_private.push_follows f
      join lateral jsonb_array_elements(
        coalesce(row.message->'subjectRefs','[]'::jsonb)
      ) ref on true
      where f.user_id=row.user_id
        and f.entity_type=ref->>'type'
        and f.entity_id=ref->>'id'
    )
    into still_following;

    -- NOTIFICATIONS V2: a GOAL_ANNULLED row follows its match like the goal.
    v_annul:=row.event_id is null and row.message ? 'annulsEventId';
    if (row.event_id is not null or v_annul) and not still_following then
      select exists(
        select 1
        from futbeat_private.push_follows f
        where f.user_id=row.user_id
          and (
            f.entity_id=row.message->>'matchId'
            or (
              row.match is not null
              and f.entity_id in (
                row.match->>'homeTeamId',
                row.match->>'awayTeamId'
              )
            )
          )
      )
      into still_following;
    end if;

    -- LIVE-PRO N1: scoped rows are revalidated per scope (still followed AND that scope's switch on).
    if row.message ? 'scopes' then
      still_following:=futbeat_private.notification_scopes_ok(row.user_id,row.message,row.match);
    end if;

    -- P0-A: an event retracted before dispatch (annulled goal, deleted card,
    -- score decrease) is never sent; a correction's twin keeps its push.
    -- NOTIFICATIONS V2: one cancellation decision with its reason (receipt).
    v_reason:=case
      when not row.enabled then 'device_disabled'
      when not coalesce(still_following,false) then 'unfollowed'
      when not (row.message ? 'scopes') and row.message->>'type'='KICKOFF' and not coalesce(row.notify_kickoff,true) then 'preference_disabled'
      when not (row.message ? 'scopes') and row.message->>'type'='GOAL' and not coalesce(row.notify_goals,true) then 'preference_disabled'
      when not (row.message ? 'scopes') and row.message->>'type'='FULL_TIME' and not coalesce(row.notify_final,true) then 'preference_disabled'
      when not (row.message ? 'scopes') and row.message->>'type'='RED_CARD' and not (coalesce(row.notify_red_cards,true) and coalesce(row.notify_cards,true)) then 'preference_disabled'
      when not (row.message ? 'scopes') and row.message->>'type'='SUBSTITUTION' and row.message->>'playerRole'='primary'
        and not coalesce(row.notify_player_sub_out,true) then 'preference_disabled'
      when not (row.message ? 'scopes') and row.message->>'type'='SUBSTITUTION' and row.message->>'playerRole'='assist'
        and not coalesce(row.notify_player_sub_in,true) then 'preference_disabled'
      when not (row.message ? 'scopes') and row.message->>'type'='LINEUP' and not (coalesce(row.notify_lineups,true)
        and case row.message->>'playerRole' when 'starter' then coalesce(row.notify_player_starter,true)
          when 'bench' then coalesce(row.notify_player_bench,true) else false end) then 'preference_disabled'
      when not (row.message ? 'scopes') and row.message->>'type'='GOAL_ANNULLED' and not coalesce(row.notify_goal_annulled,true) then 'preference_disabled'
      when row.message->>'type'='NEWS' and not coalesce(row.notify_news,true) then 'preference_disabled'
      when row.message->>'type'='TRANSFER' and not coalesce(row.notify_transfers,true) then 'preference_disabled'
      when row.event_id is not null and row.event_retracted_at is not null
         and coalesce(row.event_retraction_reason,'') not in ('corrected','superseded','legacy_superseded') then 'retracted'
      -- Types no longer pushed (rows queued before this migration).
      when row.event_id is not null and not (row.message ? 'scopes') and not (row.message->>'type' in ('KICKOFF','GOAL','RED_CARD','FULL_TIME')
         or (row.message->>'type'='SUBSTITUTION' and row.message ? 'playerRole')) then 'type_disabled'
      when row.event_id is not null and not (row.message ? 'scopes') and row.message->>'type'='RED_CARD' and row.message ? 'playerRole'
         and row.message->>'playerRole'<>'primary' then 'type_disabled'
      -- An annulment whose goal came back, or whose goal push never left.
      when v_annul and row.event_retracted_at is null then 'restored'
      when v_annul and not exists(select 1 from futbeat_private.notification_outbox g
         where g.event_id=row.message->>'annulsEventId' and g.user_id=row.user_id and g.device_id=row.device_id
           and g.state in ('sent','simulated','uncertain','sending')) then 'goal_not_delivered'
      -- Send-time age: a late match push is worse than none.
      when (row.event_id is not null or v_annul) and row.created_at<now()-v_delay then 'expired'
      when row.notification_key like 'lineup:%' and now()>coalesce((
         select futbeat_private.try_timestamptz(x.payload->>'startTime') from futbeat_private.entities x
         where x.id=row.message->>'matchId' and x.kind='match'),'infinity'::timestamptz)+v_late then 'expired'
    end;
    if v_reason is not null then
      update futbeat_private.notification_outbox
      set state='cancelled',finished_at=now(),provider_receipt=v_reason
      where id=row.id;
      continue;
    end if;

    attempt:=gen_random_uuid();
    update futbeat_private.notification_outbox
    set state='sending',attempt_id=attempt,attempt_at=now(),
      attempt_token=row.token,transport_started_at=null
    where id=row.id;

    rows:=rows||jsonb_build_array(
      jsonb_build_object(
        'id',row.id,
        'deviceId',row.device_id,
        'attemptId',attempt,
        'retryCount',row.retry_count,
        'transport',row.transport,
        'token',row.token,
        'message',row.message
      )
    );
  end loop;

  return jsonb_build_object('rows',rows,'scanned',v_scanned);
end
$function$;

CREATE OR REPLACE FUNCTION public.futbeat_notification_attempt_valid(p_id uuid, p_attempt uuid, p_token text)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists(select 1 from futbeat_private.notification_outbox o
    join futbeat_private.push_devices d on d.id=o.device_id and d.user_id=o.user_id
    where o.id=p_id and o.attempt_id=p_attempt and o.state='sending'
      and d.enabled and d.token=p_token
      and futbeat_private.push_deliverable(d.id,d.user_id,d.transport,'live'))
$function$;

CREATE OR REPLACE FUNCTION public.futbeat_mark_notification_send_started(p_id uuid, p_attempt uuid, p_token text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare affected integer;
begin
  update futbeat_private.notification_outbox o
  set transport_started_at=now()
  from futbeat_private.push_devices d
  where o.id=p_id and o.attempt_id=p_attempt and o.state='sending'
    and d.id=o.device_id and d.user_id=o.user_id and d.enabled and d.token=p_token
    and o.attempt_token=p_token
    and futbeat_private.push_deliverable(d.id,d.user_id,d.transport,'live');
  get diagnostics affected=row_count;
  return affected=1;
end $function$;

-- Source: live-pro/w2_apply.sql
-- SHA-256: acdbd84bdf488fdbef1a7d327c29090b8be28d996a9a0aaa0a0786c2fce02b8a
create or replace function futbeat_private.wake_push_dispatch()
returns trigger language plpgsql security definer set search_path to '' as $f$
declare last_wake timestamptz; has_jwt boolean;
begin
  if futbeat_private.quota_setting('goal_api','pushWakeEnabled',0)<>1 then return null; end if;
  if not exists(select 1 from new_rows o join futbeat_private.push_devices d on d.id=o.device_id
      where o.state='pending' and (d.transport='test' or (select mode from futbeat_private.push_settings where id)='live')) then
    return null;
  end if;
  select w.last_wake_at into last_wake from futbeat_private.worker_wakeups w where w.trigger='push-dispatch' for update skip locked;
  if not found then
    insert into futbeat_private.worker_wakeups(trigger,last_wake_at,wake_count) values('push-dispatch',now(),1)
    on conflict(trigger) do nothing;
    if not found then return null; end if;   -- a concurrent statement holds it: its wake covers these rows
  elsif last_wake>now()-make_interval(secs=>futbeat_private.quota_setting('goal_api','pushWakeDebounceSeconds',2)) then
    update futbeat_private.worker_wakeups set debounced_count=debounced_count+1 where trigger='push-dispatch';
    return null;                              -- the minute cron (or the next wake) drains it
  else
    update futbeat_private.worker_wakeups set last_wake_at=now(),wake_count=wake_count+1 where trigger='push-dispatch';
  end if;
  if to_regnamespace('net') is null or to_regnamespace('vault') is null then
    update futbeat_private.worker_wakeups set last_result='unavailable' where trigger='push-dispatch';
    return null;
  end if;
  execute $q$select exists(select 1 from vault.secrets where name='futbeat_push_public_jwt')$q$ into has_jwt;
  if not coalesce(has_jwt,false) then
    update futbeat_private.worker_wakeups set last_result='unavailable' where trigger='push-dispatch';
    return null;
  end if;
  execute $q$select net.http_post(
    url:='https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-push-dispatch',
    headers:=jsonb_build_object('Content-Type','application/json',
      'Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_public_jwt'),
      'x-futbeat-scheduler',(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_scheduler_token')),
    body:='{}'::jsonb,timeout_milliseconds:=60000)$q$;
  update futbeat_private.worker_wakeups set last_result='queued' where trigger='push-dispatch';
  return null;
exception when others then
  -- A wake problem must never fail the event write: the minute cron remains.
  return null;
end $f$;

revoke all on function futbeat_private.wake_push_dispatch() from public,anon,authenticated;

drop trigger if exists notification_outbox_wake_dispatch on futbeat_private.notification_outbox;

create trigger notification_outbox_wake_dispatch
after insert on futbeat_private.notification_outbox
referencing new table as new_rows
for each statement execute function futbeat_private.wake_push_dispatch();

-- Source: be18-results/fix_be18b.sql
-- SHA-256: 19b41ca911128d44c55c0ae8b7ff7b68d8ae316a2f2cee5a037ca7957cd00153
CREATE OR REPLACE FUNCTION futbeat_private.reserve_goal_results_date(p_trigger_source text DEFAULT 'supabase-cron'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
declare v_date date; v_id bigint; v_remaining integer; v_used integer;
  v_results_used integer; v_local jsonb; v_attempt integer; v_user_priority boolean:=false;
  v_settled_before integer; v_settled_after integer; v_last_provider timestamptz;
begin
  perform pg_advisory_xact_lock(hashtext('futbeat-provider-quota:goal_api:'||(now() at time zone 'UTC')::date::text));
  -- Retain 90 days, well beyond the 14-day automatic window. Primary key
  -- supports deletion by provider/date; old evidence remains in observations.
  delete from futbeat_private.results_date_attempts
    where provider='goal_api' and provider_date<(now() at time zone 'UTC')::date-90;
  -- Indexed by (provider,provider_date,state); never scans JSON.
  delete from futbeat_private.match_result_reconciliation
    where provider='goal_api' and provider_date<(now() at time zone 'UTC')::date-90;
  delete from futbeat_private.results_date_user_demand
    where provider='goal_api' and requested_at<now()-interval '90 days';

  -- A date a user opened in the last 24h, not yet reserved since that
  -- request and not in provider backoff, jumps the background planner --
  -- but only while the central 'results' quota class allows it, so a flood
  -- of user opens cannot outrun the budget everything else shares.
  select d.provider_date into v_date
  from futbeat_private.results_date_user_demand d
  left join futbeat_private.results_date_attempts a
    on a.provider='goal_api' and a.provider_date=d.provider_date
  where d.provider='goal_api' and d.requested_at>now()-interval '24 hours'
    -- Outside the 90-day retention window, results_date_attempts rows for
    -- this date are deleted every call below, so no backoff could ever
    -- stick and a single stale request would win every reservation.
    and d.provider_date>=(now() at time zone 'UTC')::date-90
    and (a.next_retry_at is null or a.next_retry_at<=now())
    and (a.updated_at is null or a.updated_at<d.requested_at)
  order by d.requested_at desc limit 1;
  if v_date is not null then
    v_user_priority:=true;
    if not coalesce((futbeat_private.quota_decision('goal_api','results-date','results')->>'allowed')::boolean,false) then
      v_date:=null;
      v_user_priority:=false;
    end if;
  end if;

  if v_date is null then
    v_date:=futbeat_private.next_goal_results_candidate();
  end if;
  if v_date is null then return jsonb_build_object('allowed',false,'reason','no_results_due'); end if;
  -- BE18b: progress = rows of the date that became settled (any state but 'unresolved'), not rows
  -- rewritten: a pass that only rewrites the same payloads (two writers on payload.events) is no progress.
  select count(*) into v_settled_before from futbeat_private.match_result_reconciliation
    where provider='goal_api' and provider_date=v_date and state<>'unresolved';
  v_local:=futbeat_private.reconcile_goal_results_local(v_date);
  select count(*) into v_settled_after from futbeat_private.match_result_reconciliation
    where provider='goal_api' and provider_date=v_date and state<>'unresolved';
  select last_attempt_at into v_last_provider from futbeat_private.results_date_attempts
    where provider='goal_api' and provider_date=v_date;
  -- BE16: a partial local pass ('more') finishes locally over the next calls before any provider request.
  -- BE18/BE18b: 'more' defers the provider request only while the local pass promotes finals, or
  -- settles rows within 2 h of the last provider request for the date (bounded: a writer that keeps
  -- reverting rows cannot hold a date away from GOAL). Otherwise the date goes to GOAL.
  if coalesce((v_local->>'resultsComplete')::boolean,false)
     or (coalesce((v_local->>'more')::boolean,false)
       and (coalesce((v_local->>'promoted')::integer,0)>0
         or (v_settled_after>v_settled_before
           and coalesce(v_last_provider,'-infinity'::timestamptz)>now()-interval '2 hours'))) then
    insert into futbeat_private.results_date_attempts(provider,provider_date,last_outcome,next_retry_at,updated_at)
    values('goal_api',v_date,'LOCAL_REPAIRED',now(),now())
    on conflict(provider,provider_date) do update set last_outcome='LOCAL_REPAIRED',
      next_retry_at=now(),updated_at=now();
    return jsonb_build_object('allowed',false,'reason','reconciled_locally','date',v_date,'localRepair',v_local);
  end if;
  select provider_remaining into v_remaining from futbeat_private.provider_call_ledger
    where provider='goal_api' and provider_remaining is not null
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'
    order by coalesce(completed_at,reserved_at) desc,id desc limit 1;
  -- Provider request units of every call (failed paginated calls included).
  select coalesce(sum(futbeat_private.provider_call_units(metadata)),0)::integer
    into v_used from futbeat_private.provider_call_ledger where provider='goal_api'
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  select coalesce(sum(futbeat_private.provider_call_units(metadata)),0)::integer into v_results_used
    from futbeat_private.provider_call_ledger
    where provider='goal_api' and call_kind='results-date'
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  -- A user-priority date already cleared the central 'results' quota class
  -- above; it is not re-gated by the legacy fixed thresholds below, which
  -- remain exactly as they were for the unmodified background path.
  if not v_user_priority and (v_results_used>=60 or v_used>=880 or (v_remaining is not null and v_remaining<=120)) then
    insert into futbeat_private.results_date_attempts(provider,provider_date,last_outcome,next_retry_at)
    values('goal_api',v_date,'QUOTA_DEFERRED',now()+interval '30 minutes')
    on conflict(provider,provider_date) do update set last_outcome='QUOTA_DEFERRED',
      next_retry_at=now()+interval '30 minutes',updated_at=now();
    return jsonb_build_object('allowed',false,'reason','results_quota_guard','localRepair',v_local,
      'usedToday',v_used,'resultsUsedToday',v_results_used,'providerRemaining',v_remaining);
  end if;
  -- BE16: once /results/date capped this date (500 rows, no pagination) only the worker's /fixtures/date
  -- fallback can add results, and the worker skips it at <= 300 remaining. Below that, a call re-reads the
  -- same 500 rows: no request, retry in 30 min (the quota resets at 00:00 UTC).
  if v_remaining is not null and v_remaining<=301 and exists(
      select 1 from futbeat_private.provider_call_ledger l
      where l.provider='goal_api' and l.reserved_at>now()-interval '14 days' and l.call_kind='results-date'
        and l.metadata->>'date'=v_date::text
        and l.metadata->>'truncatedBy' in ('results_cap','fallback_quota')) then
    insert into futbeat_private.results_date_attempts(provider,provider_date,last_outcome,next_retry_at)
    values('goal_api',v_date,'QUOTA_DEFERRED',now()+interval '30 minutes')
    on conflict(provider,provider_date) do update set last_outcome='QUOTA_DEFERRED',
      next_retry_at=now()+interval '30 minutes',updated_at=now();
    return jsonb_build_object('allowed',false,'reason','results_cap_fallback_quota','date',v_date,
      'localRepair',v_local,'providerRemaining',v_remaining);
  end if;
  insert into futbeat_private.results_date_attempts(
    provider,provider_date,last_attempt_at,attempt_count,last_outcome,next_retry_at,updated_at)
  values('goal_api',v_date,now(),1,'RESERVED',now()+futbeat_private.results_retry_delay(v_date,1),now())
  on conflict(provider,provider_date) do update set last_attempt_at=now(),
    attempt_count=futbeat_private.results_date_attempts.attempt_count+1,
    last_outcome='RESERVED',next_retry_at=now()+futbeat_private.results_retry_delay(
      v_date,futbeat_private.results_date_attempts.attempt_count+1),updated_at=now()
  returning attempt_count into v_attempt;
  insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
  values('goal_api','results-date',left(p_trigger_source,40),now(),
    jsonb_build_object('date',v_date,'attempt',v_attempt,'userPriority',v_user_priority)) returning id into v_id;
  return jsonb_build_object('allowed',true,'reservationId',v_id,'date',v_date,
    'attempt',v_attempt,'localRepair',v_local,'providerRemaining',v_remaining,'userPriority',v_user_priority);
end $$
;

-- Source: premium/prod/pb1_apply.sql
-- SHA-256: d6da6df6eeb6936d768eaceaf26091fb92c200a153ff4690d4b0fb160c2cb315
-- Local proposal. Apply only in an approved deployment after staging validation.
CREATE SCHEMA if not exists billing_private;

REVOKE ALL ON SCHEMA billing_private FROM PUBLIC;

CREATE SEQUENCE if not exists billing_private.observation_revision AS bigint;

CREATE TABLE if not exists billing_private.purchases (
  token_hash bytea PRIMARY KEY CHECK (octet_length(token_hash) = 32),
  account_id uuid NOT NULL,
  auth_issuer text NOT NULL,
  package_name text NOT NULL CHECK (package_name = 'com.futbeat.futbeat'),
  product_id text NOT NULL CHECK (product_id = 'futbeat_premium'),
  base_plan_id text NOT NULL CHECK (base_plan_id IN ('monthly', 'yearly')),
  sealed_token bytea NOT NULL CHECK (octet_length(sealed_token) > 28),
  key_version text NOT NULL CHECK (key_version <> ''),
  revision bigint NOT NULL CHECK (revision > 0),
  verified_at timestamptz NOT NULL,
  expires_at timestamptz,
  terminal boolean NOT NULL,
  ack_pending boolean NOT NULL,
  next_check_at timestamptz,
  ack_attempts integer NOT NULL DEFAULT 0,
  ack_due_at timestamptz NOT NULL DEFAULT now(),
  ack_lease_until timestamptz,
  CHECK (NOT terminal OR (expires_at IS NULL AND NOT ack_pending AND next_check_at IS NULL)),
  CHECK (NOT ack_pending OR expires_at IS NOT NULL)
);

ALTER TABLE billing_private.purchases ENABLE ROW LEVEL SECURITY;

CREATE INDEX if not exists purchases_owner ON billing_private.purchases (auth_issuer, account_id);

CREATE INDEX if not exists purchases_due ON billing_private.purchases (next_check_at) WHERE NOT terminal;

CREATE INDEX if not exists purchases_ack_due ON billing_private.purchases (ack_due_at) WHERE ack_pending;

-- Called only after Publisher verification. Revision is reserved before the HTTP call.
-- The worker must commit this transaction before it can send the Play acknowledgement.
create or replace function billing_private.record_observation(observed billing_private.purchases)
RETURNS boolean LANGUAGE sql SET search_path = pg_catalog AS $$
  WITH written AS (
    INSERT INTO billing_private.purchases AS current_purchase
    SELECT (observed).*
    ON CONFLICT (token_hash) DO UPDATE SET
      sealed_token = EXCLUDED.sealed_token,
      key_version = EXCLUDED.key_version,
      revision = EXCLUDED.revision,
      verified_at = EXCLUDED.verified_at,
      expires_at = EXCLUDED.expires_at,
      terminal = EXCLUDED.terminal,
      ack_pending = EXCLUDED.ack_pending AND current_purchase.ack_due_at <> 'infinity',
      next_check_at = EXCLUDED.next_check_at
    WHERE current_purchase.account_id = EXCLUDED.account_id
      AND current_purchase.auth_issuer = EXCLUDED.auth_issuer
      AND current_purchase.package_name = EXCLUDED.package_name
      AND current_purchase.product_id = EXCLUDED.product_id
      AND current_purchase.base_plan_id = EXCLUDED.base_plan_id
      AND NOT current_purchase.terminal
      AND current_purchase.revision < EXCLUDED.revision
    RETURNING 1
  )
  SELECT EXISTS (SELECT 1 FROM written)
$$;

REVOKE ALL ON FUNCTION billing_private.record_observation(billing_private.purchases) FROM PUBLIC;

create or replace function billing_private.replace_purchase(
  observed billing_private.purchases, previous_hash bytea
) RETURNS boolean LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE previous billing_private.purchases;
BEGIN
  IF previous_hash = observed.token_hash OR observed.terminal OR
     observed.expires_at IS NULL OR observed.expires_at <= now() THEN RETURN false; END IF;
  -- Serialize replacements even if the predecessor has never been seen.
  PERFORM pg_advisory_xact_lock(hashtextextended(encode(previous_hash, 'hex'), 0));
  SELECT * INTO previous FROM billing_private.purchases WHERE token_hash = previous_hash FOR UPDATE;
  IF NOT FOUND OR previous.account_id <> observed.account_id OR
     previous.auth_issuer <> observed.auth_issuer OR previous.revision >= observed.revision THEN
    RETURN false;
  END IF;
  IF NOT billing_private.record_observation(observed) THEN RETURN false; END IF;
  UPDATE billing_private.purchases SET terminal = true, revision = observed.revision,
    expires_at = NULL, ack_pending = false, next_check_at = NULL, ack_lease_until = NULL
  WHERE token_hash = previous_hash;
  RETURN true;
END
$$;

REVOKE ALL ON FUNCTION billing_private.replace_purchase(billing_private.purchases, bytea) FROM PUBLIC;

create or replace function billing_private.claim_ack(issuer text, max_jobs integer)
RETURNS SETOF billing_private.purchases LANGUAGE sql SET search_path = pg_catalog AS $$
  WITH due AS (
    SELECT token_hash FROM billing_private.purchases
    WHERE auth_issuer = issuer AND ack_pending AND NOT terminal AND expires_at > now() AND ack_due_at <= now()
      AND (ack_lease_until IS NULL OR ack_lease_until <= now())
    ORDER BY ack_due_at, token_hash
    LIMIT least(greatest(max_jobs, 0), 50) FOR UPDATE SKIP LOCKED
  )
  UPDATE billing_private.purchases p SET ack_lease_until = now() + interval '60 seconds',
    ack_attempts = p.ack_attempts + 1
  FROM due WHERE p.token_hash = due.token_hash RETURNING p.*
$$;

REVOKE ALL ON FUNCTION billing_private.claim_ack(text, integer) FROM PUBLIC;

create or replace function billing_private.finish_ack(hash bytea, attempt integer, succeeded boolean)
RETURNS boolean LANGUAGE sql SET search_path = pg_catalog AS $$
  WITH written AS (
    UPDATE billing_private.purchases SET ack_pending = NOT succeeded,
      ack_lease_until = NULL,
      ack_due_at = CASE WHEN succeeded THEN 'infinity'::timestamptz ELSE
        now() + make_interval(secs => least(300, 5 * power(2, least(attempt, 6)))) END
    WHERE token_hash = hash AND ack_attempts = attempt AND ack_pending AND NOT terminal
      AND ack_lease_until > now()
    RETURNING 1
  )
  SELECT EXISTS (SELECT 1 FROM written)
$$;

REVOKE ALL ON FUNCTION billing_private.finish_ack(bytea, integer, boolean) FROM PUBLIC;

create or replace function billing_private.claim_rechecks(issuer text, max_jobs integer)
RETURNS SETOF billing_private.purchases LANGUAGE sql SET search_path = pg_catalog AS $$
  WITH due AS (
    SELECT token_hash FROM billing_private.purchases
    WHERE auth_issuer = issuer AND NOT terminal AND next_check_at <= now()
    ORDER BY next_check_at, token_hash
    LIMIT least(greatest(max_jobs, 0), 50) FOR UPDATE SKIP LOCKED
  )
  UPDATE billing_private.purchases p SET next_check_at = now() + interval '2 minutes'
  FROM due WHERE p.token_hash = due.token_hash RETURNING p.*
$$;

REVOKE ALL ON FUNCTION billing_private.claim_rechecks(text, integer) FROM PUBLIC;

CREATE TABLE if not exists billing_private.publisher_budget (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  requests timestamptz[] NOT NULL DEFAULT '{}',
  blocked_until timestamptz NOT NULL DEFAULT '-infinity'
);

ALTER TABLE billing_private.publisher_budget ENABLE ROW LEVEL SECURITY;

INSERT INTO billing_private.publisher_budget DEFAULT VALUES ON CONFLICT DO NOTHING;

-- One budget per Publisher quota project; all workers must use this database.
create or replace function billing_private.reserve_publisher(max_per_minute integer)
RETURNS boolean LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE recent timestamptz[];
DECLARE paused_until timestamptz;
DECLARE stamp timestamptz;
BEGIN
  SELECT requests, blocked_until INTO recent, paused_until
    FROM billing_private.publisher_budget WHERE singleton FOR UPDATE;
  stamp := clock_timestamp();
  IF stamp < paused_until THEN RETURN false; END IF;
  recent := ARRAY(SELECT x FROM unnest(recent) x WHERE x > stamp - interval '1 minute');
  IF cardinality(recent) >= least(greatest(max_per_minute, 1), 3000) THEN RETURN false; END IF;
  UPDATE billing_private.publisher_budget SET requests = array_append(recent, stamp) WHERE singleton;
  RETURN true;
END
$$;

REVOKE ALL ON FUNCTION billing_private.reserve_publisher(integer) FROM PUBLIC;

create or replace function billing_private.pause_publisher(seconds integer)
RETURNS void LANGUAGE sql SET search_path = pg_catalog AS $$
  UPDATE billing_private.publisher_budget SET blocked_until = greatest(blocked_until,
    clock_timestamp() + make_interval(secs => greatest(seconds, 1))) WHERE singleton
$$;

REVOKE ALL ON FUNCTION billing_private.pause_publisher(integer) FROM PUBLIC;

-- PREMIUM-PROD additions on top of the Codex ledger (premium-production-ledger.sql, unchanged).
-- Audit trail (no token, no PII beyond the account id), RTDN recheck, account erasure.
CREATE TABLE if not exists billing_private.events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at timestamptz NOT NULL DEFAULT now(),
  token_hash bytea NOT NULL CHECK (octet_length(token_hash) = 32),
  account_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('purchase','recheck','replacement','rtdn','forget')),
  play_state text,
  result text
);

ALTER TABLE billing_private.events ENABLE ROW LEVEL SECURITY;

CREATE INDEX if not exists events_account ON billing_private.events (account_id, at);

create or replace function billing_private.note_event(hash bytea, account uuid, kind text, play_state text, result text)
RETURNS void LANGUAGE sql SET search_path = pg_catalog AS $$
  INSERT INTO billing_private.events(token_hash, account_id, kind, play_state, result)
  VALUES (hash, account, kind, play_state, result);
  DELETE FROM billing_private.events WHERE at < now() - interval '400 days';
$$;

REVOKE ALL ON FUNCTION billing_private.note_event(bytea, uuid, text, text, text) FROM PUBLIC;

-- RTDN: make a known, non-terminal token due now (the service then asks Play).
create or replace function billing_private.mark_recheck(hash bytea)
RETURNS boolean LANGUAGE sql SET search_path = pg_catalog AS $$
  WITH w AS (UPDATE billing_private.purchases SET next_check_at = now()
    WHERE token_hash = hash AND NOT terminal RETURNING account_id)
  INSERT INTO billing_private.events(token_hash, account_id, kind)
  SELECT hash, account_id, 'rtdn' FROM w
  RETURNING true
$$;

REVOKE ALL ON FUNCTION billing_private.mark_recheck(bytea) FROM PUBLIC;

-- Account deletion: rights and sealed tokens are erased (Play keeps billing the subscription until the
-- user cancels it in Play: the app must say so before deleting the account).
create or replace function billing_private.forget_account(account uuid, issuer text)
RETURNS integer LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE n integer;
BEGIN
  DELETE FROM billing_private.purchases WHERE account_id = account AND auth_issuer = issuer;
  GET DIAGNOSTICS n = ROW_COUNT;
  DELETE FROM billing_private.events WHERE account_id = account;
  RETURN n;
END
$$;

REVOKE ALL ON FUNCTION billing_private.forget_account(uuid, text) FROM PUBLIC;

-- Nothing in billing_private is reachable through PostgREST (schema not exposed) or by client roles.
REVOKE ALL ON ALL TABLES IN SCHEMA billing_private FROM PUBLIC;

REVOKE ALL ON ALL SEQUENCES IN SCHEMA billing_private FROM PUBLIC;

DO $r$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON SCHEMA billing_private FROM anon, authenticated;
  END IF;
END $r$;

-- Per-account request limit for verify/restore (protects the shared Publisher budget from one account).
CREATE TABLE if not exists billing_private.request_window (
  account_id uuid PRIMARY KEY,
  window_start timestamptz NOT NULL,
  requests integer NOT NULL
);

ALTER TABLE billing_private.request_window ENABLE ROW LEVEL SECURITY;

create or replace function billing_private.allow_request(account uuid, max_per_minute integer)
RETURNS boolean LANGUAGE sql SET search_path = pg_catalog AS $$
  INSERT INTO billing_private.request_window AS w (account_id, window_start, requests)
  VALUES (account, clock_timestamp(), 1)
  ON CONFLICT (account_id) DO UPDATE SET
    window_start = CASE WHEN w.window_start <= clock_timestamp() - interval '1 minute' THEN clock_timestamp() ELSE w.window_start END,
    requests = CASE WHEN w.window_start <= clock_timestamp() - interval '1 minute' THEN 1 ELSE w.requests + 1 END
  RETURNING requests <= greatest(max_per_minute, 1)
$$;

REVOKE ALL ON FUNCTION billing_private.allow_request(uuid, integer) FROM PUBLIC;

-- Whatever path deletes a Supabase Auth user (app, dashboard, futbeat-delete-account), its billing data goes.
create or replace function billing_private.forget_deleted_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  DELETE FROM billing_private.purchases WHERE account_id = OLD.id;
  DELETE FROM billing_private.events WHERE account_id = OLD.id;
  DELETE FROM billing_private.request_window WHERE account_id = OLD.id;
  RETURN OLD;
END
$$;

REVOKE ALL ON FUNCTION billing_private.forget_deleted_user() FROM PUBLIC;

DO $t$ BEGIN
  IF to_regclass('auth.users') IS NOT NULL THEN
    DROP TRIGGER IF EXISTS futbeat_billing_forget_deleted_user ON auth.users;
    CREATE TRIGGER futbeat_billing_forget_deleted_user AFTER DELETE ON auth.users
      FOR EACH ROW EXECUTE FUNCTION billing_private.forget_deleted_user();
  END IF;
END $t$;

-- Source: live-pro/k2_apply.sql
-- SHA-256: be912438e196b3f41e4fdf927f2c08cdbab64efe6db57a114ac72b05e2849518
-- Base: production bodies read 2026-11-14 21:2xZ (match_detail_planner_due md5 6c725010).
-- Signals already in the database, all aggregated and expiring (no new table, no new counter):
--   P0 = an open Match Center: a source='user' row in match_detail_requests (one row per match,
--        15-min expiry renewed by request_match_detail, deduped per match: repeated opens from one
--        client cannot add weight).
--   P1 = many followers: explicit_followers on the match's teams/competition/match >= liveHotFollowers.
--   P2 = any follower or temporary interest (match_interest_score>0, b11-q1).
--   P3 = no demand.
-- The competition alone is never demand: competition rows count only through their followers.
create or replace function futbeat_private.live_demand_tier(p_match_id text)
returns integer language sql stable security definer set search_path to '' as $f$
  select case
    when exists(select 1 from futbeat_private.match_detail_requests r
      where r.match_id=p_match_id and r.source='user' and r.expires_at>now()) then 0
    when coalesce((select sum(ci.explicit_followers)
      from futbeat_private.entities e
      join futbeat_private.coverage_interests ci
        on (ci.subject_type='team' and ci.subject_id in (e.payload->>'homeTeamId',e.payload->>'awayTeamId'))
        or (ci.subject_type='competition' and ci.subject_id=e.payload->>'competitionId')
        or (ci.subject_type='match' and ci.subject_id=e.id)
      where e.id=p_match_id and e.kind='match' and ci.explicit_followers>0),0)
      >=futbeat_private.quota_setting('goal_api','liveHotFollowers',5) then 1
    when futbeat_private.match_interest_score(p_match_id)>0 then 2
    else 3 end
$f$;

revoke all on function futbeat_private.live_demand_tier(text) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION futbeat_private.match_detail_planner_due(p_match_id text, p_bucket text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare cov futbeat_private.match_detail_coverage; fetched timestamptz; kickoff timestamptz;
  sections jsonb; gap interval; final_after interval; phase text; used integer;
  tier integer; refresh_min numeric;
begin
  if p_bucket is null or p_bucket not in ('live','results','prematch','upcoming','recent_hot','recent','history') then
    return false;
  end if;
  select * into cov from futbeat_private.match_detail_coverage where match_id=p_match_id;
  if coalesce(cov.next_retry_at>now(),false) then return false; end if;
  select c.fetched_at into fetched from futbeat_private.match_detail_cache c where c.match_id=p_match_id;
  -- Hard bound on background work per match and phase (user opens are not
  -- counted): pre-match, LIVE and results attempts never eat the post-match
  -- fetch, and each phase has its own cap.
  phase:=case p_bucket when 'prematch' then 'prematch' when 'live' then 'live'
    when 'results' then 'results' else 'finished' end;
  -- LIVE-PRO K2: demand tier read once per call (LIVE bucket only).
  if p_bucket='live' then tier:=futbeat_private.live_demand_tier(p_match_id); end if;
  select count(*) into used from futbeat_private.provider_call_ledger l
  where l.call_kind='match-detail' and l.metadata->>'matchId'=p_match_id
    and l.reserved_at>now()-interval '1 day' and coalesce(l.metadata->>'source','')<>'user'
    and case coalesce(l.metadata->>'bucket','') when 'prematch' then 'prematch' when 'live' then 'live'
      when 'results' then 'results' when 'recovery' then 'recovery' else 'finished' end=phase;
  -- B11-Q1: followed matches (coverage_interests) keep the deeper per-phase limits.
  if used>=(case phase
      when 'prematch' then case when futbeat_private.match_interest_score(p_match_id)>0
        then futbeat_private.quota_setting('goal_api','plannerMaxPrematchFetchesFollowed',3)
        else futbeat_private.quota_setting('goal_api','plannerMaxPrematchFetches',3) end
      when 'live' then case
        when tier<=1
          then futbeat_private.quota_setting('goal_api','plannerMaxLiveFetchesHot',
            futbeat_private.quota_setting('goal_api','plannerMaxLiveFetchesFollowed',6))
        when futbeat_private.match_interest_score(p_match_id)>0
        then futbeat_private.quota_setting('goal_api','plannerMaxLiveFetchesFollowed',6)
        else futbeat_private.quota_setting('goal_api','plannerMaxLiveFetches',6) end
      when 'results' then futbeat_private.quota_setting('goal_api','plannerMaxResultFetches',2)
      else futbeat_private.quota_setting('goal_api','plannerMaxFetchesPerMatchDay',4) end) then
    return false;
  end if;
  if fetched is null then return true; end if;
  if p_bucket='results' then
    return futbeat_private.match_detail_due('FINISHED_PENDING_VERIFICATION',fetched);
  end if;
  if p_bucket='upcoming' then return false; end if;
  if p_bucket='live' then
    -- LIVE-PRO K2: the periodic LIVE refresh follows demand (live_demand_tier).
    -- Score, status, goals and cards come from the shared /fixtures/live feed for
    -- every match; this per-match call only adds lineups/statistics. P3 (nobody
    -- follows it, nobody has it open) gets no periodic refresh once
    -- plannerLiveRefreshUnfollowed=0; P1/P2 refresh faster. With the K2 keys
    -- absent every default equals the previous behaviour (30 min for all).
    refresh_min:=case
      when tier<=1 then futbeat_private.quota_setting('goal_api','plannerLiveRefreshMinutesHot',
        futbeat_private.quota_setting('goal_api','plannerLiveRefreshMinutes',30))
      when tier=2 then futbeat_private.quota_setting('goal_api','plannerLiveRefreshMinutesFollowed',
        futbeat_private.quota_setting('goal_api','plannerLiveRefreshMinutes',30))
      when futbeat_private.quota_setting('goal_api','plannerLiveRefreshUnfollowed',1)=1
        then futbeat_private.quota_setting('goal_api','plannerLiveRefreshMinutes',30)
      else null end;
    return coalesce((coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN'
        and fetched<now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','liveRetryMinutes',5)::integer))
      -- Periodic refresh only while the provider budget is comfortable.
      or (refresh_min is not null and fetched<now()-make_interval(mins=>refresh_min::integer)
        and futbeat_private.detail_planner_band()->>'band' in ('abundant','normal')),false);
  end if;
  sections:=futbeat_private.match_detail_sections(p_match_id);
  if sections is null then return false; end if;
  gap:=make_interval(secs=>(sections->>'retryGap')::double precision);
  if p_bucket='prematch' then
    return coalesce((sections->>'lineupWanted')::boolean and coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN'
      and fetched<now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','prematchRetryMinutes',20)::integer),false);
  end if;
  -- Finished: one post-match fetch, then only missing sections / due rechecks.
  select nullif(e.payload->>'startTime','')::timestamptz into kickoff
  from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
  final_after:=make_interval(mins=>futbeat_private.quota_setting('goal_api','finalFetchAfterMinutes',120)::integer);
  if kickoff is not null and now()>=kickoff+final_after and fetched<kickoff+final_after then
    return true;
  end if;
  return coalesce(fetched<now()-gap and (
    coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN' or coalesce(cov.statistics_state,'UNKNOWN')='UNKNOWN'
    -- A NO_DATA without a recheck time (older rows) is never rechecked.
    or (cov.lineup_state='NO_DATA' and coalesce(cov.lineup_recheck_at,'infinity')<=now())
    or (cov.statistics_state='NO_DATA' and coalesce(cov.statistics_recheck_at,'infinity')<=now())),false);
end $function$;

update futbeat_private.provider_quota_policy
set freshness=freshness||'{"plannerMaxLiveFetches":2,"plannerMaxLiveFetchesFollowed":12}'::jsonb||'{"plannerMaxLiveFetchesHot":24,"plannerLiveRefreshMinutesHot":5,"plannerLiveRefreshMinutesFollowed":10,"plannerLiveRefreshUnfollowed":0,"liveHotFollowers":5}'::jsonb,updated_at=now()
where provider='goal_api';

-- Source: id-split/guard/guard_apply.sql
-- SHA-256: 597916e43353c6884318bffc2d9e47b7453b1b610b5fe785c53f04abc49d125e
CREATE OR REPLACE FUNCTION futbeat_private.resolve_global_entity_before_player_lock(p_provider text, p_kind text, p_external text, p_name text DEFAULT ''::text, p_country text DEFAULT ''::text, p_short_name text DEFAULT ''::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  result text;
  matched text;
  matches integer;
begin
  if p_provider not in ('sofascore','espn','goal_api')
     or p_kind not in ('competition','team','match','player')
     or nullif(p_external,'') is null
  then
    raise exception 'Invalid global provider identity';
  end if;

  select canonical_id into result
  from futbeat_private.provider_entities
  where provider=p_provider
    and kind=p_kind
    and external_id=p_external;

  if result is not null then
    return futbeat_private.futbeat_resolve_entity_id(p_kind,result);
  end if;

  if p_kind in ('competition','team') and nullif(p_name,'') is not null then
    select count(*),min(e.id)
    into matches,matched
    from futbeat_private.entities e
    where e.kind=p_kind
      and not exists(
        select 1
        from futbeat_private.entity_redirects r
        where r.alias_id=e.id and r.kind=p_kind
      )
      -- ID-GUARD: a provider never has two ids for one club. A name never attaches a new id of a provider to an
      -- entity that already holds an id of that same provider and kind (homonyms: Arsenal, Barcelona, Liverpool...).
      and not exists(
        select 1 from futbeat_private.provider_entities pe0
        where pe0.canonical_id=e.id and pe0.provider=p_provider and pe0.kind=p_kind
      )
      and (
        lower(coalesce(e.payload->>'name',''))=lower(p_name)
        or (
          nullif(p_short_name,'') is not null
          and lower(coalesce(e.payload->>'shortName',''))=lower(p_short_name)
        )
        or exists(
          select 1
          from jsonb_array_elements_text(
            case
            when jsonb_typeof(e.payload->'aliases')='array'
              then e.payload->'aliases'
            else '[]'::jsonb
          end
          ) a(value)
          where lower(a.value)=lower(p_name)
        )
      )
      and (
        nullif(p_country,'') is null
        or nullif(e.payload->>'country','') is null
        or lower(e.payload->>'country')=lower(p_country)
      );

    if matches=1 then
      result:=futbeat_private.futbeat_resolve_entity_id(p_kind,matched);
    end if;
  end if;

  if result is null then
    result:='fb_' || p_kind || '_' || replace(gen_random_uuid()::text,'-','');
    insert into futbeat_private.entities(id,kind,payload)
    values(
      result,
      p_kind,
      jsonb_build_object(
        'id',result,
        'name',coalesce(p_name,''),
        'country',coalesce(p_country,''),
        'shortName',coalesce(p_short_name,'')
      )
    )
    on conflict(id) do nothing;
  end if;

  insert into futbeat_private.provider_entities(
    provider,kind,external_id,canonical_id
  )
  values(p_provider,p_kind,p_external,result)
  on conflict(provider,kind,external_id)
  do update set canonical_id=excluded.canonical_id;

  return result;
end
$function$
;

-- Source: cov-planner/cov_apply.sql
-- SHA-256: 600e48700f5de52b6aa64e85a2090374d19db5f32faf439f5457ddbee64650ba
create table if not exists futbeat_private.central_coverage_log(
  day date not null,
  kind text not null check (kind in ('standings','team')),
  enqueued integer not null default 0 check (enqueued>=0),
  runs integer not null default 0,
  last_run_at timestamptz,
  last_result jsonb,
  primary key(day,kind));

revoke all on futbeat_private.central_coverage_log from public;

do $r$ begin
  if exists(select 1 from pg_roles where rolname='anon') then execute 'revoke all on futbeat_private.central_coverage_log from anon, authenticated'; end if;
end $r$;

update futbeat_private.provider_quota_policy
set freshness=freshness||jsonb_build_object(
  'centralCoverageEnabled',1,
  'centralStandingsDaily',100,         -- under kind cap standings=120
  'centralStandingsOpen',4,            -- queued standings demands kept open at once
  'centralStandingsHorizonHours',72,   -- competitions with matches in [-24 h, +72 h]
  'centralTeamsDaily',25,              -- under kind cap team-fixtures=60 units (~1-2 units per team)
  'centralTeamsOpen',6,
  'centralTeamHorizonHours',48,        -- teams playing in the next 48 h
  'centralTeamRefreshDays',3),         -- one history fetch per team per 3 days at most
  updated_at=now()
where provider='goal_api';

create or replace function futbeat_private.plan_central_coverage(p_dry boolean default false)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare
  f jsonb:=(select freshness from futbeat_private.provider_quota_policy where provider='goal_api');
  enabled boolean:=coalesce((f->>'centralCoverageEnabled')::integer,0)=1;
  st_daily integer:=coalesce((f->>'centralStandingsDaily')::integer,100);
  st_open integer:=coalesce((f->>'centralStandingsOpen')::integer,4);
  st_h integer:=coalesce((f->>'centralStandingsHorizonHours')::integer,72);
  tm_daily integer:=coalesce((f->>'centralTeamsDaily')::integer,25);
  tm_open integer:=coalesce((f->>'centralTeamsOpen')::integer,6);
  tm_h integer:=coalesce((f->>'centralTeamHorizonHours')::integer,48);
  tm_days integer:=coalesce((f->>'centralTeamRefreshDays')::integer,3);
  today date:=(now() at time zone 'UTC')::date;
  st_used integer; tm_used integer; st_now integer; tm_now integer; st_take integer; tm_take integer;
  st_pick jsonb:='[]'; tm_pick jsonb:='[]'; r record; n_st integer:=0; n_tm integer:=0; woke text;
begin
  if not enabled and not p_dry then return jsonb_build_object('enabled',false); end if;
  if not pg_catalog.pg_try_advisory_xact_lock(hashtext('futbeat-central-coverage')) then
    return jsonb_build_object('skipped','locked'); end if;
  select coalesce(sum(enqueued) filter(where kind='standings'),0),coalesce(sum(enqueued) filter(where kind='team'),0)
    into st_used,tm_used from futbeat_private.central_coverage_log where day=today;
  select count(*) into st_now from futbeat_private.standings_demands where status='QUEUED';
  select count(*) into tm_now from futbeat_private.team_match_demands d
    left join futbeat_private.team_match_coverage c on c.team_id=d.team_id
    where d.requested_at>now()-interval '7 days' and d.requested_at>coalesce(c.last_attempt_at,'-infinity');
  st_take:=greatest(0,least(st_open-st_now,st_daily-st_used));
  tm_take:=greatest(0,least(tm_open-tm_now,tm_daily-tm_used));

  -- STANDINGS: one (competition, season) per GOAL call; all phases/groups come in that one table.
  if st_take>0 then
    with m as (
      select cm.match_id,cm.start_time,e.payload p,
        futbeat_private.futbeat_resolve_entity_id('competition',e.payload->>'competitionId') comp
      from futbeat_private.calendar_matches cm
      join futbeat_private.entities e on e.id=cm.match_id and e.kind='match'
      where cm.start_time between now()-interval '24 hours' and now()+make_interval(hours=>st_h)),
    rep as (
      select distinct on (p->>'competitionId',coalesce(p->>'season','')) match_id,
        count(*) over (partition by p->>'competitionId',coalesce(p->>'season','')) n_near
      from m order by p->>'competitionId',coalesce(p->>'season',''),start_time,match_id),
    st as (select rep.match_id,rep.n_near,futbeat_private.match_standings_state(rep.match_id) s from rep),
    cand as (
      select st.match_id,st.n_near,st.s->>'competitionId' comp,st.s->>'seasonKey' skey,st.s->>'externalLeagueId' ext,
        st.s->>'standings' state, snap.fetched_at
      from st left join futbeat_private.standings_snapshots snap
        on snap.competition_id=st.s->>'competitionId' and snap.season_key=st.s->>'seasonKey'
      where coalesce((st.s->>'due')::boolean,false) and coalesce((st.s->>'fetchable')::boolean,false)
        and coalesce(st.s->>'demandStatus','')<>'QUEUED'
        -- a table we have is refreshed only after a match of that competition has been played since
        and (snap.competition_id is null or exists(
          select 1 from m m2 where m2.comp=st.s->>'competitionId'
            and m2.start_time>snap.fetched_at-interval '2 hours' and m2.start_time<now()-interval '2 hours'))),
    scored as (
      -- Strict tiers (never additive with the aggregate demand score): followed competition, then a followed team
      -- plays in it, then no table at all; inside a tier, aggregated user demand, then near matches.
      select cand.*,
        (case when exists(select 1 from futbeat_private.coverage_interests ci where ci.subject_type='competition'
               and ci.subject_id=cand.comp and ci.explicit_followers>0) then 4 else 0 end
        + case when exists(select 1 from m join futbeat_private.coverage_interests ci on ci.subject_type='team'
               and ci.explicit_followers>0 and ci.subject_id in (m.p->>'homeTeamId',m.p->>'awayTeamId')
               where m.comp=cand.comp) then 2 else 0 end
        + case when cand.fetched_at is null then 1 else 0 end) tier,
        coalesce((select ci.priority_score from futbeat_private.coverage_interests ci
            where ci.subject_type='competition' and ci.subject_id=cand.comp),0) prio
      from cand)
    select coalesce(jsonb_agg(jsonb_build_object('competitionId',comp,'seasonKey',skey,'externalLeagueId',ext,
        'state',state,'tier',tier,'priority',prio,'nearMatches',n_near) order by tier desc,prio desc,n_near desc,comp),'[]')
      into st_pick
    from (select * from scored order by tier desc,prio desc,n_near desc,comp limit st_take) x;

    if not p_dry then
      for r in select * from jsonb_to_recordset(st_pick) as x("competitionId" text,"seasonKey" text,"externalLeagueId" text) loop
        perform pg_catalog.pg_advisory_xact_lock(hashtext('futbeat-standings-demand'),hashtext(r."competitionId"||'|'||r."seasonKey"));
        -- Same upsert as futbeat_request_match_standings__ungated, without the wake (detail-cron drains it each minute).
        insert into futbeat_private.standings_demands(competition_id,season_key,external_league_id,queued_at)
        values(r."competitionId",r."seasonKey",r."externalLeagueId",now())
        on conflict(competition_id,season_key) do update set
          request_count=futbeat_private.standings_demands.request_count+1,
          requested_at=now(),external_league_id=excluded.external_league_id,
          queued_at=case when futbeat_private.standings_demands.status='QUEUED'
            then futbeat_private.standings_demands.queued_at else now() end,
          failure_count=case when futbeat_private.standings_demands.status='QUEUED'
            then futbeat_private.standings_demands.failure_count else 0 end,
          status='QUEUED'
        where futbeat_private.standings_demands.status<>'QUEUED';
        if found then n_st:=n_st+1; end if;
      end loop;
    end if;
  end if;

  -- TEAM HISTORY (feeds H2H and profile results): teams playing soon, never fetched or older than tm_days.
  if tm_take>0 then
    with m as (
      select cm.match_id,cm.start_time,e.payload p from futbeat_private.calendar_matches cm
      join futbeat_private.entities e on e.id=cm.match_id and e.kind='match'
      where cm.start_time between now() and now()+make_interval(hours=>tm_h)),
    t as (
      select x.tid,min(m.start_time) kickoff,
        bool_or(exists(select 1 from futbeat_private.coverage_interests ci where ci.subject_type='competition'
          and ci.explicit_followers>0 and ci.subject_id=futbeat_private.futbeat_resolve_entity_id('competition',m.p->>'competitionId'))) comp_followed
      from m, lateral (values (futbeat_private.futbeat_resolve_entity_id('team',nullif(m.p->>'homeTeamId',''))),
                              (futbeat_private.futbeat_resolve_entity_id('team',nullif(m.p->>'awayTeamId','')))) x(tid)
      where x.tid is not null group by x.tid),
    cand as (
      select t.*,c.last_attempt_at,c.next_retry_at,c.lease_until,futbeat_private.team_match_coverage_state(t.tid)->>'state' state
      from t left join futbeat_private.team_match_coverage c on c.team_id=t.tid
      where exists(select 1 from futbeat_private.entities te where te.id=t.tid and te.kind='team')
        -- exactly one GOAL team id: a canonical holding several clubs (homonym merge) is never fetched until split
        and cardinality(futbeat_private.team_goal_external_ids(t.tid,2))=1
        and coalesce(c.lease_until,'-infinity')<=now() and coalesce(c.next_retry_at,'-infinity')<=now()
        and (c.team_id is null or coalesce(c.last_attempt_at,'-infinity')<now()-make_interval(days=>tm_days))
        and not exists(select 1 from futbeat_private.team_match_demands d where d.team_id=t.tid
          and d.requested_at>now()-interval '7 days' and d.requested_at>coalesce(c.last_attempt_at,'-infinity'))),
    scored as (
      select cand.*,
        (case when exists(select 1 from futbeat_private.coverage_interests ci where ci.subject_type='team'
          and ci.subject_id=cand.tid and ci.explicit_followers>0) then 4 else 0 end
        + case when cand.comp_followed then 2 else 0 end
        + case when cand.kickoff<now()+interval '24 hours' then 1 else 0 end) tier,
        coalesce((select ci.priority_score from futbeat_private.coverage_interests ci
            where ci.subject_type='team' and ci.subject_id=cand.tid),0) prio
      from cand where cand.state in ('PENDING','STALE'))
    select coalesce(jsonb_agg(jsonb_build_object('teamId',tid,'state',state,'tier',tier,'priority',prio,'kickoff',kickoff)
        order by tier desc,prio desc,kickoff,tid),'[]')
      into tm_pick
    from (select * from scored order by tier desc,prio desc,kickoff,tid limit tm_take) x;

    if not p_dry then
      for r in select * from jsonb_to_recordset(tm_pick) as x("teamId" text) loop
        perform pg_catalog.pg_advisory_xact_lock(hashtext('futbeat-team-match-demand'),hashtext(r."teamId"));
        insert into futbeat_private.team_match_demands as d(team_id,reason) values(r."teamId",'central')
        on conflict(team_id) do update set requested_at=now(),request_count=d.request_count+1,reason='central'
          where d.requested_at<now()-interval '1 minute';
        if found then n_tm:=n_tm+1; end if;
      end loop;
      if n_tm>0 then woke:=futbeat_private.wake_provider_worker('team-fixtures-only'); end if;
    end if;
  end if;

  if not p_dry then
    insert into futbeat_private.central_coverage_log as l(day,kind,enqueued,runs,last_run_at,last_result)
    values(today,'standings',n_st,1,now(),st_pick),(today,'team',n_tm,1,now(),tm_pick)
    on conflict(day,kind) do update set enqueued=l.enqueued+excluded.enqueued,runs=l.runs+1,
      last_run_at=now(),last_result=excluded.last_result;
    if n_st>0 then perform futbeat_private.bump_metric('central_standings_enqueued',n_st); end if;
    if n_tm>0 then perform futbeat_private.bump_metric('central_team_enqueued',n_tm); end if;
  end if;
  return jsonb_build_object('enabled',enabled,'dry',p_dry,
    'standings',jsonb_build_object('usedToday',st_used,'open',st_now,'take',st_take,'enqueued',n_st,'picked',st_pick),
    'teams',jsonb_build_object('usedToday',tm_used,'open',tm_now,'take',tm_take,'enqueued',n_tm,'picked',tm_pick,'wake',woke));
end $f$;

revoke all on function futbeat_private.plan_central_coverage(boolean) from public;

do $r$ begin
  if exists(select 1 from pg_roles where rolname='anon') then
    execute 'revoke all on function futbeat_private.plan_central_coverage(boolean) from anon, authenticated, service_role'; end if;
end $r$;

do $schedule$ begin if to_regnamespace('cron') is not null then perform cron.schedule('futbeat-central-coverage','4,19,34,53 * * * *',$c$select futbeat_private.plan_central_coverage()$c$); end if; end $schedule$;

-- Source: cov-planner/cov1b_apply.sql
-- SHA-256: 13fb973feff72726198e518fcde0eea701918dc68b67dba7fc25581c9f870707
CREATE OR REPLACE FUNCTION futbeat_private.plan_central_coverage(p_dry boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  f jsonb:=(select freshness from futbeat_private.provider_quota_policy where provider='goal_api');
  enabled boolean:=coalesce((f->>'centralCoverageEnabled')::integer,0)=1;
  st_daily integer:=coalesce((f->>'centralStandingsDaily')::integer,100);
  st_open integer:=coalesce((f->>'centralStandingsOpen')::integer,4);
  st_h integer:=coalesce((f->>'centralStandingsHorizonHours')::integer,72);
  tm_daily integer:=coalesce((f->>'centralTeamsDaily')::integer,25);
  tm_open integer:=coalesce((f->>'centralTeamsOpen')::integer,6);
  tm_h integer:=coalesce((f->>'centralTeamHorizonHours')::integer,48);
  tm_days integer:=coalesce((f->>'centralTeamRefreshDays')::integer,3);
  today date:=(now() at time zone 'UTC')::date;
  st_used integer; tm_used integer; st_now integer; tm_now integer; st_take integer; tm_take integer;
  st_pick jsonb:='[]'; tm_pick jsonb:='[]'; r record; n_st integer:=0; n_tm integer:=0; woke text;
begin
  if not enabled and not p_dry then return jsonb_build_object('enabled',false); end if;
  if not pg_catalog.pg_try_advisory_xact_lock(hashtext('futbeat-central-coverage')) then
    return jsonb_build_object('skipped','locked'); end if;
  select coalesce(sum(enqueued) filter(where kind='standings'),0),coalesce(sum(enqueued) filter(where kind='team'),0)
    into st_used,tm_used from futbeat_private.central_coverage_log where day=today;
  select count(*) into st_now from futbeat_private.standings_demands where status='QUEUED';
  select count(*) into tm_now from futbeat_private.team_match_demands d
    left join futbeat_private.team_match_coverage c on c.team_id=d.team_id
    where d.requested_at>now()-interval '7 days' and d.requested_at>coalesce(c.last_attempt_at,'-infinity');
  st_take:=greatest(0,least(st_open-st_now,st_daily-st_used));
  tm_take:=greatest(0,least(tm_open-tm_now,tm_daily-tm_used));

  -- STANDINGS: one (competition, season) per GOAL call; all phases/groups come in that one table.
  if st_take>0 then
    with m as (
      select cm.match_id,cm.start_time,e.payload p,
        futbeat_private.futbeat_resolve_entity_id('competition',e.payload->>'competitionId') comp
      from futbeat_private.calendar_matches cm
      join futbeat_private.entities e on e.id=cm.match_id and e.kind='match'
      where cm.start_time between now()-interval '24 hours' and now()+make_interval(hours=>st_h)),
    rep as (
      select distinct on (p->>'competitionId',coalesce(p->>'season','')) match_id,
        count(*) over (partition by p->>'competitionId',coalesce(p->>'season','')) n_near
      from m order by p->>'competitionId',coalesce(p->>'season',''),start_time,match_id),
    st as (select rep.match_id,rep.n_near,futbeat_private.match_standings_state(rep.match_id) s from rep),
    cand as (
      select st.match_id,st.n_near,st.s->>'competitionId' comp,st.s->>'seasonKey' skey,st.s->>'externalLeagueId' ext,
        st.s->>'standings' state, snap.fetched_at
      from st left join futbeat_private.standings_snapshots snap
        on snap.competition_id=st.s->>'competitionId' and snap.season_key=st.s->>'seasonKey'
      where coalesce((st.s->>'due')::boolean,false) and coalesce((st.s->>'fetchable')::boolean,false)
        and coalesce(st.s->>'demandStatus','')<>'QUEUED'
        -- COV-1b: a table the existing store rejected (FETCH_FAILED) is not asked again for 7 days
        and not exists(select 1 from futbeat_private.standings_demands sd where sd.competition_id=st.s->>'competitionId'
          and sd.season_key=st.s->>'seasonKey' and sd.status='FETCH_FAILED'
          and coalesce(sd.last_attempt_at,'-infinity')>now()-interval '7 days')
        -- a table we have is refreshed only after a match of that competition has been played since
        and (snap.competition_id is null or exists(
          select 1 from m m2 where m2.comp=st.s->>'competitionId'
            and m2.start_time>snap.fetched_at-interval '2 hours' and m2.start_time<now()-interval '2 hours'))),
    scored as (
      -- Strict tiers (never additive with the aggregate demand score): followed competition, then a followed team
      -- plays in it, then no table at all; inside a tier, aggregated user demand, then near matches.
      select cand.*,
        (case when exists(select 1 from futbeat_private.coverage_interests ci where ci.subject_type='competition'
               and ci.subject_id=cand.comp and ci.explicit_followers>0) then 4 else 0 end
        + case when exists(select 1 from m join futbeat_private.coverage_interests ci on ci.subject_type='team'
               and ci.explicit_followers>0 and ci.subject_id in (m.p->>'homeTeamId',m.p->>'awayTeamId')
               where m.comp=cand.comp) then 2 else 0 end
        + case when cand.fetched_at is null then 1 else 0 end) tier,
        coalesce((select ci.priority_score from futbeat_private.coverage_interests ci
            where ci.subject_type='competition' and ci.subject_id=cand.comp),0) prio
      from cand)
    select coalesce(jsonb_agg(jsonb_build_object('competitionId',comp,'seasonKey',skey,'externalLeagueId',ext,
        'state',state,'tier',tier,'priority',prio,'nearMatches',n_near) order by tier desc,prio desc,n_near desc,comp),'[]')
      into st_pick
    from (select * from scored order by tier desc,prio desc,n_near desc,comp limit st_take) x;

    if not p_dry then
      for r in select * from jsonb_to_recordset(st_pick) as x("competitionId" text,"seasonKey" text,"externalLeagueId" text) loop
        perform pg_catalog.pg_advisory_xact_lock(hashtext('futbeat-standings-demand'),hashtext(r."competitionId"||'|'||r."seasonKey"));
        -- Same upsert as futbeat_request_match_standings__ungated, without the wake (detail-cron drains it each minute).
        insert into futbeat_private.standings_demands(competition_id,season_key,external_league_id,queued_at)
        values(r."competitionId",r."seasonKey",r."externalLeagueId",now())
        on conflict(competition_id,season_key) do update set
          request_count=futbeat_private.standings_demands.request_count+1,
          requested_at=now(),external_league_id=excluded.external_league_id,
          queued_at=case when futbeat_private.standings_demands.status='QUEUED'
            then futbeat_private.standings_demands.queued_at else now() end,
          failure_count=case when futbeat_private.standings_demands.status='QUEUED'
            then futbeat_private.standings_demands.failure_count else 0 end,
          status='QUEUED'
        where futbeat_private.standings_demands.status<>'QUEUED';
        if found then n_st:=n_st+1; end if;
      end loop;
    end if;
  end if;

  -- TEAM HISTORY (feeds H2H and profile results): teams playing soon, never fetched or older than tm_days.
  if tm_take>0 then
    with m as (
      select cm.match_id,cm.start_time,e.payload p from futbeat_private.calendar_matches cm
      join futbeat_private.entities e on e.id=cm.match_id and e.kind='match'
      where cm.start_time between now() and now()+make_interval(hours=>tm_h)),
    t as (
      select x.tid,min(m.start_time) kickoff,
        bool_or(exists(select 1 from futbeat_private.coverage_interests ci where ci.subject_type='competition'
          and ci.explicit_followers>0 and ci.subject_id=futbeat_private.futbeat_resolve_entity_id('competition',m.p->>'competitionId'))) comp_followed
      from m, lateral (values (futbeat_private.futbeat_resolve_entity_id('team',nullif(m.p->>'homeTeamId',''))),
                              (futbeat_private.futbeat_resolve_entity_id('team',nullif(m.p->>'awayTeamId','')))) x(tid)
      where x.tid is not null group by x.tid),
    cand as (
      select t.*,c.last_attempt_at,c.next_retry_at,c.lease_until,futbeat_private.team_match_coverage_state(t.tid)->>'state' state
      from t left join futbeat_private.team_match_coverage c on c.team_id=t.tid
      where exists(select 1 from futbeat_private.entities te where te.id=t.tid and te.kind='team')
        -- exactly one GOAL team id: a canonical holding several clubs (homonym merge) is never fetched until split
        and cardinality(futbeat_private.team_goal_external_ids(t.tid,2))=1
        and coalesce(c.lease_until,'-infinity')<=now() and coalesce(c.next_retry_at,'-infinity')<=now()
        and (c.team_id is null or coalesce(c.last_attempt_at,'-infinity')<now()-make_interval(days=>tm_days))
        and not exists(select 1 from futbeat_private.team_match_demands d where d.team_id=t.tid
          and d.requested_at>now()-interval '7 days' and d.requested_at>coalesce(c.last_attempt_at,'-infinity'))),
    scored as (
      select cand.*,
        (case when exists(select 1 from futbeat_private.coverage_interests ci where ci.subject_type='team'
          and ci.subject_id=cand.tid and ci.explicit_followers>0) then 4 else 0 end
        + case when cand.comp_followed then 2 else 0 end
        + case when cand.kickoff<now()+interval '24 hours' then 1 else 0 end) tier,
        coalesce((select ci.priority_score from futbeat_private.coverage_interests ci
            where ci.subject_type='team' and ci.subject_id=cand.tid),0) prio
      from cand where cand.state in ('PENDING','STALE'))
    select coalesce(jsonb_agg(jsonb_build_object('teamId',tid,'state',state,'tier',tier,'priority',prio,'kickoff',kickoff)
        order by tier desc,prio desc,kickoff,tid),'[]')
      into tm_pick
    from (select * from scored order by tier desc,prio desc,kickoff,tid limit tm_take) x;

    if not p_dry then
      for r in select * from jsonb_to_recordset(tm_pick) as x("teamId" text) loop
        perform pg_catalog.pg_advisory_xact_lock(hashtext('futbeat-team-match-demand'),hashtext(r."teamId"));
        insert into futbeat_private.team_match_demands as d(team_id,reason) values(r."teamId",'central')
        on conflict(team_id) do update set requested_at=now(),request_count=d.request_count+1,reason='central'
          where d.requested_at<now()-interval '1 minute';
        if found then n_tm:=n_tm+1; end if;
      end loop;
      if n_tm>0 then woke:=futbeat_private.wake_provider_worker('team-fixtures-only'); end if;
    end if;
  end if;

  if not p_dry then
    insert into futbeat_private.central_coverage_log as l(day,kind,enqueued,runs,last_run_at,last_result)
    values(today,'standings',n_st,1,now(),st_pick),(today,'team',n_tm,1,now(),tm_pick)
    on conflict(day,kind) do update set enqueued=l.enqueued+excluded.enqueued,runs=l.runs+1,
      last_run_at=now(),last_result=excluded.last_result;
    if n_st>0 then perform futbeat_private.bump_metric('central_standings_enqueued',n_st); end if;
    if n_tm>0 then perform futbeat_private.bump_metric('central_team_enqueued',n_tm); end if;
  end if;
  return jsonb_build_object('enabled',enabled,'dry',p_dry,
    'standings',jsonb_build_object('usedToday',st_used,'open',st_now,'take',st_take,'enqueued',n_st,'picked',st_pick),
    'teams',jsonb_build_object('usedToday',tm_used,'open',tm_now,'take',tm_take,'enqueued',n_tm,'picked',tm_pick,'wake',woke));
end $function$
;

-- Source: id-split/attrs/attrs_apply.sql
-- SHA-256: ceb2297e4e9882cb34ea08fd1e74bba5e694cef8d103b3e1e3125c159f9cec19
create or replace function futbeat_private.preserve_curated_team() returns trigger language plpgsql set search_path to '' as $f$
declare c jsonb;
begin
  if new.kind<>'team' then return new; end if;
  if new.payload ? 'curation' then
    c:=new.payload->'curation';
    if c='null'::jsonb then new.payload:=new.payload-'curation'; return new; end if;   -- explicit opt-out
  elsif tg_op='UPDATE' then
    c:=old.payload->'curation';
  end if;
  if c is null or jsonb_typeof(c->'fields')<>'object' then return new; end if;
  new.payload:=new.payload||(c->'fields')||jsonb_build_object('curation',c);
  return new;
end $f$;

revoke all on function futbeat_private.preserve_curated_team() from public;

drop trigger if exists aa_preserve_curated_team on futbeat_private.entities;

create trigger aa_preserve_curated_team before insert or update of payload on futbeat_private.entities
  for each row execute function futbeat_private.preserve_curated_team();

-- Source: cov-planner/st-reject/stgroups_apply.sql
-- SHA-256: 7118776c5dc1747e09018a25657b0a660661eb40c96412d87c9b4a4224baed46
CREATE OR REPLACE FUNCTION futbeat_private.futbeat_store_goal_standings(p_competition_id text, p_external_league_id text, p_received_at timestamp with time zone, p_season text, p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  item jsonb;
  external_team text;
  team_name text;
  team_country text;
  team_id text;
  group_label text;
  position_value integer;
  played_value integer;
  won_value integer;
  drawn_value integer;
  lost_value integer;
  gf_value integer;
  ga_value integer;
  points_value integer;
  raw_rows jsonb := '[]'::jsonb;
  sorted_rows jsonb := '[]'::jsonb;
  table_json jsonb;
  raw_row_count integer := 0;
  row_count integer := 0;
  group_count integer := 0;
  groups_resolved boolean := true;
begin
  if p_competition_id is null
     or p_external_league_id is null
     or p_received_at is null
     or jsonb_typeof(p_rows)<>'array'
     or jsonb_array_length(p_rows)<2
     -- ST-GROUPS: a multi-group table (every row carries a group/stage label) may hold up to 400 rows
     -- (Serie D 9 groups/162, Oberliga 14/243, Tercera RFEF 18/327); a single table stays capped at 100.
     or jsonb_array_length(p_rows)>(case when (select count(*) from jsonb_array_elements(p_rows) g(r)
          where nullif(btrim(coalesce(
            case when jsonb_typeof(g.r->'group')='object' then g.r#>>'{group,name}'
                 when jsonb_typeof(g.r->'group')='string' then g.r->>'group' end,
            g.r->>'groupName',g.r->>'group_name',g.r->>'stageName',g.r->>'stage_name')),'') is not null)
          =jsonb_array_length(p_rows) then 400 else 100 end)
     or not exists(
       select 1
       from futbeat_private.provider_entities pe
       where pe.provider='goal_api'
         and pe.kind='competition'
         and pe.external_id=p_external_league_id
         and pe.canonical_id=p_competition_id
     )
  then
    raise exception 'Invalid GOAL standings payload';
  end if;

  for item in select value from jsonb_array_elements(p_rows)
  loop
    external_team:=nullif(coalesce(
      item#>>'{team,id}',
      item->>'teamId',
      item->>'team_id',
      item->>'teamKey'
    ),'');
    team_name:=nullif(coalesce(
      item#>>'{team,name}',
      item->>'teamName',
      item->>'team_name'
    ),'');
    team_country:=coalesce(
      item#>>'{team,country,name}',
      item#>>'{team,country}',
      ''
    );
    -- Group/stage label when the provider sends one (object or text).
    group_label:=nullif(btrim(coalesce(
      case when jsonb_typeof(item->'group')='object' then item#>>'{group,name}'
           when jsonb_typeof(item->'group')='string' then item->>'group' end,
      item->>'groupName',
      item->>'group_name',
      item->>'stageName',
      item->>'stage_name'
    )),'');

    if external_team is null or team_name is null then
      raise exception 'Invalid GOAL standings team';
    end if;

    begin
      position_value:=coalesce(
        nullif(item->>'overallLeaguePosition','')::integer,
        nullif(item->>'position','')::integer,
        nullif(item->>'rank','')::integer,
        raw_row_count+1
      );
      played_value:=coalesce(
        nullif(item->>'overallLeaguePlayed','')::integer,
        nullif(item->>'played','')::integer,
        0
      );
      won_value:=coalesce(
        nullif(item->>'overallLeagueW','')::integer,
        nullif(item->>'won','')::integer,
        nullif(item->>'win','')::integer,
        0
      );
      drawn_value:=coalesce(
        nullif(item->>'overallLeagueD','')::integer,
        nullif(item->>'drawn','')::integer,
        nullif(item->>'draw','')::integer,
        0
      );
      lost_value:=coalesce(
        nullif(item->>'overallLeagueL','')::integer,
        nullif(item->>'lost','')::integer,
        nullif(item->>'loss','')::integer,
        0
      );
      gf_value:=coalesce(
        nullif(item->>'overallLeagueGF','')::integer,
        nullif(item->>'goalsFor','')::integer,
        nullif(item->>'gf','')::integer,
        0
      );
      ga_value:=coalesce(
        nullif(item->>'overallLeagueGA','')::integer,
        nullif(item->>'goalsAgainst','')::integer,
        nullif(item->>'ga','')::integer,
        0
      );
      points_value:=coalesce(
        nullif(item->>'overallLeaguePTS','')::integer,
        nullif(item->>'points','')::integer,
        nullif(item->>'pts','')::integer,
        0
      );
    exception when others then
      raise exception 'Invalid GOAL standings numeric data';
    end;

    if position_value<1
       or played_value<0
       or won_value<0
       or drawn_value<0
       or lost_value<0
       or gf_value<0
       or ga_value<0
       or points_value<0
    then
      raise exception 'Invalid GOAL standings values';
    end if;

    team_id:=futbeat_private.futbeat_resolve_global_entity(
      'goal_api','team',external_team,team_name,team_country,''
    );

    raw_rows:=raw_rows || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'position',position_value,
      'group',group_label,
      'teamId',team_id,
      'played',played_value,
      'won',won_value,
      'drawn',drawn_value,
      'lost',lost_value,
      'gf',gf_value,
      'ga',ga_value,
      'points',points_value
    )));
    raw_row_count:=raw_row_count+1;
  end loop;

  with ranked as (
    select
      value,
      row_number() over(
        partition by coalesce(value->>'group',''),value->>'teamId'
        order by
          (value->>'played')::integer desc,
          (value->>'points')::integer desc,
          (value->>'position')::integer,
          ((value->>'gf')::integer-(value->>'ga')::integer) desc,
          (value->>'gf')::integer desc
      ) as rn
    from jsonb_array_elements(raw_rows)
  ), kept as (
    select value from ranked where rn=1
  ), group_order as (
    -- Groups in the provider's order of first appearance by position.
    select coalesce(value->>'group','') group_key,
      min((value->>'position')::integer) first_position,
      min(value->>'group') label
    from kept group by 1
  )
  select
    coalesce(jsonb_agg(
      k.value
      order by
        g.first_position,
        g.label nulls first,
        (k.value->>'position')::integer,
        (k.value->>'points')::integer desc,
        ((k.value->>'gf')::integer-(k.value->>'ga')::integer) desc,
        (k.value->>'gf')::integer desc,
        k.value->>'teamId'
    ),'[]'::jsonb),
    (select count(*)::integer from group_order),
    -- A repeated position inside one group means several unlabelled groups
    -- were sent together: they cannot be told apart.
    not exists(
      select 1 from kept
      group by coalesce(value->>'group',''),(value->>'position')::integer
      having count(*)>1
    )
  into sorted_rows,group_count,groups_resolved
  from kept k
  join group_order g on g.group_key=coalesce(k.value->>'group','');

  row_count:=jsonb_array_length(sorted_rows);
  if row_count<2 then
    raise exception 'Insufficient canonical teams in standings';
  end if;

  table_json:=jsonb_build_object(
    'competitionId',p_competition_id,
    'season',coalesce(p_season,''),
    'provisional',false,
    'source','GOAL API',
    'updatedAt',p_received_at,
    'grouped',group_count>1,
    'groupsResolved',groups_resolved,
    'rows',sorted_rows
  );

  insert into futbeat_private.standings_cache(
    competition_id,provider,external_league_id,season,table_payload,fetched_at
  )
  values(
    p_competition_id,'goal_api',p_external_league_id,
    coalesce(p_season,''),table_json,p_received_at
  )
  on conflict(competition_id) do update set
    provider=excluded.provider,
    external_league_id=excluded.external_league_id,
    season=excluded.season,
    table_payload=excluded.table_payload,
    fetched_at=excluded.fetched_at;

  return jsonb_build_object(
    'competitionId',p_competition_id,
    'rows',row_count,
    'rawRows',raw_row_count,
    'duplicatesCollapsed',raw_row_count-row_count,
    'groups',group_count,
    'groupsResolved',groups_resolved,
    'fetchedAt',p_received_at
  );
end
$function$
;

-- Source: id-players/pid_index.sql
-- SHA-256: 8dcaebd8c88f6367f1e50584ab1e842d919018269869961d7fe7fbc97c88321b
-- PID-1 step 0 (run alone, outside a transaction): lookup index for the GOAL apiId crosswalk.
-- CONCURRENTLY: no write lock on futbeat_private.entities. Rollback: pid_rollback.sql drops it.
create index if not exists entities_player_lineup_external_idx
  on futbeat_private.entities ((payload->'provenance'->>'lineupExternalId'))
  where kind='player' and payload->'provenance' ? 'lineupExternalId';

-- Merges move lineup alerts by player id (101k rows; the PK starts with match_id).
create index if not exists lineup_player_alerts_player_idx
  on futbeat_private.lineup_player_alerts (player_id);

-- Source: id-players/pid_apply.sql
-- SHA-256: def7f0326174cc75adfc1ba77087233bba3d4878254a354d783d01dc2abe011e
-- Provider id rows this kit added (rollback removes exactly these).
create table if not exists futbeat_private.player_crosswalk_links(
  external_id text primary key,
  canonical_id text not null,
  source text not null check (source in ('batch','trigger')),
  created_at timestamptz not null default now());

-- Pairs that need review, or a merge the trigger left for the batch.
create table if not exists futbeat_private.player_crosswalk_pending(
  keep_id text primary key,
  lineup_external_id text not null,
  alias_id text,
  reason text not null,
  seen_at timestamptz not null default now());

-- What a crosswalk merge moved beyond futbeat_merge_player_identity (undo).
create table if not exists futbeat_private.player_identity_merge_extras(
  merge_id bigint primary key references futbeat_private.player_identity_merges(id) on delete cascade,
  lineup_external_id text not null,
  moved_alerts jsonb not null default '[]');

revoke all on futbeat_private.player_crosswalk_links, futbeat_private.player_crosswalk_pending,
  futbeat_private.player_identity_merge_extras from public, anon, authenticated;

-- One verdict per catalog player. 'merge' only with provider evidence and no conflicting fact.
create or replace function futbeat_private.player_crosswalk_verdict(p_keep text, p_allow_team_conflict boolean default false)
returns table(keep_id text, lineup_external_id text, alias_id text, verdict text)
language sql stable security definer set search_path to '' as $$
  with k as (
    select e.id, e.payload p, btrim(e.payload->'provenance'->>'lineupExternalId') lext
    from futbeat_private.entities e where e.id=p_keep and e.kind='player'),
  a as (
    select k.*, pe.canonical_id mapped, ae.payload ap
    from k
    left join futbeat_private.provider_entities pe
      on pe.provider='goal_api' and pe.kind='player' and pe.external_id=k.lext
    left join futbeat_private.entities ae on ae.id=pe.canonical_id and ae.kind='player')
  select a.id, a.lext, a.mapped, case
    when a.lext is null or a.lext !~ '^[1-9][0-9]*$' then 'skip:no_crosswalk'
    when coalesce(a.p->'provenance'->>'externalId','') !~ '[^0-9]' then 'skip:keep_not_catalog'
    when exists(select 1 from futbeat_private.entity_redirects r where r.alias_id=a.id) then 'skip:keep_redirected'
    when exists(select 1 from futbeat_private.entities o
                where o.kind='player' and o.payload->'provenance' ? 'lineupExternalId'
                  and o.payload->'provenance'->>'lineupExternalId'=a.lext and o.id<>a.id
                  and not exists(select 1 from futbeat_private.entity_redirects r where r.alias_id=o.id))
      then 'review:crosswalk_shared'
    when a.mapped is null then 'link'
    when futbeat_private.futbeat_resolve_entity_id('player',a.mapped)=a.id then 'same'
    when a.ap is null then 'review:alias_missing'
    when exists(select 1 from futbeat_private.entity_redirects r where r.alias_id=a.mapped) then 'review:alias_redirected'
    when exists(select 1 from futbeat_private.provider_entities z
                where z.canonical_id=a.mapped and z.kind='player' and z.external_id !~ '^[0-9]+$')
      then 'review:alias_has_catalog_id'
    when exists(select 1 from futbeat_private.team_squad_twins t where t.alias_id=a.id) then 'review:keep_is_hidden_twin'
    when exists(select 1 from futbeat_private.team_squad_members s where s.player_id=a.mapped) then 'review:alias_in_squad'
    when exists(select 1 from futbeat_private.transfer_events t where t.player_id=a.mapped) then 'review:alias_has_transfers'
    when nullif(btrim(a.p->>'dateOfBirth'),'')<>nullif(btrim(a.ap->>'dateOfBirth'),'') then 'review:dob_conflict'
    when not p_allow_team_conflict
      and futbeat_private.futbeat_resolve_entity_id('team',nullif(a.p->>'teamId',''))
       <>futbeat_private.futbeat_resolve_entity_id('team',nullif(a.ap->>'teamId',''))
      then 'review:team_conflict'
    else 'merge' end
  from a
$$;

create or replace function futbeat_private.merge_player_crosswalk(p_keep text, p_allow_team_conflict boolean default false)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v record; r jsonb; v_mid bigint; v_moved jsonb;
begin
  perform pg_catalog.pg_advisory_xact_lock(hashtext('futbeat-player-merge'));
  select * into v from futbeat_private.player_crosswalk_verdict(p_keep,p_allow_team_conflict);
  if v.keep_id is null then return jsonb_build_object('status','skip:no_entity','keepId',p_keep); end if;
  if v.verdict='link' then
    insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
    values('goal_api','player',v.lineup_external_id,v.keep_id) on conflict do nothing;
    if not found then return jsonb_build_object('status','skip:raced','keepId',p_keep); end if;
    insert into futbeat_private.player_crosswalk_links(external_id,canonical_id,source)
    values(v.lineup_external_id,v.keep_id,'batch');
    delete from futbeat_private.player_crosswalk_pending where keep_id=p_keep;
    return jsonb_build_object('status','linked','keepId',p_keep,'lineupExternalId',v.lineup_external_id);
  elsif v.verdict<>'merge' then
    if v.verdict like 'review:%' then
      insert into futbeat_private.player_crosswalk_pending(keep_id,lineup_external_id,alias_id,reason)
      values(v.keep_id,v.lineup_external_id,v.alias_id,v.verdict)
      on conflict(keep_id) do update set lineup_external_id=excluded.lineup_external_id,
        alias_id=excluded.alias_id,reason=excluded.reason,seen_at=now();
    else
      delete from futbeat_private.player_crosswalk_pending where keep_id=p_keep;
    end if;
    return jsonb_build_object('status',v.verdict,'keepId',p_keep,'aliasId',v.alias_id);
  end if;
  -- Lineup alerts (N1) are keyed by player id; futbeat_merge_player_identity does not move them.
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('keptAlert',(
      select to_jsonb(k) from futbeat_private.lineup_player_alerts k
      where k.match_id=x.match_id and k.player_id=v.keep_id))),'[]')
  into v_moved from futbeat_private.lineup_player_alerts x where x.player_id=v.alias_id;
  r:=futbeat_private.futbeat_merge_player_identity(v.alias_id,v.keep_id,
    'goal_apiId_crosswalk:'||v.lineup_external_id);
  if r->>'status'<>'merged' then raise exception 'PID-1 merge did not complete: %',r; end if;
  select max(id) into v_mid from futbeat_private.player_identity_merges
  where alias_id=v.alias_id and canonical_id=v.keep_id;
  insert into futbeat_private.player_identity_merge_extras(merge_id,lineup_external_id,moved_alerts)
  values(v_mid,v.lineup_external_id,v_moved);
  -- Union of notified roles: a role either id was already notified for is never re-sent.
  insert into futbeat_private.lineup_player_alerts as a(match_id,player_id,role,official,notified_roles,first_seen_at,updated_at)
  select match_id,v.keep_id,role,official,notified_roles,first_seen_at,updated_at
  from futbeat_private.lineup_player_alerts where player_id=v.alias_id
  on conflict(match_id,player_id) do update set
    notified_roles=(select coalesce(array_agg(distinct n order by n),'{}') from unnest(a.notified_roles||excluded.notified_roles) n),
    official=a.official or excluded.official,
    first_seen_at=least(a.first_seen_at,excluded.first_seen_at),
    updated_at=greatest(a.updated_at,excluded.updated_at);
  delete from futbeat_private.lineup_player_alerts where player_id=v.alias_id;
  delete from futbeat_private.player_crosswalk_pending where keep_id=p_keep;
  return r||jsonb_build_object('mergeId',v_mid,'movedAlerts',jsonb_array_length(v_moved),
    'lineupExternalId',v.lineup_external_id);
end $$;

-- Bounded batch, priority: followed > temporary interest > team plays in the next 8 days > rest.
create or replace function futbeat_private.merge_player_crosswalk_batch(p_limit integer default 200, p_allow_team_conflict boolean default false)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare k record; r jsonb; v_counts jsonb:='{}'; v_status text; v_n integer:=0;
begin
  if p_limit is null or p_limit<1 or p_limit>2000 then raise exception 'PID-1 batch limit 1..2000'; end if;
  for k in
    with c as (
      select e.id, e.payload->>'teamId' team, pe.canonical_id mapped
      from futbeat_private.entities e
      left join futbeat_private.provider_entities pe on pe.provider='goal_api' and pe.kind='player'
        and pe.external_id=e.payload->'provenance'->>'lineupExternalId'
      where e.kind='player' and e.payload->'provenance' ? 'lineupExternalId'
        and btrim(e.payload->'provenance'->>'lineupExternalId') ~ '^[1-9][0-9]*$'
        and coalesce(e.payload->'provenance'->>'externalId','') ~ '[^0-9]'
        and (pe.canonical_id is null or pe.canonical_id<>e.id)
        and not exists(select 1 from futbeat_private.entity_redirects r where r.alias_id=e.id)
        and not exists(select 1 from futbeat_private.player_crosswalk_pending q
                       where q.keep_id=e.id and q.reason like 'review:%' and q.seen_at>now()-interval '1 day'))
    select c.id from c
    order by
      exists(select 1 from futbeat_private.push_follows f where f.entity_type='player' and f.entity_id in (c.id,c.mapped)) desc,
      exists(select 1 from futbeat_private.temporary_interests t where t.entity_type='player' and t.entity_id in (c.id,c.mapped)) desc,
      exists(select 1 from futbeat_private.entities m where m.kind='match'
        and c.team in (m.payload->>'homeTeamId',m.payload->>'awayTeamId')
        and m.payload->>'startTime'>=to_char(now() at time zone 'UTC','YYYY-MM-DD')
        and m.payload->>'startTime'<to_char((now()+interval '8 days') at time zone 'UTC','YYYY-MM-DD')) desc,
      (c.mapped is not null) desc, c.id
    limit p_limit
  loop
    r:=futbeat_private.merge_player_crosswalk(k.id,p_allow_team_conflict);
    v_status:=r->>'status';
    v_counts:=v_counts||jsonb_build_object(v_status,coalesce((v_counts->>v_status)::integer,0)+1);
    v_n:=v_n+1;
  end loop;
  return jsonb_build_object('processed',v_n,'byStatus',v_counts);
end $$;

-- Prevention: a catalog player that carries GOAL's lineup id registers it, so the next lineup
-- resolves to this player instead of creating a new one. An id already owned by another player
-- is never merged inline (ingest stays cheap): it is queued for the batch.
create or replace function futbeat_private.link_player_crosswalk() returns trigger
language plpgsql security definer set search_path to '' as $$
declare lx text:=btrim(new.payload->'provenance'->>'lineupExternalId'); cur text;
begin
  if lx is null or lx !~ '^[1-9][0-9]*$' then return null; end if;
  if tg_op='UPDATE' and lx is not distinct from btrim(old.payload->'provenance'->>'lineupExternalId') then return null; end if;
  if coalesce(new.payload->'provenance'->>'externalId','') !~ '[^0-9]' then return null; end if;
  if exists(select 1 from futbeat_private.entity_redirects r where r.alias_id=new.id) then return null; end if;
  select canonical_id into cur from futbeat_private.provider_entities
  where provider='goal_api' and kind='player' and external_id=lx;
  if cur is null then
    if exists(select 1 from futbeat_private.entities o where o.kind='player'
              and o.payload->'provenance' ? 'lineupExternalId'
              and o.payload->'provenance'->>'lineupExternalId'=lx and o.id<>new.id) then
      insert into futbeat_private.player_crosswalk_pending(keep_id,lineup_external_id,reason)
      values(new.id,lx,'review:crosswalk_shared') on conflict(keep_id) do update
        set lineup_external_id=excluded.lineup_external_id,reason=excluded.reason,seen_at=now();
      return null;
    end if;
    insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
    values('goal_api','player',lx,new.id) on conflict do nothing;
    if found then
      insert into futbeat_private.player_crosswalk_links(external_id,canonical_id,source)
      values(lx,new.id,'trigger') on conflict do nothing;
      return null;
    end if;
    select canonical_id into cur from futbeat_private.provider_entities
    where provider='goal_api' and kind='player' and external_id=lx;
  end if;
  if futbeat_private.futbeat_resolve_entity_id('player',cur) is distinct from new.id then
    insert into futbeat_private.player_crosswalk_pending(keep_id,lineup_external_id,alias_id,reason)
    values(new.id,lx,cur,'queued') on conflict(keep_id) do update
      set lineup_external_id=excluded.lineup_external_id,alias_id=excluded.alias_id,reason=excluded.reason,seen_at=now();
  end if;
  return null;
end $$;

drop trigger if exists zz_link_player_crosswalk on futbeat_private.entities;

create trigger zz_link_player_crosswalk
  after insert or update of payload on futbeat_private.entities
  for each row when (new.kind='player' and new.payload->'provenance' ? 'lineupExternalId')
  execute function futbeat_private.link_player_crosswalk();

-- Undo one crosswalk merge (newest first). Restores ids, follows, interests, memberships,
-- alerts and the facts the merge filled in on the kept player.
create or replace function futbeat_private.unmerge_player_crosswalk(p_merge_id bigint)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare m futbeat_private.player_identity_merges; x futbeat_private.player_identity_merge_extras;
  cur jsonb; nxt jsonb; k text; v_name text; v_al jsonb; v_follow boolean:=false;
begin
  perform pg_catalog.pg_advisory_xact_lock(hashtext('futbeat-player-merge'));
  select * into m from futbeat_private.player_identity_merges where id=p_merge_id;
  select * into x from futbeat_private.player_identity_merge_extras where merge_id=p_merge_id;
  if m.id is null or x.merge_id is null then raise exception 'PID-1: % is not a crosswalk merge',p_merge_id; end if;
  if exists(select 1 from futbeat_private.player_identity_merges l
            where l.id>m.id and (l.canonical_id in (m.alias_id,m.canonical_id) or l.alias_id in (m.alias_id,m.canonical_id))) then
    raise exception 'PID-1: undo newer merges of these players first';
  end if;
  delete from futbeat_private.entity_redirects where alias_id=m.alias_id and canonical_id=m.canonical_id;
  update futbeat_private.entity_redirects set canonical_id=m.alias_id
  where kind='player' and canonical_id=m.canonical_id and alias_id=any(m.redirected_aliases);
  update futbeat_private.provider_entities set canonical_id=m.alias_id
  where kind='player' and canonical_id=m.canonical_id and external_id=any(m.moved_provider_ids);
  update futbeat_private.provider_media_cache set canonical_id=m.alias_id
  where kind='player' and canonical_id=m.canonical_id and provider||':'||external_id=any(m.moved_media_cache);
  insert into futbeat_private.team_squad_members(team_id,player_id,provider,updated_at)
  select j->>'team_id',m.alias_id,j->>'provider',(j->>'updated_at')::timestamptz
  from jsonb_array_elements(m.moved_memberships) j on conflict do nothing;
  delete from futbeat_private.team_squad_members s using jsonb_array_elements(m.moved_memberships) j
  where s.player_id=m.canonical_id and s.team_id=j->>'team_id' and not (j->>'keptHadMembership')::boolean;
  insert into futbeat_private.push_follows(user_id,entity_type,entity_id,created_at)
  select (j->>'user_id')::uuid,'player',m.alias_id,(j->>'created_at')::timestamptz
  from jsonb_array_elements(m.moved_follows) j on conflict do nothing;
  delete from futbeat_private.push_follows f using jsonb_array_elements(m.moved_follows) j
  where f.entity_type='player' and f.entity_id=m.canonical_id and f.user_id=(j->>'user_id')::uuid
    and not (j->>'keptHadFollow')::boolean;
  insert into futbeat_private.temporary_interests(user_id,entity_type,entity_id,touched_at,expires_at)
  select (j->>'user_id')::uuid,'player',m.alias_id,(j->>'touched_at')::timestamptz,(j->>'expires_at')::timestamptz
  from jsonb_array_elements(m.moved_interests) j on conflict do nothing;
  delete from futbeat_private.temporary_interests t using jsonb_array_elements(m.moved_interests) j
  where t.entity_type='player' and t.entity_id=m.canonical_id and t.user_id=(j->>'user_id')::uuid
    and not (j->>'keptHadInterest')::boolean;
  v_follow:=jsonb_array_length(m.moved_follows)+jsonb_array_length(m.moved_interests)>0;
  -- Alerts: alias rows back as they were; kept rows back to their pre-merge state (or removed).
  for v_al in select value from jsonb_array_elements(x.moved_alerts) loop
    insert into futbeat_private.lineup_player_alerts
    select * from jsonb_populate_record(null::futbeat_private.lineup_player_alerts,v_al-'keptAlert')
    on conflict do nothing;
    delete from futbeat_private.lineup_player_alerts
    where match_id=v_al->>'match_id' and player_id=m.canonical_id;
    if jsonb_typeof(v_al->'keptAlert')='object' then
      insert into futbeat_private.lineup_player_alerts
      select * from jsonb_populate_record(null::futbeat_private.lineup_player_alerts,v_al->'keptAlert');
    end if;
  end loop;
  -- Kept payload: revert only fields whose current value is still what the merge copied from the alias.
  select payload into cur from futbeat_private.entities where id=m.canonical_id and kind='player' for update;
  nxt:=cur;
  foreach k in array array['shortName','country','dateOfBirth','age','height','preferredFoot','position','shirtNumber','media'] loop
    if nxt->k is distinct from m.canonical_payload_before->k and nxt->k is not distinct from m.alias_payload->k then
      nxt:=case when m.canonical_payload_before ? k then jsonb_set(nxt,array[k],m.canonical_payload_before->k)
               else nxt-k end;
    end if;
  end loop;
  v_name:=lower(nullif(btrim(m.alias_payload->>'name'),''));
  if v_name is not null and jsonb_typeof(nxt->'aliases')='array'
     and not exists(select 1 from jsonb_array_elements_text(case when jsonb_typeof(m.canonical_payload_before->'aliases')='array'
                    then m.canonical_payload_before->'aliases' else '[]' end) b where lower(b)=v_name) then
    nxt:=jsonb_set(nxt,'{aliases}',(select coalesce(jsonb_agg(a),'[]') from jsonb_array_elements_text(nxt->'aliases') a
                                     where lower(a)<>v_name));
    if not (m.canonical_payload_before ? 'aliases') and nxt->'aliases'='[]'::jsonb then nxt:=nxt-'aliases'; end if;
  end if;
  if nxt is distinct from cur then
    update futbeat_private.entities set payload=nxt where id=m.canonical_id and kind='player';
  end if;
  delete from futbeat_private.player_identity_merges where id=m.id;
  if v_follow then perform futbeat_private.refresh_interest_aggregates(); end if;
  return jsonb_build_object('status','unmerged','mergeId',m.id,'aliasId',m.alias_id,'canonicalId',m.canonical_id);
end $$;

revoke all on function futbeat_private.player_crosswalk_verdict(text,boolean),
  futbeat_private.merge_player_crosswalk(text,boolean),
  futbeat_private.merge_player_crosswalk_batch(integer,boolean),
  futbeat_private.link_player_crosswalk(),
  futbeat_private.unmerge_player_crosswalk(bigint) from public, anon, authenticated;

-- Source: id-players/pid_upsert_apply.sql
-- SHA-256: 0dc7d25ce6cbdc7ee7759d3543ede3738d6cfd785c1af317291c0d2ba77c060c
CREATE OR REPLACE FUNCTION futbeat_private.upsert_goal_player(p_item jsonb, p_source text, p_received timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ext text:=nullif(btrim(p_item->>'externalId'),''); name text:=nullif(btrim(p_item->>'name'),'');
  existed boolean; pid text; old jsonb; next jsonb; key text; value jsonb; team_id text; squad boolean; url text;
  bridge_pid text;
begin
  if ext is null or p_source not in ('search','profile') then return null; end if;
  existed:=exists(select 1 from futbeat_private.provider_entities where provider='goal_api' and kind='player' and external_id=ext);
  if not existed and name is null then return null; end if;
  if not existed then
    bridge_pid:=futbeat_private.bridge_player_identity(ext,name,p_item->>'teamExternalId');
  end if;
  if bridge_pid is not null then
    perform pg_catalog.pg_advisory_xact_lock(hashtextextended('player:goal_api:'||ext,0));
    select canonical_id into pid from futbeat_private.provider_entities
    where provider='goal_api' and kind='player' and external_id=ext;
    if pid is null then
      insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
      values('goal_api','player',ext,bridge_pid) on conflict do nothing;
      pid:=bridge_pid;
      perform futbeat_private.bump_metric('lineup_identity_bridged');
    end if;
  else
    if not existed then perform futbeat_private.bump_metric('lineup_identity_bridge_skipped'); end if;
    pid:=futbeat_private.futbeat_resolve_global_entity('goal_api','player',ext,coalesce(name,''),
      coalesce(p_item->>'country',''),coalesce(p_item->>'shortName',''));
  end if;
  select payload into old from futbeat_private.entities where id=pid and kind='player' for update;
  if old is null then return null; end if;
  next:=old;
  squad:=exists(select 1 from futbeat_private.team_squad_members where player_id=pid);
  foreach key in array array['name','shortName','country','dateOfBirth','age','height','preferredFoot'] loop
    value:=p_item->key;
    if value is null or value='null'::jsonb or value='""'::jsonb then continue; end if;
    -- A stored squad also writes these facts: only fill what it lacks, so the
    -- two sources never flip-flop.
    if p_source='profile' and not squad and key not in ('name','shortName')
       or coalesce(btrim(next->>key),'')='' then
      next:=next||jsonb_build_object(key,value);
    end if;
  end loop;
  if not squad then
    if coalesce(next->>'teamId','')='' and nullif(p_item->>'teamExternalId','') is not null then
      select canonical_id into team_id from futbeat_private.provider_entities
      where provider='goal_api' and kind='team' and external_id=p_item->>'teamExternalId';
      if team_id is not null then
        next:=next||jsonb_build_object('teamId',futbeat_private.futbeat_resolve_entity_id('team',team_id));
      end if;
    end if;
    if coalesce(btrim(next->>'position'),'')='' and coalesce(btrim(p_item->>'position'),'')<>'' then
      next:=next||jsonb_build_object('position',p_item->'position');
    end if;
    if jsonb_typeof(next->'shirtNumber') is distinct from 'number' and jsonb_typeof(p_item->'shirtNumber')='number' then
      next:=next||jsonb_build_object('shirtNumber',p_item->'shirtNumber');
    end if;
  end if;
  url:=p_item->>'photo';
  if futbeat_private.futbeat_valid_goal_player_media_url(url,'GOAL API')
     and not futbeat_private.valid_player_media(old->'media') then
    next:=jsonb_set(next,'{media}',jsonb_build_object('url',url,'kind','PLAYER_PHOTO','source','GOAL API',
      'externalId',ext,'receivedAt',p_received,'verificationStatus','VERIFIED','rightsStatus','REVIEW_REQUIRED',
      'usageScope','DEVELOPMENT_ONLY','discoveredVia','player_'||p_source),true);
  end if;
  if next->'provenance' is null then
    next:=next||jsonb_build_object('provenance',jsonb_build_object('source','GOAL API','externalId',ext,
      'receivedAt',p_received,'verificationStatus','PROVISIONAL'));
  end if;
  -- PID-1: keep GOAL's own lineup id (apiId) so the crosswalk trigger can link it. Never a name.
  if btrim(coalesce(p_item->>'lineupExternalId','')) ~ '^[1-9][0-9]*$' and ext ~ '[^0-9]'
     and coalesce(next->'provenance'->>'lineupExternalId','')='' and jsonb_typeof(next->'provenance')='object' then
    next:=jsonb_set(next,'{provenance,lineupExternalId}',to_jsonb(btrim(p_item->>'lineupExternalId')),true);
  end if;
  if next is distinct from old then
    update futbeat_private.entities set payload=next where id=pid and kind='player';
  end if;
  return jsonb_build_object('id',pid,'created',not existed,
    'gained',(select count(*) from jsonb_each(next) n where not (old ? n.key) or old->n.key is distinct from n.value));
end $function$
;

-- Source: live-pro/q429/q429_apply.sql
-- SHA-256: 640253373697ddba7fa27394245bdd3b325583dcb194d26eac6ce45ecffa7f4a
CREATE OR REPLACE FUNCTION futbeat_private.provider_remaining(p_provider text)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select provider_remaining from futbeat_private.provider_call_ledger
  where provider=p_provider and provider_remaining is not null
    and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'
    and (status is distinct from 'FAILED'
      or coalesce(completed_at,reserved_at)>=now()-interval '15 minutes')
  order by coalesce(completed_at,reserved_at) desc,id desc
  limit 1
$function$;

-- Source: live-pro/d1v2_apply.sql
-- SHA-256: c429b059797f77a9020c881998876ab23e4816e2878e84d02f9df5bc0b7d2493
CREATE OR REPLACE FUNCTION futbeat_private.note_match_detail_open(p_match_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_existing futbeat_private.match_detail_requests;
begin
  -- LIVE-PRO D1v2: an open records interest (P0 for live_demand_tier / planner_due). It never wakes the
  -- provider worker and never reserves a call: the central planner decides (openTriggersFetch=0).
  -- Interest is recorded even when the cache is fresh: K2 reads an unexpired source='user' row as P0.
  if p_match_id is null
     or not exists(select 1 from futbeat_private.entities where id=p_match_id and kind='match')
     or not futbeat_private.match_detail_fetchable(p_match_id) then
    return;
  end if;
  perform pg_advisory_xact_lock(hashtext('futbeat-match-detail-request'),hashtext(p_match_id));
  select * into v_existing from futbeat_private.match_detail_requests
  where match_id=p_match_id and expires_at>now();
  -- Debounce: at most one write per match and minute (repeated opens only count).
  if v_existing.match_id is not null and v_existing.source='user'
     and v_existing.user_requested_at>now()-interval '1 minute' then
    perform futbeat_private.bump_metric('deduped_requests');
    return;
  end if;
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
  perform futbeat_private.bump_metric('match_detail_user_demands');
end
$function$;

revoke all on function futbeat_private.note_match_detail_open(text) from public,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.futbeat_request_match_detail(p_match_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_match_detail__ungated(p_match_id);
  end if;
  -- LIVE-PRO D1v2: record the open as interest (no wake, no reservation); a failure here never breaks the read.
  begin
    perform futbeat_private.note_match_detail_open(p_match_id);
  exception when others then
    null;
  end;
  -- Passive: the stored detail, exactly as the read-only path answers it.
  return public.futbeat_read_match_detail(p_match_id);
end $function$;

CREATE OR REPLACE FUNCTION futbeat_private.request_match_detail(p_match_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_start timestamptz;
  v_fetched timestamptz;
  v_existing futbeat_private.match_detail_requests;
  v_open text;
begin
  select nullif(payload->>'startTime','')::timestamptz
  into v_start
  from futbeat_private.entities
  where id=p_match_id and kind='match';

  if p_match_id is null or v_start is null then
    raise exception 'Unknown canonical match';
  end if;

  -- Anonymous requests only enqueue trusted canonical matches. Historical
  -- hydration is intentionally bounded to the provider horizon.
  if futbeat_private.match_detail_fetchable(p_match_id) then
    -- Serialize opens of the same match so dedupe accounting is exact.
    perform pg_advisory_xact_lock(hashtext('futbeat-match-detail-request'),hashtext(p_match_id));
    select fetched_at into v_fetched from futbeat_private.match_detail_cache where match_id=p_match_id;
    if not futbeat_private.match_detail_needs_fetch(p_match_id) then
      v_open:=case when v_fetched is not null then 'warm' else 'backoff' end;
      perform futbeat_private.bump_metric('match_detail_cache_hits');
    else
      v_open:=case when v_fetched is not null then 'refresh'
        when exists(select 1 from futbeat_private.provider_observations po
          where po.provider='goal_api' and po.canonical_match_id=p_match_id) then 'partial'
        else 'cold' end;
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
        -- Due and not in flight: wake (debounced).
        -- LIVE-PRO D1: with openTriggersFetch=0 an open is only a P0 demand signal for the central planner
        -- (K2/K3); it never wakes the provider worker by itself.
        if futbeat_private.quota_setting('goal_api','openTriggersFetch',1)=1 then
          perform futbeat_private.wake_provider_worker('demand');
        end if;
      end if;
    end if;
  else
    v_open:='out_of_horizon';
  end if;
  -- Warm/cold/partial opens, only for finished (historical) matches.
  if v_start<now()-make_interval(hours=>futbeat_private.quota_setting('goal_api','recentFinishedHours',36)::integer) then
    perform futbeat_private.bump_metric('md_history_open_'||v_open);
  end if;

  return futbeat_private.read_match_detail(p_match_id);
end
$function$;

CREATE OR REPLACE FUNCTION futbeat_private.reserve_match_detail_call(p_trigger_source text DEFAULT 'github-actions'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  v_bg_open boolean;
  v_live_open boolean;
  v_class_ok jsonb;
  v_bucket text;
  v_source text;
  v_floor_ok boolean:=futbeat_private.detail_planner_floor_ok();
begin
  if p_trigger_source is null or btrim(p_trigger_source)='' then
    raise exception 'trigger_source is required';
  end if;

  perform futbeat_private.lock_provider_quota('goal_api');
  -- Shares are read under the quota lock (concurrent reservers cannot overrun).
  v_bg_open:=futbeat_private.detail_share_open('background');
  v_live_open:=futbeat_private.detail_share_open('live');
  -- Full quota decision per class (floors, kind caps and the blind budget),
  -- so the chosen head is always servable when any candidate is.
  select jsonb_object_agg(c,(futbeat_private.quota_decision('goal_api','match-detail',c)->>'allowed')::boolean)
  into v_class_ok
  from unnest(array['live','results','user_high','user','coverage','bootstrap']) c;

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
      r.user_requested_at,
      nullif(e.payload->>'startTime','')::timestamptz start_time,
      futbeat_private.match_detail_bucket(futbeat_private.match_detail_status(r.match_id),
        nullif(e.payload->>'startTime','')::timestamptz) bucket
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
        when status='FINISHED_PENDING_VERIFICATION' and bucket='results' then 2
        when source='prematch' then 3
        when source='user' and coalesce(status,'SCHEDULED') not in ('VERIFIED','CANCELLED','ABANDONED','POSTPONED')
          and start_time>now()-interval '3 hours' then 3
        when source='user' then 4
        when source='recent' then 5
        when source='prefetch' then 6
        else 7
      end rank_value,
      case
        when status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then 'live'
        -- #101: GOAL finals stay FPV forever; only the results window is the
        -- protected results class. A historical open stays user demand.
        when status='FINISHED_PENDING_VERIFICATION' and bucket='results' then 'results'
        when source='prematch' then 'user_high'
        when source='user' and coalesce(status,'SCHEDULED') not in ('VERIFIED','CANCELLED','ABANDONED','POSTPONED')
          and start_time>now()-interval '3 hours' then 'user_high'
        when source='user' then 'user'
        when source in ('recent','prefetch') then 'coverage'
        else 'bootstrap'
      end quota_class
    from candidates
    -- User opens keep the full freshness rules; background rows must still
    -- be due by the section-aware policy and fit their bucket budget.
    -- LIVE-PRO D1: with openTriggersFetch=0 a user row follows the same central policy as the planner
    -- (planner_due: K2/K3 tiers, per-phase caps, bucket budget); the open only raises its priority.
    where case when source='user' and futbeat_private.quota_setting('goal_api','openTriggersFetch',1)=1
        then futbeat_private.match_detail_needs_fetch(match_id)
      else coalesce(futbeat_private.match_detail_planner_due(match_id,bucket)
        and futbeat_private.detail_bucket_budget_open(bucket),false) end
  )
  -- Best allowed candidate first; if none fits its class, the best due one
  -- explains the refusal.
  select match_id,external_id,status,quota_class,rank_value,
    coalesce((v_class_ok->>quota_class)::boolean,false),bucket,source
  into v_match_id,v_external,v_status,v_class,v_rank,v_allowed,v_bucket,v_source
  from ranked
  -- Planner work only within its share: never picked when it cannot be
  -- served, so it cannot block a user open or a result.
  where source='user' or quota_class='results'
    -- Background work stops above the user floor: users keep their reserve.
    or (quota_class='live' and v_live_open and v_floor_ok)
    or (quota_class<>'live' and v_bg_open and v_floor_ok)
  order by 6 desc,
    (source='user' and coalesce(user_requested_at,requested_at)
      <now()-make_interval(secs=>futbeat_private.quota_setting('goal_api','userAgingSeconds',60))) desc,
    -- Fair drain: waiting background rows climb within the background ranks
    -- (never above a user open); oldest first within a rank.
    case when source<>'user' and rank_value>=5 then greatest(5,rank_value-floor(extract(epoch from now()-requested_at)/60
      /futbeat_private.quota_setting('goal_api','fairnessAgingMinutes',20))::integer) else rank_value end,
    requested_at,match_id
  limit 1;

  if v_match_id is null or not v_allowed then
    return jsonb_build_object(
      'allowed',false,
      'reason',case when v_match_id is null then 'no_detail_due'
        else coalesce(futbeat_private.quota_decision('goal_api','match-detail',v_class)->>'reason',
          'provider_remaining_reserve') end,
      'quotaClass',v_class,
      'detailUsed',(v_cap->>'usedToday')::integer,'providerRemaining',v_remaining
    );
  end if;

  -- Full decision for the chosen class: when remaining is unknown, non-LIVE
  -- classes also respect the conservative daily total and per-kind share.
  if not (futbeat_private.quota_decision('goal_api','match-detail',v_class)->>'allowed')::boolean then
    return futbeat_private.quota_decision('goal_api','match-detail',v_class)||jsonb_build_object(
      'allowed',false,'quotaClass',v_class,'matchId',v_match_id);
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
      'status',v_status,'quotaClass',v_class,'priority',v_rank,'bucket',v_bucket,'source',v_source)
  )
  returning id into v_reservation;
  insert into futbeat_private.match_detail_queue_log(event,bucket,source) values('reserved',v_bucket,v_source);

  return jsonb_build_object(
    'allowed',true,
    'bucket',v_bucket,
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
$function$;

update futbeat_private.provider_quota_policy set freshness=freshness||'{"openTriggersFetch":0}'::jsonb where provider='goal_api';

-- calendar-provider-observation-20261117: verified deployed additive observation contract.
CREATE OR REPLACE FUNCTION futbeat_private.build_compact_calendar(p_from_date date, p_to_date date, p_timezone text DEFAULT 'America/Costa_Rica'::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with bounds as (
    select p_from_date::timestamp at time zone p_timezone lo,
      (p_to_date+1)::timestamp at time zone p_timezone hi
  ), projected as materialized (
    -- The list projection resolves team/competition redirects (chained
    -- included) exactly once; events are only built for live matches.
    select futbeat_private.match_read_model_core(e.payload,false) item,c.updated_at
    from bounds b join futbeat_private.calendar_matches c
      on c.start_time>=b.lo and c.start_time<b.hi
    join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
  ), ranked as materialized (
    select item,updated_at,item->>'id' id,
      nullif(item->>'competitionId','') comp,
      nullif(item->>'homeTeamId','') home,nullif(item->>'awayTeamId','') away,
      futbeat_private.try_timestamptz(item->>'startTime') kickoff,
      futbeat_private.fixture_display_rank(item) rank,
      futbeat_private.fixture_final_score(item) final_score,
      futbeat_private.fixture_is_ghost(item) ghost
    from projected
  ), reconciled as materialized (
    -- One canonical fixture is listed once (see the header for the evidence
    -- levels). Nothing is deleted; the hidden twin stays reachable by id.
    select a.item,a.updated_at from ranked a
    where not exists(
        -- The equalities are restated outside same_fixture_level so the
        -- planner hashes on them (a day is one pass, not a pairwise scan).
        select 1 from ranked b
        where b.comp=a.comp and b.home=a.home and b.away=a.away
          and b.id<>a.id and (b.rank,b.id)<(a.rank,a.id)
          and futbeat_private.same_fixture_level(a.id,a.comp,a.home,a.away,a.kickoff,a.final_score,
            b.id,b.comp,b.home,b.away,b.kickoff,b.final_score) is not null)
      -- A scheduled ghost whose real twin (played or playing, kicking off
      -- after it) may be on another calendar day. Far-future days never
      -- have such a twin.
      and not (a.ghost and a.kickoff<now()+interval '24 hours'
        and futbeat_private.fixture_played_twin(a.id,a.comp,a.home,a.away,a.kickoff) is not null)
  ), source as (
    select jsonb_build_object(
      'updatedAt',coalesce((select max(greatest(
        nullif(item#>>'{provenance,receivedAt}','')::timestamptz,
        nullif(item->>'liveChangedAt','')::timestamptz,updated_at)) from reconciled),now()),
      'freshness',jsonb_build_object('stale',false),
      'coverage',jsonb_build_object('source','FutBeat','partial',not complete,
        'live',false,'developmentOnly',false,'sources',jsonb_build_array('GOAL API'),
        'calendar',jsonb_build_object('from',p_from_date,'to',p_to_date,
          'timezone',p_timezone,'complete',complete))) value
    from (
      select count(*)=(select ((hi-interval '1 microsecond') at time zone 'UTC')::date
        -(lo at time zone 'UTC')::date+1 from bounds) complete
      from futbeat_private.calendar_coverage,bounds
      where provider='goal_api' and provider_date between (lo at time zone 'UTC')::date
        and ((hi-interval '1 microsecond') at time zone 'UTC')::date
    ) coverage
  ), team_items as (
    select e.payload item from futbeat_private.entities e where e.kind='team'
      and e.id in (select item->>'homeTeamId' from reconciled
                   union select item->>'awayTeamId' from reconciled)
  ), competition_items as (
    select e.payload item from futbeat_private.entities e where e.kind='competition'
      and e.id in (select item->>'competitionId' from reconciled)
  ), compact_teams as (
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','name',item->'name','shortName',item->'shortName',
      'media',case when item->'media' is null then null else jsonb_strip_nulls(
        jsonb_build_object('url',item#>'{media,url}','verificationStatus',
          item#>'{media,verificationStatus}')) end
    )) order by item->>'name',item->>'id'),'[]'::jsonb) value
    from team_items
  ), compact_competitions as (
    select coalesce(jsonb_agg((jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','name',item->'name','country',item->'country',
      'media',case when item->'media' is null then null else jsonb_strip_nulls(
        jsonb_build_object('url',item#>'{media,url}','verificationStatus',
          item#>'{media,verificationStatus}')) end
    ))||jsonb_build_object(
      'countryCode',meta.country_code,
      'relevanceScore',coalesce(meta.relevance_score,
        futbeat_private.derived_competition_relevance(item->>'competitionClass',item->>'audienceClass')),
      'competitionClass',coalesce(meta.competition_class,'other'),
      'domesticTier',meta.domestic_tier,
      'isPrimaryDomestic',coalesce(meta.is_primary_domestic,false),
      'isGlobalRelevant',coalesce(meta.is_global_relevant,false),
      'audienceClass',coalesce(meta.audience_class,'unknown'),
      'relevanceSource',coalesce(meta.source,'derived')
    )) order by item->>'country',item->>'name',item->>'id'),'[]'::jsonb) value
    from competition_items
    left join futbeat_private.competition_editorial_metadata meta
      on meta.competition_id=item->>'id'
  ), compact_matches as (
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','competitionId',item->'competitionId',
      'homeTeamId',item->'homeTeamId','awayTeamId',item->'awayTeamId',
      'startTime',item->'startTime','status',item->'status',
      'score',item->'score','minute',item->'minute',
      'hasPlayedEvidence',item->'hasPlayedEvidence',
      'provenance',case when observation.observed_at is not null
        then jsonb_build_object('providerObservedAt',observation.observed_at) end,
      'latestEvent',case when item->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
        then (select event from jsonb_array_elements(item->'events') event
          order by (event->>'minute')::integer desc nulls last,
            (event->>'extraMinute')::integer desc nulls last,event->>'id' desc limit 1) end
    )) order by item->>'startTime',item->>'id'),'[]'::jsonb) value
    from reconciled
    left join lateral (
      -- last_seen_at is the receipt of a real live batch, including an
      -- unchanged repeat. A poll for a different sporting state is not
      -- evidence that the state we are returning is fresh.
      select max(l.last_seen_at) observed_at
      from futbeat_private.live_match_state l
      where item->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
        and l.canonical_match_id=item->>'id'
        and l.status=item->>'status'
        and l.minute is not distinct from futbeat_private.safe_result_integer(item->>'minute')
        and l.home_score is not distinct from futbeat_private.safe_result_integer(item#>>'{score,home}')
        and l.away_score is not distinct from futbeat_private.safe_result_integer(item#>>'{score,away}')
    ) observation on true
  )
  select jsonb_build_object(
    'schemaVersion',1,'demo',false,'updatedAt',source.value->'updatedAt',
    'coverage',source.value->'coverage','freshness',source.value->'freshness',
    'teams',compact_teams.value,'competitions',compact_competitions.value,
    'matches',compact_matches.value,'players','[]'::jsonb,'standings','[]'::jsonb)
  from source,compact_teams,compact_competitions,compact_matches
$function$;

-- O1 schema equivalence only: table and one-argument wrapper. No historical planner run.
-- Source SHA-256: 1229dd841009d7ee5e9ea4e96f25d2a8e3bbafa90fa121e211e78ef4d306a753
create table if not exists futbeat_private.detail_planner_schedule (
  singleton boolean primary key default true check (singleton),
  last_full_planned_at timestamptz
);

insert into futbeat_private.detail_planner_schedule(singleton) values(true)
on conflict(singleton) do nothing;

alter table futbeat_private.detail_planner_schedule enable row level security;

revoke all on futbeat_private.detail_planner_schedule from public,anon,authenticated,service_role;

create or replace function futbeat_private.plan_match_detail_coverage(p_limit integer DEFAULT NULL::integer)
 RETURNS text[]
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select futbeat_private.plan_match_detail_coverage(p_limit,true)
$function$;

revoke all on function futbeat_private.plan_match_detail_coverage(integer) from public,anon,authenticated,service_role;
