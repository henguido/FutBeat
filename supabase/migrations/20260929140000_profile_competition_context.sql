-- Issue #161: competition + season as the central context of a team profile
-- (and the #157 gaps of the team matches read).
--
-- Before: the profile had no notion of season. "Tabla" read the latest cached
-- table per competition (standings_cache), "Partidos" listed every match with
-- no competition/season filter, and nothing told the app which
-- (competition, season) combinations the team really has.
--
-- Now:
--   * futbeat_private.team_context_options(team): the REAL combinations of
--     the canonical team (aliases included): every stored match grouped by
--     canonical competition + normalize_season(match.season). A match without
--     a season is its own option with seasonKey null (never an invented
--     season). Per option: match counts, first/last/next kickoff and whether
--     an exact archived table (standings_snapshots) contains the team.
--   * public.futbeat_read_team_context(team, competition?, season?): the
--     options, the selected context (the requested one when it is a real
--     option, else a deterministic default) and that exact table (provisional
--     overlay only for the competition's current season, as Match Center).
--     Default order: active (upcoming, or a match in the last 180 days) >
--     the competition's current season > has a table with the team > the
--     team's main competition > soonest next kickoff > latest kickoff >
--     competition id > season key. Season '-' selects the seasonless option
--     explicitly.
--   * public.futbeat_read_team_matches gains optional p_competition_id /
--     p_season_key filters and exposes the team's match coverage state
--     (coverage.teamMatches: AVAILABLE / STALE / PENDING / NO_DATA /
--     UNAVAILABLE + covered range). Same buckets, same keyset cursor; the
--     4-argument call of older clients/functions keeps working (defaults).
--
-- Depends on: 20260929100000 (team_identity_ids, team_match_bucket, read
-- model), 20260929110000 (team_match_coverage_state), 20260923180000
-- (normalize_season, standings_snapshots, competition_season_key).
-- Read-only functions; no table changes, no data rewritten.
-- Rollback (conceptual): drop the two new functions and restore the
-- 4-argument futbeat_read_team_matches from 20260929100000.

-- Canonical competition plus every alias redirected to it (bounded).
create function futbeat_private.competition_identity_ids(p_competition_id text)
returns text[] language sql stable set search_path='' as $$
  with recursive ids(id,depth,path) as (
    select p_competition_id,0,array[p_competition_id]
    union all
    select r.alias_id,i.depth+1,i.path||r.alias_id
    from ids i join futbeat_private.entity_redirects r
      on r.kind='competition' and r.canonical_id=i.id
    where i.depth<8 and not r.alias_id=any(i.path)
  ) select array_agg(distinct id) from ids
$$;

-- A stored table in canonical ids (competition + row teams): aliases left
-- by merges never hide a row's team or the table itself.
create function futbeat_private.canonical_table(p_table jsonb,p_competition_id text)
returns jsonb language sql stable set search_path='' as $$
  select p_table||jsonb_build_object(
    'competitionId',p_competition_id,
    'rows',coalesce((select jsonb_agg(case when nullif(r->>'teamId','') is null then r
        else r||jsonb_build_object('teamId',futbeat_private.futbeat_resolve_entity_id('team',r->>'teamId')) end
        order by ord)
      from jsonb_array_elements(coalesce(p_table->'rows','[]'::jsonb)) with ordinality x(r,ord)),'[]'::jsonb))
$$;

create function futbeat_private.team_context_options(p_team_id text)
returns jsonb language sql stable set search_path='' as $$
  with ids as (
    select futbeat_private.team_identity_ids(p_team_id) a
  ), m as (
    select e.id,e.payload from futbeat_private.entities e,ids
    where e.kind='match' and e.payload->>'homeTeamId'=any(ids.a)
      and nullif(e.payload->>'startTime','') is not null
    union
    select e.id,e.payload from futbeat_private.entities e,ids
    where e.kind='match' and e.payload->>'awayTeamId'=any(ids.a)
      and nullif(e.payload->>'startTime','') is not null
  ), g as (
    select
      futbeat_private.futbeat_resolve_entity_id('competition',nullif(m.payload->>'competitionId','')) comp,
      -- '-' is reserved for "no season" (never a real key).
      nullif(nullif(futbeat_private.normalize_season(m.payload->>'season'),''),'-') season_key,
      min(nullif(btrim(m.payload->>'season'),'')) season_label,
      count(*)::integer matches,
      min((m.payload->>'startTime')::timestamptz) first_start,
      max((m.payload->>'startTime')::timestamptz) last_start,
      min((m.payload->>'startTime')::timestamptz)
        filter(where (m.payload->>'startTime')::timestamptz>=now()) next_start
    from m group by 1,2
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'competitionId',g.comp,
      'competitionName',c.payload->>'name',
      'seasonKey',g.season_key,
      'season',g.season_label,
      'matchCount',g.matches,
      'firstStart',g.first_start,
      'lastStart',g.last_start,
      'nextStart',g.next_start,
      'currentSeason',g.season_key is not null
        and g.season_key=futbeat_private.competition_season_key(g.comp),
      'hasStandings',coalesce(t.has_team,false)))
    order by g.season_key desc nulls last,g.last_start desc,g.comp),'[]'::jsonb)
  from g
  join futbeat_private.entities c on c.id=g.comp and c.kind='competition'
  left join lateral (
    select exists(
      select 1 from jsonb_array_elements(coalesce(s.table_payload->'rows','[]'::jsonb)) r
      where futbeat_private.futbeat_resolve_entity_id('team',r->>'teamId')=p_team_id) has_team
    from futbeat_private.standings_snapshots s
    where g.season_key is not null and s.competition_id=g.comp and s.season_key=g.season_key
  ) t on true
