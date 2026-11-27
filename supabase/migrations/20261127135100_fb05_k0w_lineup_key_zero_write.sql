-- APPLIED IN PRODUCTION 2026-11-27 13:51Z via ops ledger op 'fb05-k0w' (FB-PLAY-17). Recorded here for reproducibility;
-- source kit: k0w/apply.sql

-- (the kit's md5 gate block is omitted here: it pins the prod pre-state, not a schema requirement)
-- K0-W apply (one transaction, wrapped by the runner)
CREATE OR REPLACE FUNCTION futbeat_private.harvest_lineup_players(p_match_id text, p_payload jsonb, p_seen timestamp with time zone)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record; ext text; pid text; player_name text; photo text; media jsonb;
 old_payload jsonb; next_payload jsonb; tid text; home text; away text;
 position text; shirt integer; country text; owned text[]; last_seen timestamptz;
 team_moved boolean; changed integer:=0; existed boolean; bridge_pid text; team_external text;
begin
 if p_match_id is not null then
   select futbeat_private.futbeat_resolve_entity_id('team',payload->>'homeTeamId'),
     futbeat_private.futbeat_resolve_entity_id('team',payload->>'awayTeamId')
   into home,away from futbeat_private.entities where id=p_match_id and kind='match';
 end if;
 for r in select * from futbeat_private.lineup_rows(p_payload) loop
   ext:=coalesce(nullif(btrim(r.item->>'playerId'),''),nullif(btrim(r.item->>'playerKey'),''),
     nullif(btrim(r.item#>>'{player,id}'),''));
   -- K0-W: GOAL key 0 names nobody: never an identity (no crosswalk, no club facts).
   if ext ~ '^0+$' then ext:=null; end if;
   if ext is null then continue; end if;
   player_name:=coalesce(nullif(btrim(r.item->>'lineupPlayer'),''),
     nullif(btrim(r.item#>>'{player,name}'),''),nullif(btrim(r.item->>'playerName'),''),'');
   tid:=case r.side when 'home' then home when 'away' then away end;
   -- Provider identity only (resolve_global_entity never matches players by
   -- name). The ONLY name-assisted step is bridge_player_identity, gated on
   -- a verified current team, and only for an id this player has never had.
   existed:=exists(select 1 from futbeat_private.provider_entities where provider='goal_api' and kind='player' and external_id=ext);
   bridge_pid:=null;
   if not existed and tid is not null and player_name<>'' then
     select external_id into team_external from futbeat_private.provider_entities
     where provider='goal_api' and kind='team' and canonical_id=tid limit 1;
     if team_external is not null then
       bridge_pid:=futbeat_private.bridge_player_identity(ext,player_name,team_external);
     end if;
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
     if not existed and tid is not null then perform futbeat_private.bump_metric('lineup_identity_bridge_skipped'); end if;
     -- Provider identity only (resolve_global_entity never matches players by name).
     pid:=futbeat_private.futbeat_resolve_global_entity('goal_api','player',ext,player_name);
   end if;
   select payload into old_payload from futbeat_private.entities
     where id=pid and kind='player' for update;
   if old_payload is null then continue; end if;
   next_payload:=old_payload;
   -- Identity-level facts: fill only when missing, from any lineup age.
   if coalesce(btrim(next_payload->>'name'),'')='' and player_name<>'' then
     next_payload:=next_payload||jsonb_build_object('name',player_name);
   end if;
   country:=nullif(btrim(coalesce(r.item->>'playerCountry','')),'');
   if coalesce(btrim(next_payload->>'country'),'')='' and country is not null then
     next_payload:=next_payload||jsonb_build_object('country',country);
   end if;
   photo:=coalesce(nullif(r.item->>'playerImage',''),nullif(r.item#>>'{player,image}',''),nullif(r.item->>'photo',''));
   -- Detail omission is NOT evidence of NO_PHOTO. Only trusted CDN URLs, and an
   -- identical valid photo is not rewritten (idempotent, keeps its TTL). An
   -- older photo cannot replace a newer one (preserve_verified_player_media).
   if futbeat_private.futbeat_valid_goal_player_media_url(photo,'GOAL API')
      and not (futbeat_private.valid_player_media(old_payload->'media')
        and old_payload#>>'{media,url}'=photo) then
     media:=jsonb_build_object('url',photo,'kind','PLAYER_PHOTO','source','GOAL API','externalId',ext,
       'receivedAt',p_seen,'verificationStatus','VERIFIED','rightsStatus','REVIEW_REQUIRED',
       'usageScope','DEVELOPMENT_ONLY','discoveredVia','lineup');
     next_payload:=jsonb_set(next_payload,'{media}',media,true);
   end if;
   -- Club-level facts: a stored squad owns them; lineups never touch squad data.
   -- Otherwise only the NEWEST lineup applies, as one block: fields it set
   -- earlier (lineupOwned) advance together, so a newer club is never paired
   -- with an older lineup's shirt number/position. Fields from another source
   -- are only filled when missing.
   -- A row without a resolvable club (no side or no match context) carries no
   -- club-level evidence: it never touches team/position/shirtNumber nor the
   -- freshness markers, so it cannot block an older row that has context.
   last_seen:=futbeat_private.try_timestamptz(next_payload->>'lineupSeenAt');
   if tid is not null
      and not exists(select 1 from futbeat_private.team_squad_members sm where sm.player_id=pid)
      and (last_seen is null or p_seen>=last_seen) then
     owned:=array(select jsonb_array_elements_text(case when jsonb_typeof(next_payload->'lineupOwned')='array'
       then next_payload->'lineupOwned' else '[]'::jsonb end));
     team_moved:=false;
     if tid is distinct from next_payload->>'teamId'
        and (coalesce(next_payload->>'teamId','')='' or 'teamId'=any(owned)) then
       team_moved:=coalesce(next_payload->>'teamId','')<>'';
       next_payload:=next_payload||jsonb_build_object('teamId',tid);
       owned:=array_append(array_remove(owned,'teamId'),'teamId');
     end if;
     position:=futbeat_private.lineup_position(r.item->>'playerPosition');
     if position is not null and (coalesce(btrim(next_payload->>'position'),'')='' or 'position'=any(owned)) then
       next_payload:=next_payload||jsonb_build_object('position',position);
       owned:=array_append(array_remove(owned,'position'),'position');
     elsif position is null and team_moved and 'position'=any(owned) then
       next_payload:=next_payload-'position';
       owned:=array_remove(owned,'position');
     end if;
     shirt:=case when btrim(coalesce(r.item->>'lineupNumber',r.item->>'shirtNumber','')) ~ '^[0-9]{1,3}$'
       then btrim(coalesce(r.item->>'lineupNumber',r.item->>'shirtNumber',''))::integer end;
     if shirt is not null and (jsonb_typeof(next_payload->'shirtNumber') is distinct from 'number'
        or 'shirtNumber'=any(owned)) then
       next_payload:=next_payload||jsonb_build_object('shirtNumber',shirt);
       owned:=array_append(array_remove(owned,'shirtNumber'),'shirtNumber');
     elsif shirt is null and team_moved and 'shirtNumber'=any(owned) then
       next_payload:=next_payload-'shirtNumber';
       owned:=array_remove(owned,'shirtNumber');
     end if;
     if cardinality(owned)>0 then
       next_payload:=next_payload||jsonb_build_object('lineupOwned',
         (select to_jsonb(array_agg(f order by f)) from unnest(owned) f),
         -- Deterministic UTC text, independent of the session TimeZone.
         'lineupSeenAt',to_char(p_seen at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
     end if;
   end if;
   if next_payload is distinct from old_payload then
     update futbeat_private.entities set payload=next_payload where id=pid and kind='player';
     changed:=changed+1;
   end if;
 end loop;
 return changed;
end $function$
;
CREATE OR REPLACE FUNCTION futbeat_private.futbeat_resolve_global_entities(p_provider text, p_items jsonb)
 RETURNS TABLE(entity_kind text, external_id text, canonical_id text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  item record;
  resolved text;
begin
  if p_provider not in ('sofascore','espn','goal_api')
     or jsonb_typeof(p_items)<>'array'
     or jsonb_array_length(p_items)>10000
  then
    raise exception 'Invalid global provider identity batch';
  end if;

  for item in
    with parsed as (
      select
        value->>'kind' as kind,
        value->>'external' as external,
        coalesce(value->>'name','') as name,
        coalesce(value->>'country','') as country,
        coalesce(value->>'shortName','') as short_name
      from jsonb_array_elements(p_items)
    )
    select
      kind,
      external,
      coalesce(max(nullif(name,'')),'') as name,
      coalesce(max(nullif(country,'')),'') as country,
      coalesce(max(nullif(short_name,'')),'') as short_name
    from parsed
    where kind in ('competition','team','match','player')
      and nullif(external,'') is not null
      and not (kind='player' and external ~ '^0+$')  -- K0-W: GOAL key 0 is no player
    group by kind,external
    order by kind,external
  loop
    resolved:=futbeat_private.futbeat_resolve_global_entity(
      p_provider,
      item.kind,
      item.external,
      item.name,
      item.country,
      item.short_name
    );

    entity_kind:=item.kind;
    external_id:=item.external;
    canonical_id:=resolved;
    return next;
  end loop;
end;
$function$
;
