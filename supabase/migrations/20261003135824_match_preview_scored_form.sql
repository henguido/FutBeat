-- Match Center 2.0: backfill recent form with actual scored matches.
-- Read-only change; preserves the 365-day team lookup, 5-item cap, H2H
-- implementation, stable/security-definer contract, and service-only RPC.

create or replace function futbeat_private.read_match_preview(p_match_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t jsonb; kickoff timestamptz; home text; away text;
  form_days constant integer:=365; max_items constant integer:=5; max_meetings constant integer:=20;
  home_ids text[]; away_ids text[]; result jsonb;
  -- head-to-head (canonical)
  c_home text; c_away text; c_comp text; home_alias text[]; away_alias text[];
  target jsonb; target_final boolean:=false;
  meetings jsonb:='[]'::jsonb; summary jsonb; comp_summary jsonb;
  legacy_ids text[]:='{}'; legacy_summary jsonb;
  cov_home jsonb; cov_away jsonb; availability text; verified_from date;
begin
  select e.payload into t from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
  if t is null then return null; end if;
  kickoff:=nullif(t->>'startTime','')::timestamptz;
  home:=nullif(t->>'homeTeamId','');
  away:=nullif(t->>'awayTeamId','');

  if kickoff is not null and home is not null and away is not null then
    -- Recent form per side: validate the score before LIMIT, so a scoreless
    -- terminal row cannot displace an older scored result.
    select array_agg(x.id order by x.st desc,x.id) into home_ids from (
      select e.id,nullif(e.payload->>'startTime','')::timestamptz st
      from futbeat_private.entities e
      where e.kind='match' and (e.payload->>'homeTeamId'=home or e.payload->>'awayTeamId'=home)
        and e.payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
        -- Only complete, nonnegative, integer-valued results count as form.
        and case when jsonb_typeof(e.payload->'score'->'home')='number' then
          (e.payload->'score'->>'home')::numeric>=0 and
          (e.payload->'score'->>'home')::numeric=trunc((e.payload->'score'->>'home')::numeric)
          else false end
        and case when jsonb_typeof(e.payload->'score'->'away')='number' then
          (e.payload->'score'->>'away')::numeric>=0 and
          (e.payload->'score'->>'away')::numeric=trunc((e.payload->'score'->>'away')::numeric)
          else false end
        and nullif(e.payload->>'startTime','')::timestamptz<kickoff
        and nullif(e.payload->>'startTime','')::timestamptz>=kickoff-make_interval(days=>form_days)
      order by 2 desc,1 limit max_items) x;
    select array_agg(x.id order by x.st desc,x.id) into away_ids from (
      select e.id,nullif(e.payload->>'startTime','')::timestamptz st
      from futbeat_private.entities e
      where e.kind='match' and (e.payload->>'homeTeamId'=away or e.payload->>'awayTeamId'=away)
        and e.payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
        -- Only complete, nonnegative, integer-valued results count as form.
        and case when jsonb_typeof(e.payload->'score'->'home')='number' then
          (e.payload->'score'->>'home')::numeric>=0 and
          (e.payload->'score'->>'home')::numeric=trunc((e.payload->'score'->>'home')::numeric)
          else false end
        and case when jsonb_typeof(e.payload->'score'->'away')='number' then
          (e.payload->'score'->>'away')::numeric>=0 and
          (e.payload->'score'->>'away')::numeric=trunc((e.payload->'score'->>'away')::numeric)
          else false end
        and nullif(e.payload->>'startTime','')::timestamptz<kickoff
        and nullif(e.payload->>'startTime','')::timestamptz>=kickoff-make_interval(days=>form_days)
      order by 2 desc,1 limit max_items) x;

    -- Head-to-head v2: canonical pair, aliases included, effective status.
    c_home:=futbeat_private.futbeat_resolve_entity_id('team',home);
    c_away:=futbeat_private.futbeat_resolve_entity_id('team',away);
    c_comp:=futbeat_private.futbeat_resolve_entity_id('competition',nullif(t->>'competitionId',''));
    target:=futbeat_private.match_read_model_core(t,false);
    target_final:=target->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
      and jsonb_typeof(target->'score'->'home')='number' and jsonb_typeof(target->'score'->'away')='number';
    if c_home<>c_away then
      home_alias:=futbeat_private.team_identity_ids(c_home);
      away_alias:=futbeat_private.team_identity_ids(c_away);
      with candidates as (
        -- Two index lookups (home/away team indexes), then the pair filter.
        select e.id,e.payload from futbeat_private.entities e
        where e.kind='match' and e.payload->>'homeTeamId'=any(home_alias||away_alias)
          and e.payload->>'awayTeamId'=any(home_alias||away_alias)
          and ((e.payload->>'homeTeamId'=any(home_alias) and e.payload->>'awayTeamId'=any(away_alias))
            or (e.payload->>'homeTeamId'=any(away_alias) and e.payload->>'awayTeamId'=any(home_alias)))
          and nullif(e.payload->>'startTime','') is not null
          and (e.payload->>'startTime')::timestamptz<=kickoff
      ), modeled as (
        select c.id,futbeat_private.match_read_model_core(c.payload,false) m from candidates c
      ), finals as (
        select id,m,futbeat_private.team_match_result(m,c_home) r from modeled
        where m->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
          and jsonb_typeof(m->'score'->'home')='number' and jsonb_typeof(m->'score'->'away')='number'
          -- The target counts only once final (and then exactly once).
          and (id<>p_match_id or target_final)
      )
      select
        coalesce((select jsonb_agg(jsonb_build_object(
            'matchId',f.id,
            'competitionId',f.m->>'competitionId',
            'startTime',f.m->>'startTime',
            'status',f.m->>'status',
            'homeTeamId',f.m->>'homeTeamId',
            'awayTeamId',f.m->>'awayTeamId',
            'score',jsonb_build_object('home',f.m->'score'->'home','away',f.m->'score'->'away'),
            'result',f.r)
            order by (f.m->>'startTime')::timestamptz desc,f.id)
          from (select * from finals order by (m->>'startTime')::timestamptz desc,id limit max_meetings) f),'[]'::jsonb),
        (select jsonb_build_object('homeWins',count(*) filter(where r='WIN'),'draws',count(*) filter(where r='DRAW'),
            'awayWins',count(*) filter(where r='LOSS'),'counted',count(r)) from finals),
        (select jsonb_build_object('competitionId',c_comp,'homeWins',count(*) filter(where r='WIN'),
            'draws',count(*) filter(where r='DRAW'),'awayWins',count(*) filter(where r='LOSS'),'counted',count(r))
          from finals where m->>'competitionId'=c_comp)
      into meetings,summary,comp_summary;

      select coalesce(array_agg(x.id order by x.st desc,x.id),'{}') into legacy_ids from (
        select value->>'matchId' id,(value->>'startTime')::timestamptz st
        from jsonb_array_elements(meetings)
        where value->>'matchId'<>p_match_id and (value->>'startTime')::timestamptz<kickoff
        order by 2 desc,1 limit max_items) x;
      select jsonb_build_object('homeWins',count(*) filter(where value->>'result'='WIN'),
          'draws',count(*) filter(where value->>'result'='DRAW'),
          'awayWins',count(*) filter(where value->>'result'='LOSS'),'counted',count(value->>'result'))
        into legacy_summary
        from jsonb_array_elements(meetings) where value->>'matchId'=any(legacy_ids);

      cov_home:=futbeat_private.team_match_coverage_state(c_home);
      cov_away:=futbeat_private.team_match_coverage_state(c_away);
      availability:=case
        when jsonb_array_length(meetings)>0 then
          case when cov_home->>'state' in ('AVAILABLE','NO_DATA','UNAVAILABLE')
            and cov_away->>'state' in ('AVAILABLE','NO_DATA','UNAVAILABLE') then 'AVAILABLE' else 'STALE' end
        when cov_home->>'state' in ('AVAILABLE','NO_DATA') and cov_away->>'state' in ('AVAILABLE','NO_DATA')
          then 'CONFIRMED_EMPTY'
        when cov_home->>'state' in ('PENDING','STALE') or cov_away->>'state' in ('PENDING','STALE')
          then 'PENDING'
        else 'UNAVAILABLE' end;
      -- The verified window is where BOTH teams have an explicit covered
      -- range (a NO_DATA side has none): otherwise null, never a date that
      -- claims more than what was checked.
      verified_from:=case when nullif(cov_home->>'coveredFrom','') is not null
          and nullif(cov_away->>'coveredFrom','') is not null
        then greatest((cov_home->>'coveredFrom')::date,(cov_away->>'coveredFrom')::date) end;
    end if;
  end if;
  home_ids:=coalesce(home_ids,'{}'); away_ids:=coalesce(away_ids,'{}');

  with meeting_rows as (
    select value m from jsonb_array_elements(coalesce(meetings,'[]'::jsonb))
  ), ids as (
    -- Legacy `matches`: form + the legacy 5 meetings (v1 contract).
    select distinct unnest(home_ids||away_ids||legacy_ids) id
  ), items as (
    select e.id,e.payload p from futbeat_private.entities e join ids on ids.id=e.id where e.kind='match'
  ), team_ids as (
    select distinct x id from (
      select home x union all select away union all select c_home union all select c_away
      union all select i.p->>'homeTeamId' from items i
      union all select i.p->>'awayTeamId' from items i
      union all select r.m->>'homeTeamId' from meeting_rows r
      union all select r.m->>'awayTeamId' from meeting_rows r) t where x is not null
  ), comp_ids as (
    select distinct x id from (select i.p->>'competitionId' x from items i
      union all select r.m->>'competitionId' from meeting_rows r union all select c_comp) c where x is not null
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
    'h2h',jsonb_strip_nulls(jsonb_build_object(
      -- Legacy keys (installed apps, v1 contract: 5 meetings before kickoff).
      'state',case when cardinality(legacy_ids)>0 then 'available' else 'none' end,
      'matchIds',to_jsonb(legacy_ids),
      'summary',coalesce(legacy_summary,jsonb_build_object('homeWins',0,'draws',0,'awayWins',0,'counted',0)),
      -- v2
      'pairKey',case when c_home is not null and c_away is not null
        then least(c_home,c_away)||'|'||greatest(c_home,c_away) end,
      'homeTeamId',c_home,
      'awayTeamId',c_away,
      'competitionId',c_comp,
      'availability',coalesce(availability,'UNAVAILABLE'),
      'coverage',jsonb_build_object('home',cov_home->>'state','away',cov_away->>'state',
        'verifiedFrom',verified_from),
      'totals',coalesce(summary,jsonb_build_object('homeWins',0,'draws',0,'awayWins',0,'counted',0)),
      'competitionTotals',comp_summary,
      'meetings',coalesce(meetings,'[]'::jsonb),
      'current',case when target is not null and not target_final then jsonb_build_object(
        'matchId',p_match_id,'competitionId',target->>'competitionId','startTime',target->>'startTime',
        'status',target->>'status','homeTeamId',target->>'homeTeamId','awayTeamId',target->>'awayTeamId',
        'score',case when jsonb_typeof(target->'score'->'home')='number' and jsonb_typeof(target->'score'->'away')='number'
          then jsonb_build_object('home',target->'score'->'home','away',target->'score'->'away') end) end)),
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

revoke all on function futbeat_private.read_match_preview(text) from public,anon,authenticated,service_role;
