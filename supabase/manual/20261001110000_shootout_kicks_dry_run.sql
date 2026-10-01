-- DRY RUN (read-only) for 20261001110000_shootout_kicks_cleanup.sql.
--
-- Active canonical GOAL rows of provider goal_api derived from a penalty
-- shoot-out kick: a live_events GOAL row whose raw provider row is of the
-- shoot-out phase (scoreInfoTime 'Penalty', see
-- futbeat_private.is_shootout_kick_row) produced the row, by its upstream
-- key (providerEventKey) or by the record_live_events id formula (the
-- historical content id, or content id + key). A row that an in-game live row
-- of the same match produces as well is ambiguous and never selected.
-- One line per match; the sum of "candidates" is the expected count the
-- cleanup asserts (set futbeat.expected_shootout_rows to it).
with lm as (
  select le.event_key, le.event_type, le.minute, le.team_external_id, le.player_external_id, le.payload,
    pe.canonical_id mid,
    coalesce(upper(le.payload#>>'{payload,scoreInfoTime}'),'') ~ '(PENALT|SHOOT)' is_kick
  from futbeat_private.live_events le
  join futbeat_private.provider_entities pe
    on pe.provider='goal_api' and pe.kind='match' and pe.external_id=le.external_match_id
  where le.provider='goal_api' and le.event_type='GOAL'
    and le.external_match_id in (select x.external_match_id from futbeat_private.live_events x
      where x.provider='goal_api' and x.event_type='GOAL'
        and coalesce(upper(x.payload#>>'{payload,scoreInfoTime}'),'') ~ '(PENALT|SHOOT)')
), ids as (
  select lm.mid, lm.is_kick, lm.event_key,
    'fb_event_'||md5(concat_ws('|',lm.mid,'goal_api',lm.event_type,lm.minute,
      coalesce(lm.payload->>'extraMinute',lm.payload#>>'{payload,time,extra}'),
      lm.team_external_id,lm.player_external_id,'')) content_id
  from lm
), produced as (
  select c.id, c.match_id, i.is_kick
  from futbeat_private.canonical_events c
  join ids i on i.mid=c.match_id
   and (c.id=i.content_id or c.id='fb_event_'||md5(i.content_id||'|'||i.event_key)
     or c.payload->>'providerEventKey'=i.event_key)
  where c.provider='goal_api' and c.event_type='GOAL' and c.retracted_at is null
    and not futbeat_private.is_synthetic_event(c.payload)
), per_row as (
  select id, match_id, bool_and(is_kick) kick_only, bool_or(is_kick) any_kick from produced group by id, match_id
)
select match_id,
  count(*) filter (where kick_only) candidates,
  count(*) filter (where any_kick and not kick_only) ambiguous_kept
from per_row
group by match_id
having count(*) filter (where kick_only)>0
order by match_id;
