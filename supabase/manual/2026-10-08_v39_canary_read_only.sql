-- v39 staging canary observability. READ ONLY: never run against production.
-- Replace the literals in each canary CTE before use. Production ref
-- izlmruqawgagwdcsjhte is intentionally rejected by the first query.

begin transaction read only;
set local statement_timeout = '5s';
set local lock_timeout = '1s';

-- Safety gate. Expected: SAFE_STAGING.
with canary as (
  select 'REPLACE_WITH_20_CHAR_STAGING_REF'::text project_ref,
         '2026-09-19'::date provider_date,
         'goal_api'::text provider,
         'GOAL API'::text source
)
select 'SAFE_STAGING' target_guard, provider_date, provider
from canary
where project_ref <> 'izlmruqawgagwdcsjhte'
  and project_ref ~ '^[a-z]{20}$';
-- ZERO rows is a hard STOP. This SQL guard supplements, not replaces, the
-- local preflight and independent dashboard/hostname verification.

-- Bounded before/after snapshot. Capture twice using the same literals.
with canary as (
  select '2026-09-19'::date provider_date, 'goal_api'::text provider, 'GOAL API'::text source
), bounds as (
  select provider_date::timestamp at time zone 'UTC' from_utc,
         (provider_date + 1)::timestamp at time zone 'UTC' to_utc, *
  from canary
)
select b.provider_date, b.provider, count(cm.match_id) indexed_matches,
       min(cm.start_time) first_kickoff, max(cm.start_time) last_kickoff,
       cc.fixture_count published_fixture_count,
       cc.fetched_at coverage_fetched_at
from bounds b
left join futbeat_private.calendar_matches cm
  on cm.source = b.source and cm.start_time >= b.from_utc and cm.start_time < b.to_utc
left join futbeat_private.calendar_coverage cc
  on cc.provider = b.provider and cc.provider_date = b.provider_date
group by b.provider_date, b.provider, cc.fixture_count, cc.fetched_at;

-- Duplicate provider mappings used by this date. Expected: zero rows.
with bounds as (
  select '2026-09-19'::date::timestamp at time zone 'UTC' from_utc,
         ('2026-09-19'::date + 1)::timestamp at time zone 'UTC' to_utc
), date_matches as materialized (
  select cm.match_id from futbeat_private.calendar_matches cm, bounds b
  where cm.source = 'GOAL API'
    and cm.start_time >= b.from_utc and cm.start_time < b.to_utc
)
select pe.external_id, count(distinct pe.canonical_id) canonical_ids
from futbeat_private.provider_entities pe
join date_matches dm on dm.match_id = pe.canonical_id
where pe.provider = 'goal_api' and pe.kind = 'match'
group by pe.external_id
having count(distinct pe.canonical_id) > 1
limit 100;

-- Missing entities/mappings and wrong UTC date. Expected: all zero.
with bounds as (
  select '2026-09-19'::date::timestamp at time zone 'UTC' from_utc,
         ('2026-09-19'::date + 1)::timestamp at time zone 'UTC' to_utc
), date_matches as materialized (
  select cm.match_id, cm.start_time
  from futbeat_private.calendar_matches cm, bounds b
  where cm.source = 'GOAL API'
    and cm.start_time >= b.from_utc and cm.start_time < b.to_utc
)
select count(*) filter (where e.id is null) missing_entities,
       count(*) filter (where pe.canonical_id is null) missing_goal_match_mappings,
       count(*) filter (
         where nullif(e.payload->>'startTime','') is not null
           and ((e.payload->>'startTime')::timestamptz < b.from_utc
                or (e.payload->>'startTime')::timestamptz >= b.to_utc)
       ) wrong_utc_date
from date_matches dm cross join bounds b
left join futbeat_private.entities e on e.id = dm.match_id
left join futbeat_private.provider_entities pe
  on pe.provider = 'goal_api' and pe.kind = 'match' and pe.canonical_id = dm.match_id;

-- During an injected partial failure this must remain absent or unchanged.
select provider, provider_date, fetched_at, fixture_count
from futbeat_private.calendar_coverage
where provider = 'goal_api' and provider_date = '2026-09-19'::date;
commit;

-- Sessions and locks, isolated so a permission failure cannot discard above.
begin transaction read only;
set local statement_timeout = '3s';
select a.pid, a.application_name, a.state, a.wait_event_type, a.wait_event,
       clock_timestamp() - a.query_start query_age,
       left(a.query, 160) query_sample, l.locktype, l.mode, l.granted,
       coalesce(c.relname, '') relation
from pg_catalog.pg_stat_activity a
left join pg_catalog.pg_locks l on l.pid = a.pid
left join pg_catalog.pg_class c on c.oid = l.relation
where a.datid = (select oid from pg_catalog.pg_database where datname = current_database())
  and (a.pid = pg_backend_pid()
       or c.relname in ('calendar_matches','calendar_coverage','entities','provider_entities'))
order by a.pid, l.granted, l.mode;
commit;

-- Capability discovery. available=false means UNAVAILABLE; do not enable an
-- extension or change grants during this canary.
begin transaction read only;
set local statement_timeout = '3s';
select 'pg_stat_statements' metric, to_regclass('public.pg_stat_statements') is not null available
union all select 'pg_stat_io', to_regclass('pg_catalog.pg_stat_io') is not null
union all select 'pg_stat_wal', to_regclass('pg_catalog.pg_stat_wal') is not null;
commit;

-- Optional privileged metrics: run each only if reported available and the
-- observer already has SELECT. Never reset statistics.
-- begin transaction read only;
-- set local statement_timeout = '3s';
-- select wal_records, wal_fpi, wal_bytes, stats_reset from pg_catalog.pg_stat_wal;
-- commit;
--
-- begin transaction read only;
-- set local statement_timeout = '3s';
-- select backend_type, object, context, reads, read_time, writes, write_time,
--        writebacks, writeback_time, extends, extend_time, hits, evictions
-- from pg_catalog.pg_stat_io
-- where backend_type in ('client backend','background worker');
-- commit;
--
-- For pg_stat_statements, filter to futbeat_store_calendar_range and
-- futbeat_finalize_calendar_date and capture calls, rows, execution time,
-- block counters and WAL before/after. Never run an unfiltered dump.
