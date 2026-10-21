-- Rollback of 20261019110000_team_profile_fixture_twins.sql (manual, NOT a
-- migration). Restores public.futbeat_read_team_matches exactly as in
-- 20260929140000 (team profiles list both copies of a duplicated fixture
-- again) and drops the two new read-only functions. Nothing else changed.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';
drop function public.futbeat_read_team_matches(text,text,text,integer,text,text);
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
revoke all on function public.futbeat_read_team_matches(text,text,text,integer,text,text)
  from public,anon,authenticated;
grant execute on function public.futbeat_read_team_matches(text,text,text,integer,text,text)
  to service_role;
drop function if exists futbeat_private.fixture_better_twin(jsonb);
drop function if exists futbeat_private.team_identity_twin_candidates(date,date);
notify pgrst, 'reload schema';
commit;
