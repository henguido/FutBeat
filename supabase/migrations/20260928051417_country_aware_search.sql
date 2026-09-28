-- Country is a relevance signal only. It never filters the global catalog.
-- The compact Explore contract must expose the canonical code used by the
-- client. Normal ingestion stores human-readable country names in payloads,
-- while competition metadata owns the authoritative ISO code.
create or replace function futbeat_private.catalog_entity(p_payload jsonb,p_score integer)
returns jsonb language sql stable set search_path='' as $$
 select jsonb_strip_nulls(jsonb_build_object('id',p_payload->'id','name',p_payload->'name',
   'shortName',p_payload->'shortName','country',p_payload->'country',
   'countryCode',to_jsonb(case
     when p_payload ? 'teamId' then coalesce(
       futbeat_private.resolve_country_code(p_payload->>'countryCode'),
       futbeat_private.resolve_country_code(p_payload->>'country'),
       (select coalesce(futbeat_private.resolve_country_code(t.payload->>'countryCode'),
                        futbeat_private.resolve_country_code(t.payload->>'country'))
        from futbeat_private.entities t where t.kind='team' and t.id=
          futbeat_private.futbeat_resolve_entity_id('team',p_payload->>'teamId')),
       (select m.country_code from futbeat_private.competition_editorial_metadata m
        where m.competition_id=futbeat_private.futbeat_resolve_entity_id('competition',
          (select t.payload->>'competitionId' from futbeat_private.entities t
           where t.kind='team' and t.id=
             futbeat_private.futbeat_resolve_entity_id('team',p_payload->>'teamId')))))
     when p_payload ? 'competitionId' then coalesce(
       futbeat_private.resolve_country_code(p_payload->>'countryCode'),
       futbeat_private.resolve_country_code(p_payload->>'country'),
       (select m.country_code from futbeat_private.competition_editorial_metadata m
        where m.competition_id=futbeat_private.futbeat_resolve_entity_id(
          'competition',p_payload->>'competitionId')))
     else coalesce(
       (select m.country_code from futbeat_private.competition_editorial_metadata m
        where m.competition_id=futbeat_private.futbeat_resolve_entity_id(
          'competition',p_payload->>'id')),
       futbeat_private.resolve_country_code(p_payload->>'countryCode'),
       futbeat_private.resolve_country_code(p_payload->>'country')) end),
   'media',p_payload->'media','competitionId',p_payload->'competitionId',
   'teamId',p_payload->'teamId','relevanceScore',p_score,
   'isGlobalRelevant',to_jsonb(coalesce(
     (select m.is_global_relevant
      from futbeat_private.competition_editorial_metadata m
      where not (p_payload ? 'competitionId') and not (p_payload ? 'teamId')
        and m.competition_id=futbeat_private.futbeat_resolve_entity_id(
          'competition',p_payload->>'id')),false))))
$$;

-- Country detection and a manual override are independent preferences. A
-- client must not overwrite one with a stale cached value while updating the
-- other, so expose an explicitly partial synchronization contract.
create or replace function futbeat_private.sync_user_preference_fields(
  p_detected text,p_selected text,p_update_detected boolean,p_update_selected boolean)
returns void language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();
begin
 if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
 p_detected:=nullif(upper(trim(p_detected)),'');
 p_selected:=nullif(upper(trim(p_selected)),'');
 if (p_update_detected and p_detected is not null and p_detected!~'^[A-Z]{2}$')
   or (p_update_selected and p_selected is not null and p_selected!~'^[A-Z]{2}$')
  then raise exception 'Invalid country'; end if;
 insert into futbeat_private.user_preferences(user_id,detected_country,selected_country,updated_at)
 values(uid,case when p_update_detected then p_detected end,
   case when p_update_selected then p_selected end,now())
 on conflict(user_id) do update set
   detected_country=case when p_update_detected then excluded.detected_country
     else futbeat_private.user_preferences.detected_country end,
   selected_country=case when p_update_selected then excluded.selected_country
     else futbeat_private.user_preferences.selected_country end,
   updated_at=now();
 perform futbeat_private.refresh_interest_aggregates();
end $$;
create or replace function public.futbeat_sync_user_preference_fields(
  p_detected text,p_selected text,p_update_detected boolean,p_update_selected boolean)
returns void language sql security invoker set search_path='' as $$
 select futbeat_private.sync_user_preference_fields(
   p_detected,p_selected,p_update_detected,p_update_selected)
$$;
revoke all on function futbeat_private.sync_user_preference_fields(text,text,boolean,boolean),
 public.futbeat_sync_user_preference_fields(text,text,boolean,boolean) from public,anon;
