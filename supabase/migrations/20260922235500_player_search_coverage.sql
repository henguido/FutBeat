-- Player coverage + search quality. Local harvest only: no provider calls,
-- ledger writes, image downloads or name-based identity merges.
--
-- Search (players ONLY): accent/punctuation-folded terms and query; players
-- rank exact name > name prefix > name word prefix > alias/shortName > fuzzy,
-- and a fuzzy-only player needs strict word similarity >= 0.5 (0.65 for
-- multi-word queries). "messi" vs "mestre" scores 0.3, so an unrelated player
-- is never returned; a typo such as "mesi" (0.57) still finds "Lionel Messi".
-- Teams and competitions keep EXACTLY the previous index terms, candidate
-- filter, quality formula, similarity and ordering.
--
-- Harvest: stored match_detail_cache lineups (array AND object shapes; the
-- previous harvest only read the array shape) resolve players strictly by
-- provider ID. A stored squad owns team/position/shirtNumber and lineups never
-- touch them; a new squad takes ownership of lineup-derived values. Otherwise
-- the NEWEST lineup with club context owns teamId/position/shirtNumber as one
-- block (older lineups never mix in stale values; rows without club context
-- never touch them); name/country are only filled when missing. Valid existing
-- photos are never lost.

create or replace function futbeat_private.search_fold(p_value text)
returns text language sql immutable set search_path='' as $$
 select nullif(btrim(regexp_replace(lower(translate(coalesce(p_value,''),
   'ÁÀÄÂÃÅáàäâãåÉÈËÊéèëêÍÌÏÎíìïîÓÒÖÔÕóòöôõÚÙÜÛúùüûÑñÇçÝýÿ',
   'AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuNnCcYyy')),
   '[[:space:]''’`´.,_/-]+',' ','g')),'')
$$;

create or replace function futbeat_private.index_entity_search() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if TG_OP='UPDATE' and new.kind=old.kind
   and new.payload->'name' is not distinct from old.payload->'name'
   and new.payload->'shortName' is not distinct from old.payload->'shortName'
   and new.payload->'aliases' is not distinct from old.payload->'aliases' then return new; end if;
 delete from futbeat_private.entity_search_index where entity_id=new.id;
 if new.kind in ('competition','team','player') then
   insert into futbeat_private.entity_search_index
   select new.id,new.kind,variant from (
     select new.payload->>'name' term union select new.payload->>'shortName'
     union select jsonb_array_elements_text(case when jsonb_typeof(new.payload->'aliases')='array'
       then new.payload->'aliases' else '[]'::jsonb end)
   ) terms cross join lateral (values(lower(btrim(term))),
     -- Folded variants only for players: team/competition terms are unchanged.
     (case when new.kind='player' then futbeat_private.search_fold(term) end)) v(variant)
   where nullif(btrim(variant),'') is not null on conflict do nothing;
 end if;
 return new;
end $$;

-- Backfill folded variants for players only (raw terms are kept).
insert into futbeat_private.entity_search_index
select e.id,e.kind,futbeat_private.search_fold(term) from futbeat_private.entities e cross join lateral (
 select e.payload->>'name' term union select e.payload->>'shortName'
 union select jsonb_array_elements_text(case when jsonb_typeof(e.payload->'aliases')='array'
   then e.payload->'aliases' else '[]'::jsonb end)
) terms where e.kind='player'
  and futbeat_private.search_fold(term) is not null
on conflict do nothing;

create or replace function public.futbeat_search_catalog(
 p_query text default '',p_country text default null,p_limit integer default 50)
returns jsonb language plpgsql volatile security definer
set search_path='' set pg_trgm.strict_word_similarity_threshold='0.5' as $$
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
       else extensions.strict_word_similarity(qf,h.term) end) similarity
   from hits h join futbeat_private.entities src on src.id=h.entity_id
   cross join lateral (select h.kind='player' and h.term in (lower(btrim(coalesce(src.payload->>'name',''))),
     coalesce(futbeat_private.search_fold(src.payload->>'name'),'')) is_name) n
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
   -- Multi-word queries need a stronger fuzzy score: one shared word
   -- ("lionel messi" vs "lionel scaloni" = 0.54) is not a typo (0.79+).
   where e.kind<>'player' or h.quality>=2 or (h.quality=1 and length(qf)>=4)
     or h.similarity>=case when position(' ' in qf)>0 then 0.65 else 0.5 end
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
end $$;

