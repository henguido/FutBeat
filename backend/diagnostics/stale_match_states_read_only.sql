-- FutBeat stale/impossible match-state audit. READ ONLY and bounded.
-- Replace the UTC dates below with an explicitly approved interval of at
-- most 31 days. Run only after independently verifying the target project.

begin transaction read only;
set local statement_timeout = '8s';
set local lock_timeout = '1s';

-- Guard: one row is safe. zero rows means STOP (invalid/unbounded interval).
with params as (
  select '2026-09-01'::date from_date, '2026-10-01'::date to_date,
         'goal_api'::text provider, 500::integer max_candidates
)
select 'SAFE_BOUNDED_READ' guard, from_date, to_date, provider, max_candidates
from params
where to_date >= from_date and to_date-from_date between 0 and 30
  and provider in ('goal_api','api_football')
  and max_candidates between 1 and 1000;

-- Coverage and reconciliation summary by UTC provider date. Index-bounded.
with params as (
  select '2026-09-01'::date from_date, '2026-10-01'::date to_date,
         'goal_api'::text provider
)
select c.provider_date, c.fixture_count, c.fixtures_complete,
       c.results_complete, c.results_checked_at,
       count(mr.match_id) filter (where mr.state='resolved') resolved,
       count(mr.match_id) filter (where mr.state='unresolved') unresolved,
       count(mr.match_id) filter (where mr.state='missing_from_provider') missing,
       count(mr.match_id) filter (where mr.state='rescheduled') rescheduled
from params p
join futbeat_private.calendar_coverage c
  on c.provider=p.provider and c.provider_date between p.from_date and p.to_date
left join futbeat_private.match_result_reconciliation mr
  on mr.provider=p.provider and mr.provider_date=c.provider_date
group by c.provider_date,c.fixture_count,c.fixtures_complete,
         c.results_complete,c.results_checked_at
order by c.provider_date;

