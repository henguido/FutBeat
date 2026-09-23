-- Player search: per-word guard for multi-word typos + apostrophe-free names.
--
-- Multi-word fuzzy player matches previously needed strict word similarity
-- >= 0.65. That dropped one-letter typos in six-letter words ("keilor navas"
-- vs "keylor navas" = 0.625) yet still accepted players that only share a long
-- first name ("maximiliano ruiz" vs "maximiliano lopez" = 0.706). Now a
-- multi-word fuzzy match needs >= 0.5 AND every query word must resemble some
-- word of the term (trigram similarity >= 0.35 or word prefix). A word with no
-- counterpart ("messi" vs "scaloni" = 0) rejects the candidate.
--
-- Names with apostrophes ("N'Golo Kanté") also get a compact folded variant
-- ("ngolo kante") so "ngolo" finds them. Players only: teams and competitions
-- keep exactly the previous terms, filter, formula and order.

create or replace function futbeat_private.search_compact_fold(p_value text)
returns text language sql immutable set search_path='' as $$
 select futbeat_private.search_fold(regexp_replace(coalesce(p_value,''),'[''’`´]','','g'))
$$;

-- Weakest per-word match of a query against a term: 1 when every query word
-- is a word prefix, 0 when some query word has no similar term word.
create or replace function futbeat_private.search_word_guard(p_query text,p_term text)
returns real language sql immutable set search_path='' as $$
 select coalesce(min(best),0)::real from (
   select (select max(greatest(extensions.similarity(w,x),case when x like w||'%' then 1 else 0 end))
     from unnest(string_to_array(p_term,' ')) x where x<>'') best
   from unnest(string_to_array(p_query,' ')) w where w<>''
 ) words
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
     (case when new.kind='player' then futbeat_private.search_fold(term) end),
     (case when new.kind='player' then futbeat_private.search_compact_fold(term) end)) v(variant)
   where nullif(btrim(variant),'') is not null on conflict do nothing;
 end if;
 return new;
end $$;

-- Backfill compact variants for players only (existing terms are kept).
insert into futbeat_private.entity_search_index
select e.id,e.kind,futbeat_private.search_compact_fold(term) from futbeat_private.entities e cross join lateral (
 select e.payload->>'name' term union select e.payload->>'shortName'
 union select jsonb_array_elements_text(case when jsonb_typeof(e.payload->'aliases')='array'
   then e.payload->'aliases' else '[]'::jsonb end)
) terms where e.kind='player'
  and futbeat_private.search_compact_fold(term) is not null
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
       else extensions.strict_word_similarity(qf,h.term) end) similarity,
     max(case when h.kind='player' and position(' ' in qf)>0
       then futbeat_private.search_word_guard(qf,h.term) end) word_guard
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
     or (position(' ' in qf)>0 and h.similarity>=0.5 and h.word_guard>=0.35)
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

revoke all on function futbeat_private.search_compact_fold(text),
 futbeat_private.search_word_guard(text,text)
 from public,anon,authenticated,service_role;
analyze futbeat_private.entity_search_index;
notify pgrst,'reload schema';
