
do $$ declare job record; command text; begin
 if to_regnamespace('cron') is null then return; end if;
 for job in execute 'select jobid,command from cron.job where jobname=$1' using 'futbeat-live-sync-free-tier' loop
  command:=replace(job.command,'''x-futbeat-cron-token''','''x-futbeat-scheduler''');
  command:=replace(command,'''futbeat_live_sync_cron_token''','''futbeat_push_scheduler_token''');
  command:=replace(command,'''Content-Type'', ''application/json'',',
   '''Content-Type'', ''application/json'', ''Authorization'', ''Bearer '' || (select decrypted_secret from vault.decrypted_secrets where name = ''futbeat_push_public_jwt''),');
  perform cron.alter_job(job.jobid,command:=command);
 end loop;
end $$;
