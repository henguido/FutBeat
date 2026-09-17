create or replace function futbeat_private.futbeat_resolve_live_competition(p_external_league_id text)
returns text language sql stable security definer set search_path='' as $$
 select case when p_external_league_id='162' then 'fb_comp_cr'
  else (select canonical_id from futbeat_private.provider_entities
   where provider='api_football' and kind='competition'
    and external_id=p_external_league_id
    and external_id in ('2','39','140','253','262')) end
$$;
create or replace function public.futbeat_resolve_live_competition(p_external_league_id text)
returns text language sql stable security definer set search_path='' as $$
 select futbeat_private.futbeat_resolve_live_competition(p_external_league_id)
$$;

create or replace function futbeat_private.futbeat_reserve_live_call(p_trigger_source text default 'cron')
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_now timestamptz:=now();
 v_day_start timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
 v_total integer; v_live integer; v_last timestamptz; v_id bigint;
 v_active integer; v_next timestamptz;
begin
 if p_trigger_source is null or btrim(p_trigger_source)='' then raise exception 'trigger_source is required'; end if;
 perform pg_advisory_xact_lock(hashtext('futbeat-provider-quota:api_football:'||v_day_start::date::text));
 select count(*)::integer,
  count(*) filter(where call_kind='live')::integer,
  max(reserved_at) filter(where call_kind='live')
 into v_total,v_live,v_last from futbeat_private.provider_call_ledger
 where provider='api_football' and reserved_at>=v_day_start and reserved_at<v_day_start+interval '1 day';

 with beta_matches as (
  select e.id,(e.payload->>'startTime')::timestamptz start_time,
   coalesce(l.status,e.payload->>'status') status
  from futbeat_private.entities e
  left join public.live_match_updates l on l.match_id=e.id
  where e.kind='match' and nullif(e.payload->>'startTime','') is not null
   and (e.payload->>'competitionId'='fb_comp_cr' or exists(
    select 1 from futbeat_private.provider_entities p where p.provider='api_football'
     and p.kind='competition' and p.external_id in ('2','39','140','253','262')
     and p.canonical_id=e.payload->>'competitionId'))
 ), eligible as (
  select * from beta_matches where status not in
   ('FINISHED_PENDING_VERIFICATION','VERIFIED','CANCELLED','ABANDONED','POSTPONED')
   and ((v_now between start_time-interval '5 minutes' and start_time+interval '135 minutes')
    or (status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') and v_now<start_time+interval '5 hours'))
 )
 select count(*)::integer into v_active from eligible;
 select min((e.payload->>'startTime')::timestamptz) into v_next
  from futbeat_private.entities e where e.kind='match'
   and (e.payload->>'startTime')::timestamptz>v_now
   and (e.payload->>'competitionId'='fb_comp_cr' or exists(
    select 1 from futbeat_private.provider_entities p where p.provider='api_football'
     and p.kind='competition' and p.external_id in ('2','39','140','253','262')
     and p.canonical_id=e.payload->>'competitionId'));

 if v_total>=95 then return jsonb_build_object('allowed',false,'reason','global_daily_limit','usedToday',v_total,'limit',95,'liveUsed',v_live); end if;
 if v_live>=75 then return jsonb_build_object('allowed',false,'reason','live_daily_limit','usedToday',v_total,'liveUsed',v_live,'liveLimit',75); end if;
 if v_active=0 then return jsonb_build_object('allowed',false,'reason','outside_beta_window','usedToday',v_total,'liveUsed',v_live,'nextBetaStart',v_next); end if;
 if v_last is not null and v_last>v_now-interval '5 minutes' then
  return jsonb_build_object('allowed',false,'reason','min_interval','usedToday',v_total,'liveUsed',v_live,
   'retryAfterSeconds',greatest(0,300-extract(epoch from (v_now-v_last))::integer));
 end if;
 insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at)
 values('api_football','live',left(p_trigger_source,40),v_now) returning id into v_id;
 return jsonb_build_object('allowed',true,'reservationId',v_id,'usedToday',v_total+1,
  'limit',95,'liveUsed',v_live+1,'liveLimit',75,'activeMatches',v_active,'nextBetaStart',v_next);
end $$;
create or replace function public.futbeat_reserve_live_call(p_trigger_source text default 'cron')
returns jsonb language sql security definer set search_path='' as $$
 select futbeat_private.futbeat_reserve_live_call(p_trigger_source)
$$;
revoke all on function futbeat_private.futbeat_resolve_live_competition(text),
 public.futbeat_resolve_live_competition(text),futbeat_private.futbeat_reserve_live_call(text),
 public.futbeat_reserve_live_call(text) from public,anon,authenticated;
grant execute on function futbeat_private.futbeat_resolve_live_competition(text),
 public.futbeat_resolve_live_competition(text),futbeat_private.futbeat_reserve_live_call(text),
 public.futbeat_reserve_live_call(text) to service_role;

do $$ declare command text; live_command text; old_id bigint; begin
 if to_regnamespace('cron') is null or to_regnamespace('net') is null or to_regnamespace('vault') is null then return; end if;
 select jobid into old_id from cron.job where jobname='futbeat-fixtures-three-day-window';
 if old_id is not null then perform cron.unschedule(old_id); end if;
 command:=$job$
 select net.http_post(url:='https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-fixtures-sync',
  headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_public_jwt'),
   'x-futbeat-scheduler',(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_scheduler_token')),
  body:='WINDOW_BODY'::jsonb,timeout_milliseconds:=60000)
 $job$;
 perform cron.schedule('futbeat-fixtures-today','7 */3 * * *',replace(command,'WINDOW_BODY','{"window":"today"}'));
 perform cron.schedule('futbeat-fixtures-tomorrow','17 */6 * * *',replace(command,'WINDOW_BODY','{"window":"tomorrow"}'));
 perform cron.schedule('futbeat-fixtures-yesterday','30 6 * * *',replace(command,'WINDOW_BODY','{"window":"yesterday"}'));
 live_command:=$live$
 select net.http_post(url:='https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-live-sync',
  headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_public_jwt'),
   'x-futbeat-scheduler',(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_scheduler_token')),
  body:='{"trigger":"cron"}'::jsonb,timeout_milliseconds:=30000)
 $live$;
 perform cron.alter_job((select jobid from cron.job where jobname='futbeat-live-sync-free-tier'),
  schedule:='*/5 * * * *',command:=live_command);
end $$;
notify pgrst,'reload schema';