$$;

create function public.futbeat_read_team_context(
  p_team_id text,
  p_competition_id text default null,
  p_season_key text default null
) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
  tid text; team jsonb; main_comp text; req_comp text; req_season text;
  options jsonb; selected jsonb; requested_matched boolean:=false;
  snap futbeat_private.standings_snapshots; table_json jsonb; teams_json jsonb; comps_json jsonb;
begin
  if nullif(p_team_id,'') is null or length(p_team_id)>120
     or (p_competition_id is not null and (p_competition_id='' or length(p_competition_id)>120))
     or (p_season_key is not null and (p_season_key='' or length(p_season_key)>40)) then
    raise exception 'Invalid team context request';
  end if;
  -- A raw label ('2026/27' from a match), a normalized key, or '-' for the
  -- seasonless option.
  req_season:=case when p_season_key='-' then '-'
    else nullif(futbeat_private.normalize_season(p_season_key),'') end;
  tid:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id);
  select e.payload into team from futbeat_private.entities e where e.id=tid and e.kind='team';
  if team is null then return null; end if;
  main_comp:=futbeat_private.futbeat_resolve_entity_id('competition',nullif(team->>'competitionId',''));
  options:=futbeat_private.team_context_options(tid);

  -- Requested context (opened from a match / chosen by the user): only when
  -- it is a real option. Without a season: that competition's latest season.
  if p_competition_id is not null then
    req_comp:=futbeat_private.futbeat_resolve_entity_id('competition',p_competition_id);
    select o into selected from jsonb_array_elements(options) o
    where o->>'competitionId'=req_comp
      and (req_season is null or o->>'seasonKey'=req_season
        or (req_season='-' and o->>'seasonKey' is null))
    order by o->>'seasonKey' desc nulls last,(o->>'lastStart')::timestamptz desc
    limit 1;
    requested_matched:=selected is not null;
  end if;
  if selected is null then
    select o into selected from jsonb_array_elements(options) o
    order by
      ((o->>'nextStart') is not null or (o->>'lastStart')::timestamptz>=now()-interval '180 days') desc,
      coalesce((o->>'currentSeason')::boolean,false) desc,
      coalesce((o->>'hasStandings')::boolean,false) desc,
      (o->>'competitionId'=main_comp) desc nulls last,
      (o->>'nextStart')::timestamptz asc nulls last,
      (o->>'lastStart')::timestamptz desc,
      o->>'competitionId' asc,
      o->>'seasonKey' desc nulls last
    limit 1;
  end if;

  -- The exact table of the selected context (never another season's).
  if selected is not null and selected->>'seasonKey' is not null then
    select * into snap from futbeat_private.standings_snapshots s
    where s.competition_id=selected->>'competitionId' and s.season_key=selected->>'seasonKey';
    if snap.competition_id is not null then
      table_json:=futbeat_private.canonical_table(
        case when snap.season_key=coalesce(futbeat_private.competition_season_key(snap.competition_id),'')
          then futbeat_private.futbeat_apply_provisional_standings(snap.table_payload,snap.fetched_at)
          else snap.table_payload end,
        snap.competition_id);
    end if;
  end if;

  select coalesce(jsonb_agg(e.payload order by e.payload->>'name',e.id),'[]'::jsonb) into teams_json
  from futbeat_private.entities e
  where e.kind='team' and e.id in (
    select tid
    union
    select r->>'teamId'
    from jsonb_array_elements(coalesce(table_json->'rows','[]'::jsonb)) r
    where nullif(r->>'teamId','') is not null);

  select coalesce(jsonb_agg(e.payload order by e.payload->>'name',e.id),'[]'::jsonb) into comps_json
  from futbeat_private.entities e
  where e.kind='competition' and e.id in (select o->>'competitionId' from jsonb_array_elements(options) o);

  return jsonb_build_object(
    'schemaVersion',1,
    'teamId',tid,
    'options',options,
    'selected',case when selected is null then null else jsonb_strip_nulls(jsonb_build_object(
      'competitionId',selected->>'competitionId','seasonKey',selected->>'seasonKey',
      'requested',requested_matched)) end,
    'standings',case when table_json is null then '[]'::jsonb else jsonb_build_array(table_json) end,
    'coverage',jsonb_build_object(
      'standings',case when table_json is not null then 'available' else 'missing' end,
      'teamMatches',futbeat_private.team_match_coverage_state(tid)),
    'teams',teams_json,
    'competitions',comps_json);
end $$;

-- ---------------------------------------------------------------------------
-- Team matches: optional competition/season filters + coverage state.
-- Same body as 20260929100000 otherwise (buckets, pre-filters, keyset).
-- ---------------------------------------------------------------------------

drop function public.futbeat_read_team_matches(text,text,text,integer);

create function public.futbeat_read_team_matches(
  p_team_id text,
  p_bucket text,
  p_cursor text default null,
  p_limit integer default 20,
  p_competition_id text default null,
  p_season_key text default null
) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
  tid text;
  ids text[];
  comp_filter text;
  comp_ids text[];
  -- '-' = only matches without a season.
  season_filter text:=case when p_season_key='-' then '-'
    else nullif(futbeat_private.normalize_season(p_season_key),'') end;
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
     or nullif(p_team_id,'') is null
     or (p_competition_id is not null and (p_competition_id='' or length(p_competition_id)>120))
     or (p_season_key is not null and (p_season_key='' or length(p_season_key)>40)) then
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
  comp_filter:=case when p_competition_id is not null
    then futbeat_private.futbeat_resolve_entity_id('competition',p_competition_id) end;
  comp_ids:=case when comp_filter is not null
    then futbeat_private.competition_identity_ids(comp_filter) end;

  for rec in
    select c.id,c.payload,c.start_time from (
      select e.id,e.payload,(e.payload->>'startTime')::timestamptz start_time
      from futbeat_private.entities e
      where e.kind='match' and e.payload->>'homeTeamId'=any(ids)
        and nullif(e.payload->>'startTime','') is not null
        and (comp_ids is null or e.payload->>'competitionId'=any(comp_ids))
      union
      select e.id,e.payload,(e.payload->>'startTime')::timestamptz
      from futbeat_private.entities e
      where e.kind='match' and e.payload->>'awayTeamId'=any(ids)
        and nullif(e.payload->>'startTime','') is not null
        and (comp_ids is null or e.payload->>'competitionId'=any(comp_ids))
    ) c
    where (
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
    -- Season filter (the competition, aliases included, is already in the
    -- scan); checked before the (costlier) read model.
    continue when season_filter='-' and nullif(nullif(futbeat_private.normalize_season(
      rec.payload->>'season'),''),'-') is not null;
    continue when season_filter is not null and season_filter<>'-' and nullif(futbeat_private.normalize_season(
      rec.payload->>'season'),'') is distinct from season_filter;
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
      'developmentOnly',false,'sources',jsonb_build_array('GOAL API'),
      'teamMatches',futbeat_private.team_match_coverage_state(tid)),
    'teamId',tid,
    'bucket',p_bucket,
    'competitionId',comp_filter,
    'seasonKey',season_filter,
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

revoke all on function
  futbeat_private.team_context_options(text),
  futbeat_private.competition_identity_ids(text),
  futbeat_private.canonical_table(jsonb,text)
from public,anon,authenticated,service_role;
revoke all on function
  public.futbeat_read_team_context(text,text,text),
  public.futbeat_read_team_matches(text,text,text,integer,text,text)
from public,anon,authenticated;
grant execute on function
  public.futbeat_read_team_context(text,text,text),
  public.futbeat_read_team_matches(text,text,text,integer,text,text)
to service_role;

notify pgrst,'reload schema';