-- Both GOAL lineup shapes: [{team,type,...}] and {home:{startingLineups,substitutes},away:{...}}.
-- Starters and substitutes only (coach/missing are not appearances).
create or replace function futbeat_private.lineup_rows(p_payload jsonb)
returns table(side text,item jsonb) language sql immutable set search_path='' as $$
 select nullif(lower(r->>'team'),''),r
 from jsonb_array_elements(case when jsonb_typeof(p_payload->'lineups')='array'
   then p_payload->'lineups' else '[]'::jsonb end) r
 where lower(coalesce(r->>'type','')) like 'start%' or lower(coalesce(r->>'type','')) like 'sub%'
 union all
 select s.side,r
 from (values('home'),('away')) s(side)
 cross join (values('startingLineups'),('substitutes')) k(key)
 cross join lateral jsonb_array_elements(case when jsonb_typeof(p_payload->'lineups'->s.side->k.key)='array'
   then p_payload->'lineups'->s.side->k.key else '[]'::jsonb end) r
 where jsonb_typeof(p_payload->'lineups')='object'
$$;

create or replace function futbeat_private.lineup_position(p_value text)
returns text language sql immutable set search_path='' as $$
 select case upper(btrim(coalesce(p_value,'')))
   when '' then null when 'G' then 'Goalkeeper' when 'GK' then 'Goalkeeper'
   when 'D' then 'Defender' when 'M' then 'Midfielder'
   when 'F' then 'Forward' when 'A' then 'Forward'
   else btrim(p_value) end
$$;

create or replace function futbeat_private.harvest_lineup_players(
 p_match_id text,p_payload jsonb,p_seen timestamptz
) returns integer language plpgsql security definer set search_path='' as $$
declare r record; ext text; pid text; player_name text; photo text; media jsonb;
 old_payload jsonb; next_payload jsonb; tid text; home text; away text;
 position text; shirt integer; country text; owned text[]; last_seen timestamptz;
 team_moved boolean; changed integer:=0;
