-- Explorar first paint: make the Explore cache-miss path cheap.
--
-- Field report: the first Explorar open of a session showed an empty page for
-- 10-20 s. Production evidence (read-only, 2026-10-02):
--   * futbeat_private.catalog_cache_version.revision was 1784 while both
--     explore caches held version 1683: ~100 catalog bumps in ~8 h (any real
--     team/competition change, kickoff corrections...), on top of the 5 min
--     TTL. In practice the first open of a session is a cache MISS.
--   * The miss path of public.futbeat_read_explore() (also run by
--     futbeat_read_country_explore on its own miss) measured 5.4 s cold and
--     3.1 s warm with EXPLAIN ANALYZE of its SELECT. 2.2-4.5 s of it is the
--     `competitions` CTE: with a 1-row-ish estimate the planner merge-joins
--     metadata (509 rows) against a FULL walk of entities_pkey filtered by
--     kind (89k rows, ~90k buffers) instead of 509 primary-key probes. The
--     `activity` CTE added ~0.85 s, resolving the competition of each of the
--     ~5k window matches one by one.
--   * The country part itself is ~0.19 s.
--
-- This keeps the contract, cache table, version/TTL semantics, advisory lock
-- and output byte-for-byte equivalent, and only reshapes the miss query:
--   * competitions: one primary-key probe per editorial row (lateral
--     subquery with OFFSET 0, an optimization fence), never a pkey walk;
--   * activity: matches in the window are read once by primary key, each
--     distinct competition reference is resolved once (not per match), and
--     team ids are resolved once per distinct raw id.
-- Measured on production with the same data: 687 ms (vs 3.1-5.4 s) before
-- the join fix below; the per-match competition join is a plain hash join.
-- No GOAL call, no write other than the existing cache upsert.

create or replace function public.futbeat_read_explore() returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare v_version bigint; v_payload jsonb;
begin
 select revision into v_version from futbeat_private.catalog_cache_version;
 select payload into v_payload from futbeat_private.explore_cache
   where singleton and version=v_version and expires_at>now();
 if found then return v_payload; end if;
 perform pg_catalog.pg_advisory_xact_lock(hashtextextended('futbeat:explore',0));
 select revision into v_version from futbeat_private.catalog_cache_version;
 select payload into v_payload from futbeat_private.explore_cache
   where singleton and version=v_version and expires_at>now();
 if found then return v_payload; end if;
 with competitions as materialized (
   select e.id,e.payload,m.relevance_score,m.is_global_relevant
   from futbeat_private.competition_editorial_metadata m
   -- One primary-key probe per editorial row (OFFSET 0 keeps it a probe).
   cross join lateral (select e.id,e.payload from futbeat_private.entities e
     where e.id=m.competition_id and e.kind='competition' offset 0) e
   where not exists(select 1 from futbeat_private.entity_redirects r where r.alias_id=e.id and r.kind='competition')
   -- Relevance leads: domestic major leagues are not crowded out by global flags.
   order by m.relevance_score desc,m.is_global_relevant desc,e.payload->>'name',e.id limit 12
 ), window_matches as materialized (
   select c.start_time,e.payload->>'homeTeamId' home_id,e.payload->>'awayTeamId' away_id,
     e.payload->>'competitionId' competition_ref
   from futbeat_private.calendar_matches c
   cross join lateral (select e.payload from futbeat_private.entities e
     where e.id=c.match_id and e.kind='match' offset 0) e
   where c.start_time between now()-interval '7 days' and now()+interval '7 days'
 ), competition_scores as materialized (
   -- Each distinct competition reference is resolved once.
   select r.ref,m.relevance_score
   from (select distinct w.competition_ref ref from window_matches w where w.competition_ref is not null) r
   left join futbeat_private.competition_editorial_metadata m on m.competition_id=
     futbeat_private.futbeat_resolve_entity_id('competition',r.ref)
 ), sides as (
   select team.id raw_id,max(coalesce(s.relevance_score,100)) score,
     min(abs(extract(epoch from w.start_time-now()))) distance
   from window_matches w
   left join competition_scores s on s.ref=w.competition_ref
   cross join lateral (values(w.home_id),(w.away_id)) team(id)
   group by 1
 ), activity as (
   -- Each distinct raw team id is resolved once.
   select futbeat_private.futbeat_resolve_entity_id('team',raw_id) team_id,
     max(score) score,min(distance) distance
   from sides group by 1
 ), teams as (
   select e.payload,a.score,a.distance from activity a
   join futbeat_private.entities e on e.id=a.team_id and e.kind='team'
   order by a.score desc,a.distance,e.payload->>'name',e.id limit 16
 )
 select futbeat_private.catalog_snapshot(
   (select coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance_score)
      order by relevance_score desc,is_global_relevant desc,payload->>'name',id),'[]') from competitions),
   (select coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,score)
      order by score desc,distance,payload->>'name',payload->>'id'),'[]') from teams)
 ) into v_payload;
 insert into futbeat_private.explore_cache values(true,v_version,v_payload,now()+interval '5 minutes')
 on conflict(singleton) do update set version=excluded.version,payload=excluded.payload,expires_at=excluded.expires_at;
 return v_payload;
end $$;

revoke all on function public.futbeat_read_explore() from public,anon,authenticated;
grant execute on function public.futbeat_read_explore() to service_role;

notify pgrst,'reload schema';
