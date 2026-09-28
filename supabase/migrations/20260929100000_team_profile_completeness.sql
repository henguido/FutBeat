-- Issues #150 / #111: team and national-team profile completeness.
--
-- Root causes (code as of 20260928100000):
--   * Matches: futbeat_read_entity_detail keeps only the 100 matches nearest
--     to now and returns the raw stored payload. The effective status
--     (match_read_model) is never applied, so a kickoff that passed with a
--     raw SCHEDULED status still looks like a normal future match.
--   * Squad: the profile only sees an empty players list. It cannot tell
--     "never fetched", "in flight", "provider has none" and "stale" apart,
--     and opening a team records no central demand (guests record nothing).
--   * Standings "Equipo": the entity detail returns tables without the team
--     entities of their rows; the app then has no name for any row whose team
--     is not also in one of the listed matches.
--   * Standings groups: futbeat_store_goal_standings drops the row position
--     and any group label, orders the rows by position across all groups
--     (interleaving them) and dedupes by team only. The provisional overlay
--     then re-sorts the whole list and applies matches between teams of
--     different groups.
--
-- Fix (read-model-first; no provider call, cron, quota or secret changes):
--   * futbeat_read_team_matches: paginated team matches across every
--     competition, by canonical team id (plus its redirected aliases),
--     classified by the EFFECTIVE status into live / upcoming / results.
--   * The entity detail applies match_read_model to its matches, carries the
--     team entities of every standings row and a coverage.squad state.
--   * Squad state AVAILABLE | STALE | PENDING | CONFIRMED_EMPTY | UNAVAILABLE, one
--     central, deduplicated demand per canonical team (team_squad_demands),
--     consumed by the existing squad planner inside the existing governor.
--   * Standings keep position and group; a table whose groups cannot be
--     told apart is flagged groupsResolved=false (never shown as one table).

-- ---------------------------------------------------------------------------
-- Effective bucket shared by the profile read and the app.
-- ---------------------------------------------------------------------------

-- live     = in play (effective LIVE/HALFTIME/EXTRA_TIME/PENALTIES).
-- upcoming = not started yet: future kickoff, or inside the 15-minute grace
--            (the window the app uses for "awaiting update") while the start
--            is reconciled.
-- results  = everything else: finished, postponed, cancelled, abandoned,
--            suspended, and a past kickoff still reported as SCHEDULED with
--            no terminal evidence (awaiting verification, never "next").
create function futbeat_private.team_match_bucket(p_match jsonb)
returns text language sql stable set search_path='' as $$
  select case
    when p_match->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then 'live'
    when p_match->>'status' in ('DISCOVERED','SCHEDULED','PRE_MATCH')
      and now()<=(p_match->>'startTime')::timestamptz+interval '15 minutes' then 'upcoming'
    else 'results'
  end
$$;

-- Canonical team plus every alias redirected to it (bounded traversal).
create function futbeat_private.team_identity_ids(p_team_id text)
returns text[] language sql stable set search_path='' as $$
  with recursive ids(id,depth,path) as (
    select p_team_id,0,array[p_team_id]
    union all
    select r.alias_id,i.depth+1,i.path||r.alias_id
    from ids i join futbeat_private.entity_redirects r
      on r.kind='team' and r.canonical_id=i.id
    where i.depth<8 and not r.alias_id=any(i.path)
  ) select array_agg(distinct id) from ids
$$;

-- ---------------------------------------------------------------------------
-- A) Team matches read model (paginated, every competition).
-- ---------------------------------------------------------------------------

-- The read filters matches by team id. Both indexes were first created by
-- 20260925060000_match_preview_form_h2h.sql; restated here (idempotent) so
-- this read model is self-contained on any installation.
create index if not exists entities_match_home_team_idx
  on futbeat_private.entities ((payload->>'homeTeamId'))
  where kind='match';

create index if not exists entities_match_away_team_idx
  on futbeat_private.entities ((payload->>'awayTeamId'))
  where kind='match';

