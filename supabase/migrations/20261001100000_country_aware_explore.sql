-- Country-aware onboarding/Explore suggestions.
--
-- The global Explore payload is one country-agnostic list (top competitions by
-- editorial relevance, teams by nearby activity). For a user in a country with
-- a modest editorial score, neither the primary domestic league nor its clubs
-- nor the national team ever made that cut, so onboarding suggested foreign
-- national teams instead. This adds a country lens on top of the same global
-- list: country is a relevance signal only and never filters the catalog.
--
-- Everything is derived from catalog metadata (country_catalog,
-- competition_editorial_metadata, match activity). No team, league or country
-- is named here.

-- Competitions also expose the domestic contract the feed already uses, so the
-- client can apply the same country-aware ordering to catalog entries.
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
   || coalesce((select jsonb_strip_nulls(jsonb_build_object(
        'isPrimaryDomestic',m.is_primary_domestic,'domesticTier',m.domestic_tier))
      from futbeat_private.competition_editorial_metadata m
      where not (p_payload ? 'competitionId') and not (p_payload ? 'teamId')
        and m.competition_id=futbeat_private.futbeat_resolve_entity_id(
          'competition',p_payload->>'id')),'{}'::jsonb)
$$;

create table futbeat_private.explore_country_cache (
 country_code text primary key references futbeat_private.country_catalog(country_code) on delete cascade,
 version bigint not null,payload jsonb not null,expires_at timestamptz not null
);
alter table futbeat_private.explore_country_cache enable row level security;
revoke all on futbeat_private.explore_country_cache from public,anon,authenticated;

