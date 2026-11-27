-- APPLIED IN PRODUCTION 2026-11-27 06:41Z via ops ledger op 'fb05-k0' (FB-PLAY-17). Recorded here for reproducibility;
-- source kit: fb05/k0/apply.sql

-- (the kit's md5 gate block is omitted here: it pins the prod pre-state, not a schema requirement)
-- FB-05 K0 apply (one transaction, wrapped by the runner): key-0 is never a player identity.
CREATE OR REPLACE FUNCTION futbeat_private.futbeat_read_lineup_player_media(p_provider text, p_external_ids text[])
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with ids as (
   select ids.ext,e.id,e.payload
   from (select distinct unnest(p_external_ids) ext) ids
   left join futbeat_private.provider_entities pe on pe.provider=p_provider and pe.kind='player' and pe.external_id=ids.ext
   left join futbeat_private.entities e on e.id=futbeat_private.futbeat_resolve_entity_id('player',pe.canonical_id) and e.kind='player'
   where p_provider='goal_api' and cardinality(p_external_ids)<=100 and nullif(ids.ext,'') is not null and ids.ext !~ '^0+$'  -- K0: GOAL key 0 = no key, never an identity
 ), twins as (
   select t.player_id,t.twin_id,t.url
   from futbeat_private.lineup_squad_photo_twins((select array_agg(distinct id) from ids where id is not null)) t
 )
 select coalesce(jsonb_object_agg(r.ext,jsonb_build_object('providerId',r.ext,'canonicalId',r.id,'image',r.image)
   || jsonb_strip_nulls(jsonb_build_object('imageSource',r.source,'twinCanonicalId',r.twin_id))),'{}')
 from (
   select ids.ext,ids.id,
     case when own then ids.payload#>>'{media,url}' else t.url end image,
     case when own then 'PLAYER' when t.url is not null then 'SQUAD_TWIN' end source,
     case when not own then t.twin_id end twin_id
   from (select ids.*,futbeat_private.valid_player_media(ids.payload->'media') own from ids) ids
   left join twins t on t.player_id=ids.id
 ) r
$function$
;
CREATE OR REPLACE FUNCTION futbeat_private.team_last_confirmed_lineup(p_team text, p_before timestamp with time zone, p_as_side text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ids text[]; src record; rows jsonb;
begin
  if p_team is null or p_before is null or p_as_side not in ('home','away') then return null; end if;
  ids:=futbeat_private.team_identity_ids(p_team);
  for src in
    select x.id, x.p, case when x.p->>'homeTeamId'=any(ids) then 'home' else 'away' end side
    from (
      select e.id, e.payload p from futbeat_private.entities e
       where e.kind='match' and e.payload->>'homeTeamId'=any(ids)
      union
      select e.id, e.payload from futbeat_private.entities e
       where e.kind='match' and e.payload->>'awayTeamId'=any(ids)
    ) x
    where nullif(x.p->>'startTime','') is not null
      and (x.p->>'startTime')::timestamptz <  p_before
      and (x.p->>'startTime')::timestamptz >  p_before - interval '45 days'
      and futbeat_private.match_read_model_core(x.p,false)->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
      and exists(select 1 from futbeat_private.match_detail_cache c where c.match_id=x.id)
    order by (x.p->>'startTime')::timestamptz desc, x.id desc
    limit 6
  loop
    select jsonb_agg(r.item || jsonb_build_object('team',p_as_side) || case when r.item->>'playerKey' ~ '^0+$' then jsonb_build_object('playerKey',null) else '{}'::jsonb end order by
             (lower(coalesce(r.item->>'type','')) like 'start%') desc, r.ord)
      into rows
      from (select l.item, row_number() over () ord
              from futbeat_private.match_detail_cache c, futbeat_private.lineup_rows(c.payload) l
             where c.match_id=src.id and l.side=src.side) r;
    if (select count(*) from jsonb_array_elements(coalesce(rows,'[]')) v
         where lower(coalesce(v->>'type','')) like 'start%') between 7 and 11 then
      return jsonb_build_object(
        'kind','LAST_CONFIRMED',
        'teamId',p_team,
        'sourceMatch',jsonb_build_object('matchId',src.id,'startTime',src.p->>'startTime',
          'competitionId',src.p->>'competitionId','side',src.side,
          'opponentTeamId',case src.side when 'home' then src.p->>'awayTeamId' else src.p->>'homeTeamId' end),
        'lineups',rows);
    end if;
  end loop;
  return null;
end $function$
;
