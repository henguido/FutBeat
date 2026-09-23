-- 1) Match detail: a later, poorer refresh never wipes a richer stored lineup
--    or statistics section, whatever its shape. The previous check only
--    counted ARRAY lineups/statistics, so the GOAL object shapes
--    ({home:{startingLineups,...}} and {match:{fullTime:[...]}}) counted as 0
--    and were replaced by [], {hasLineups:false} or null. Lineups are now
--    counted with lineup_rows (both shapes, starters + substitutes) and
--    statistics by their non-null values. Other sections are unchanged.
--
-- 2) Squads: when a squad moves a player to a DIFFERENT club, club-level facts
--    from the previous club (shirt number, position, season numbers, injury)
--    that the new squad does not supply are dropped instead of being shown as
--    the new club's. Same-club refreshes keep the previous behavior.
--
-- Local only: no provider calls, no ledger writes.

create or replace function futbeat_private.detail_statistics_count(p_value jsonb)
returns integer language sql immutable set search_path='' as $$
 select count(*)::integer from jsonb_path_query(coalesce(p_value,'null'::jsonb),
   'strict $.** ? (@.type() == "number" || @.type() == "string" || @.type() == "boolean")')
$$;

create or replace function futbeat_private.store_match_detail_before_media(
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
  foreach v_key in array array['events','cards','substitutions'] loop
    v_old_count:=case when jsonb_typeof(v_existing->v_key)='array'
      then jsonb_array_length(v_existing->v_key) else 0 end;
    v_new_count:=case when jsonb_typeof(p_payload->v_key)='array'
      then jsonb_array_length(p_payload->v_key) else 0 end;
    if v_old_count>v_new_count then
      v_merged:=jsonb_set(v_merged,array[v_key],v_existing->v_key,true);
    end if;
  end loop;

  -- Statistics in any shape (array rows, {match:{fullTime}}, team-keyed).
  if v_existing ? 'statistics'
     and futbeat_private.detail_statistics_count(v_existing->'statistics')
       >futbeat_private.detail_statistics_count(p_payload->'statistics') then
    v_merged:=jsonb_set(v_merged,'{statistics}',v_existing->'statistics',true);
  end if;

  -- Lineups in both GOAL shapes; formations travel with their lineup.
  select count(*) into v_old_count from futbeat_private.lineup_rows(coalesce(v_existing,'{}'::jsonb));
  select count(*) into v_new_count from futbeat_private.lineup_rows(p_payload);
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

alter function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb)
 rename to store_team_squad_before_club_move;
create function futbeat_private.futbeat_store_team_squad(p_team_id text,p_provider text,p_received_at timestamptz,p_players jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare tid text:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id); prior jsonb; result jsonb;
 r record; next_payload jsonb; supplied jsonb; field text;
begin
 -- Previous club of every already-known player in this squad.
 select coalesce(jsonb_object_agg(e.id,jsonb_build_object('teamId',
   futbeat_private.futbeat_resolve_entity_id('team',e.payload->>'teamId'),'item',x.item)),'{}')
 into prior
 from jsonb_array_elements(case when jsonb_typeof(p_players)='array' then p_players else '[]'::jsonb end) x(item)
 join futbeat_private.provider_entities pe on pe.provider='goal_api' and pe.kind='player'
   and pe.external_id=x.item#>>'{provenance,externalId}'
 join futbeat_private.entities e on e.id=futbeat_private.futbeat_resolve_entity_id('player',pe.canonical_id)
   and e.kind='player'
 where coalesce(e.payload->>'teamId','')<>'';
 result:=futbeat_private.store_team_squad_before_club_move(p_team_id,p_provider,p_received_at,p_players);
 for r in select key pid,value from jsonb_each(prior) loop
   if r.value->>'teamId' is not distinct from tid then continue; end if;
   select payload into next_payload from futbeat_private.entities where id=r.pid and kind='player' for update;
   -- Only players this squad really moved (older observations are ignored).
   if next_payload is null or next_payload->>'teamId' is distinct from tid
      or futbeat_private.try_timestamptz(next_payload#>>'{provenance,receivedAt}') is distinct from p_received_at
      or not exists(select 1 from futbeat_private.team_squad_members sm
        where sm.team_id=tid and sm.player_id=r.pid) then
     continue;
   end if;
   foreach field in array array['shirtNumber','position','matchesPlayed','appearances','starts',
     'minutesPlayed','goals','assists','yellowCards','redCards','rating','injured','seasonStats'] loop
     supplied:=r.value->'item'->field;
     if supplied is null or supplied='null'::jsonb or supplied='""'::jsonb then
       next_payload:=next_payload-field;
     end if;
   end loop;
   update futbeat_private.entities set payload=next_payload
     where id=r.pid and kind='player' and payload is distinct from next_payload;
 end loop;
 return result;
end $$;

revoke all on function futbeat_private.detail_statistics_count(jsonb),
 futbeat_private.store_team_squad_before_club_move(text,text,timestamptz,jsonb)
 from public,anon,authenticated,service_role;
revoke all on function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb)
 from public,anon,authenticated;
grant execute on function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb) to service_role;
notify pgrst,'reload schema';
