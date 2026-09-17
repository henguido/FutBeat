do $$ declare live_command text; begin
 if to_regnamespace('cron') is null or to_regnamespace('net') is null or to_regnamespace('vault') is null then return; end if;
 live_command:=$live$
 select net.http_post(url:='https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-live-sync',
  headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_public_jwt'),
   'x-futbeat-scheduler',(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_scheduler_token')),
  body:='{"trigger":"cron"}'::jsonb,timeout_milliseconds:=30000)
 $live$;
 perform cron.alter_job((select jobid from cron.job where jobname='futbeat-live-sync-free-tier'),
  schedule:='*/5 * * * *',command:=live_command,active:=true);
end $$;
