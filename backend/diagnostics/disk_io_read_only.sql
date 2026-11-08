-- Disk IO budget diagnosis — READ-ONLY, lightweight. SELECT on statistics
-- views only (no table scans of FutBeat data). Run one block at a time,
-- outside a live-match window if possible. Nothing here changes settings,
-- resets statistics or kills sessions.

-- 0. Since when are the cumulative numbers counting? (Divide by this.)
select stats_reset from pg_stat_database where datname=current_database();
select pg_postmaster_start_time();

-- 1. Statements by PHYSICAL reads and temp files (what costs disk IO,
--    not CPU). shared_blks_read and temp blocks are 8 KB pages.
select left(regexp_replace(query,'\s+',' ','g'),90) query, calls,
  round(total_exec_time/1000) total_s, round(mean_exec_time) mean_ms,
  shared_blks_read, round(shared_blks_read*8/1024.0) read_mb,
  shared_blks_written, temp_blks_read+temp_blks_written temp_blks,
  round(wal_bytes/1024/1024.0) wal_mb
from pg_stat_statements
order by shared_blks_read+temp_blks_read+temp_blks_written desc
limit 15;

-- 2. Same, by WAL produced (writes): ingestion, snapshots, counters.
select left(regexp_replace(query,'\s+',' ','g'),90) query, calls,
  round(wal_bytes/1024/1024.0) wal_mb, shared_blks_dirtied, rows
from pg_stat_statements order by wal_bytes desc limit 15;

-- 3. Tables read from disk vs cache, sequential scans and churn.
select relname, heap_blks_read, heap_blks_hit,
  round(100*heap_blks_hit::numeric/nullif(heap_blks_hit+heap_blks_read,0),1) hit_pct,
  idx_blks_read, toast_blks_read
from pg_statio_user_tables where schemaname='futbeat_private'
order by heap_blks_read+coalesce(toast_blks_read,0)+idx_blks_read desc limit 15;

select relname, seq_scan, seq_tup_read, idx_scan, n_tup_ins, n_tup_upd, n_tup_hot_upd, n_tup_del,
  n_dead_tup, last_autovacuum, last_autoanalyze, autovacuum_count
from pg_stat_user_tables where schemaname='futbeat_private'
order by seq_tup_read desc limit 15;

-- 4. Table + TOAST size of the heaviest tables (JSON payloads live in TOAST).
select c.relname, pg_size_pretty(pg_table_size(c.oid)) table_and_toast,
  pg_size_pretty(pg_indexes_size(c.oid)) indexes
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='futbeat_private' and c.relkind='r'
order by pg_table_size(c.oid) desc limit 12;

-- 5. Checkpoints / background writer / WAL (write pressure).
select * from pg_stat_bgwriter;
select * from pg_stat_wal;

-- 6. Autovacuum running right now (and how long).
select pid, now()-xact_start running_for, left(query,100) query
from pg_stat_activity where backend_type='autovacuum worker' or query ilike 'autovacuum:%';

-- 7. TEMPORAL EVIDENCE: cron jobs in the last 24 h, by hour and job.
--    job_run_details has no time index: the filter scans it once; if the
--    table is very large, add "and runid > <recent runid>" first.
select date_trunc('hour',d.start_time) hour_utc, j.jobname,
  count(*) runs, round(avg(extract(epoch from d.end_time-d.start_time))::numeric,1) avg_s,
  round(max(extract(epoch from d.end_time-d.start_time))::numeric,1) max_s,
  count(*) filter (where d.status<>'succeeded') failed
from cron.job_run_details d join cron.job j using(jobid)
where d.start_time>now()-interval '24 hours'
group by 1,2 order by 1 desc,4 desc;

-- 8. Who is connected and what they run now (separate agents' audits:
--    application_name / client_addr / usename tell them apart).
select usename, application_name, client_addr, state, now()-query_start running_for,
  left(regexp_replace(query,'\s+',' ','g'),100) query
from pg_stat_activity where datname=current_database() and pid<>pg_backend_pid()
order by query_start nulls last;

-- 9. Worker stages per hour from FutBeat's own ledger (provider calls and
--    their duration), last 24 h.
select date_trunc('hour',reserved_at) hour_utc, call_kind, count(*) calls,
  round(avg(extract(epoch from completed_at-reserved_at))::numeric,1) avg_s
from futbeat_private.provider_call_ledger
where reserved_at>now()-interval '24 hours'
group by 1,2 order by 1 desc,3 desc;