create function public.futbeat_read_team_matches(
  p_team_id text,
  p_bucket text,
  p_cursor text default null,
  p_limit integer default 20
) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
  tid text;
  ids text[];
  cursor_time timestamptz;
  cursor_id text;
  rec record;
  modeled jsonb;
  page jsonb:='[]'::jsonb;
  has_more boolean:=false;
  last_time timestamptz;
  last_id text;
  teams_json jsonb;
  competitions_json jsonb;
begin
  if p_bucket not in ('live','upcoming','results') or p_limit is null or p_limit<1 or p_limit>50
     or nullif(p_team_id,'') is null then
    raise exception 'Invalid team matches request';
  end if;
  if p_cursor is not null then
    begin
      cursor_time:=split_part(p_cursor,'|',1)::timestamptz;
      cursor_id:=nullif(split_part(p_cursor,'|',2),'');
    exception when others then
      raise exception 'Invalid team matches cursor';
    end;
    if cursor_id is null then raise exception 'Invalid team matches cursor'; end if;
  end if;

  tid:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id);
  if not exists(select 1 from futbeat_private.entities where id=tid and kind='team') then
    return null;
  end if;
  ids:=futbeat_private.team_identity_ids(tid);

  -- Keyset scan in display order; the effective status is computed lazily,
  -- only until one row past the page is found.
  for rec in
    select c.id,c.payload,c.start_time from (
      select e.id,e.payload,(e.payload->>'startTime')::timestamptz start_time
      from futbeat_private.entities e
      where e.kind='match' and e.payload->>'homeTeamId'=any(ids)
        and nullif(e.payload->>'startTime','') is not null
      union
      select e.id,e.payload,(e.payload->>'startTime')::timestamptz
      from futbeat_private.entities e
      where e.kind='match' and e.payload->>'awayTeamId'=any(ids)
        and nullif(e.payload->>'startTime','') is not null
    ) c
    where (
      -- Raw pre-filters that can never drop a row of the bucket: nothing
      -- older than 6 h is still live or upcoming, nothing in the future is
      -- live, and a future not-started match has no evidence (evidence always
      -- postdates the kickoff) to end it.
      (p_bucket='live' and c.start_time between now()-interval '6 hours' and now())
      or (p_bucket='upcoming' and c.start_time>=now()-interval '6 hours')
      or (p_bucket='results' and (c.start_time<=now()
        or coalesce(c.payload->>'status','') not in
          ('DISCOVERED','SCHEDULED','PRE_MATCH','LIVE','HALFTIME','EXTRA_TIME','PENALTIES')))
    ) and (
      cursor_time is null
      or (p_bucket in ('live','upcoming') and (c.start_time,c.id)>(cursor_time,cursor_id))
      or (p_bucket='results' and (c.start_time,c.id)<(cursor_time,cursor_id))
    )
    order by
      case when p_bucket in ('live','upcoming') then c.start_time end asc,
      case when p_bucket in ('live','upcoming') then c.id end asc,
      case when p_bucket='results' then c.start_time end desc,
      case when p_bucket='results' then c.id end desc
  loop
    modeled:=futbeat_private.match_read_model(rec.payload);
    continue when futbeat_private.team_match_bucket(modeled)<>p_bucket;
    if jsonb_array_length(page)>=p_limit then
      has_more:=true;
      exit;
    end if;
    page:=page||jsonb_build_array(modeled);
    last_time:=rec.start_time;
    last_id:=rec.id;
  end loop;

  select coalesce(jsonb_agg(e.payload order by e.payload->>'name',e.id),'[]'::jsonb)
  into teams_json
  from futbeat_private.entities e
  where e.kind='team' and e.id in (
    select tid
    union select value->>'homeTeamId' from jsonb_array_elements(page)
    union select value->>'awayTeamId' from jsonb_array_elements(page)
  );

  select coalesce(jsonb_agg(e.payload order by e.payload->>'name',e.id),'[]'::jsonb)
  into competitions_json
  from futbeat_private.entities e
  where e.kind='competition'
    and e.id in (select value->>'competitionId' from jsonb_array_elements(page));

  return jsonb_build_object(
    'schemaVersion',1,
    'demo',false,
    'updatedAt',now(),
    'freshness',jsonb_build_object('stale',false),
    'coverage',jsonb_build_object('source','FutBeat','partial',false,'live',false,
      'developmentOnly',false,'sources',jsonb_build_array('GOAL API')),
    'teamId',tid,
    'bucket',p_bucket,
    'hasMore',has_more,
    'nextCursor',case when has_more then
      to_char(last_time at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')||'|'||last_id end,
    'competitions',competitions_json,
    'teams',teams_json,
    'players','[]'::jsonb,
    'matches',page,
    'standings','[]'::jsonb
  );
end $$;

-- ---------------------------------------------------------------------------
-- C) Squad state + central deduplicated demand.
-- ---------------------------------------------------------------------------

