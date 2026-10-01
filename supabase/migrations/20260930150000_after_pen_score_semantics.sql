-- GOAL AFTER_PEN result semantics (P0 results integrity).
--
-- Evidence (production, read-only audit of 117 stored AFTER_PEN answers):
--   * for matchStatus AFTER_PEN the running total homeTeamScore /
--     awayTeamScore carries a BONUS of +1 or +2 for the shoot-out WINNER
--     (it drifts between fetches); the real result is FtScore + ExtraScore;
--   * bonus in {0,1,2}; with a complete, non-tied penalty score the bonus
--     side is always the shoot-out winner (49/49);
--   * LIVE answers during the PENALTIES period and the match_detail_cache
--     events always equal FT + ET;
--   * two-legged ties exist where FT + ET is NOT tied (e.g. FT 0-1,
--     pens 2-4, running total 0-2): FT + ET is not required to be tied;
--   * FINISHED and AFTER_ET never show the bonus;
--   * 1 answer without ExtraScore: stays unknown.
-- 20260930125000 returned NULL (unknown) for most AFTER_PEN answers, which
-- kept the inflated stored final, and returned the inflated running total
-- for AFTER_PEN without FtScore (stored 3-2, truth 2-2).
--
-- Rule for AFTER_PEN (mirrors goalFixtureScore in supabase/functions/
-- _shared/live_events.ts; parity test backend/test/goal_terminal_score):
--   * FtScore and ExtraScore both complete -> base = FT + ET:
--       - base below the half-time score on either side -> unknown;
--       - running total absent, equal to base, or the 0-0 reset -> base;
--       - running total - base = (k,0) or (0,k), k in {1,2}, and the
--         penalty score is complete, not tied and won by that same side
--         -> base;
--       - anything else (excess with no / tied / opposite penalty score,
--         excess on both sides, negative excess) -> unknown;
--   * FtScore or ExtraScore missing -> unknown (never the running total).
-- FINISHED / AFTER_ET / AWARDED / not-terminal semantics are unchanged.
-- goal_fixture_score is redefined from 20260930125000; the body is verbatim
-- except the penalty fields in the single jsonb_to_record read and the
-- AFTER_PEN branches. goal_score_value and observation_score are unchanged.
-- No data is written (the repair is a separate, manual, guarded script:
-- supabase/manual/2026-10-01_after_pen_repair.sql).

create or replace function futbeat_private.goal_fixture_score(p_fixture jsonb)
returns jsonb language plpgsql immutable set search_path='' as $$
declare
  r record; v_status text;
  v_lh integer; v_la integer; v_fh integer; v_fa integer;
  v_eh integer; v_ea integer; v_hh integer; v_ha integer;
  v_ph integer; v_pa integer; v_dh integer; v_da integer;
  v_home integer; v_away integer;
begin
  if p_fixture is null or jsonb_typeof(p_fixture)<>'object' then return null; end if;
  select * into r from jsonb_to_record(p_fixture) as x(
    "matchStatus" jsonb,"homeTeamScore" jsonb,"awayTeamScore" jsonb,
    "homeTeamFtScore" jsonb,"awayTeamFtScore" jsonb,
    "homeTeamExtraScore" jsonb,"awayTeamExtraScore" jsonb,
    "homeTeamHalftimeScore" jsonb,"awayTeamHalftimeScore" jsonb,
    "homeTeamPenaltyScore" jsonb,"awayTeamPenaltyScore" jsonb);
  v_status:=upper(btrim(coalesce(case when jsonb_typeof(r."matchStatus")='string'
    then r."matchStatus"#>>'{}' end,'')));
  v_lh:=futbeat_private.goal_score_value(r."homeTeamScore");
  v_la:=futbeat_private.goal_score_value(r."awayTeamScore");
  if v_lh is null or v_la is null then v_lh:=null; v_la:=null; end if;
  -- Not over: the running total (extra time included, penalties never).
  if v_status not in ('FINISHED','AFTER_ET','AFTER_PEN','AWARDED') then
    return case when v_lh is not null then jsonb_build_object('home',v_lh,'away',v_la) end;
  end if;
  v_home:=v_lh; v_away:=v_la;
  v_fh:=futbeat_private.goal_score_value(r."homeTeamFtScore");
  v_fa:=futbeat_private.goal_score_value(r."awayTeamFtScore");
  -- After penalties the running total carries a shoot-out bonus: without
  -- the regulation score the result is unknown.
  if v_status='AFTER_PEN' and (v_fh is null or v_fa is null) then return null; end if;
  if v_fh is not null and v_fa is not null then
    v_eh:=futbeat_private.goal_score_value(r."homeTeamExtraScore");
    v_ea:=futbeat_private.goal_score_value(r."awayTeamExtraScore");
    if v_eh is null or v_ea is null then
      -- After extra time the extra-time goals are required: unknown.
      if v_status in ('AFTER_ET','AFTER_PEN') then return null; end if;
      v_eh:=0; v_ea:=0;
    end if;
    -- The running total must agree, be absent, or be the 0-0 reset...
    if v_lh is not null and not (v_lh=0 and v_la=0)
       and (v_lh<>v_fh+v_eh or v_la<>v_fa+v_ea) then
      -- ...or, after penalties, carry a +1/+2 bonus for the shoot-out
      -- winner only (complete, non-tied penalty score won by that side).
      if v_status<>'AFTER_PEN' then return null; end if;
      v_dh:=v_lh-(v_fh+v_eh); v_da:=v_la-(v_fa+v_ea);
      v_ph:=futbeat_private.goal_score_value(r."homeTeamPenaltyScore");
      v_pa:=futbeat_private.goal_score_value(r."awayTeamPenaltyScore");
      if v_ph is null or v_pa is null
         or not ((v_dh in (1,2) and v_da=0 and v_ph>v_pa)
              or (v_dh=0 and v_da in (1,2) and v_pa>v_ph)) then
        return null;
      end if;
    end if;
    v_home:=v_fh+v_eh; v_away:=v_fa+v_ea;
  end if;
  if v_home is null then return null; end if;
  -- A final below the half-time score is impossible.
  v_hh:=futbeat_private.goal_score_value(r."homeTeamHalftimeScore");
  v_ha:=futbeat_private.goal_score_value(r."awayTeamHalftimeScore");
  if v_hh is not null and v_ha is not null and (v_home<v_hh or v_away<v_ha) then
    return null;
  end if;
  return jsonb_build_object('home',v_home,'away',v_away);
end $$;

revoke all on function
  futbeat_private.goal_fixture_score(jsonb)
from public,anon,authenticated;

notify pgrst,'reload schema';
