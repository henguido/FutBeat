-- CANDIDATE, NOT APPLIED. Manual on purpose: outside supabase/migrations so no
-- build, db push or kit picks it up. Requires owner authorization.
--
-- Stored-only readers for futbeat-qa-stored. Every function is STABLE: PostgREST
-- runs them in a read-only transaction, so a write would fail instead of landing.
-- They never build, enqueue, wake or touch calendar_snapshot_zones. Expired or
-- outdated rows are served marked stale; a missing row is NULL or an empty catalog.
-- futbeat_read_qa_stored_calendar keeps the name and arguments of
-- scripts/qa/qa227-stored-calendar.sql (mobile), and also accepts other timezones.
-- Rollback: 20261031_qa_stored_reads_candidate_rollback.sql

create or replace function public.futbeat_read_qa_stored_calendar(
  p_local_date date,p_timezone text default 'America/Costa_Rica')
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_row futbeat_private.compact_calendar_cache;
begin
 -- Exact key lookup: an unknown timezone is a miss, no validation needed.
 select * into v_row from futbeat_private.compact_calendar_cache
   where calendar_date=p_local_date and timezone=p_timezone;
 if not found then return null; end if;
 return v_row.payload||jsonb_build_object('freshness',jsonb_build_object(
   'stale',v_row.expires_at<=now()
     or v_row.version<>futbeat_private.calendar_cache_version(p_local_date,p_timezone),
   'revalidating',false));
end $$;

create or replace function public.futbeat_read_qa_stored_explore(p_country text default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_revision bigint; v_payload jsonb; v_version bigint; v_expires timestamptz;
begin
 if length(coalesce(p_country,''))>8 then raise exception 'Invalid country'; end if;
 select c.payload,c.version,c.expires_at into v_payload,v_version,v_expires
   from futbeat_private.explore_country_cache c
   where c.country_code=upper(btrim(coalesce(p_country,'')));
 if not found then
   select c.payload,c.version,c.expires_at into v_payload,v_version,v_expires
     from futbeat_private.explore_cache c where c.singleton;
 end if;
 if v_payload is null then return futbeat_private.catalog_snapshot('[]','[]'); end if;
 select revision into v_revision from futbeat_private.catalog_cache_version;
 return v_payload||jsonb_build_object('freshness',jsonb_build_object(
   'stale',v_expires<=now() or v_version<>v_revision,'revalidating',false));
end $$;

-- Deployed futbeat_search_catalog (read with pg_get_functiondef on 2026-10-31) without
-- its player demand and without the explore fallback of an empty query.
create or replace function public.futbeat_read_qa_stored_search(
  p_query text default '',p_country text default null,p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare qr text:=lower(btrim(coalesce(p_query,''))); pr text; qf text; pf text;
 vc text:=upper(btrim(coalesce(p_country,''))); v_result jsonb;
begin
 if length(qr)>80 or length(vc)>8 then raise exception 'Invalid search query'; end if;
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
       and futbeat_private.search_word_guard(qf,h.term)>=0.35) multiword_fuzzy
   from hits h join futbeat_private.entities src on src.id=h.entity_id
   cross join lateral (select h.kind='player' and h.term in (lower(btrim(coalesce(src.payload->>'name',''))),
     coalesce(futbeat_private.search_fold(src.payload->>'name'),''),
     coalesce(futbeat_private.search_compact_fold(src.payload->>'name'),'')) is_name) n
   group by h.kind,2
 ), scored as (
   select e.id,e.kind,e.payload,h.quality,h.similarity,h.multiword_fuzzy,
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
 ) into v_result from bounded;
 return v_result;
end $$;

create or replace function public.futbeat_read_qa_stored_national_teams()
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce((select c.payload from futbeat_private.national_team_cache c where c.singleton),
    '{"schemaVersion":1,"teams":{}}'::jsonb)
$$;

revoke all on function public.futbeat_read_qa_stored_calendar(date,text) from public,anon,authenticated;
revoke all on function public.futbeat_read_qa_stored_explore(text) from public,anon,authenticated;
revoke all on function public.futbeat_read_qa_stored_search(text,text,integer) from public,anon,authenticated;
revoke all on function public.futbeat_read_qa_stored_national_teams() from public,anon,authenticated;
grant execute on function public.futbeat_read_qa_stored_calendar(date,text) to service_role;
grant execute on function public.futbeat_read_qa_stored_explore(text) to service_role;
grant execute on function public.futbeat_read_qa_stored_search(text,text,integer) to service_role;
grant execute on function public.futbeat_read_qa_stored_national_teams() to service_role;