-- One row per canonical team, whatever the number of users opening it.
create table futbeat_private.team_squad_demands (
  team_id text primary key,
  first_requested_at timestamptz not null default now(),
  requested_at timestamptz not null default now(),
  request_count integer not null default 1 check(request_count>0)
);
revoke all on futbeat_private.team_squad_demands from public,anon,authenticated;

create function futbeat_private.team_squad_mapped(p_team_id text)
returns boolean language sql stable set search_path='' as $$
  select exists(
    select 1 from futbeat_private.provider_entities pe
    where pe.provider='goal_api' and pe.kind='team'
      and nullif(btrim(pe.external_id),'') is not null
      and pe.canonical_id=any(futbeat_private.team_identity_ids(p_team_id)))
$$;

-- AVAILABLE       players and a snapshot inside its 7-day freshness window
-- STALE           players, snapshot older than the window (shown, revalidated)
-- PENDING         a source exists but no valid answer yet: never fetched, in
--                 flight, failed and retrying, or an expired NO_DATA being
--                 revalidated
-- CONFIRMED_EMPTY the source was queried and validly answered "no squad"
--                 (NO_DATA still valid)
-- UNAVAILABLE     no usable provider source/mapping for this team: nothing
--                 proves the squad is empty, there is just nothing to ask
create function futbeat_private.team_squad_state(p_team_id text)
returns jsonb language plpgsql stable set search_path='' as $$
declare
  players integer;
  cov futbeat_private.team_detail_coverage;
  fresh_until timestamptz;
  state text;
  reason text;
begin
  select count(*)::integer into players
  from futbeat_private.team_squad_members sm
  join futbeat_private.entities e on e.id=sm.player_id and e.kind='player'
  where sm.team_id=p_team_id;
  select * into cov from futbeat_private.team_detail_coverage where team_id=p_team_id;
  fresh_until:=coalesce(cov.last_success_at,cov.fetched_at)+interval '7 days';
  if players>0 then
    state:=case when fresh_until>now() then 'AVAILABLE' else 'STALE' end;
  elsif cov.status='NO_DATA'
    and coalesce(cov.next_retry_at,cov.fetched_at+interval '30 days','-infinity')>now() then
    state:='CONFIRMED_EMPTY'; reason:='provider_no_data';
  elsif not futbeat_private.team_squad_mapped(p_team_id) then
    state:='UNAVAILABLE'; reason:='no_provider_source';
  else
    state:='PENDING';
    reason:=case
      when cov.team_id is null then 'never_fetched'
      when cov.lease_until>now() then 'in_flight'
      when cov.status='FETCH_FAILED' then 'retrying'
      when cov.status='NO_DATA' then 'revalidating'
      else 'queued' end;
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'state',state,
    'reason',reason,
    'playerCount',players,
    'updatedAt',coalesce(cov.last_success_at,cov.fetched_at)));
end $$;

-- Called by the API when a team profile opens. Records at most one demand
-- row per team (deduplicated, throttled to one write a minute) and only when
-- the squad is PENDING or STALE; never calls a provider.
create function public.futbeat_request_team_squad(p_team_id text)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  tid text;
  st jsonb;
  recorded boolean:=false;
