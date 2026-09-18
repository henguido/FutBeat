-- SofaScore blocks Supabase Edge egress, so global discovery is scheduled
-- from GitHub-hosted runners and ingested through short-lived GitHub OIDC.
do $$
declare
  v_job_id bigint;
begin
  if to_regnamespace('cron') is null then
    return;
  end if;

  select jobid into v_job_id
  from cron.job
  where jobname = 'futbeat-global-three-day';

  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;
end
$$;