begin
 if p_match_id is not null then
   select futbeat_private.futbeat_resolve_entity_id('team',payload->>'homeTeamId'),
     futbeat_private.futbeat_resolve_entity_id('team',payload->>'awayTeamId')
   into home,away from futbeat_private.entities where id=p_match_id and kind='match';
 end if;
 for r in select * from futbeat_private.lineup_rows(p_payload) loop
   ext:=coalesce(nullif(btrim(r.item->>'playerId'),''),nullif(btrim(r.item->>'playerKey'),''),
     nullif(btrim(r.item#>>'{player,id}'),''));
   if ext is null then continue; end if;
   player_name:=coalesce(nullif(btrim(r.item->>'lineupPlayer'),''),
     nullif(btrim(r.item#>>'{player,name}'),''),nullif(btrim(r.item->>'playerName'),''),'');
   -- Provider identity only (resolve_global_entity never matches players by name).
   pid:=futbeat_private.futbeat_resolve_global_entity('goal_api','player',ext,player_name);
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
   tid:=case r.side when 'home' then home when 'away' then away end;
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
end $$;

-- Same signature for existing callers; no match context means no teamId.
create or replace function futbeat_private.harvest_lineup_media(p_payload jsonb,p_seen timestamptz)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform futbeat_private.harvest_lineup_players(null,p_payload,p_seen);
end $$;

create or replace function futbeat_private.store_match_detail(p_match_id text,p_external_match_id text,p_fetched_at timestamptz,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=futbeat_private.store_match_detail_before_media(p_match_id,p_external_match_id,p_fetched_at,p_payload);
 perform futbeat_private.harvest_lineup_players(p_match_id,p_payload,p_fetched_at);
 return result;
end $$;

-- A stored squad takes ownership of lineup-derived club facts. Incremental
-- wrapper (same pattern as store_team_squad_before_media): the squad write
-- itself is unchanged; afterwards, for each player this squad actually applied
-- to (same provider identity, now in this squad, squad timestamp stamped):
--   * squad-supplied position/shirtNumber already replaced lineup values;
--   * a lineup value the squad did not supply is dropped when the lineup had
--     placed the player in a DIFFERENT club (never a new club + old number);
--   * for the SAME club it is kept: it describes this club, so nothing mixes;
--   * lineupOwned/lineupSeenAt are removed: the squad now owns these fields.
-- Media and identity are untouched.
alter function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb)
 rename to store_team_squad_before_lineup_owner;
create function futbeat_private.futbeat_store_team_squad(p_team_id text,p_provider text,p_received_at timestamptz,p_players jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare tid text:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id); prior jsonb; result jsonb;
 r record; next_payload jsonb; owned text[]; lineup_team text; supplied jsonb; field text;
begin
 -- Lineup-owned state before the squad write, keyed by canonical player.
 select coalesce(jsonb_object_agg(e.id,jsonb_build_object('payload',e.payload,'item',x.item)),'{}')
 into prior
 from jsonb_array_elements(case when jsonb_typeof(p_players)='array' then p_players else '[]'::jsonb end) x(item)
 join futbeat_private.provider_entities pe on pe.provider='goal_api' and pe.kind='player'
   and pe.external_id=x.item#>>'{provenance,externalId}'
 join futbeat_private.entities e on e.id=futbeat_private.futbeat_resolve_entity_id('player',pe.canonical_id)
   and e.kind='player'
 where jsonb_typeof(e.payload->'lineupOwned')='array';
 result:=futbeat_private.store_team_squad_before_lineup_owner(p_team_id,p_provider,p_received_at,p_players);
 for r in select key pid,value from jsonb_each(prior) loop
   select payload into next_payload from futbeat_private.entities where id=r.pid and kind='player' for update;
   -- Only players this squad really applied to (an older squad observation is
   -- ignored by the inner function and must not strip anything).
   if next_payload is null or next_payload->>'teamId' is distinct from tid
      or futbeat_private.try_timestamptz(next_payload#>>'{provenance,receivedAt}') is distinct from p_received_at
      or not exists(select 1 from futbeat_private.team_squad_members sm
        where sm.team_id=tid and sm.player_id=r.pid) then
     continue;
   end if;
   owned:=array(select jsonb_array_elements_text(r.value->'payload'->'lineupOwned'));
   lineup_team:=case when 'teamId'=any(owned) then r.value->'payload'->>'teamId' end;
   foreach field in array array['position','shirtNumber'] loop
     supplied:=r.value->'item'->field;
     if field=any(owned) and lineup_team is distinct from tid
        and (supplied is null or supplied='null'::jsonb or supplied='""'::jsonb) then
       next_payload:=next_payload-field;
     end if;
   end loop;
   next_payload:=next_payload-'lineupOwned'-'lineupSeenAt';
   update futbeat_private.entities set payload=next_payload
     where id=r.pid and kind='player' and payload is distinct from next_payload;
 end loop;
 return result;
end $$;

create or replace function public.futbeat_player_catalog_metrics() returns jsonb
language sql stable security definer set search_path='' as $$
 with players as (
   select e.id,e.payload from futbeat_private.entities e where e.kind='player'
     and not exists(select 1 from futbeat_private.entity_redirects r where r.alias_id=e.id)
 ), appearances as (
   select exists(select 1 from futbeat_private.provider_entities pe where pe.provider='goal_api'
       and pe.kind='player' and pe.external_id=coalesce(nullif(btrim(l.item->>'playerId'),''),
         nullif(btrim(l.item->>'playerKey'),''),nullif(btrim(l.item#>>'{player,id}'),''))) resolved
   from futbeat_private.match_detail_cache c cross join lateral futbeat_private.lineup_rows(c.payload) l
 )
 select jsonb_build_object(
   'canonical_players',(select count(*) from players),
   'indexed_players',(select count(distinct s.entity_id) from futbeat_private.entity_search_index s
     join players p on p.id=s.entity_id),
   'mapped_players',(select count(*) from players p where exists(select 1 from futbeat_private.provider_entities pe
     where pe.kind='player' and pe.canonical_id=p.id)),
   'with_team',(select count(*) from players where coalesce(payload->>'teamId','')<>''),
   'with_position',(select count(*) from players where coalesce(btrim(payload->>'position'),'')<>''),
   'with_shirt_number',(select count(*) from players where jsonb_typeof(payload->'shirtNumber')='number'),
   'with_country',(select count(*) from players where coalesce(btrim(payload->>'country'),'')<>''),
   'with_photo',(select count(*) from players where futbeat_private.valid_player_media(payload->'media')),
   'lineup_appearances_resolved',(select count(*) from appearances where resolved),
   'lineup_appearances_unresolved',(select count(*) from appearances where not resolved))
$$;

-- Backfill from already stored detail only. Zero provider requests.
do $$ declare r record; begin
 for r in select match_id,payload,fetched_at from futbeat_private.match_detail_cache order by fetched_at loop
   perform futbeat_private.harvest_lineup_players(r.match_id,r.payload,r.fetched_at);
 end loop;
end $$;

revoke all on function futbeat_private.search_fold(text),
 futbeat_private.lineup_rows(jsonb),futbeat_private.lineup_position(text),
 futbeat_private.harvest_lineup_players(text,jsonb,timestamptz)
 from public,anon,authenticated,service_role;
-- Inner squad writer is internal only; the wrapper keeps the previous grants.
revoke all on function futbeat_private.store_team_squad_before_lineup_owner(text,text,timestamptz,jsonb)
 from public,anon,authenticated,service_role;
revoke all on function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb)
 from public,anon,authenticated;
grant execute on function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb) to service_role;
revoke all on function public.futbeat_player_catalog_metrics() from public,anon,authenticated;
grant execute on function public.futbeat_player_catalog_metrics() to service_role;
analyze futbeat_private.entity_search_index;
notify pgrst,'reload schema';