begin
  if nullif(p_team_id,'') is null then raise exception 'Invalid team'; end if;
  tid:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id);
  if not exists(select 1 from futbeat_private.entities where id=tid and kind='team') then
    return jsonb_build_object('state','MISSING','demandRecorded',false);
  end if;
  st:=futbeat_private.team_squad_state(tid);
  if st->>'state' in ('PENDING','STALE') and futbeat_private.team_squad_mapped(tid) then
    perform pg_catalog.pg_advisory_xact_lock(hashtext('futbeat-squad-demand'),hashtext(tid));
    insert into futbeat_private.team_squad_demands as d(team_id) values(tid)
    on conflict(team_id) do update
      set requested_at=now(),request_count=d.request_count+1
      where d.requested_at<now()-interval '1 minute';
    recorded:=found;
  end if;
  return st||jsonb_build_object('teamId',tid,'demandRecorded',recorded);
end $$;

-- Existing planner (20260922154959) plus one tier: teams opened while their
-- squad was missing or stale ('requested'), right after favorites. A demand
-- is consumed by the next reservation attempt (last_attempt_at); eligibility,
-- mapping, freshness, backoff, lease and quota stay exactly as before.
create or replace function futbeat_private.futbeat_team_squad_plan(p_limit integer default 3)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb:='[]'; part jsonb; ids text[]; comps text[]; chosen text[]:=array[]::text[];
 tier integer; remaining integer;
begin
 if p_limit is null or p_limit<1 or p_limit>25 then raise exception 'Invalid squad plan limit'; end if;
 foreach tier in array array[0,1,6,2,3,4,5] loop
  remaining:=p_limit-jsonb_array_length(result);
  exit when remaining<=0;
  part:='[]'; ids:=array[]::text[];
  if tier=0 then
   -- Exhaustive LIVE source, no match pre-limit. Global result limit follows.
   select array_agg(distinct x.id) into ids from futbeat_private.calendar_matches c
   join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
   cross join lateral(values(e.payload->>'homeTeamId'),(e.payload->>'awayTeamId')) x(id)
   where c.start_time between now()-interval '6 hours' and now()+interval '7 days'
    and e.payload->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES');
   part:=futbeat_private.squad_pool_due(ids,chosen,coalesce(cardinality(ids),0));
   select coalesce(jsonb_agg(value order by ord),'[]') into part from
    (select value,ord from jsonb_array_elements(part) with ordinality x(value,ord) order by ord limit remaining) q;
  elsif tier=1 then
   select array_agg(subject_id) into ids from futbeat_private.coverage_interests where subject_type='team' and explicit_followers>0;
   part:=futbeat_private.squad_pool_due(ids,chosen,remaining);
  elsif tier=2 then
   part:=futbeat_private.squad_upcoming_due(chosen,remaining);
  elsif tier=6 then
   select array_agg(d.team_id order by d.requested_at desc,d.team_id) into ids
   from futbeat_private.team_squad_demands d
   left join futbeat_private.team_detail_coverage c on c.team_id=d.team_id
   where d.requested_at>now()-interval '7 days'
     and d.requested_at>coalesce(c.last_attempt_at,'-infinity');
   part:=futbeat_private.squad_pool_due(ids,chosen,remaining);
  elsif tier in (3,4) then
   if tier=3 then
    select array_agg(distinct futbeat_private.squad_candidate_id('competition',subject_id)) into comps
    from futbeat_private.coverage_interests where subject_type='competition' and explicit_followers>0;
   else
    select array_agg(competition_id) into comps from futbeat_private.competition_editorial_metadata where relevance_score>=800 and source<>'derived';
   end if;
   if coalesce(cardinality(comps),0)>0 then
    ids:=futbeat_private.squad_competition_pool(comps);
    part:=futbeat_private.squad_pool_due(ids,chosen,remaining);
   end if;
  else
   select array_agg(distinct entity_id) into ids from futbeat_private.temporary_interests where entity_type='team' and expires_at>now();
   part:=futbeat_private.squad_pool_due(ids,chosen,remaining);
  end if;
  select result||coalesce(jsonb_agg(value||jsonb_build_object(
   'priority',case when tier=6 then 45000 else 60000-tier*10000 end,'priorityTier',tier,
   'reason',(array['live','favorite','upcoming','followed_competition','editorial_relevance','recently_opened','requested'])[tier+1]) order by ord),'[]'),
   chosen||coalesce(array_agg(value->>'teamId' order by ord),array[]::text[])
  into result,chosen from jsonb_array_elements(part) with ordinality x(value,ord);
 end loop;
 return result;
