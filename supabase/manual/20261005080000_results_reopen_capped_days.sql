-- MANUAL, ONE-OFF (not a migration; never run by `supabase db push`).
-- NOT EXECUTED. Requires explicit authorization, and only AFTER the worker
-- with the /fixtures/date fallback (commit 18a9869) and migrations
-- 20261005010000 + 20261005070000 are deployed.
--
-- Why: results days capped by GOAL at 500 rows closed their unanswered
-- matches as 'missing_from_provider' (>= 4 attempts and kickoff > 48 h ago).
-- Such a date is never a planner candidate again. Production 2026-10-05:
-- 09-26 = 834 and 09-27 = 460 missing, still inside the 14-day window.
-- Reopening lets the results lane answer them once more, now with the
-- fallback (<= 15 /fixtures/date pages per date, above 150 remaining units).
-- Nothing is marked FINAL here: the state only goes back to 'unresolved';
-- finals come from provider evidence or the matches stay "Por confirmar".

-- A. DRY RUN (read-only): dates to reopen.
select mr.provider_date, count(*) missing, a.attempt_count, a.next_retry_at
from futbeat_private.match_result_reconciliation mr
left join futbeat_private.results_date_attempts a
  on a.provider='goal_api' and a.provider_date=mr.provider_date
where mr.provider='goal_api' and mr.state='missing_from_provider'
  and mr.provider_date>=(now() at time zone 'UTC')::date-13
group by mr.provider_date,a.attempt_count,a.next_retry_at
having count(*)>=100
order by mr.provider_date desc;

-- B. REOPEN (write; one transaction; review A first). At most 3 dates per
--    run to spread quota (each may cost up to 16 units).
-- begin;
-- create table if not exists futbeat_private.results_reopen_audit(
--   provider_date date,match_id text,old_state text,reopened_at timestamptz default now());
-- with dates as (
--   select provider_date from futbeat_private.match_result_reconciliation
--   where provider='goal_api' and state='missing_from_provider'
--     and provider_date>=(now() at time zone 'UTC')::date-13
--   group by provider_date having count(*)>=100
--   order by provider_date desc limit 3
-- ), audit as (
--   insert into futbeat_private.results_reopen_audit(provider_date,match_id,old_state)
--   select mr.provider_date,mr.match_id,mr.state from futbeat_private.match_result_reconciliation mr
--   join dates d using(provider_date) where mr.state='missing_from_provider' returning 1
-- ), reopened as (
--   update futbeat_private.match_result_reconciliation mr set state='unresolved',updated_at=now()
--   from dates d where mr.provider_date=d.provider_date and mr.state='missing_from_provider'
--   returning 1
-- )
-- update futbeat_private.results_date_attempts a
--   set attempt_count=least(a.attempt_count,3),next_retry_at=now(),updated_at=now()
-- from dates d where a.provider='goal_api' and a.provider_date=d.provider_date;
-- commit;

-- C. ROLLBACK (write): put the audited rows back.
-- update futbeat_private.match_result_reconciliation mr set state=a.old_state,updated_at=now()
-- from futbeat_private.results_reopen_audit a
-- where mr.match_id=a.match_id and mr.state='unresolved';
