-- Preserve the richest durable match detail and expose canonical player media
-- to the server-side BFF. Clients retain no access to private tables.

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
declare
  v_existing jsonb;
  v_merged jsonb;
  v_key text;
  v_old_count integer;
  v_new_count integer;
begin
  if p_fetched_at is null
     or p_payload is null
     or jsonb_typeof(p_payload)<>'object'
     or not exists(
       select 1 from futbeat_private.provider_entities
       where provider='goal_api' and kind='match'
         and external_id=p_external_match_id and canonical_id=p_match_id
     ) then
    raise exception 'Invalid match detail payload';
  end if;

  select payload into v_existing
  from futbeat_private.match_detail_cache
  where match_id=p_match_id;

  v_merged:=coalesce(v_existing,'{}'::jsonb)||p_payload;

  -- An endpoint response may temporarily omit previously published sections.
  -- Keep the richer array, while still allowing later, fuller data to win.
  foreach v_key in array array['events','cards','substitutions','statistics'] loop
    v_old_count:=case when jsonb_typeof(v_existing->v_key)='array'
      then jsonb_array_length(v_existing->v_key) else 0 end;
    v_new_count:=case when jsonb_typeof(p_payload->v_key)='array'
      then jsonb_array_length(p_payload->v_key) else 0 end;
    if v_old_count>v_new_count then
      v_merged:=jsonb_set(v_merged,array[v_key],v_existing->v_key,true);
    end if;
  end loop;

  v_old_count:=case when jsonb_typeof(v_existing->'lineups')='array' then
    (select count(*) from jsonb_array_elements(v_existing->'lineups') x
      where lower(coalesce(x->>'type','')) like 'start%'
         or lower(coalesce(x->>'type','')) like 'sub%') else 0 end;
  v_new_count:=case when jsonb_typeof(p_payload->'lineups')='array' then
    (select count(*) from jsonb_array_elements(p_payload->'lineups') x
      where lower(coalesce(x->>'type','')) like 'start%'
         or lower(coalesce(x->>'type','')) like 'sub%') else 0 end;
  if v_old_count>v_new_count then
    v_merged:=jsonb_set(v_merged,'{lineups}',v_existing->'lineups',true);
  end if;

  foreach v_key in array array[
    'kickoffUtc','matchDate','matchTime','matchStatus','matchPeriod',
    'matchStadium','matchReferee','homeTeamScore','awayTeamScore',
    'homeTeamSystem','awayTeamSystem'
  ] loop
    if nullif(btrim(coalesce(p_payload->>v_key,'')),'') is null
       and nullif(btrim(coalesce(v_existing->>v_key,'')),'') is not null then
      v_merged:=jsonb_set(v_merged,array[v_key],v_existing->v_key,true);
    end if;
  end loop;

  insert into futbeat_private.match_detail_cache(
    match_id,provider,external_match_id,fetched_at,payload
  ) values(p_match_id,'goal_api',p_external_match_id,p_fetched_at,v_merged)
  on conflict(match_id) do update
    set provider=excluded.provider,
        external_match_id=excluded.external_match_id,
        fetched_at=excluded.fetched_at,
        payload=excluded.payload
  where futbeat_private.match_detail_cache.fetched_at<=excluded.fetched_at;

  return futbeat_private.read_match_detail(p_match_id);
end
$$;

-- Backfill stable GOAL player identities from already persisted lineups. This
-- is ID based; names are metadata only and never used to cross-link players.
do $$
declare
  v_items jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'kind','player','external',provider_id,'name',player_name
  )) into v_items
  from (
    select
      coalesce(nullif(x->>'playerId',''),nullif(x->>'playerKey','')) provider_id,
      max(coalesce(x->>'lineupPlayer','')) player_name
    from futbeat_private.match_detail_cache c,
      lateral jsonb_array_elements(coalesce(c.payload->'lineups','[]'::jsonb)) x
    where lower(coalesce(x->>'type','')) like 'start%'
       or lower(coalesce(x->>'type','')) like 'sub%'
    group by coalesce(nullif(x->>'playerId',''),nullif(x->>'playerKey',''))
    having coalesce(nullif(x->>'playerId',''),nullif(x->>'playerKey','')) is not null
  ) players;

  if jsonb_array_length(coalesce(v_items,'[]'::jsonb))>0 then
    perform 1 from futbeat_private.futbeat_resolve_global_entities('goal_api',v_items);
  end if;
end
$$;