end $$;

-- ---------------------------------------------------------------------------
-- E) Standings keep position and group.
-- ---------------------------------------------------------------------------

-- Copied from 20260918212500; changes: rows keep position and an optional
-- group label, dedupe is per (group, team), rows are ordered group by group,
-- and the table says whether its groups can be told apart.
create or replace function futbeat_private.futbeat_store_goal_standings(
  p_competition_id text,
  p_external_league_id text,
  p_received_at timestamptz,
  p_season text,
  p_rows jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  item jsonb;
  external_team text;
  team_name text;
  team_country text;
  team_id text;
  group_label text;
  position_value integer;
  played_value integer;
  won_value integer;
  drawn_value integer;
  lost_value integer;
  gf_value integer;
  ga_value integer;
  points_value integer;
  raw_rows jsonb := '[]'::jsonb;
  sorted_rows jsonb := '[]'::jsonb;
  table_json jsonb;
  raw_row_count integer := 0;
  row_count integer := 0;
  group_count integer := 0;
  groups_resolved boolean := true;
begin
  if p_competition_id is null
     or p_external_league_id is null
     or p_received_at is null
     or jsonb_typeof(p_rows)<>'array'
     or jsonb_array_length(p_rows)<2
     or jsonb_array_length(p_rows)>100
     or not exists(
       select 1
       from futbeat_private.provider_entities pe
       where pe.provider='goal_api'
         and pe.kind='competition'
         and pe.external_id=p_external_league_id
         and pe.canonical_id=p_competition_id
     )
  then
    raise exception 'Invalid GOAL standings payload';
  end if;

  for item in select value from jsonb_array_elements(p_rows)
  loop
    external_team:=nullif(coalesce(
      item#>>'{team,id}',
      item->>'teamId',
      item->>'team_id',
      item->>'teamKey'
    ),'');
    team_name:=nullif(coalesce(
      item#>>'{team,name}',
      item->>'teamName',
      item->>'team_name'
    ),'');
    team_country:=coalesce(
      item#>>'{team,country,name}',
      item#>>'{team,country}',
      ''
    );
    -- Group/stage label when the provider sends one (object or text).
    group_label:=nullif(btrim(coalesce(
      case when jsonb_typeof(item->'group')='object' then item#>>'{group,name}'
           when jsonb_typeof(item->'group')='string' then item->>'group' end,
      item->>'groupName',
      item->>'group_name',
      item->>'stageName',
      item->>'stage_name'
    )),'');

    if external_team is null or team_name is null then
      raise exception 'Invalid GOAL standings team';
    end if;

    begin
      position_value:=coalesce(
        nullif(item->>'overallLeaguePosition','')::integer,
        nullif(item->>'position','')::integer,
        nullif(item->>'rank','')::integer,
        raw_row_count+1
      );
      played_value:=coalesce(
        nullif(item->>'overallLeaguePlayed','')::integer,
        nullif(item->>'played','')::integer,
        0
      );
      won_value:=coalesce(
        nullif(item->>'overallLeagueW','')::integer,
        nullif(item->>'won','')::integer,
        nullif(item->>'win','')::integer,
        0
      );
      drawn_value:=coalesce(
        nullif(item->>'overallLeagueD','')::integer,
        nullif(item->>'drawn','')::integer,
        nullif(item->>'draw','')::integer,
        0
      );
      lost_value:=coalesce(
        nullif(item->>'overallLeagueL','')::integer,
        nullif(item->>'lost','')::integer,
        nullif(item->>'loss','')::integer,
        0
      );
      gf_value:=coalesce(
        nullif(item->>'overallLeagueGF','')::integer,
        nullif(item->>'goalsFor','')::integer,
        nullif(item->>'gf','')::integer,
        0
      );
      ga_value:=coalesce(
        nullif(item->>'overallLeagueGA','')::integer,
        nullif(item->>'goalsAgainst','')::integer,
        nullif(item->>'ga','')::integer,
        0
      );
      points_value:=coalesce(
        nullif(item->>'overallLeaguePTS','')::integer,
        nullif(item->>'points','')::integer,
        nullif(item->>'pts','')::integer,
        0
      );
    exception when others then
      raise exception 'Invalid GOAL standings numeric data';
    end;

    if position_value<1
       or played_value<0
       or won_value<0
       or drawn_value<0
       or lost_value<0
       or gf_value<0
       or ga_value<0
       or points_value<0
    then
      raise exception 'Invalid GOAL standings values';
    end if;

    team_id:=futbeat_private.futbeat_resolve_global_entity(
      'goal_api','team',external_team,team_name,team_country,''
    );

    raw_rows:=raw_rows || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'position',position_value,
      'group',group_label,
      'teamId',team_id,
      'played',played_value,
      'won',won_value,
      'drawn',drawn_value,
      'lost',lost_value,
      'gf',gf_value,
      'ga',ga_value,
      'points',points_value
    )));
    raw_row_count:=raw_row_count+1;
  end loop;

  with ranked as (
    select
      value,
      row_number() over(
        partition by coalesce(value->>'group',''),value->>'teamId'
        order by
          (value->>'played')::integer desc,
          (value->>'points')::integer desc,
          (value->>'position')::integer,
          ((value->>'gf')::integer-(value->>'ga')::integer) desc,
          (value->>'gf')::integer desc
      ) as rn
    from jsonb_array_elements(raw_rows)
  ), kept as (
    select value from ranked where rn=1
  ), group_order as (
    -- Groups in the provider's order of first appearance by position.
    select coalesce(value->>'group','') group_key,
      min((value->>'position')::integer) first_position,
      min(value->>'group') label
    from kept group by 1
  )
  select
    coalesce(jsonb_agg(
      k.value
      order by
        g.first_position,
        g.label nulls first,
        (k.value->>'position')::integer,
        (k.value->>'points')::integer desc,
        ((k.value->>'gf')::integer-(k.value->>'ga')::integer) desc,
        (k.value->>'gf')::integer desc,
        k.value->>'teamId'
    ),'[]'::jsonb),
    (select count(*)::integer from group_order),
    -- A repeated position inside one group means several unlabelled groups
    -- were sent together: they cannot be told apart.
    not exists(
      select 1 from kept
      group by coalesce(value->>'group',''),(value->>'position')::integer
      having count(*)>1
    )
  into sorted_rows,group_count,groups_resolved
  from kept k
  join group_order g on g.group_key=coalesce(k.value->>'group','');

  row_count:=jsonb_array_length(sorted_rows);
  if row_count<2 then
    raise exception 'Insufficient canonical teams in standings';
  end if;

  table_json:=jsonb_build_object(
    'competitionId',p_competition_id,
    'season',coalesce(p_season,''),
    'provisional',false,
    'source','GOAL API',
    'updatedAt',p_received_at,
    'grouped',group_count>1,
    'groupsResolved',groups_resolved,
    'rows',sorted_rows
  );

  insert into futbeat_private.standings_cache(
    competition_id,provider,external_league_id,season,table_payload,fetched_at
  )
  values(
    p_competition_id,'goal_api',p_external_league_id,
    coalesce(p_season,''),table_json,p_received_at
  )
  on conflict(competition_id) do update set
    provider=excluded.provider,
    external_league_id=excluded.external_league_id,
    season=excluded.season,
    table_payload=excluded.table_payload,
    fetched_at=excluded.fetched_at;

  return jsonb_build_object(
    'competitionId',p_competition_id,
    'rows',row_count,
    'rawRows',raw_row_count,
    'duplicatesCollapsed',raw_row_count-row_count,
    'groups',group_count,
    'groupsResolved',groups_resolved,
    'fetchedAt',p_received_at
  );