-- Candidate classification. The calendar range is the driving indexed scan;
-- every evidence lookup is restricted to those candidate match ids.
with params as (
  select '2026-09-01'::date from_date, '2026-10-01'::date to_date,
         500::integer max_candidates
), bounds as (
  select from_date::timestamp at time zone 'UTC' from_utc,
         (to_date+1)::timestamp at time zone 'UTC' to_utc,max_candidates
  from params
), candidates as materialized (
  select cm.match_id,cm.start_time,cm.source,cm.updated_at,e.payload
  from bounds b
  join futbeat_private.calendar_matches cm
    on cm.start_time>=b.from_utc and cm.start_time<b.to_utc
  join futbeat_private.entities e on e.id=cm.match_id and e.kind='match'
  order by cm.start_time,cm.match_id
  limit (select max_candidates+1 from bounds)
), evidence as (
  select c.*,
    futbeat_private.match_read_model_core(c.payload,false)->>'status' effective_status,
    latest.status latest_status,latest.provider latest_provider,
    latest.received_at latest_received_at,
    terminal.status terminal_status,terminal.provider terminal_provider,
    coalesce(terminal.provider_observed_at,terminal.received_at) terminal_at,
    live.status last_live_status,live.last_seen_at,
    mr.state reconciliation_state,
    cov.fixtures_complete,cov.results_complete,cov.results_checked_at,
    conflict.provider_count,conflict.status_count
  from candidates c
  left join lateral (
    select o.status,o.provider,o.received_at,o.provider_observed_at
    from futbeat_private.provider_observations o
    where o.canonical_match_id=c.match_id
    order by o.received_at desc,o.id desc limit 1
  ) latest on true
  left join lateral (
    select o.status,o.provider,o.received_at,o.provider_observed_at
    from futbeat_private.provider_observations o
    where o.canonical_match_id=c.match_id
      and o.status in ('VERIFIED','FINISHED_PENDING_VERIFICATION',
        'POSTPONED','CANCELLED','SUSPENDED','ABANDONED')
    order by coalesce(o.provider_observed_at,o.received_at) desc,o.id desc limit 1
  ) terminal on true
  left join lateral (
    select l.status,l.last_seen_at
    from futbeat_private.live_match_state l
    where l.canonical_match_id=c.match_id
    order by l.last_seen_at desc limit 1
  ) live on true
  left join lateral (
    select count(distinct o.provider)::integer provider_count,
           count(distinct o.status)::integer status_count
    from futbeat_private.provider_observations o
    where o.canonical_match_id=c.match_id
      and o.received_at>=c.start_time-interval '6 hours'
  ) conflict on true
  left join futbeat_private.match_result_reconciliation mr on mr.match_id=c.match_id
  left join futbeat_private.calendar_coverage cov
    on cov.provider='goal_api'
   and cov.provider_date=(c.start_time at time zone 'UTC')::date
)
select match_id,start_time,payload->>'status' canonical_status,effective_status,
       latest_provider,latest_status,latest_received_at,
       terminal_provider,terminal_status,terminal_at,
       last_live_status,last_seen_at,reconciliation_state,
       fixtures_complete,results_complete,results_checked_at,
       case
         when coalesce(payload->>'status','') in ('POSTPONED','CANCELLED','SUSPENDED','ABANDONED')
           or reconciliation_state='rescheduled'
           then 'POSTPONED_OR_RESCHEDULED'
         when effective_status='VERIFIED' and start_time>now()+interval '5 minutes'
           then 'IMPOSSIBLE_FUTURE_VERIFIED'
         when terminal_status in ('VERIFIED','FINISHED_PENDING_VERIFICATION')
           and terminal_at<start_time then 'PROVIDER_CONFLICT'
         when provider_count>1 and status_count>1
           and latest_status in ('SCHEDULED','PRE_MATCH','LIVE','HALFTIME')
           and terminal_status in ('VERIFIED','FINISHED_PENDING_VERIFICATION')
           then 'PROVIDER_CONFLICT'
         when effective_status in ('VERIFIED','FINISHED_PENDING_VERIFICATION')
           and start_time<=now()
           and (terminal_at>=start_time
             or futbeat_private.try_timestamptz(payload#>>'{provenance,receivedAt}')>=start_time)
           then 'VALID_VERIFIED'
         when effective_status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
           and last_seen_at>=greatest(start_time,now()-interval '15 minutes')
           then 'LEGITIMATE_LIVE'
         when (coalesce(payload->>'status','') in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
             or last_live_status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES'))
           and coalesce(last_seen_at,'-infinity'::timestamptz)<now()-interval '15 minutes'
           and terminal_status is null then 'STALE_LIVE'
         when effective_status in ('DISCOVERED','SCHEDULED','PRE_MATCH')
           and start_time>now()-interval '5 minutes' then 'LEGITIMATE_SCHEDULED'
         when effective_status in ('DISCOVERED','SCHEDULED','PRE_MATCH')
           and start_time<=now()-interval '6 hours'
           and terminal_status is null
           and (results_complete or reconciliation_state='missing_from_provider')
           then 'STALE_SCHEDULED'
         else 'MANUAL_REVIEW'
       end classification
from evidence
where (select count(*) from candidates)<=(select max_candidates from params)
order by start_time,match_id;

-- If this returns a row, raise max_candidates only after narrowing dates.
with params as (
  select '2026-09-01'::date from_date, '2026-10-01'::date to_date,500 max_candidates
), bounds as (
  select from_date::timestamp at time zone 'UTC' from_utc,
         (to_date+1)::timestamp at time zone 'UTC' to_utc,max_candidates from params
)
select 'TRUNCATED_NARROW_DATE_RANGE' warning,count(*) observed
from bounds b join futbeat_private.calendar_matches cm
  on cm.start_time>=b.from_utc and cm.start_time<b.to_utc
group by b.max_candidates having count(*)>b.max_candidates;

commit;
-- Metric capability only. Missing objects are UNAVAILABLE; do not install or
-- grant anything during this audit.
begin transaction read only;
set local statement_timeout='3s';
select 'pg_stat_statements' metric,
       case when to_regclass('public.pg_stat_statements') is null
         then 'UNAVAILABLE' else 'AVAILABLE' end status
union all
select 'pg_stat_io',case when to_regclass('pg_catalog.pg_stat_io') is null
  then 'UNAVAILABLE' else 'AVAILABLE' end;
commit;
