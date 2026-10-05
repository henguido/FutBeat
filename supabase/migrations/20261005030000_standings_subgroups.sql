-- Standings sub-groups rebuilt from real fixtures (no provider call).
--
-- Evidence (read-only production, 2026-10-05): GOAL standings rows carry
-- only `stageName` (captured shape: overallLeague* + stageName), so a stage
-- made of several groups arrives as ONE label with repeated positions
-- ("League A" = 16 rows, positions 1,1,1,1,2,...). The store flags such a
-- table groupsResolved=false and the app shows "Tabla no disponible" for
-- every match of UEFA Nations League, Concacaf Nations League, ...
--
-- Rule (generic, nothing named): inside one stage label with repeated
-- positions, two teams belong to the same group when they meet in a fixture
-- of this competition within [fetched_at - 180 d, fetched_at + 120 d]
-- (connected components of that graph). The split is accepted only when it
-- is unambiguous for EVERY such label: at least two components, and each
-- component holds exactly the positions 1..n once. Then each row keeps its
-- provider `group` label and gets `subgroup` (1..k, provider order) and the
-- table becomes groupsResolved=true. Anything else (a knockout or an
-- interzonal fixture joining groups, a team without fixtures, shared
-- positions) leaves the table exactly as stored (still fail-closed).
-- Production check: UEFA NL League A-D and Concacaf NL League A-B split
-- cleanly; Concacaf NL League C (a shared position), Liga Profesional
-- Argentina and MLS (interzonal / inter-conference fixtures) stay unresolved.
-- Rollback: drop trigger standings_aa_subgroups and the two functions; then
-- `update futbeat_private.standings_cache set table_payload=table_payload`
-- is NOT enough (rows keep `subgroup`) -- re-store the tables or strip it:
-- update ... set table_payload=jsonb_set(table_payload,'{rows}',(select
-- jsonb_agg(r-'subgroup') from jsonb_array_elements(table_payload->'rows') r))
-- ||'{"groupsResolved":false}' where table_payload ? 'subgroupsFromFixtures'.

create or replace function futbeat_private.standings_split_subgroups(
  p_competition_id text,p_table jsonb,p_at timestamptz
) returns jsonb language plpgsql stable set search_path='' as $$
declare
  v_split jsonb;
begin
  if p_competition_id is null or p_at is null
     or jsonb_typeof(p_table)<>'object'
     or jsonb_typeof(p_table->'rows')<>'array'
     or coalesce(p_table->>'groupsResolved','')<>'false' then
    return p_table;
  end if;

  with recursive rows as (
    select r.ord,r.value,coalesce(r.value->>'group','') grp,
      r.value->>'teamId' team,(r.value->>'position')::integer pos
    from jsonb_array_elements(p_table->'rows') with ordinality r(value,ord)
  ), dup as (
    -- Labels holding repeated positions: the ones to split.
    select distinct grp from rows group by grp,pos having count(*)>1
  ), teams as (
    select * from rows where grp in (select grp from dup)
  ), fixtures as (
    select e.payload->>'homeTeamId' h,e.payload->>'awayTeamId' a
    from futbeat_private.entities e
    where e.kind='match'
      and e.payload->>'competitionId'=p_competition_id
      and e.payload->>'startTime' ~ '^\d{4}-\d{2}-\d{2}T'
      and (e.payload->>'startTime')::timestamptz>p_at-interval '180 days'
      and (e.payload->>'startTime')::timestamptz<p_at+interval '120 days'
  ), edges as (
    select distinct x.grp,x.team a,y.team b
    from teams x join teams y on y.grp=x.grp and y.team<>x.team
    join fixtures f on (f.h=x.team and f.a=y.team) or (f.h=y.team and f.a=x.team)
  ), reach(grp,root,team) as (
    select grp,team,team from teams
    union
    select r.grp,r.root,e.b from reach r join edges e on e.grp=r.grp and e.a=r.team
  ), comp as (
    select grp,team,min(root) root from reach group by grp,team
  ), checked as (
    select t.grp,c.root,count(*) n,count(distinct t.pos) dpos,min(t.pos) lo,max(t.pos) hi,
      min(t.ord) first_ord
    from teams t join comp c on c.grp=t.grp and c.team=t.team
    group by t.grp,c.root
  ), valid as (
    select grp from checked group by grp
    having count(*)>=2 and bool_and(n>=2 and n=dpos and lo=1 and hi=n)
  ), numbered as (
    select grp,root,row_number() over (partition by grp order by first_ord) sub
    from checked
  )
  select case
    when (select count(*) from dup)=(select count(*) from valid) and (select count(*) from dup)>0
    then (select jsonb_agg(
        case when n.sub is null then r.value
          else r.value||jsonb_build_object('subgroup',n.sub) end
        order by r.ord)
      from rows r
      left join comp c on c.grp=r.grp and c.team=r.team
      left join numbered n on n.grp=c.grp and n.root=c.root)
  end into v_split;

  if v_split is null then return p_table; end if;
  return p_table||jsonb_build_object(
    'rows',v_split,'groupsResolved',true,'subgroupsFromFixtures',true);
