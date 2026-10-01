-- MANUAL, ONE-OFF REPAIR (not a migration; never run by `supabase db push`).
-- AFTER_PEN finals stored with GOAL's shoot-out bonus in the score.
--
-- Background: for matchStatus AFTER_PEN, GOAL's running total
-- (homeTeamScore/awayTeamScore) adds +1/+2 to the shoot-out WINNER; the real
-- result is FtScore + ExtraScore. Migration 20260930150000 teaches
-- futbeat_private.goal_fixture_score that rule. Finals stored before it may
-- still carry the inflated running total. This script rewrites exactly
-- those, and only when the evidence is unambiguous.
--
-- A match is a candidate only when ALL hold:
--   * canonical match is terminal (FINISHED_PENDING_VERIFICATION/VERIFIED);
--   * its latest terminal GOAL observation (received_at desc, id desc) is an
--     AFTER_PEN answer whose NEW goal_fixture_score is non-null;
--   * every AFTER_PEN observation of that match with a non-null new score
--     agrees on that score;
--   * the stored score differs from it AND equals the running total of one
--     of that match's GOAL observations (i.e. it is the inflated total, not
--     an independent correction).
-- The UPDATE sets score=new and audit keys in provenance; status and
-- provenance.receivedAt are unchanged.
--
-- PROCEDURE (production, explicit operator decision only):
--   0. Migration 20260930150000 applied (both sections check it and refuse
--      otherwise).
--   1. Run section [dry-run]; review every row; note the count N.
--   2. Replace __EXPECTED_COUNT__ in section [apply] with N and run it. The
--      DO block is atomic: if the updated row count differs from N it
--      raises and nothing is written.
--   3. Re-run [dry-run]: it must return 0 rows.
--   Revert one match: payload.provenance.scoreCorrectedFrom holds the old
--   score.
-- Keep the candidate query in both sections identical.

-- [dry-run] ------------------------------------------------------------------
select futbeat_private.goal_fixture_score(
  '{"matchStatus":"AFTER_PEN","homeTeamScore":"3","awayTeamScore":"2","homeTeamFtScore":"2","awayTeamFtScore":"2","homeTeamExtraScore":"0","awayTeamExtraScore":"0","homeTeamPenaltyScore":"4","awayTeamPenaltyScore":"3"}'::jsonb
) = '{"home":2,"away":2}'::jsonb as after_pen_semantics_installed;

with latest_terminal as (
  select distinct on (o.canonical_match_id)
    o.canonical_match_id match_id,o.id obs_id,o.raw_payload
  from futbeat_private.provider_observations o
  where o.provider='goal_api' and o.canonical_match_id is not null
    and o.status in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
  order by o.canonical_match_id,o.received_at desc,o.id desc
), scored as (
  select t.match_id,t.obs_id,t.raw_payload,e.payload->'score' old_score,
    futbeat_private.goal_fixture_score(t.raw_payload) new_score
  from latest_terminal t
  join futbeat_private.entities e on e.id=t.match_id and e.kind='match'
  where jsonb_typeof(t.raw_payload)='object'
    and upper(btrim(coalesce(t.raw_payload->>'matchStatus','')))='AFTER_PEN'
    and e.payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
), candidates as (
  select s.* from scored s
  where s.new_score is not null
    and s.old_score is distinct from s.new_score
    and not exists(
      select 1 from futbeat_private.provider_observations o
      where o.provider='goal_api' and o.canonical_match_id=s.match_id
        and jsonb_typeof(o.raw_payload)='object'
        and upper(btrim(coalesce(o.raw_payload->>'matchStatus','')))='AFTER_PEN'
        and futbeat_private.goal_fixture_score(o.raw_payload) is not null
        and futbeat_private.goal_fixture_score(o.raw_payload) is distinct from s.new_score)
    and exists(
      select 1 from futbeat_private.provider_observations o
      where o.provider='goal_api' and o.canonical_match_id=s.match_id
        and jsonb_typeof(o.raw_payload)='object'
        and futbeat_private.goal_score_value(o.raw_payload->'homeTeamScore')
          =futbeat_private.safe_result_integer(s.old_score->>'home')
        and futbeat_private.goal_score_value(o.raw_payload->'awayTeamScore')
          =futbeat_private.safe_result_integer(s.old_score->>'away'))
)
select count(*) over () candidate_count,c.match_id id,c.old_score old,c.new_score new,c.obs_id observation_id,
  c.raw_payload->>'homeTeamScore'||'-'||(c.raw_payload->>'awayTeamScore') running_total,
  c.raw_payload->>'homeTeamFtScore'||'-'||(c.raw_payload->>'awayTeamFtScore') ft,
  c.raw_payload->>'homeTeamExtraScore'||'-'||(c.raw_payload->>'awayTeamExtraScore') et,
  c.raw_payload->>'homeTeamPenaltyScore'||'-'||(c.raw_payload->>'awayTeamPenaltyScore') pens
