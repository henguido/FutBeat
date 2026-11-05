-- Team profile: one real fixture is listed once; twin team identities are
-- reported for review, never merged automatically.
--
-- QA81 (#222): the Cartaginés profile showed the 13-oct fixture against
-- Puntarenas twice (final 3-1 and "Por confirmar"). Verified in the
-- 17-oct export: the TheSportsDB copy plays a Puntarenas identity
-- (fb_team_6393...) different from the one the GOAL fixtures use
-- (fb_team_a201...). The GOAL id of the 3-1 row is NOT verified.
--
-- Two separate gaps, both reproduced locally with generic ids:
--   1. Team identity. Two providers created two canonical teams for one
--      club. No provider ever sees both, and nothing links them except
--      fixtures. This migration does NOT link them: names are not identity.
--      team_identity_twin_candidates() lists pairs with STRUCTURAL evidence
--      only (same competition, same opponent on the same side, kickoff
--      within 24 h, disjoint provider mappings, never opponents of each
--      other) so an operator can review them and register the redirect
--      with the existing futbeat_register_entity_redirect.
--   2. Team profile read. Even after such a redirect,
--      public.futbeat_read_team_matches listed both entities: only the
--      Partidos calendar applied the same-fixture rule of 20260930110000
--      (documented as an open risk in CONTROL_FUTBEAT_LONG_SESSION.md).
--      The team list now skips a match that has a better-ranked twin under
--      that same rule (exact_kickoff, single_evidence_3h, and the earlier
--      scheduled ghost of a played twin within 24 h). Canonical ids only;
--      two finished results that differ are never collapsed; another
--      competition is never a twin; nothing is deleted.
--
-- Read-only functions; no provider call, quota, cron or mapping change.

-- A better-ranked twin of p_item (a match_read_model_core item: ids already
-- resolved), or null. Same evidence levels as the calendar.
create or replace function futbeat_private.fixture_better_twin(p_item jsonb)
returns text language plpgsql stable security definer set search_path='' as $$
declare
  v_id text:=p_item->>'id';
  v_comp text:=nullif(p_item->>'competitionId','');
  v_home text:=nullif(p_item->>'homeTeamId','');
  v_away text:=nullif(p_item->>'awayTeamId','');
  v_redirect_context boolean;
  v_kickoff timestamptz:=futbeat_private.try_timestamptz(p_item->>'startTime');
  v_rank text:=futbeat_private.fixture_display_rank(p_item);
  v_final text:=futbeat_private.fixture_final_score(p_item);
  v_ghost boolean:=futbeat_private.fixture_is_ghost(p_item);
  x record; xi jsonb; x_kickoff timestamptz; v_level text;
begin
  if v_comp is null or v_home is null or v_away is null or v_home=v_away or v_kickoff is null then
    return null;
  end if;
  v_redirect_context:=cardinality(futbeat_private.team_identity_ids(v_home))>1
    or cardinality(futbeat_private.team_identity_ids(v_away))>1;
  for x in
    select e.id,e.payload from futbeat_private.entities e
    where e.kind='match' and e.id<>v_id
      and e.payload->>'homeTeamId'=any(futbeat_private.team_identity_ids(v_home))
      and e.payload->>'awayTeamId'=any(futbeat_private.team_identity_ids(v_away))
      and futbeat_private.try_timestamptz(e.payload->>'startTime')
        between v_kickoff-interval '24 hours' and v_kickoff+interval '24 hours'
    order by e.id
  loop
    xi:=futbeat_private.match_read_model_core(x.payload,false);
    continue when xi->>'competitionId' is distinct from v_comp;
    x_kickoff:=futbeat_private.try_timestamptz(xi->>'startTime');
    v_level:=futbeat_private.same_fixture_level(v_id,v_comp,v_home,v_away,v_kickoff,v_final,
      x.id,v_comp,xi->>'homeTeamId',xi->>'awayTeamId',x_kickoff,futbeat_private.fixture_final_score(xi));
    if v_level is not null
       -- A loose time/evidence match is safe here only after a reviewed team
       -- redirect made two stored identities canonical. Redirect registration
       -- rewrites historical match payloads, so the alias set is the durable
       -- evidence; without it two real fixtures can be a few hours apart.
       and (v_level='exact_kickoff' or v_redirect_context)
       and (futbeat_private.fixture_display_rank(xi),x.id)<(v_rank,v_id) then
      return x.id;
    end if;
    -- A scheduled ghost whose time passed before a played twin (never a
    -- later scheduled game: that can be a real second game).
    if v_ghost and v_redirect_context and x_kickoff>v_kickoff
       and xi->>'status' in ('VERIFIED','FINISHED_PENDING_VERIFICATION','LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then
      return x.id;
    end if;
  end loop;
  return null;
end $$;

-- Review queue (read-only): pairs of team identities that look like one
-- club stored twice by two providers. Evidence = number of shared fixtures.
create or replace function futbeat_private.team_identity_twin_candidates(p_from_date date,p_to_date date)
returns table(team_a text,team_b text,evidence integer,competition_id text,
  sample_match_a text,sample_match_b text,providers_a text[],providers_b text[],
  name_a text,name_b text)
language sql stable security definer set search_path='' as $$
  with m as materialized (
    select e.id,
      futbeat_private.futbeat_resolve_entity_id('competition',e.payload->>'competitionId') comp,
      futbeat_private.futbeat_resolve_entity_id('team',e.payload->>'homeTeamId') home,
      futbeat_private.futbeat_resolve_entity_id('team',e.payload->>'awayTeamId') away,
      c.start_time kickoff
    from futbeat_private.calendar_matches c
    join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
    where c.start_time>=p_from_date::timestamp at time zone 'UTC'
      and c.start_time<(p_to_date+1)::timestamp at time zone 'UTC'
  ), pairs as (
    select a.id ma,b.id mb,a.comp,
      case when a.home=b.home then a.away else a.home end x,
      case when a.home=b.home then b.away else b.home end y
    from m a join m b on b.comp=a.comp and a.id<b.id
      and abs(extract(epoch from (b.kickoff-a.kickoff)))<=86400
      and ((a.home=b.home and a.away<>b.away) or (a.away=b.away and a.home<>b.home))
    where a.comp is not null and a.home<>a.away and b.home<>b.away
  ), oriented as (
    select least(x,y) team_a,greatest(x,y) team_b,comp,
      case when x<y then ma else mb end sample_a,case when x<y then mb else ma end sample_b
    from pairs
  ), mapped as (
    select o.*,
      (select array_agg(distinct pe.provider order by pe.provider) from futbeat_private.provider_entities pe
        where pe.kind='team' and pe.canonical_id=any(futbeat_private.team_identity_ids(o.team_a))) pa,
      (select array_agg(distinct pe.provider order by pe.provider) from futbeat_private.provider_entities pe
        where pe.kind='team' and pe.canonical_id=any(futbeat_private.team_identity_ids(o.team_b))) pb
    from oriented o
  )
  select g.team_a,g.team_b,count(*)::integer,min(g.comp),min(g.sample_a),min(g.sample_b),
    min(g.pa),min(g.pb),
    (select payload->>'name' from futbeat_private.entities where id=g.team_a),
    (select payload->>'name' from futbeat_private.entities where id=g.team_b)
  from mapped g
  where g.pa is not null and g.pb is not null and not (g.pa && g.pb)
    -- Two identities that ever met each other are two clubs.
    and not exists(select 1 from futbeat_private.entities e
      where e.kind='match'
        and ((e.payload->>'homeTeamId'=any(futbeat_private.team_identity_ids(g.team_a))
              and e.payload->>'awayTeamId'=any(futbeat_private.team_identity_ids(g.team_b)))
          or (e.payload->>'homeTeamId'=any(futbeat_private.team_identity_ids(g.team_b))
              and e.payload->>'awayTeamId'=any(futbeat_private.team_identity_ids(g.team_a)))))
  group by g.team_a,g.team_b
$$;

-- Team matches: 20260929140000 body; one line added (twin skip).
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
    -- The same real fixture stored twice is listed once (calendar rule).
    continue when futbeat_private.fixture_better_twin(
      futbeat_private.match_read_model_core(rec.payload,false)) is not null;
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

revoke all on function futbeat_private.fixture_better_twin(jsonb),
  futbeat_private.team_identity_twin_candidates(date,date)
  from public,anon,authenticated,service_role;
revoke all on function public.futbeat_read_team_matches(text,text,text,integer,text,text)
  from public,anon,authenticated;
grant execute on function public.futbeat_read_team_matches(text,text,text,integer,text,text)
  to service_role;

notify pgrst,'reload schema';