exception when others then
  return p_table;
end $$;

create or replace function futbeat_private.standings_subgroups_trigger()
returns trigger language plpgsql set search_path='' as $$
begin
  new.table_payload:=futbeat_private.standings_split_subgroups(
    new.competition_id,new.table_payload,new.fetched_at);
  return new;
end $$;

revoke all on function futbeat_private.standings_split_subgroups(text,jsonb,timestamptz),
  futbeat_private.standings_subgroups_trigger() from public,anon,authenticated;

-- 'aa' sorts before standings_current_group_hint: BEFORE triggers fire in
-- name order (the hint only reads labels, so the order is not critical).
drop trigger if exists standings_aa_subgroups on futbeat_private.standings_cache;
create trigger standings_aa_subgroups
before insert or update of table_payload,fetched_at on futbeat_private.standings_cache
for each row execute function futbeat_private.standings_subgroups_trigger();

-- The live provisional overlay re-ranks rows per group: a sub-group must be
-- its own group there too (else a live match re-ranked all of "League A"
-- as one table). Copied from 20260929100000 (identical to production);
-- changes: group_key includes `subgroup`, rows keep `subgroup`.
create or replace function futbeat_private.futbeat_apply_provisional_standings(
  p_table jsonb,
  p_fetched_at timestamptz
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  with input as (
    select
      p_table as table_payload,
      nullif(p_table->>'competitionId','') as competition_id
  ),
  base_rows as (
    select
      row.value as payload,
      row.ordinality::integer as base_position,
      -- A server sub-group (20261005030000) is its own group.
      coalesce(row.value->>'group','')||chr(31)||coalesce(row.value->>'subgroup','') as group_key,
      row.value->>'teamId' as team_id,
      (row.value->>'played')::integer as played,
      (row.value->>'won')::integer as won,
      (row.value->>'drawn')::integer as drawn,
      (row.value->>'lost')::integer as lost,
      (row.value->>'gf')::integer as gf,
      (row.value->>'ga')::integer as ga,
      (row.value->>'points')::integer as points
    from input
    cross join lateral jsonb_array_elements(
      coalesce(input.table_payload->'rows','[]'::jsonb)
    ) with ordinality row(value,ordinality)
  ),
  states as (
    select
      m.id as match_id,
      m.payload->>'homeTeamId' as home_team_id,
      m.payload->>'awayTeamId' as away_team_id,
      (m.payload->>'startTime')::timestamptz as start_time,
      case
        when coalesce(m.payload->>'status','') in (
          'FINISHED_PENDING_VERIFICATION','VERIFIED',
          'POSTPONED','ABANDONED','CANCELLED'
        )
        and coalesce(
          nullif(m.payload#>>'{provenance,receivedAt}','')::timestamptz,
          '-infinity'::timestamptz
        ) >= coalesce(l.changed_at,'-infinity'::timestamptz)
          then m.payload->>'status'
        else coalesce(l.status,m.payload->>'status')
      end as effective_status,
      case
        when coalesce(m.payload->>'status','') in (
          'FINISHED_PENDING_VERIFICATION','VERIFIED'
        )
        and coalesce(
          nullif(m.payload#>>'{provenance,receivedAt}','')::timestamptz,
          '-infinity'::timestamptz
        ) >= coalesce(l.changed_at,'-infinity'::timestamptz)
          then nullif(m.payload#>>'{score,home}','')::integer
        else coalesce(
          l.home_score,
          nullif(m.payload#>>'{score,home}','')::integer
        )
      end as home_score,
      case
        when coalesce(m.payload->>'status','') in (
          'FINISHED_PENDING_VERIFICATION','VERIFIED'
        )
        and coalesce(
          nullif(m.payload#>>'{provenance,receivedAt}','')::timestamptz,
          '-infinity'::timestamptz
        ) >= coalesce(l.changed_at,'-infinity'::timestamptz)
          then nullif(m.payload#>>'{score,away}','')::integer
        else coalesce(
          l.away_score,
          nullif(m.payload#>>'{score,away}','')::integer
        )
      end as away_score
    from input
    join futbeat_private.entities m
      on m.kind='match'
     and m.payload->>'competitionId'=input.competition_id
     and nullif(m.payload->>'startTime','') is not null
    left join public.live_match_updates l
      on l.match_id=m.id
    where p_fetched_at is not null
      and (m.payload->>'startTime')::timestamptz>p_fetched_at
      and (m.payload->>'startTime')::timestamptz<=now()
  ),
  eligible_matches as (
    select s.*
    from states s
    where s.effective_status in (
      'LIVE','HALFTIME','EXTRA_TIME','PENALTIES',
      'FINISHED_PENDING_VERIFICATION','VERIFIED'
    )
      and s.home_score is not null
      and s.away_score is not null
      -- Both teams in the SAME group: a cross-group (or knockout) match
      -- never changes a group table.
      and exists(
        select 1 from base_rows h join base_rows a on a.group_key=h.group_key
        where h.team_id=s.home_team_id and a.team_id=s.away_team_id
      )
  ),
  deltas as (
    select
      home_team_id as team_id,
      1 as played,
      case when home_score>away_score then 1 else 0 end as won,
      case when home_score=away_score then 1 else 0 end as drawn,
      case when home_score<away_score then 1 else 0 end as lost,
      home_score as gf,
      away_score as ga,
      case
        when home_score>away_score then 3
        when home_score=away_score then 1
        else 0
      end as points
    from eligible_matches

    union all

    select
      away_team_id,
      1,
      case when away_score>home_score then 1 else 0 end,
      case when away_score=home_score then 1 else 0 end,
      case when away_score<home_score then 1 else 0 end,
      away_score,
      home_score,
      case
        when away_score>home_score then 3
        when away_score=home_score then 1
        else 0
      end
    from eligible_matches
  ),
  aggregated as (
    select
      team_id,
      sum(played)::integer as played,
      sum(won)::integer as won,
      sum(drawn)::integer as drawn,
      sum(lost)::integer as lost,
      sum(gf)::integer as gf,
      sum(ga)::integer as ga,
      sum(points)::integer as points
    from deltas
    group by team_id
  ),
  adjusted as (
    select
      b.team_id,
      b.group_key,
      b.payload->>'group' as group_label,
      b.payload->'subgroup' as subgroup,
      b.base_position,
      min(b.base_position) over(partition by b.group_key) as group_order,
      b.played+coalesce(a.played,0) as played,
      b.won+coalesce(a.won,0) as won,
      b.drawn+coalesce(a.drawn,0) as drawn,
      b.lost+coalesce(a.lost,0) as lost,
      b.gf+coalesce(a.gf,0) as gf,
      b.ga+coalesce(a.ga,0) as ga,
      b.points+coalesce(a.points,0) as points
    from base_rows b
    left join aggregated a on a.team_id=b.team_id
  ),
  ranked as (
    select adjusted.*,
      row_number() over(
        partition by group_key
        order by points desc,(gf-ga) desc,gf desc,base_position
      )::integer as group_position
    from adjusted
  ),
  ordered as (
    select coalesce(
      jsonb_agg(
        jsonb_strip_nulls(jsonb_build_object(
          'position',group_position,
          'group',group_label,
          'subgroup',subgroup,
          'teamId',team_id,
          'played',played,
          'won',won,
          'drawn',drawn,
          'lost',lost,
          'gf',gf,
          'ga',ga,
          'points',points
        ))
        order by group_order,group_position
      ),
      '[]'::jsonb
    ) as rows
    from ranked
  ),
  meta as (
    select
      count(*)::integer as overlay_matches,
      count(*) filter(
        where effective_status in (
          'LIVE','HALFTIME','EXTRA_TIME','PENALTIES'
        )
      )::integer as active_matches
    from eligible_matches
  )
  select case
    when input.competition_id is null
      or jsonb_typeof(input.table_payload)<>'object'
      or meta.overlay_matches=0
      -- Unresolvable groups: leave the published table untouched.
      or input.table_payload->>'groupsResolved'='false'
      then input.table_payload
    else
      (input.table_payload-'rows'-'provisional'-'updatedAt')
      || jsonb_build_object(
        'rows',ordered.rows,
        'provisional',true,
        'baselineUpdatedAt',input.table_payload->'updatedAt',
        'updatedAt',now(),
        'provisionalMatches',meta.overlay_matches,
        'activeMatches',meta.active_matches
      )
  end
  from input,ordered,meta
$$;

-- Tables already stored unresolved get the split now (no provider call).
update futbeat_private.standings_cache sc
set table_payload=sc.table_payload
where sc.table_payload->>'groupsResolved'='false';
