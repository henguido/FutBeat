-- Move GOAL LIVE polling from GitHub Actions to Supabase Cron.
-- No provider credential is stored in source. The key is provisioned once from
-- GitHub OIDC into Vault; only then is the five-minute Supabase cron activated.

do $outer$
begin
  if to_regnamespace('vault') is null
     or to_regnamespace('cron') is null
     or to_regnamespace('net') is null then
    return;
  end if;

  execute $ddl$
    create or replace function futbeat_private.futbeat_read_goal_live_secret()
    returns text language sql stable security definer set search_path=''
    as $fn$
      select decrypted_secret
      from vault.decrypted_secrets
      where name='futbeat_goal_api_key'
      order by updated_at desc nulls last,created_at desc
      limit 1
    $fn$
  $ddl$;

  execute $ddl$
    create or replace function futbeat_private.futbeat_read_goal_live_cron_token()
    returns text language sql stable security definer set search_path=''
    as $fn$
      select decrypted_secret
      from vault.decrypted_secrets
      where name='futbeat_goal_live_cron_token'
      order by updated_at desc nulls last,created_at desc
      limit 1
    $fn$
  $ddl$;

  execute $ddl$
    create or replace function futbeat_private.futbeat_activate_goal_live_cron()
    returns jsonb language plpgsql security definer set search_path=''
    as $fn$
    declare
      v_job_id bigint;
      v_command text;
    begin
      if not exists(
        select 1 from vault.decrypted_secrets
        where name='futbeat_goal_live_cron_token'
          and nullif(decrypted_secret,'') is not null
      ) then
        raise exception 'GOAL live cron token is not provisioned';
      end if;

      select jobid into v_job_id
      from cron.job where jobname='futbeat-goal-live-cron';
      if v_job_id is not null then perform cron.unschedule(v_job_id); end if;

      v_command := $cmd$
        select net.http_post(
          url := 'https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-goal-live-sync',
          headers := jsonb_build_object(
            'Content-Type','application/json',
            'x-futbeat-cron-token',(
              select decrypted_secret
              from vault.decrypted_secrets
              where name='futbeat_goal_live_cron_token'
              order by updated_at desc nulls last,created_at desc
              limit 1
            )
          ),
          body := jsonb_build_object('trigger','cron'),
          timeout_milliseconds := 55000
        );
      $cmd$;

      perform cron.schedule(
        'futbeat-goal-live-cron','*/5 * * * *',v_command
      );

      return jsonb_build_object(
        'active',true,
        'schedule','*/5 * * * *',
        'transport','supabase-cron'
      );
    end
    $fn$
  $ddl$;

  execute $ddl$
    create or replace function futbeat_private.futbeat_store_goal_live_secret(
      p_secret text
    ) returns jsonb language plpgsql security definer set search_path=''
    as $fn$
    declare
      v_value text:=btrim(coalesce(p_secret,''));
      v_key_id uuid;
      v_token_id uuid;
      v_status jsonb;
    begin
      if length(v_value)<16 or length(v_value)>1024 then
        raise exception 'Invalid GOAL API key';
      end if;

      select id into v_key_id
      from vault.secrets
      where name='futbeat_goal_api_key'
      order by updated_at desc nulls last,created_at desc
      limit 1;

      if v_key_id is null then
        perform vault.create_secret(
          v_value,'futbeat_goal_api_key',
          'GOAL API key for FutBeat LIVE Supabase cron'
        );
      else
        perform vault.update_secret(
          v_key_id,v_value,'futbeat_goal_api_key',
          'GOAL API key for FutBeat LIVE Supabase cron'
        );
      end if;

      select id into v_token_id
      from vault.secrets
      where name='futbeat_goal_live_cron_token'
      order by updated_at desc nulls last,created_at desc
      limit 1;

      if v_token_id is null then
        perform vault.create_secret(
          replace(pg_catalog.gen_random_uuid()::text,'-','')
          || replace(pg_catalog.gen_random_uuid()::text,'-',''),
          'futbeat_goal_live_cron_token',
          'Authentication token for FutBeat GOAL LIVE cron'
        );
      end if;

      v_status:=futbeat_private.futbeat_activate_goal_live_cron();
      return v_status || jsonb_build_object(
        'goalKeyStored',true,'cronTokenStored',true
      );
    end
    $fn$
  $ddl$;

  execute $ddl$
    create or replace function public.futbeat_read_goal_live_secret()
    returns text language sql stable security definer set search_path=''
    as $fn$ select futbeat_private.futbeat_read_goal_live_secret() $fn$
  $ddl$;

  execute $ddl$
    create or replace function public.futbeat_read_goal_live_cron_token()
    returns text language sql stable security definer set search_path=''
    as $fn$ select futbeat_private.futbeat_read_goal_live_cron_token() $fn$
  $ddl$;

  execute $ddl$
    create or replace function public.futbeat_store_goal_live_secret(p_secret text)
    returns jsonb language sql security definer set search_path=''
    as $fn$ select futbeat_private.futbeat_store_goal_live_secret(p_secret) $fn$
  $ddl$;

  execute $ddl$
    create or replace function public.futbeat_goal_live_transport_status()
    returns jsonb language sql stable security definer set search_path=''
    as $fn$
      select jsonb_build_object(
        'goalKeyStored',exists(
          select 1 from vault.secrets where name='futbeat_goal_api_key'
        ),
        'cronTokenStored',exists(
          select 1 from vault.secrets where name='futbeat_goal_live_cron_token'
        ),
        'cronActive',exists(
          select 1 from cron.job
          where jobname='futbeat-goal-live-cron' and active
        ),
        'schedule',(
          select schedule from cron.job
          where jobname='futbeat-goal-live-cron' limit 1
        ),
        'transport','supabase-cron'
      )
    $fn$
  $ddl$;

  execute 'revoke all on function futbeat_private.futbeat_read_goal_live_secret() from public,anon,authenticated';
  execute 'revoke all on function futbeat_private.futbeat_read_goal_live_cron_token() from public,anon,authenticated';
  execute 'revoke all on function futbeat_private.futbeat_activate_goal_live_cron() from public,anon,authenticated';
  execute 'revoke all on function futbeat_private.futbeat_store_goal_live_secret(text) from public,anon,authenticated';
  execute 'revoke all on function public.futbeat_read_goal_live_secret() from public,anon,authenticated';
  execute 'revoke all on function public.futbeat_read_goal_live_cron_token() from public,anon,authenticated';
  execute 'revoke all on function public.futbeat_store_goal_live_secret(text) from public,anon,authenticated';
  execute 'revoke all on function public.futbeat_goal_live_transport_status() from public,anon,authenticated';

  execute 'grant execute on function futbeat_private.futbeat_read_goal_live_secret() to service_role';
  execute 'grant execute on function futbeat_private.futbeat_read_goal_live_cron_token() to service_role';
  execute 'grant execute on function futbeat_private.futbeat_activate_goal_live_cron() to service_role';
  execute 'grant execute on function futbeat_private.futbeat_store_goal_live_secret(text) to service_role';
  execute 'grant execute on function public.futbeat_read_goal_live_secret() to service_role';
  execute 'grant execute on function public.futbeat_read_goal_live_cron_token() to service_role';
  execute 'grant execute on function public.futbeat_store_goal_live_secret(text) to service_role';
  execute 'grant execute on function public.futbeat_goal_live_transport_status() to service_role';
end
$outer$;

notify pgrst,'reload schema';
