-- APPLIED IN PRODUCTION 2026-11-27 04:38Z via ops ledger op 'fb05-sql' (FB-PLAY-17). Recorded here for reproducibility;
-- source kit: fb05/deploy/fb05_last_lineup.sql

-- FB-05 DRAFT (local only, NOT a production op): "Última alineación confirmada" per side of an upcoming match.
-- GOAL has no predicted lineups. This returns, for each team, the starting XI (+ bench) that the provider CONFIRMED in
-- the team's most recent finished match stored in match_detail_cache. It never invents a player and is never a
-- prediction: kind='LAST_CONFIRMED', with the source match (date, competition, opponent) so the UI must label it.
-- Additive contract: a NEW read (public.futbeat_read_match_last_lineups); match-detail / match-preview are unchanged.
-- Rows are the provider's raw lineup rows (same shape match-detail already returns in payload.lineups), with
-- "team" re-labelled to the side of the UPCOMING match so the app can reuse its existing lineup parser and
-- photo hydration (playerKey -> futbeat_read_lineup_player_media). 0 provider calls.
--
-- Rules (fail-closed: no candidate -> side is null):
--   * target match exists, both teams known, status not live/finished (SCHEDULED/TIMED/POSTPONED only);
--   * source = latest match of the team (canonical + redirect aliases, team_identity_ids) with
--     kickoff < target kickoff and > target kickoff - 45 days, status FINISHED_PENDING_VERIFICATION/VERIFIED,
--     and a stored detail whose lineups give this team's side 7..11 starters (lineup_rows);
--   * the team's side in the source = home if its homeTeamId is one of the aliases, else away.

create or replace function futbeat_private.team_last_confirmed_lineup(p_team text, p_before timestamptz, p_as_side text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare ids text[]; src record; rows jsonb;
begin
  if p_team is null or p_before is null or p_as_side not in ('home','away') then return null; end if;
  ids:=futbeat_private.team_identity_ids(p_team);
  for src in
    select x.id, x.p, case when x.p->>'homeTeamId'=any(ids) then 'home' else 'away' end side
    from (
      select e.id, e.payload p from futbeat_private.entities e
       where e.kind='match' and e.payload->>'homeTeamId'=any(ids)
      union
      select e.id, e.payload from futbeat_private.entities e
       where e.kind='match' and e.payload->>'awayTeamId'=any(ids)
    ) x
    where nullif(x.p->>'startTime','') is not null
      and (x.p->>'startTime')::timestamptz <  p_before
      and (x.p->>'startTime')::timestamptz >  p_before - interval '45 days'
      and futbeat_private.match_read_model_core(x.p,false)->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
      and exists(select 1 from futbeat_private.match_detail_cache c where c.match_id=x.id)
    order by (x.p->>'startTime')::timestamptz desc, x.id desc
    limit 6
  loop
    select jsonb_agg(r.item || jsonb_build_object('team',p_as_side) order by
             (lower(coalesce(r.item->>'type','')) like 'start%') desc, r.ord)
      into rows
      from (select l.item, row_number() over () ord
              from futbeat_private.match_detail_cache c, futbeat_private.lineup_rows(c.payload) l
             where c.match_id=src.id and l.side=src.side) r;
    if (select count(*) from jsonb_array_elements(coalesce(rows,'[]')) v
         where lower(coalesce(v->>'type','')) like 'start%') between 7 and 11 then
      return jsonb_build_object(
        'kind','LAST_CONFIRMED',
        'teamId',p_team,
        'sourceMatch',jsonb_build_object('matchId',src.id,'startTime',src.p->>'startTime',
          'competitionId',src.p->>'competitionId','side',src.side,
          'opponentTeamId',case src.side when 'home' then src.p->>'awayTeamId' else src.p->>'homeTeamId' end),
        'lineups',rows);
    end if;
  end loop;
  return null;
end $$;

create or replace function public.futbeat_read_match_last_lineups(p_match_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t jsonb; ko timestamptz; st text; h text; a text; hl jsonb; al jsonb;
begin
  select e.payload into t from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
  if t is null then return null; end if;
  ko:=nullif(t->>'startTime','')::timestamptz;
  st:=futbeat_private.match_read_model_core(t,false)->>'status';
  h:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'homeTeamId',''));
  a:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'awayTeamId',''));
  if ko is null or h is null or a is null or h=a or coalesce(st,'') not in ('SCHEDULED','TIMED','POSTPONED') then
    return jsonb_build_object('schemaVersion',1,'matchId',p_match_id,'eligible',false);
  end if;
  hl:=futbeat_private.team_last_confirmed_lineup(h,ko,'home');
  al:=futbeat_private.team_last_confirmed_lineup(a,ko,'away');
  return jsonb_build_object('schemaVersion',1,'matchId',p_match_id,'eligible',true,
    'kind','LAST_CONFIRMED','isPrediction',false,
    'home',hl,'away',al,
    -- names for the label "Última alineación confirmada · <fecha> vs <rival> (<competición>)"
    'teams',(select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id',e.id,'name',e.payload->>'name',
        'shortName',e.payload->>'shortName','media',e.payload->'media')) order by e.id),'[]'::jsonb)
      from futbeat_private.entities e where e.kind='team' and e.id in (
        hl->'sourceMatch'->>'opponentTeamId', al->'sourceMatch'->>'opponentTeamId')),
    'competitions',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.payload->>'name') order by e.id),'[]'::jsonb)
      from futbeat_private.entities e where e.kind='competition' and e.id in (
        hl->'sourceMatch'->>'competitionId', al->'sourceMatch'->>'competitionId')));
end $$;

revoke all on function futbeat_private.team_last_confirmed_lineup(text,timestamptz,text) from public, anon, authenticated;
revoke all on function public.futbeat_read_match_last_lineups(text) from public;
grant execute on function public.futbeat_read_match_last_lineups(text) to anon, authenticated;
