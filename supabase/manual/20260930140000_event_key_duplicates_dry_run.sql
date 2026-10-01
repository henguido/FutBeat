-- DRY RUN (read-only) for 20260930140000_event_key_duplicates_cleanup.sql.
-- Counts the canonical rows the cleanup would retract. SELECT only.
--
-- Candidates: ACTIVE rich canonical rows stored as a re-keyed copy of
-- another row (payload.duplicateOf, written by record_live_events of
-- 20260930100000 when GOAL re-issued an event id). Per (match, copied row):
--   * copied row still active  -> every copy is retracted;
--   * copied row retracted     -> the oldest copy stays (it is the
--                                 occurrence now), the others are retracted.
-- visible_before / visible_after: what the read model shows with all active
-- rows and without the candidates (equal once 20260930140000 is applied:
-- the cleanup never changes what users see, only removes the dead weight).
with copies as (
  select c.id, c.match_id, c.event_type, c.first_seen_at, c.payload->>'duplicateOf' root,
    exists(select 1 from futbeat_private.canonical_events r
      where r.id=c.payload->>'duplicateOf' and r.retracted_at is null) root_active
  from futbeat_private.canonical_events c
  where c.retracted_at is null
    and nullif(c.payload->>'duplicateOf','') is not null
    and not futbeat_private.is_phase_event(c.event_type)
    and not futbeat_private.is_synthetic_event(c.payload)
), ranked as (
  select *, row_number() over(partition by match_id, root order by first_seen_at, id) rn from copies
), candidates as (
  select * from ranked where root_active or rn > 1
), per_match as (
  select k.match_id, count(*) candidates, count(*) filter (where k.event_type='GOAL') goal_candidates,
    count(distinct k.root) occurrences
  from candidates k group by k.match_id
)
select p.match_id, p.candidates, p.goal_candidates, p.occurrences,
  (select jsonb_array_length(futbeat_private.visible_match_events(
     coalesce(jsonb_agg(c.payload||jsonb_build_object('id',c.id,'type',c.event_type)),'[]'::jsonb),
     m.payload->>'homeTeamId', m.payload->>'awayTeamId', m.payload->'score'))
   from futbeat_private.canonical_events c
   where c.match_id=p.match_id and c.retracted_at is null) visible_before,
  (select jsonb_array_length(futbeat_private.visible_match_events(
     coalesce(jsonb_agg(c.payload||jsonb_build_object('id',c.id,'type',c.event_type)),'[]'::jsonb),
     m.payload->>'homeTeamId', m.payload->>'awayTeamId', m.payload->'score'))
   from futbeat_private.canonical_events c
   where c.match_id=p.match_id and c.retracted_at is null
     and not exists(select 1 from candidates k where k.id=c.id)) visible_after
from per_match p
join futbeat_private.entities m on m.id=p.match_id and m.kind='match'
order by p.candidates desc, p.match_id;
