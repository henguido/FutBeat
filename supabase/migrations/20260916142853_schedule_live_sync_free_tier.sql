do $$
declare
  v_has_secret boolean := false;
  v_command text;
begin
  if to_regnamespace('cron') is null
     or to_regnamespace('net') is null
     or to_regnamespace('vault') is null then
    return;
  end if;

  execute 'select exists (select 1 from vault.secrets where name = $1)'
    into v_has_secret
    using 'futbeat_live_sync_cron_token';
  if not v_has_secret then
    return;
  end if;

  v_command := $job$
    select net.http_post(
      url := 'https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-live-sync',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-futbeat-cron-token', (
          select decrypted_secret
          from vault.decrypted_secrets
          where name = 'futbeat_live_sync_cron_token'
        )
      ),
      body := jsonb_build_object('trigger', 'cron'),
      timeout_milliseconds := 10000
    ) as request_id
    where exists (
      select 1
      from futbeat_private.entities
      where kind = 'match'
        and payload ->> 'competitionId' = 'fb_comp_cr'
        and nullif(payload ->> 'startTime', '') is not null
        and now() between nullif(payload ->> 'startTime', '')::timestamptz - interval '2 minutes'
                      and nullif(payload ->> 'startTime', '')::timestamptz + interval '3 hours'
        and coalesce(payload ->> 'status', '') not in ('VERIFIED','CANCELLED','ABANDONED','POSTPONED')
    );
  $job$;

  execute 'select cron.schedule($1, $2, $3)'
    using 'futbeat-live-sync-free-tier', '*/2 * * * *', v_command;
end $$;
