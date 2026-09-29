-- Issue #155: Cara a cara must expose the full stored history of the pair.
--
-- Evidence (production, read-only, 29-sep-2026): Belgium-France had exactly
-- two canonical matches stored (a final on 2026-09-28 and the scheduled
-- 2026-10-05 fixture) and the v2 read returned exactly those (1 counted
-- meeting + the scheduled one as `current`). The read was correct; the
-- product was not:
--   * both teams' coverage only spans the initial window (2026-04-02 ..
--     2027-01-27); nothing ever asked for OLDER history of a pair, so two
--     national teams that met years ago show one meeting;
--   * `AVAILABLE` did not say since when records exist;
--   * the list stopped at 20 with no way to page further.
--
-- Fix (same canonical data, same central coverage pipeline):
--   * futbeat_private.h2h_meetings(match): the single source of the pair's
--     meetings (canonical ids + aliases, effective lifecycle, finals with a
--     complete score, up to the target's kickoff, the target only once it is
--     final). Two index lookups (home/away team indexes).
--   * public.futbeat_read_match_h2h(match, scope, cursor, limit): keyset
--     pages (startTime desc, id desc) for scope 'all' or 'competition' (the
--     target's canonical competition). Totals are over EVERY meeting of the
--     scope, independent of the page. `window` states what was verified:
--     verifiedFrom (both teams' explicit covered range), historyFloor and
--     canExtend. Never "total history" beyond that.
--   * public.futbeat_request_match_h2h_history(match): extends BOTH teams'
--     central coverage one step back through futbeat_request_team_matches
--     (p_before = its covered_from; 180-day steps, 3-year floor, one
--     deduplicated demand per team, the #153/#154 wake + safety net).

create function futbeat_private.h2h_meetings(p_match_id text)
returns table(match_id text,start_time timestamptz,competition_id text,result text,meeting jsonb)
language plpgsql stable security definer set search_path='' as $$
declare t jsonb; kickoff timestamptz; c_home text; c_away text;
  home_alias text[]; away_alias text[]; target jsonb; target_final boolean;
begin
  select e.payload into t from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
  if t is null then return; end if;
  kickoff:=nullif(t->>'startTime','')::timestamptz;
  c_home:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'homeTeamId',''));
  c_away:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'awayTeamId',''));
  if kickoff is null or c_home is null or c_away is null or c_home=c_away then return; end if;
  target:=futbeat_private.match_read_model_core(t,false);
  target_final:=target->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
    and jsonb_typeof(target->'score'->'home')='number' and jsonb_typeof(target->'score'->'away')='number';
  home_alias:=futbeat_private.team_identity_ids(c_home);
  away_alias:=futbeat_private.team_identity_ids(c_away);
  return query
  with candidates as (
    select e.id,e.payload from futbeat_private.entities e
    where e.kind='match' and e.payload->>'homeTeamId'=any(home_alias||away_alias)
      and e.payload->>'awayTeamId'=any(home_alias||away_alias)
      and ((e.payload->>'homeTeamId'=any(home_alias) and e.payload->>'awayTeamId'=any(away_alias))
        or (e.payload->>'homeTeamId'=any(away_alias) and e.payload->>'awayTeamId'=any(home_alias)))
      and nullif(e.payload->>'startTime','') is not null
      and (e.payload->>'startTime')::timestamptz<=kickoff
  ), modeled as (
    select c.id,futbeat_private.match_read_model_core(c.payload,false) m from candidates c
  )
  select x.id,(x.m->>'startTime')::timestamptz,x.m->>'competitionId',
    futbeat_private.team_match_result(x.m,c_home),
    jsonb_build_object(
      'matchId',x.id,'competitionId',x.m->>'competitionId','startTime',x.m->>'startTime',
      'status',x.m->>'status','homeTeamId',x.m->>'homeTeamId','awayTeamId',x.m->>'awayTeamId',
      'score',jsonb_build_object('home',x.m->'score'->'home','away',x.m->'score'->'away'),
      'result',futbeat_private.team_match_result(x.m,c_home))
  from modeled x
  where x.m->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
    and jsonb_typeof(x.m->'score'->'home')='number' and jsonb_typeof(x.m->'score'->'away')='number'
    and (x.id<>p_match_id or target_final);
