-- SofaScore blocks Supabase Edge egress with HTTP 403. Collection now runs
-- in GitHub Actions and sends signed batches to futbeat-global-ingest.
do $$
declare
  v_jobid bigint;
begin
  if to_regnamespace('cron') is null then
    return;
  end if;

  select jobid
    into v_jobid
    from cron.job
   where jobname = 'futbeat-global-fixtures'
   limit 1;

  if v_jobid is not null then
    perform cron.unschedule(v_jobid);
  end if;
end
$$;
