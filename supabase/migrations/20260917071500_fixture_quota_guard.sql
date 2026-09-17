-- Calendar refreshes are allowed outside a LIVE window, while retaining the
-- same shared daily ledger and a strict three-hour minimum interval.
create or replace function futbeat_private.futbeat_reserve_fixture_call(
 p_trigger_source text default 'cron'
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_now timestamptz:=now();
 v_day_start timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
 v_today integer; v_last_fixture timestamptz; v_id bigint;
begin
 if p_trigger_source not in ('cron','manual') then raise exception 'Invalid trigger source'; end if;
 perform pg_advisory_xact_lock(hashtext('futbeat-provider-quota:api_football:'||v_day_start::date::text));
 select count(*)::integer into v_today from futbeat_private.provider_call_ledger
  where provider='api_football' and reserved_at>=v_day_start and reserved_at<v_day_start+interval '1 day';
 if v_today>=95 then return jsonb_build_object('allowed',false,'reason','daily_limit','usedToday',v_today,'limit',95); end if;
 select max(reserved_at) into v_last_fixture from futbeat_private.provider_call_ledger
  where provider='api_football' and call_kind='fixtures-three-day-window';
 if v_last_fixture is not null and v_last_fixture>v_now-interval '3 hours' then
  return jsonb_build_object('allowed',false,'reason','min_interval','usedToday',v_today,'limit',95,
   'retryAfterSeconds',greatest(0,10800-extract(epoch from (v_now-v_last_fixture))::integer));
 end if;
 insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at)
  values('api_football','fixtures-three-day-window',p_trigger_source,v_now) returning id into v_id;
 return jsonb_build_object('allowed',true,'reservationId',v_id,'usedToday',v_today+1,'limit',95);
end $$;

create or replace function public.futbeat_reserve_fixture_call(p_trigger_source text default 'cron')
returns jsonb language sql security definer set search_path='' as $$
 select futbeat_private.futbeat_reserve_fixture_call(p_trigger_source)
$$;
revoke all on function futbeat_private.futbeat_reserve_fixture_call(text),
 public.futbeat_reserve_fixture_call(text) from public,anon,authenticated;
grant execute on function futbeat_private.futbeat_reserve_fixture_call(text),
 public.futbeat_reserve_fixture_call(text) to service_role;
notify pgrst,'reload schema';