-- Global Explore plus, first, the country's own competitions (primary domestic
-- league first), its national team and the clubs of its primary league. An
-- unknown or supranational code answers the plain global Explore payload, so
-- the cache is bounded by country_catalog.
create function public.futbeat_read_country_explore(p_country text) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare v_code text; v_version bigint; v_payload jsonb; v_global jsonb;
begin
 if length(coalesce(p_country,''))>8 then raise exception 'Invalid country'; end if;
 select c.country_code into v_code from futbeat_private.country_catalog c
   where c.country_code=upper(btrim(coalesce(p_country,''))) and not c.is_supranational;
 if v_code is null then return public.futbeat_read_explore(); end if;
 select revision into v_version from futbeat_private.catalog_cache_version;
 select payload into v_payload from futbeat_private.explore_country_cache
   where country_code=v_code and version=v_version and expires_at>now();
 if found then return v_payload; end if;
 v_global:=public.futbeat_read_explore();
 perform pg_catalog.pg_advisory_xact_lock(hashtextextended('futbeat:explore:'||v_code,0));
 select revision into v_version from futbeat_private.catalog_cache_version;
 select payload into v_payload from futbeat_private.explore_country_cache
   where country_code=v_code and version=v_version and expires_at>now();
 if found then return v_payload; end if;
 with local_competitions as materialized (
   -- GB also covers its football nations (GB-ENG, GB-SCT, ...).
   select e.id,e.payload,m.relevance_score,m.is_primary_domestic,m.competition_class,m.country_code,
     row_number() over(order by m.is_primary_domestic desc,m.domestic_tier nulls last,
       m.relevance_score desc,e.payload->>'name',e.id) rn
   from futbeat_private.competition_editorial_metadata m
   join futbeat_private.entities e on e.id=m.competition_id and e.kind='competition'
   where (m.country_code=v_code or m.country_code like v_code||'-%')
     and not exists(select 1 from futbeat_private.entity_redirects r
       where r.alias_id=e.id and r.kind='competition')
 ), club_sources as materialized (
   -- Clubs come from the primary domestic league; a country without one falls
   -- back to its leading domestic league.
   select c.id,c.relevance_score,c.country_code from local_competitions c
   where c.is_primary_domestic or (not exists(select 1 from local_competitions p
       where p.is_primary_domestic)
     and c.rn=(select min(l.rn) from local_competitions l where l.competition_class='domestic_league'))
 ), club_refs as (
   select s.id,s.id ref,s.relevance_score,s.country_code from club_sources s
   union
   select s.id,r.alias_id,s.relevance_score,s.country_code from club_sources s
   join futbeat_private.entity_redirects r on r.canonical_id=s.id and r.kind='competition'
 ), clubs as materialized (
   select futbeat_private.futbeat_resolve_entity_id('team',side.id) team_id,
     max(r.relevance_score) score,max(cm.start_time) last_seen,min(r.country_code) country_code
   from club_refs r
   join futbeat_private.entities match on match.kind='match'
     and match.payload->>'competitionId'=r.ref
   left join futbeat_private.calendar_matches cm on cm.match_id=match.id
   cross join lateral (values(match.payload->>'homeTeamId'),(match.payload->>'awayTeamId')) side(id)
   where side.id is not null
   group by 1
 ), national_names as (
   select c.country_code,n.term from futbeat_private.country_catalog c
   cross join lateral (select lower(c.canonical_name) term
     union select jsonb_array_elements_text(c.aliases)) n
   where (c.country_code=v_code or c.country_code like v_code||'-%') and not c.is_supranational
 ), national as materialized (
   -- A national team carries the country's catalogued name and plays an
   -- international national-team (or unclassified, non-domestic) competition.
   select distinct on (team.id) team.id team_id,team.payload,n.country_code,
     coalesce(meta.relevance_score,100) score
   from national_names n
   join futbeat_private.entity_search_index s on s.kind='team' and s.term=n.term
   join futbeat_private.entities team on team.kind='team'
     and team.id=futbeat_private.futbeat_resolve_entity_id('team',s.entity_id)
   join futbeat_private.competition_editorial_metadata meta on meta.competition_id=
     futbeat_private.futbeat_resolve_entity_id('competition',team.payload->>'competitionId')
   left join futbeat_private.country_catalog region on region.country_code=meta.country_code
   where meta.audience_class in ('open','unknown')
     and (meta.competition_class='international_national'
       or (meta.competition_class='other' and (meta.country_code is null or region.is_supranational)))
   order by team.id,score desc
 ), local_teams as (
   select 0 grp,n.payload,n.score,null::timestamptz last_seen,n.country_code,true national
   from national n
   union all
   select 1,e.payload,c.score,c.last_seen,c.country_code,false from clubs c
   join futbeat_private.entities e on e.id=c.team_id and e.kind='team'
   where not exists(select 1 from national n where n.team_id=c.team_id)
 ), ordered_local_teams as (
   select payload,
     -- The team's own last competition may be a regional cup: its country
     -- here is the one of the league (or nation) that made it local.
     futbeat_private.catalog_entity(payload,score)
       || jsonb_build_object('countryCode',country_code)
       || case when national then jsonb_build_object('isNationalTeam',true)
          else jsonb_build_object('isPrimaryDomesticClub',true) end item,
     row_number() over(order by grp,last_seen desc nulls last,lower(payload->>'name'),payload->>'id') rn
   from local_teams
 ), local_competition_items as (
   select futbeat_private.catalog_entity(payload,relevance_score) item,rn
   from local_competitions where rn<=6
 )
 select futbeat_private.catalog_snapshot(
   (select coalesce(jsonb_agg(item order by ord,rn),'[]') from (
      select item,0 ord,rn from local_competition_items
      union all
      select g.item,1,g.rn from jsonb_array_elements(v_global->'competitions') with ordinality g(item,rn)
      where not exists(select 1 from local_competition_items l where l.item->>'id'=g.item->>'id')) c),
   (select coalesce(jsonb_agg(item order by ord,rn),'[]') from (
      select item,0 ord,rn from ordered_local_teams where rn<=20
      union all
      select g.item,1,g.rn from jsonb_array_elements(v_global->'teams') with ordinality g(item,rn)
      where not exists(select 1 from ordered_local_teams l
        where l.rn<=20 and l.item->>'id'=g.item->>'id')) t)
 ) into v_payload;
 insert into futbeat_private.explore_country_cache values(v_code,v_version,v_payload,now()+interval '5 minutes')
 on conflict(country_code) do update set version=excluded.version,payload=excluded.payload,
   expires_at=excluded.expires_at;
 return v_payload;
end $$;

revoke all on function public.futbeat_read_country_explore(text) from public,anon,authenticated;
grant execute on function public.futbeat_read_country_explore(text) to service_role;

-- Cached payloads predate the new competition fields.
update futbeat_private.catalog_cache_version set revision=revision+1 where singleton;

notify pgrst,'reload schema';