end
$$;

-- Copied from 20260918214000; changes: a match only counts when both teams
-- are in the same group, rows are re-ranked inside their group (position
-- recomputed per group), and each row keeps its group label.
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
      coalesce(row.value->>'group','') as group_key,
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

-- ---------------------------------------------------------------------------
-- A/C/D) Entity detail: effective matches, standings teams, squad state.
-- ---------------------------------------------------------------------------

-- Copied from 20260919042500; changes are in `modeled`, `table_team_ids`,
-- `extra_teams` and `assembled` only.
create or replace function public.futbeat_read_entity_detail(
  p_type text,
  p_id text
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  with request as (
    select futbeat_private.futbeat_resolve_entity_id(
      p_type,p_id
    ) as resolved_id
  ),
  base as (
    select
      futbeat_private.futbeat_read_entity_detail(
        p_type,request.resolved_id
      ) as snapshot,
      request.resolved_id
    from request
  ),
  competition_ids as (
    select distinct value->>'competitionId' as id
    from base
    cross join lateral jsonb_array_elements(
      coalesce(base.snapshot->'matches','[]'::jsonb)
    )
    where nullif(value->>'competitionId','') is not null

    union

    select distinct value->>'id'
    from base
    cross join lateral jsonb_array_elements(
      coalesce(base.snapshot->'competitions','[]'::jsonb)
    )
    where nullif(value->>'id','') is not null

    union

    select resolved_id from base where p_type='competition'
  ),
  tables as (
    select coalesce(jsonb_agg(item),'[]'::jsonb) as value
    from (
      select legacy.value as item
      from base
      cross join lateral jsonb_array_elements(
        coalesce(base.snapshot->'standings','[]'::jsonb)
      ) legacy
      where legacy.value->>'competitionId' in (
        select id from competition_ids where id is not null
      )
      and not exists(
        select 1
        from futbeat_private.standings_cache sc
        where sc.competition_id=legacy.value->>'competitionId'
      )

      union all

      select futbeat_private.futbeat_apply_provisional_standings(
        sc.table_payload,
        sc.fetched_at
      )
      from futbeat_private.standings_cache sc
      where sc.competition_id in (
        select id from competition_ids where id is not null
      )
    ) selected_tables(item)
  ),
  -- Effective status (terminal evidence, stale LIVE, redirects), the same
  -- read model as the calendar.
  modeled as (
    select coalesce(
      jsonb_agg(futbeat_private.match_read_model(m.value) order by m.ordinality),
      '[]'::jsonb
    ) as value
    from base
    cross join lateral jsonb_array_elements(
      coalesce(base.snapshot->'matches','[]'::jsonb)
    ) with ordinality m(value,ordinality)
  ),
  -- Every standings row and every modeled match needs its team entity: a
  -- row without one would have no name.
  table_team_ids as (
    select distinct futbeat_private.futbeat_resolve_entity_id('team',r.value->>'teamId') as id
    from tables
    cross join lateral jsonb_array_elements(tables.value) t(value)
    cross join lateral jsonb_array_elements(coalesce(t.value->'rows','[]'::jsonb)) r(value)
    where nullif(r.value->>'teamId','') is not null
    union
    select mm.value->>'homeTeamId' from modeled,jsonb_array_elements(modeled.value) mm(value)
    union
    select mm.value->>'awayTeamId' from modeled,jsonb_array_elements(modeled.value) mm(value)
  ),
  extra_teams as (
    select coalesce(jsonb_agg(e.payload order by e.payload->>'name',e.id),'[]'::jsonb) as value
    from base,futbeat_private.entities e
    where e.kind='team'
      and e.id in (select id from table_team_ids where id is not null)
      and not exists(
        select 1 from jsonb_array_elements(coalesce(base.snapshot->'teams','[]'::jsonb)) known
        where known.value->>'id'=e.id
      )
  ),
  news_rows as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id',x.id,
          'title',x.title,
          'description',x.description,
          'url',x.url,
          'sourceName',x.source_name,
          'sourceUrl',x.source_url,
          'publishedAt',x.published_at,
          'language',x.language
        )
        order by x.published_at desc,x.id
      ),
      '[]'::jsonb
    ) as value
    from (
      select a.*
      from base
      join futbeat_private.news_subjects ns
        on ns.subject_type=p_type
       and futbeat_private.futbeat_resolve_entity_id(
         ns.subject_type,ns.subject_id
       )=base.resolved_id
      join futbeat_private.news_articles a
        on a.id=ns.article_id
      where a.published_at>=now()-interval '30 days'
      order by a.published_at desc,a.id
      limit 30
    ) x
  ),
  transfer_rows as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id',x.id,
          'playerId',x.player_id,
          'playerName',x.player_name,
          'fromTeamId',x.from_team_id,
          'fromTeamName',x.from_team_name,
          'toTeamId',x.to_team_id,
          'toTeamName',x.to_team_name,
          'detectedAt',x.detected_at,
          'status',x.status,
          'source',x.source_label
        )
        order by x.detected_at desc,x.id desc
      ),
      '[]'::jsonb
    ) as value
    from (
      select
        tr.id,tr.player_id,tr.from_team_id,tr.to_team_id,
        tr.detected_at,tr.status,tr.source_label,
        p.payload->>'name' as player_name,
        ft.payload->>'name' as from_team_name,
        tt.payload->>'name' as to_team_name
      from base
      join futbeat_private.transfer_events tr on (
        (p_type='player' and tr.player_id=base.resolved_id)
        or
        (
          p_type='team'
          and (
            tr.from_team_id=base.resolved_id
            or tr.to_team_id=base.resolved_id
          )
        )
        or
        (
          p_type='competition'
          and (
            exists(
              select 1 from futbeat_private.entities ct
              where ct.id=tr.from_team_id
                and ct.kind='team'
                and ct.payload->>'competitionId'=base.resolved_id
            )
            or exists(
              select 1 from futbeat_private.entities ct
              where ct.id=tr.to_team_id
                and ct.kind='team'
                and ct.payload->>'competitionId'=base.resolved_id
            )
          )
        )
      )
      join futbeat_private.entities p
        on p.id=tr.player_id and p.kind='player'
      join futbeat_private.entities ft
        on ft.id=tr.from_team_id and ft.kind='team'
      join futbeat_private.entities tt
        on tt.id=tr.to_team_id and tt.kind='team'
      order by tr.detected_at desc,tr.id desc
      limit 50
    ) x
  ),
  assembled as (
    select case
      when base.snapshot is null then null
      else (
        base.snapshot-'standings'-'news'-'transfers'-'matches'-'teams'-'coverage'
      ) || jsonb_build_object(
        'standings',tables.value,
        'news',news_rows.value,
        'transfers',transfer_rows.value,
        'matches',modeled.value,
        'teams',coalesce(base.snapshot->'teams','[]'::jsonb)||extra_teams.value,
        'coverage',coalesce(base.snapshot->'coverage','{}'::jsonb)
          || case when p_type='team' then jsonb_build_object(
               'squad',futbeat_private.team_squad_state(base.resolved_id))
             else '{}'::jsonb end
      )
    end as snapshot
    from base,tables,modeled,extra_teams,news_rows,transfer_rows
  )
  select case
    when snapshot is null then null
    else futbeat_private.futbeat_apply_entity_redirects_snapshot(snapshot)
  end
  from assembled
$$;

-- ---------------------------------------------------------------------------
-- Grants: API (service_role) only.
-- ---------------------------------------------------------------------------

revoke all on function
  futbeat_private.team_match_bucket(jsonb),
  futbeat_private.team_identity_ids(text),
  futbeat_private.team_squad_mapped(text),
  futbeat_private.team_squad_state(text),
  public.futbeat_read_team_matches(text,text,text,integer),
  public.futbeat_request_team_squad(text)
from public,anon,authenticated;
grant execute on function
  public.futbeat_read_team_matches(text,text,text,integer),
  public.futbeat_request_team_squad(text)
to service_role;

notify pgrst,'reload schema';
