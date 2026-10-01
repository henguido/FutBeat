-- DRY RUN (read-only) for 20260930140000_event_key_duplicates_cleanup.sql.
-- Counts the canonical rows the cleanup would retract. SELECT only.
--
-- Candidates: ACTIVE rich canonical rows stored as a re-keyed copy of
-- another row (payload.duplicateOf, written by record_live_events of
-- 20260930100000 when GOAL re-issued an event id). Per (match, copied row):
--   * copied row still active  -> every copy is retracted;
--   * copied row retracted     -> the oldest copy stays (it is the
--                                 occurrence now), the others are retracted.
-- visible_before / visible_after: how many events the read model shows with
-- all active rows and without the candidates; visible_same: whether the two
-- timelines carry the same events (type, minute, added time, team, players,
-- score-after, in order; the id of a collapsed occurrence may differ).
-- Expected once 20260930140000 is applied: visible_same true everywhere (the
-- cleanup never changes what users see, it only removes dead weight).
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
), timelines as (
  select p.*, m.payload m,
    (select futbeat_private.visible_match_events(
       coalesce(jsonb_agg(c.payload||jsonb_build_object('id',c.id,'type',c.event_type)),'[]'::jsonb),
       m.payload->>'homeTeamId', m.payload->>'awayTeamId', m.payload->'score')
     from futbeat_private.canonical_events c
     where c.match_id=p.match_id and c.retracted_at is null) before,
    (select futbeat_private.visible_match_events(
       coalesce(jsonb_agg(c.payload||jsonb_build_object('id',c.id,'type',c.event_type)),'[]'::jsonb),
       m.payload->>'homeTeamId', m.payload->>'awayTeamId', m.payload->'score')
     from futbeat_private.canonical_events c
     where c.match_id=p.match_id and c.retracted_at is null
       and not exists(select 1 from candidates k where k.id=c.id)) after
  from per_match p
  join futbeat_private.entities m on m.id=p.match_id and m.kind='match'
)
select t.match_id, t.candidates, t.goal_candidates, t.occurrences,
  jsonb_array_length(t.before) visible_before, jsonb_array_length(t.after) visible_after,
  (select coalesce(jsonb_agg(jsonb_build_array(x->>'type',x->>'minute',x->>'extraMinute',x->>'teamId',
       x->>'playerId',x->>'assistPlayerId',x->'score') order by o),'[]'::jsonb)
     from jsonb_array_elements(t.before) with ordinality b(x,o))
  = (select coalesce(jsonb_agg(jsonb_build_array(x->>'type',x->>'minute',x->>'extraMinute',x->>'teamId',
       x->>'playerId',x->>'assistPlayerId',x->'score') order by o),'[]'::jsonb)
     from jsonb_array_elements(t.after) with ordinality a(x,o)) visible_same
from timelines t
order by t.candidates desc, t.match_id;
