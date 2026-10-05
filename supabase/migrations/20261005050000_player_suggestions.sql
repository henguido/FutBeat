-- Player suggestions without a query (Explorar / onboarding).
--
-- Evidence (read-only production, 2026-10-05): /v1/explore has no players
-- section (catalog_snapshot players = []), so "Jugadores" suggestions were
-- always empty while team_squad_members holds 30k+ real squad rows (881
-- teams). Search already works.
--
-- futbeat_read_player_suggestions(p_team_ids, p_country): at most 30 real
-- canonical players from stored squads (no provider call, no write):
--   1. squads of the caller's followed teams (<= 20 ids, <= 10 per team);
--   2. squads of the clubs of p_country's editorial competitions;
--   3. squads of the clubs of the globally relevant competitions.
-- Deduplicated by canonical id (redirected aliases resolved, alias rows
-- skipped); a verified photo first inside each tier; `teamId` is the squad's
-- team (why the player is suggested). Nothing is invented: an empty squad
-- table answers [].
-- Rollback: drop function public.futbeat_read_player_suggestions(text[],text).

create or replace function public.futbeat_read_player_suggestions(
  p_team_ids text[] default '{}',p_country text default null
) returns jsonb language sql stable security definer set search_path='' as $$
 with followed as (
   select distinct on (t.id) t.id,ord
   from unnest(coalesce(p_team_ids,'{}'::text[])) with ordinality f(raw,ord)
   cross join lateral (select futbeat_private.futbeat_resolve_entity_id('team',f.raw) id) t
   where f.ord<=20 and f.raw ~ '^fb_team_[A-Za-z0-9_]+$'
   order by t.id,ord
 ), country_teams as (
   select e.id,max(m.relevance_score) score
   from futbeat_private.competition_editorial_metadata m
   join futbeat_private.entities e on e.kind='team' and e.payload->>'competitionId'=m.competition_id
   where p_country ~ '^[A-Z]{2}$' and m.country_code=p_country
   group by e.id
   order by max(m.relevance_score) desc,e.id limit 40
 ), global_teams as (
   select e.id,max(m.relevance_score) score
   from futbeat_private.competition_editorial_metadata m
   join futbeat_private.entities e on e.kind='team' and e.payload->>'competitionId'=m.competition_id
   where m.is_global_relevant
   group by e.id
   order by max(m.relevance_score) desc,e.id limit 40
 ), sources as (
   select id team_id,1 tier,ord::integer rank,10 per_team from followed
   union all select id,2,(row_number() over (order by score desc,id))::integer,3 from country_teams
   union all select id,3,(row_number() over (order by score desc,id))::integer,2 from global_teams
 ), candidates as (
   select s.tier,s.rank,s.team_id,p.id player_id,p.payload,
     futbeat_private.valid_player_media(p.payload->'media') has_photo,
     row_number() over (partition by s.tier,s.team_id
       order by futbeat_private.valid_player_media(p.payload->'media') desc,p.payload->>'name',p.id) in_team,
     s.per_team
   from sources s
   join futbeat_private.team_squad_members m on m.team_id=s.team_id
   join futbeat_private.entities p on p.id=m.player_id and p.kind='player'
   where nullif(btrim(p.payload->>'name'),'') is not null
     and not exists(select 1 from futbeat_private.entity_redirects r
       where r.alias_id=p.id and r.kind='player')
 ), unique_players as (
   select distinct on (player_id) * from candidates
   where in_team<=per_team
   order by player_id,tier,rank,in_team
 ), picked as (
   select * from unique_players
   order by tier,has_photo desc,rank,in_team,payload->>'name',player_id
   limit 30
 )
 select coalesce(jsonb_agg(
   futbeat_private.catalog_entity(payload||jsonb_build_object('teamId',team_id),
     case tier when 1 then 300 when 2 then 200 else 100 end)
   order by tier,has_photo desc,rank,in_team,payload->>'name',player_id),'[]'::jsonb)
 from picked
$$;

revoke all on function public.futbeat_read_player_suggestions(text[],text) from public,anon,authenticated;
grant execute on function public.futbeat_read_player_suggestions(text[],text) to service_role;

notify pgrst,'reload schema';