end $$;

-- What is actually verified for the pair: both teams' explicit covered range
-- (a NO_DATA side has none -> null), the floor, and whether one more step
-- back can be asked for.
create function futbeat_private.h2h_window(p_home text,p_away text)
returns jsonb language plpgsql stable set search_path='' as $$
declare
  w jsonb:=futbeat_private.team_match_window();
  floor_date date:=current_date-(w->>'historyFloorDays')::integer;
  hs jsonb:=futbeat_private.team_match_coverage_state(p_home);
  aw jsonb:=futbeat_private.team_match_coverage_state(p_away);
  h_from date:=nullif(hs->>'coveredFrom','')::date;
  a_from date:=nullif(aw->>'coveredFrom','')::date;
  requested boolean;
begin
  -- Extending = at least one of the two teams has an open demand for a range
  -- older than its own verified start (per team, never a mix of both).
  requested:=exists(select 1 from futbeat_private.team_match_demands d
      where d.team_id=p_home and d.past_target is not null and d.past_target<h_from)
    or exists(select 1 from futbeat_private.team_match_demands d
      where d.team_id=p_away and d.past_target is not null and d.past_target<a_from);
  return jsonb_strip_nulls(jsonb_build_object(
    'verifiedFrom',case when h_from is not null and a_from is not null then greatest(h_from,a_from) end,
    'historyFloor',floor_date,
    -- One more step back makes sense for a team with a known range above
    -- the floor and a provider source.
    'canExtend',coalesce(hs->>'state' in ('AVAILABLE','STALE') and h_from>floor_date,false)
      or coalesce(aw->>'state' in ('AVAILABLE','STALE') and a_from>floor_date,false),
    'extending',requested));
end $$;

create function public.futbeat_read_match_h2h(
  p_match_id text,
  p_scope text default 'all',
  p_cursor text default null,
  p_limit integer default 20
) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
  t jsonb; c_home text; c_away text; c_comp text;
  cursor_time timestamptz; cursor_id text;
  page jsonb; has_more boolean; totals jsonb; out_json jsonb;
