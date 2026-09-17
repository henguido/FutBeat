-- Independent cache windows: today is refreshed most often, tomorrow less
-- often, and yesterday at most once per day. All share the 95-call reserve.
create or replace function futbeat_private.futbeat_reserve_fixture_call(
 p_trigger_source text default 'cron',p_window text default 'today'
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_now timestamptz:=now();
 v_day_start timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
 v_today integer; v_last timestamptz; v_id bigint;
 v_interval interval; v_interval_seconds integer; v_kind text;
begin
 if p_trigger_source not in ('cron','manual') or p_window not in ('yesterday','today','tomorrow')
  then raise exception 'Invalid fixture reservation'; end if;
 v_kind:='fixtures-date-'||p_window;
 v_interval:=case p_window when 'today' then interval '3 hours'
  when 'tomorrow' then interval '6 hours' else interval '24 hours' end;
 v_interval_seconds:=extract(epoch from v_interval)::integer;
 perform pg_advisory_xact_lock(hashtext('futbeat-provider-quota:api_football:'||v_day_start::date::text));
 select count(*)::integer into v_today from futbeat_private.provider_call_ledger
  where provider='api_football' and reserved_at>=v_day_start and reserved_at<v_day_start+interval '1 day';
 if v_today>=95 then return jsonb_build_object('allowed',false,'reason','daily_limit','usedToday',v_today,'limit',95); end if;
 select max(reserved_at) into v_last from futbeat_private.provider_call_ledger
  where provider='api_football' and call_kind=v_kind;
 if v_last is not null and v_last>v_now-v_interval then
  return jsonb_build_object('allowed',false,'reason','min_interval','window',p_window,
   'usedToday',v_today,'limit',95,'retryAfterSeconds',greatest(0,v_interval_seconds-extract(epoch from (v_now-v_last))::integer));
 end if;
 insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at)
  values('api_football',v_kind,p_trigger_source,v_now) returning id into v_id;
 return jsonb_build_object('allowed',true,'reservationId',v_id,'window',p_window,'usedToday',v_today+1,'limit',95);
end $$;
create or replace function public.futbeat_reserve_fixture_call(
 p_trigger_source text default 'cron',p_window text default 'today'
) returns jsonb language sql security definer set search_path='' as $$
 select futbeat_private.futbeat_reserve_fixture_call(p_trigger_source,p_window)
$$;
revoke all on function futbeat_private.futbeat_reserve_fixture_call(text,text),
 public.futbeat_reserve_fixture_call(text,text) from public,anon,authenticated;
grant execute on function futbeat_private.futbeat_reserve_fixture_call(text,text),
 public.futbeat_reserve_fixture_call(text,text) to service_role;
notify pgrst,'reload schema';