from candidates c
-- Refuse to list anything unless the new semantics are installed.
where futbeat_private.goal_fixture_score(
  '{"matchStatus":"AFTER_PEN","homeTeamScore":"3","awayTeamScore":"2","homeTeamFtScore":"2","awayTeamFtScore":"2","homeTeamExtraScore":"0","awayTeamExtraScore":"0","homeTeamPenaltyScore":"4","awayTeamPenaltyScore":"3"}'::jsonb
) = '{"home":2,"away":2}'::jsonb
order by c.match_id;

-- [apply] --------------------------------------------------------------------
do $$
declare
  v_expected integer:=__EXPECTED_COUNT__;
  v_rows integer;
begin
  if futbeat_private.goal_fixture_score(
    '{"matchStatus":"AFTER_PEN","homeTeamScore":"3","awayTeamScore":"2","homeTeamFtScore":"2","awayTeamFtScore":"2","homeTeamExtraScore":"0","awayTeamExtraScore":"0","homeTeamPenaltyScore":"4","awayTeamPenaltyScore":"3"}'::jsonb
  ) is distinct from '{"home":2,"away":2}'::jsonb then
    raise exception 'AFTER_PEN repair refused: migration 20260930150000 (goal_fixture_score) is not installed';
  end if;

  with latest_terminal as (
    select distinct on (o.canonical_match_id)
      o.canonical_match_id match_id,o.id obs_id,o.raw_payload
    from futbeat_private.provider_observations o
    where o.provider='goal_api' and o.canonical_match_id is not null
      and o.status in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
    order by o.canonical_match_id,o.received_at desc,o.id desc
  ), scored as (
    select t.match_id,t.obs_id,t.raw_payload,e.payload->'score' old_score,
      futbeat_private.goal_fixture_score(t.raw_payload) new_score
    from latest_terminal t
    join futbeat_private.entities e on e.id=t.match_id and e.kind='match'
    where jsonb_typeof(t.raw_payload)='object'
      and upper(btrim(coalesce(t.raw_payload->>'matchStatus','')))='AFTER_PEN'
      and e.payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
  ), candidates as (
    select s.* from scored s
    where s.new_score is not null
      and s.old_score is distinct from s.new_score
      and not exists(
        select 1 from futbeat_private.provider_observations o
        where o.provider='goal_api' and o.canonical_match_id=s.match_id
          and jsonb_typeof(o.raw_payload)='object'
          and upper(btrim(coalesce(o.raw_payload->>'matchStatus','')))='AFTER_PEN'
          and futbeat_private.goal_fixture_score(o.raw_payload) is not null
          and futbeat_private.goal_fixture_score(o.raw_payload) is distinct from s.new_score)
      and exists(
        select 1 from futbeat_private.provider_observations o
        where o.provider='goal_api' and o.canonical_match_id=s.match_id
          and jsonb_typeof(o.raw_payload)='object'
          and futbeat_private.goal_score_value(o.raw_payload->'homeTeamScore')
            =futbeat_private.safe_result_integer(s.old_score->>'home')
          and futbeat_private.goal_score_value(o.raw_payload->'awayTeamScore')
            =futbeat_private.safe_result_integer(s.old_score->>'away'))
  )
  update futbeat_private.entities e set payload=e.payload
    ||jsonb_build_object('score',c.new_score)
    ||jsonb_build_object('provenance',coalesce(e.payload->'provenance','{}'::jsonb)
      ||jsonb_build_object(
        'scoreCorrected',true,
        'scoreCorrectedFrom',c.old_score,
        'scoreCorrectionReason','goal_after_pen_shootout_bonus',
        'scoreCorrectionObservation',c.obs_id,
        'scoreCorrectedAt',now(),
        'scoreCorrectionEvidence',format(
          'GOAL AFTER_PEN: running total %s-%s includes shoot-out winner bonus; result = FT %s-%s + ET %s-%s (pens %s-%s)',
          c.raw_payload->>'homeTeamScore',c.raw_payload->>'awayTeamScore',
          c.raw_payload->>'homeTeamFtScore',c.raw_payload->>'awayTeamFtScore',
          c.raw_payload->>'homeTeamExtraScore',c.raw_payload->>'awayTeamExtraScore',
          c.raw_payload->>'homeTeamPenaltyScore',c.raw_payload->>'awayTeamPenaltyScore')))
  from candidates c
  -- Guards re-checked on the row actually written.
  where e.id=c.match_id and e.kind='match'
    and e.payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
    and e.payload->'score' is not distinct from c.old_score;
  get diagnostics v_rows=row_count;

  if v_rows<>v_expected then
    raise exception 'AFTER_PEN repair aborted: % rows would change, dry-run expected %; nothing written',
      v_rows,v_expected;
  end if;
  raise notice 'AFTER_PEN repair: % canonical finals corrected',v_rows;
end $$;
