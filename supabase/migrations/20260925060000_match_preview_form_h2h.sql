-- Issue #99 phase 2: recent form + head-to-head for Match Center.
--
-- A SEPARATE, DB-only read model (never inside futbeat_read_match_context,
-- which stays light): no demand, no worker wake-up, no provider call.
--
-- Indexes: finding a team's matches scanned every match entity (no index on
-- homeTeamId/awayTeamId; ~395 ms in production for recent form + H2H). Two
-- partial expression indexes, the same shape as entities_match_competition_idx,
-- let "matches of team X" be a BitmapOr of two index lookups. A team has at
-- most a few hundred stored matches, so sorting them by kickoff is trivial.
--
-- Rules (generic, canonical ids only, never names):
--   * Form: up to 5 terminal (FINISHED_PENDING_VERIFICATION / VERIFIED)
--     matches of each side kicked off BEFORE the target's kickoff (not now():
--     a historical Match Center never sees later results), within 365 days
--     (bounded; 90 days completed 5 for both sides in only ~31% of fixtures).
--   * Result from the team's perspective only with a complete score.
--   * H2H: up to 5 terminal meetings of exactly the two canonical team ids,
--     both orientations, any competition, before the target's kickoff.
--   * Compact payload: each match once (no events/lineups/statistics), with
--     the teams and competitions it references.

create index if not exists entities_match_home_team_idx
  on futbeat_private.entities ((payload->>'homeTeamId'))
  where kind='match';
create index if not exists entities_match_away_team_idx
  on futbeat_private.entities ((payload->>'awayTeamId'))
  where kind='match';

-- WIN | DRAW | LOSS for team_id in a match payload; null without a complete
-- score or when the team did not play it.
create or replace function futbeat_private.team_match_result(p_payload jsonb,p_team_id text)
returns text language sql immutable set search_path='' as $$
  select case
    when coalesce(jsonb_typeof(p_payload->'score'->'home'),'')<>'number'
      or coalesce(jsonb_typeof(p_payload->'score'->'away'),'')<>'number' then null
    when p_payload->>'homeTeamId'=p_team_id then case
      when (p_payload->'score'->>'home')::numeric>(p_payload->'score'->>'away')::numeric then 'WIN'
      when (p_payload->'score'->>'home')::numeric=(p_payload->'score'->>'away')::numeric then 'DRAW'
      else 'LOSS' end
    when p_payload->>'awayTeamId'=p_team_id then case
      when (p_payload->'score'->>'away')::numeric>(p_payload->'score'->>'home')::numeric then 'WIN'
      when (p_payload->'score'->>'away')::numeric=(p_payload->'score'->>'home')::numeric then 'DRAW'
      else 'LOSS' end
  end
$$;