begin
  if p_scope not in ('all','competition') or p_limit is null or p_limit<1 or p_limit>50 then
    raise exception 'Invalid h2h request';
  end if;
  if p_cursor is not null then
    begin
      cursor_time:=split_part(p_cursor,'|',1)::timestamptz;
      cursor_id:=nullif(substr(p_cursor,position('|' in p_cursor)+1),'');
      if position('|' in p_cursor)=0 then cursor_id:=null; end if;
    exception when others then raise exception 'Invalid h2h cursor';
    end;
    if cursor_id is null then raise exception 'Invalid h2h cursor'; end if;
  end if;
  select e.payload into t from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
  if t is null then return null; end if;
  c_home:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'homeTeamId',''));
  c_away:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'awayTeamId',''));
  c_comp:=futbeat_private.futbeat_resolve_entity_id('competition',nullif(t->>'competitionId',''));

  with scoped as materialized (
    select * from futbeat_private.h2h_meetings(p_match_id) x
    where p_scope='all' or x.competition_id=c_comp
  ), windowed as (
    select * from scoped s
    where cursor_time is null or (s.start_time,s.match_id)<(cursor_time,cursor_id)
    order by s.start_time desc,s.match_id desc
    limit p_limit+1
  )
  select
    (select coalesce(jsonb_agg(w.meeting order by w.start_time desc,w.match_id desc),'[]'::jsonb)
      from (select * from windowed order by start_time desc,match_id desc limit p_limit) w),
    (select count(*)>p_limit from windowed),
    (select jsonb_build_object('homeWins',count(*) filter(where result='WIN'),
      'draws',count(*) filter(where result='DRAW'),'awayWins',count(*) filter(where result='LOSS'),
      'counted',count(result)) from scoped)
  into page,has_more,totals;

  select jsonb_build_object(
    'schemaVersion',1,
    'matchId',p_match_id,
    'pairKey',case when c_home is not null and c_away is not null then least(c_home,c_away)||'|'||greatest(c_home,c_away) end,
    'homeTeamId',c_home,
    'awayTeamId',c_away,
    'scope',p_scope,
    'competitionId',c_comp,
    'totals',totals,
    'meetings',page,
    'hasMore',has_more,
    'nextCursor',case when has_more then
      to_char((page->-1->>'startTime')::timestamptz at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        ||'|'||(page->-1->>'matchId') end,
    'window',case when c_home is not null and c_away is not null and c_home<>c_away
      then futbeat_private.h2h_window(c_home,c_away) else '{}'::jsonb end,
    'teams',(select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'id',e.id,'name',e.payload->>'name','shortName',e.payload->>'shortName',
        'color',e.payload->>'color','media',e.payload->'media')) order by e.id),'[]'::jsonb)
      from futbeat_private.entities e where e.kind='team' and e.id in (
        select c_home union select c_away
        union select value->>'homeTeamId' from jsonb_array_elements(page)
        union select value->>'awayTeamId' from jsonb_array_elements(page))),
    'competitions',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.payload->>'name') order by e.id),'[]'::jsonb)
      from futbeat_private.entities e where e.kind='competition' and e.id in (
        select c_comp union select value->>'competitionId' from jsonb_array_elements(page))))
  into out_json;
  return out_json;
end $$;

-- "Cargar historial anterior": one step back of BOTH teams' central coverage.
create function public.futbeat_request_match_h2h_history(p_match_id text)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare t jsonb; c_home text; c_away text; hs jsonb; aw jsonb; out_home jsonb; out_away jsonb; w jsonb;
begin
  select e.payload into t from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
  if t is null then return jsonb_build_object('matchId',p_match_id,'found',false); end if;
  c_home:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'homeTeamId',''));
  c_away:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'awayTeamId',''));
  if c_home is null or c_away is null or c_home=c_away then
    return jsonb_build_object('matchId',p_match_id,'found',true,'requested',false);
  end if;
  -- A step already in flight, or nothing left to ask: no new demand (a
  -- repeated or scripted extend never stacks steps).
  w:=futbeat_private.h2h_window(c_home,c_away);
  if (w->>'extending')::boolean or not (w->>'canExtend')::boolean then
    return jsonb_build_object('matchId',p_match_id,'found',true,'requested',false,'window',w);
  end if;
  hs:=futbeat_private.team_match_coverage_state(c_home);
  aw:=futbeat_private.team_match_coverage_state(c_away);
  -- p_before = the team's own covered_from; the request itself enforces the
  -- floor, the dedup and the throttle.
  out_home:=public.futbeat_request_team_matches(c_home,nullif(hs->>'coveredFrom','')::date);
  out_away:=public.futbeat_request_team_matches(c_away,nullif(aw->>'coveredFrom','')::date);
  return jsonb_build_object('matchId',p_match_id,'found',true,'home',out_home,'away',out_away,
    'window',futbeat_private.h2h_window(c_home,c_away));
end $$;

revoke all on function
  futbeat_private.h2h_meetings(text),
  futbeat_private.h2h_window(text,text)
from public,anon,authenticated,service_role;
revoke all on function
  public.futbeat_read_match_h2h(text,text,text,integer),
  public.futbeat_request_match_h2h_history(text)
from public,anon,authenticated;
grant execute on function
  public.futbeat_read_match_h2h(text,text,text,integer),
  public.futbeat_request_match_h2h_history(text)
to service_role;

notify pgrst,'reload schema';