grant execute on function futbeat_private.sync_user_preference_fields(text,text,boolean,boolean),
 public.futbeat_sync_user_preference_fields(text,text,boolean,boolean) to authenticated;

create or replace function public.futbeat_search_catalog(
 p_query text default '',p_country text default null,p_limit integer default 50)
returns jsonb language plpgsql volatile security definer
set search_path='' set pg_trgm.strict_word_similarity_threshold='0.5' as $$
declare qr text:=lower(btrim(coalesce(p_query,''))); pr text; qf text; pf text;
 vc text:=upper(btrim(coalesce(p_country,''))); v_result jsonb;
 v_player_ok boolean; v_demand jsonb;
begin
 if length(qr)>80 or length(vc)>8 then raise exception 'Invalid search query'; end if;
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
     bool_or(h.kind='player' and position(' ' in qf)>0
       and extensions.strict_word_similarity(qf,h.term)>=0.5
       and futbeat_private.search_word_guard(qf,h.term)>=0.35) multiword_fuzzy,
     bool_or(h.kind='player' and (h.term=qf or h.term like pf||' %' or h.term like '% '||pf
       or h.term like '% '||pf||' %')) whole_word
   from hits h join futbeat_private.entities src on src.id=h.entity_id
   cross join lateral (select h.kind='player' and h.term in (lower(btrim(coalesce(src.payload->>'name',''))),
     coalesce(futbeat_private.search_fold(src.payload->>'name'),''),
     coalesce(futbeat_private.search_compact_fold(src.payload->>'name'),'')) is_name) n
   group by h.kind,2
 ), scored as (
   select e.id,e.kind,e.payload,h.quality,h.similarity,h.whole_word,h.multiword_fuzzy,
     coalesce(meta.relevance_score,100) relevance,
     case when vc<>'' and (canonical.country_code=vc
       or canonical.country_code like vc||'-%') then 1 else 0 end country_priority
   from matches h join futbeat_private.entities e on e.id=h.id and e.kind=h.kind
   left join futbeat_private.entities team on e.kind='player' and team.id=
     futbeat_private.futbeat_resolve_entity_id('team',e.payload->>'teamId')
   left join futbeat_private.competition_editorial_metadata meta on meta.competition_id=
     case when e.kind='competition' then e.id else futbeat_private.futbeat_resolve_entity_id(
       'competition',coalesce(e.payload->>'competitionId',team.payload->>'competitionId')) end
   cross join lateral (select case e.kind
     when 'competition' then coalesce(meta.country_code,
       futbeat_private.resolve_country_code(e.payload->>'countryCode'),
       futbeat_private.resolve_country_code(e.payload->>'country'))
     when 'team' then coalesce(
       futbeat_private.resolve_country_code(e.payload->>'countryCode'),
       futbeat_private.resolve_country_code(e.payload->>'country'),meta.country_code)
     when 'player' then coalesce(
       futbeat_private.resolve_country_code(e.payload->>'countryCode'),
       futbeat_private.resolve_country_code(e.payload->>'country'),
       futbeat_private.resolve_country_code(team.payload->>'countryCode'),
       futbeat_private.resolve_country_code(team.payload->>'country'),meta.country_code)
     end country_code) canonical
   where e.kind<>'player' or h.quality>=2 or (h.quality=1 and length(qf)>=4)
     or (position(' ' in qf)=0 and h.similarity>=0.5)
     or h.multiword_fuzzy
 ), ranked as (
   select *,row_number() over(partition by kind order by quality desc,country_priority desc,
     similarity desc,relevance desc,lower(payload->>'name'),id) rn from scored
 ), bounded as (
   select * from ranked where rn<=greatest(1,least(coalesce(p_limit,50),75))
 )
 select futbeat_private.catalog_snapshot(
   coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance) order by rn) filter(where kind='competition'),'[]'),
   coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance) order by rn) filter(where kind='team'),'[]'),
   coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance) order by rn) filter(where kind='player'),'[]')
 ),
 coalesce(bool_or(kind='player' and (whole_word or multiword_fuzzy)),false)
 into v_result,v_player_ok from bounded;
 if qf is not null and not v_player_ok then
   v_demand:=futbeat_private.note_player_search_demand(qr);
   if (v_demand->>'pending')::boolean then
     v_result:=jsonb_set(v_result,'{coverage,pendingRemote}','true'::jsonb,true);
   end if;
 end if;
 return v_result;
end $$;

revoke all on function public.futbeat_search_catalog(text,text,integer)
from public,anon,authenticated;
grant execute on function public.futbeat_search_catalog(text,text,integer)
to service_role;

notify pgrst,'reload schema';