create or replace function futbeat_private.read_match_preview(p_match_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t jsonb; kickoff timestamptz; home text; away text;
  form_days constant integer:=365; max_items constant integer:=5;
  home_ids text[]; away_ids text[]; h2h_ids text[]; result jsonb;
begin
  select e.payload into t from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
  if t is null then return null; end if;
  kickoff:=nullif(t->>'startTime','')::timestamptz;
  home:=nullif(t->>'homeTeamId','');
  away:=nullif(t->>'awayTeamId','');

  if kickoff is not null and home is not null and away is not null then
    -- Recent form per side (index: BitmapOr of home/away team indexes).
    select array_agg(x.id order by x.st desc,x.id) into home_ids from (
      select e.id,nullif(e.payload->>'startTime','')::timestamptz st
      from futbeat_private.entities e
      where e.kind='match' and (e.payload->>'homeTeamId'=home or e.payload->>'awayTeamId'=home)
        and e.payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
        and nullif(e.payload->>'startTime','')::timestamptz<kickoff
        and nullif(e.payload->>'startTime','')::timestamptz>=kickoff-make_interval(days=>form_days)
      order by 2 desc,1 limit max_items) x;
    select array_agg(x.id order by x.st desc,x.id) into away_ids from (
      select e.id,nullif(e.payload->>'startTime','')::timestamptz st
      from futbeat_private.entities e
      where e.kind='match' and (e.payload->>'homeTeamId'=away or e.payload->>'awayTeamId'=away)
        and e.payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
        and nullif(e.payload->>'startTime','')::timestamptz<kickoff
        and nullif(e.payload->>'startTime','')::timestamptz>=kickoff-make_interval(days=>form_days)
      order by 2 desc,1 limit max_items) x;
    -- Head-to-head: exactly these two canonical ids, both orientations.
    if home<>away then
      select array_agg(x.id order by x.st desc,x.id) into h2h_ids from (
        select e.id,nullif(e.payload->>'startTime','')::timestamptz st
        from futbeat_private.entities e
        where e.kind='match'
          and ((e.payload->>'homeTeamId'=home and e.payload->>'awayTeamId'=away)
            or (e.payload->>'homeTeamId'=away and e.payload->>'awayTeamId'=home))
          and e.payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
          and nullif(e.payload->>'startTime','')::timestamptz<kickoff
        order by 2 desc,1 limit max_items) x;
    end if;
  end if;
  home_ids:=coalesce(home_ids,'{}'); away_ids:=coalesce(away_ids,'{}'); h2h_ids:=coalesce(h2h_ids,'{}');

  with ids as (
    select distinct unnest(home_ids||away_ids||h2h_ids) id
  ), items as (
    select e.id,e.payload p from futbeat_private.entities e join ids on ids.id=e.id where e.kind='match'
  ), team_ids as (
    select distinct x id from (
      select home x union all select away
      union all select i.p->>'homeTeamId' from items i
      union all select i.p->>'awayTeamId' from items i) t where x is not null
  ), comp_ids as (
    select distinct i.p->>'competitionId' id from items i where i.p->>'competitionId' is not null
  )
  select jsonb_build_object(
    'schemaVersion',1,
    'matchId',p_match_id,
    'homeTeamId',home,
    'awayTeamId',away,
    'startTime',t->>'startTime',
    'formWindowDays',form_days,
    'form',jsonb_build_object(
      'home',jsonb_build_object(
        'state',case cardinality(home_ids) when 0 then 'none' when max_items then 'available' else 'partial' end,
        'matchIds',to_jsonb(home_ids),
        'results',(select coalesce(jsonb_agg(futbeat_private.team_match_result(i.p,home) order by o.n),'[]')
          from unnest(home_ids) with ordinality o(id,n) join items i on i.id=o.id)),
      'away',jsonb_build_object(
        'state',case cardinality(away_ids) when 0 then 'none' when max_items then 'available' else 'partial' end,
        'matchIds',to_jsonb(away_ids),
        'results',(select coalesce(jsonb_agg(futbeat_private.team_match_result(i.p,away) order by o.n),'[]')
          from unnest(away_ids) with ordinality o(id,n) join items i on i.id=o.id))),
    'h2h',jsonb_build_object(
      'state',case when cardinality(h2h_ids)>0 then 'available' else 'none' end,
      'matchIds',to_jsonb(h2h_ids),
      -- From the target home team's perspective, complete scores only.
      'summary',(select jsonb_build_object(
          'homeWins',count(*) filter(where r='WIN'),
          'draws',count(*) filter(where r='DRAW'),
          'awayWins',count(*) filter(where r='LOSS'),
          'counted',count(r))
        from (select futbeat_private.team_match_result(i.p,home) r
          from unnest(h2h_ids) o(id) join items i on i.id=o.id) s)),
    'matches',(select coalesce(jsonb_agg(jsonb_build_object(
        'matchId',i.id,
        'competitionId',i.p->>'competitionId',
        'startTime',i.p->>'startTime',
        'status',i.p->>'status',
        'homeTeamId',i.p->>'homeTeamId',
        'awayTeamId',i.p->>'awayTeamId',
        'score',case when jsonb_typeof(i.p->'score'->'home')='number' and jsonb_typeof(i.p->'score'->'away')='number'
          then jsonb_build_object('home',i.p->'score'->'home','away',i.p->'score'->'away') end)
        order by nullif(i.p->>'startTime','')::timestamptz desc,i.id),'[]') from items i),
    'teams',(select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'id',e.id,'name',e.payload->>'name','shortName',e.payload->>'shortName',
        'color',e.payload->>'color','media',e.payload->'media')) order by e.id),'[]')
      from futbeat_private.entities e join team_ids on team_ids.id=e.id where e.kind='team'),
    'competitions',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.payload->>'name') order by e.id),'[]')
      from futbeat_private.entities e join comp_ids on comp_ids.id=e.id where e.kind='competition'))
  into result;
  return result;
end $$;

create or replace function public.futbeat_read_match_preview(p_match_id text)
returns jsonb language sql stable security definer set search_path='' as $$
  select futbeat_private.read_match_preview(p_match_id)
$$;

revoke all on function
  futbeat_private.team_match_result(jsonb,text),
  futbeat_private.read_match_preview(text)
from public,anon,authenticated,service_role;
revoke all on function public.futbeat_read_match_preview(text) from public,anon,authenticated;
grant execute on function public.futbeat_read_match_preview(text) to service_role;

notify pgrst,'reload schema';
