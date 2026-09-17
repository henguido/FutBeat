do $$
begin
  if exists (select 1 from cron.job where jobname = 'futbeat-regional-sync') then
    perform cron.unschedule('futbeat-regional-sync');
  end if;
end $$;

select cron.schedule(
  'futbeat-regional-sync',
  '27 */12 * * *',
  $$
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
  $$
);
