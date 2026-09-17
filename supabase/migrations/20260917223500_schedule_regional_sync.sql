do $$
declare
  v_command text;
  v_job_id bigint;
begin
  if to_regnamespace('cron') is null
     or to_regnamespace('net') is null
     or to_regnamespace('vault') is null then
    return;
  end if;

  execute 'select jobid from cron.job where jobname = $1 limit 1'
    into v_job_id
    using 'futbeat-regional-sync';
  if v_job_id is not null then
    execute 'select cron.unschedule($1)' using v_job_id;
  end if;

  v_command := $job$
    select net.http_post(
      url := 'https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-regional-sync',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'Authorization','Bearer ' || (
          select decrypted_secret
          from vault.decrypted_secrets
          where name='futbeat_push_public_jwt'
        ),
        'x-futbeat-scheduler',(
          select decrypted_secret
          from vault.decrypted_secrets
          where name='futbeat_push_scheduler_token'
        )
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 60000
    )
    where exists(
      select 1 from vault.secrets where name='futbeat_push_public_jwt'
    );
  $job$;

  execute 'select cron.schedule($1, $2, $3)'
    using 'futbeat-regional-sync', '27 */12 * * *', v_command;
end $$;