create or replace function futbeat_private.futbeat_read_lineup_player_media(
  p_provider text,
  p_external_ids text[]
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  select coalesce(jsonb_object_agg(pe.external_id,jsonb_build_object(
    'canonicalId',pe.canonical_id,
    'image',case when e.payload->'media'->>'verificationStatus'='VERIFIED'
      then e.payload->'media'->>'url' else null end
  )),'{}'::jsonb)
  from futbeat_private.provider_entities pe
  join futbeat_private.entities e on e.id=pe.canonical_id and e.kind='player'
  where p_provider='goal_api' and pe.provider=p_provider and pe.kind='player'
    and pe.external_id=any(coalesce(p_external_ids,array[]::text[]))
    and cardinality(coalesce(p_external_ids,array[]::text[]))<=100;
$$;

create or replace function public.futbeat_read_lineup_player_media(
  p_provider text,
  p_external_ids text[]
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_read_lineup_player_media(p_provider,p_external_ids)
$$;

revoke all on function futbeat_private.futbeat_read_lineup_player_media(text,text[]),
  public.futbeat_read_lineup_player_media(text,text[])
from public,anon,authenticated;
grant execute on function public.futbeat_read_lineup_player_media(text,text[])
to service_role;

-- Reconcile score independently from status. A newer status-only observation
-- must not erase a valid score already held by another durable layer.
alter function futbeat_private.futbeat_read_calendar_range(date,date,text)
rename to futbeat_read_calendar_range_before_field_merge;

create or replace function futbeat_private.futbeat_read_calendar_range(
  p_from_date date,
  p_to_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_snapshot jsonb;
  v_matches jsonb;
begin
  v_snapshot:=futbeat_private.futbeat_read_calendar_range_before_field_merge(
    p_from_date,p_to_date,p_timezone
  );

  select coalesce(jsonb_agg(
    m || jsonb_build_object(
      'score',coalesce(
        nullif(m->'score','null'::jsonb),
        case when e.payload->>'status' not in (
          'LIVE','HALFTIME','EXTRA_TIME','PENALTIES'
        ) or coalesce(
          nullif(e.payload->'provenance'->>'receivedAt','')::timestamptz,
          '-infinity'::timestamptz
        )>=now()-interval '15 minutes'
          then nullif(e.payload->'score','null'::jsonb) end,
        case when l.home_score is not null and l.away_score is not null
          and (l.status in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
            or l.last_seen_at>=now()-interval '15 minutes')
          then jsonb_build_object('home',l.home_score,'away',l.away_score) end,
        case when coalesce(c.payload->>'homeTeamScore','')~'^\d+$'
              and coalesce(c.payload->>'awayTeamScore','')~'^\d+$'
          then jsonb_build_object(
            'home',(c.payload->>'homeTeamScore')::integer,
            'away',(c.payload->>'awayTeamScore')::integer
          ) end
      )
    ) order by m->>'startTime',m->>'id'
  ),'[]'::jsonb) into v_matches
  from jsonb_array_elements(coalesce(v_snapshot->'matches','[]'::jsonb)) m
  left join futbeat_private.entities e on e.id=m->>'id' and e.kind='match'
  left join lateral (
    select * from futbeat_private.live_match_state
    where canonical_match_id=m->>'id'
    order by changed_at desc,last_seen_at desc limit 1
  ) l on true
  left join futbeat_private.match_detail_cache c on c.match_id=m->>'id';

  return jsonb_set(v_snapshot,'{matches}',v_matches,true);
end
$$;

create or replace function public.futbeat_read_calendar_range(
  p_from_date date,
  p_to_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  with source as materialized (
    select futbeat_private.futbeat_apply_entity_redirects_snapshot(
      futbeat_private.futbeat_read_calendar_range(
        p_from_date,p_to_date,p_timezone
      )
    ) as value
  ),
  compact_teams as (
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','name',item->'name','shortName',item->'shortName',
      'country',item->'country','competitionId',item->'competitionId',
      'media',case when item->'media' is null then null else jsonb_strip_nulls(
        jsonb_build_object('url',item#>'{media,url}','verificationStatus',
          item#>'{media,verificationStatus}')) end
    )) order by item->>'name',item->>'id'),'[]'::jsonb) value
    from source cross join lateral jsonb_array_elements(
      coalesce(source.value->'teams','[]'::jsonb)) item
  ),
  compact_competitions as (
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','name',item->'name','country',item->'country',
      'media',case when item->'media' is null then null else jsonb_strip_nulls(
        jsonb_build_object('url',item#>'{media,url}','verificationStatus',
          item#>'{media,verificationStatus}')) end
    )) order by item->>'country',item->>'name',item->>'id'),'[]'::jsonb) value
    from source cross join lateral jsonb_array_elements(
      coalesce(source.value->'competitions','[]'::jsonb)) item
  ),
  compact_matches as (
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','competitionId',item->'competitionId',
      'homeTeamId',item->'homeTeamId','awayTeamId',item->'awayTeamId',
      'startTime',item->'startTime','status',item->'status',
      'score',item->'score','minute',item->'minute',
      'events',coalesce(item->'events','[]'::jsonb),
      'statistics',coalesce(item->'statistics','[]'::jsonb),
      'venue',item->'venue','season',item->'season',
      'provenance',case when item->'provenance' is null then null
        else jsonb_strip_nulls(jsonb_build_object(
          'source',item#>'{provenance,source}',
          'receivedAt',item#>'{provenance,receivedAt}')) end
    )) order by item->>'startTime',item->>'id'),'[]'::jsonb) value
    from source cross join lateral jsonb_array_elements(
      coalesce(source.value->'matches','[]'::jsonb)) item
  )
  select (source.value-'teams'-'competitions'-'matches') ||
    jsonb_build_object('teams',compact_teams.value,
      'competitions',compact_competitions.value,'matches',compact_matches.value)
  from source,compact_teams,compact_competitions,compact_matches
$$;

revoke all on function
  futbeat_private.store_match_detail(text,text,timestamptz,jsonb),
  futbeat_private.futbeat_read_calendar_range_before_field_merge(date,date,text),
  futbeat_private.futbeat_read_calendar_range(date,date,text),
  public.futbeat_read_calendar_range(date,date,text)
from public,anon,authenticated;
grant execute on function public.futbeat_read_calendar_range(date,date,text)
to service_role;

notify pgrst,'reload schema';
