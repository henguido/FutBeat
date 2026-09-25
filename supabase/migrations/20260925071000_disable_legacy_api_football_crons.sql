-- Provider Hub hardening before #102 Phase 1B: permanently disable the
-- legacy API-Football schedulers.
--
-- The legacy Edge Functions futbeat-live-sync / futbeat-fixtures-sync were
-- scheduled by earlier migrations (20260916142853, 20260917070000,
-- 20260917133000, 20260917133500). Only futbeat-live-sync-free-tier was ever
-- unscheduled by a migration (20260918194000); futbeat-fixtures-today /
-- -tomorrow / -yesterday and -three-day-window never were. Production has no
-- such job today, but a migration replay or a rebuilt/old database would
-- leave them active. This migration removes them for good.
--
-- Selection (either criterion):
--   * a known legacy job name, or
--   * a command that targets /functions/v1/futbeat-live-sync or
--     /functions/v1/futbeat-fixtures-sync exactly (the function name must end
--     there, so futbeat-goal-live-sync and any other function never match).
-- GOAL jobs (futbeat-goal-live-cron, -detail-cron, -results-cron,
-- futbeat-prune-stale-live) target other functions and are never selected.
-- Idempotent: 0, 1 or many jobs; no jobid assumed. Portable: a database
-- without pg_cron (tests, local) is left untouched.

do $$
declare
  job record;
begin
  if to_regnamespace('cron') is null or to_regclass('cron.job') is null then
    return;
  end if;
  for job in execute $q$
    select jobid from cron.job
    where jobname in (
        'futbeat-live-sync-free-tier',
        'futbeat-fixtures-today',
        'futbeat-fixtures-tomorrow',
        'futbeat-fixtures-yesterday',
        'futbeat-fixtures-three-day-window')
      or command ~ '/functions/v1/futbeat-(live|fixtures)-sync([^A-Za-z0-9_-]|$)'
    order by jobid
  $q$ loop
    execute 'select cron.unschedule($1::bigint)' using job.jobid;
  end loop;
end
$$;
