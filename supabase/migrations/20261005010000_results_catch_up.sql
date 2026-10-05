-- Results catch-up: kickoff passed, no observation, still SCHEDULED.
--
-- Evidence (read-only production diagnostics, 2026-10-05 ~05:30 UTC):
--   * 2026-10-03 (1,089 calendar matches) failed its last two results
--     attempts at the LINK stage: futbeat_link_goal_live_matches over the
--     whole 500-1000 fixture day hit the statement timeout (57014), so
--     every result read was thrown away; 915 matches stayed unresolved.
--   * 2026-10-03 / 10-04 were reserved 5-7 times while the day was still
--     being played (user opens -> partial answers of 0-75 results). Each
--     partial attempt escalated the retry delay (2 h x attempt, up to 8 h)
--     and spent one of the four attempts before the day even ended.
--   * The results cron runs once every 2 hours, one date per run: after an
--     outage, recent dates wait behind the per-date backoff.
--   * Today's own overdue fixtures (kickoff hours ago, never seen by the
--     capped live list) were never a background candidate: the planner
--     window stopped at yesterday.
--
-- Fix (provider evidence only; never a clock-made FINAL or score):
--   1. futbeat_link_goal_results_chunk(p_fixtures, p_reported): the worker
--      links a big day in chunks, each its own short statement. p_reported
--      carries EVERY provider id of the whole answer, so the discovery
--      "ghost still reported -> alive" rule sees the same batch as before.
--      The one-argument RPC is unchanged (same body, full batch).
--   2. results_retry_delay: a day still in play (today) or yesterday retries
--      every 45 min / 1 h without escalation; the last three days cap at
--      3 h; older days keep 6 h x attempt (unchanged).
--   3. next_goal_results_candidate: also today's matches whose kickoff was
--      more than 150 min ago; never-attempted dates first, then the date
--      waiting longest since its last attempt (recent dates break ties), so
--      frequent recent retries never starve a due older date.
--      Closing as missing_from_provider still needs >= 4 attempts AND
--      kickoff > 48 h ago (unchanged), so frequent partial-day attempts
--      can never close a match early.
--   4. The results cron runs every 30 min. The quota guards are unchanged
--      (60 results units/day, 880 total, provider floor 120): catch-up is
--      faster only while quota is left.
-- Rollback: re-create the three functions from
-- 20260921194839_competition_order_historical_reconciliation.sql, drop the
-- two new functions, reschedule 'futbeat-goal-results-cron' at
-- '43 */2 * * *'. No data is rewritten by this migration.

create or replace function futbeat_private.link_and_discover_goal_live_matches_reported(
  p_fixtures jsonb,p_reported text[]
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_result jsonb; v_fixture jsonb; v_out jsonb; v_ext text; v_match text;
  v_relinked integer:=0; v_created integer:=0; v_still jsonb:='[]'::jsonb; v_unmapped jsonb;
  v_reported text[];
begin
  v_result:=futbeat_private.futbeat_link_goal_live_matches(p_fixtures);
  v_unmapped:=coalesce(v_result->'unmapped','[]'::jsonb);
  if jsonb_array_length(v_unmapped)=0 then
    return v_result||jsonb_build_object('relinked',0,'created',0);
  end if;
  -- The ids of this chunk are always part of the batch, whatever the
  -- caller sent.
  select coalesce(array_agg(distinct x),'{}') into v_reported from (
    select nullif(coalesce(value->>'apiId',value->>'id'),'') x from jsonb_array_elements(p_fixtures)
    union all select unnest(coalesce(p_reported,'{}'::text[]))) ids where x is not null;
  -- Ascending provider id: identity locks are always taken in the same
  -- order as the catalogue resolver takes them (no lock-order deadlock).
  for v_fixture in select value from jsonb_array_elements(p_fixtures)
      order by nullif(coalesce(value->>'apiId',value->>'id'),'') loop
    v_ext:=nullif(coalesce(v_fixture->>'apiId',v_fixture->>'id'),'');
    if v_ext is null or not exists(select 1 from jsonb_array_elements(v_unmapped) u
        where u->>'externalMatchId'=v_ext) then
      continue;
    end if;
    v_out:=futbeat_private.discover_goal_live_match(v_fixture,v_reported);
    if v_out->>'outcome' in ('relinked','created','already_linked') then
      v_match:=v_out->>'matchId';
      if v_out->>'outcome'='relinked' then v_relinked:=v_relinked+1;
      elsif v_out->>'outcome'='created' then v_created:=v_created+1; end if;
      -- Evidence stored while the fixture was unmapped now belongs to it.
      update futbeat_private.live_match_state set canonical_match_id=v_match
       where provider='goal_api' and external_match_id=v_ext and canonical_match_id is null;
      update futbeat_private.provider_observations set canonical_match_id=v_match
       where provider='goal_api' and external_match_id=v_ext and canonical_match_id is null;
      update futbeat_private.live_events set canonical_match_id=v_match
       where provider='goal_api' and external_match_id=v_ext and canonical_match_id is null;
      if exists(select 1 from futbeat_private.live_match_state
          where provider='goal_api' and external_match_id=v_ext and canonical_match_id=v_match) then
        perform public.futbeat_publish_live_state('goal_api',v_ext);
      end if;
    else
      v_still:=v_still||(select jsonb_agg(u||jsonb_build_object('discovery',v_out->>'reason'))
        from jsonb_array_elements(v_unmapped) u where u->>'externalMatchId'=v_ext);
    end if;
  end loop;
  return v_result||jsonb_build_object(
    'linked',coalesce((v_result->>'linked')::integer,0)+v_relinked+v_created,
    'relinked',v_relinked,'created',v_created,
    'unmappedCount',jsonb_array_length(v_still),'unmapped',v_still);
end $$;

create or replace function public.futbeat_link_goal_results_chunk(p_fixtures jsonb,p_reported text[])
returns jsonb language sql security definer set search_path='' as $$
  select futbeat_private.link_and_discover_goal_live_matches_reported(p_fixtures,p_reported)
$$;

revoke all on function futbeat_private.link_and_discover_goal_live_matches_reported(jsonb,text[]),
  public.futbeat_link_goal_results_chunk(jsonb,text[]) from public,anon,authenticated;
grant execute on function public.futbeat_link_goal_results_chunk(jsonb,text[]) to service_role;

create or replace function futbeat_private.results_retry_delay(p_date date,p_attempt integer)
returns interval language sql stable security invoker set search_path='' as $$
  select case
    when p_date>=(now() at time zone 'UTC')::date then interval '45 minutes'
    when p_date>=(now() at time zone 'UTC')::date-1 then interval '1 hour'
    when p_date>=(now() at time zone 'UTC')::date-2
      then interval '1 hour'*least(greatest(p_attempt,1),3)
    else interval '6 hours'*least(greatest(p_attempt,1),4) end
$$;

create or replace function futbeat_private.next_goal_results_candidate()
returns date language sql stable security invoker set search_path='' as $$
 with candidates as (
   select distinct (cm.start_time at time zone 'UTC')::date provider_date
   from futbeat_private.calendar_matches cm
   join futbeat_private.entities e on e.id=cm.match_id and e.kind='match'
   left join futbeat_private.match_result_reconciliation mr on mr.match_id=cm.match_id
   where cm.start_time>=((now() at time zone 'UTC')::date-14)::timestamp at time zone 'UTC'
     -- Up to today, but only fixtures whose kickoff is 150 min gone: a
     -- match still being played is the live lane's job.
     and cm.start_time<least(
       ((now() at time zone 'UTC')::date+1)::timestamp at time zone 'UTC',
       now()-interval '150 minutes')
     and (cm.start_time<((now() at time zone 'UTC')::date)::timestamp at time zone 'UTC'
       or coalesce(e.payload->>'status','') in ('DISCOVERED','SCHEDULED','PRE_MATCH',
         'LIVE','HALFTIME','EXTRA_TIME','PENALTIES'))
     and (mr.match_id is null or mr.state='unresolved'
       or mr.canonical_payload_hash is distinct from md5(e.payload::text)
       or mr.provider_date<>(cm.start_time at time zone 'UTC')::date
       or exists(select 1 from futbeat_private.provider_observations o
         where o.provider='goal_api' and o.canonical_match_id=cm.match_id
           and o.received_at>coalesce(mr.evidence_at,'-infinity'::timestamptz))
       or exists(select 1 from futbeat_private.canonical_events ce
         where ce.match_id=cm.match_id and not coalesce(e.payload->'events','[]'::jsonb)
           @> jsonb_build_array(ce.payload)))
 )
 select c.provider_date from candidates c
 left join futbeat_private.results_date_attempts a
   on a.provider='goal_api' and a.provider_date=c.provider_date
 where a.next_retry_at is null or a.next_retry_at<=now()
 -- Never-attempted dates first (after an outage), then the date waiting
 -- longest since its last attempt (round robin: today/yesterday, due every
 -- 45-60 min, cannot starve a due older date); the last three days break
 -- ties, then fewest attempts.
 order by (a.last_attempt_at is not null),
   coalesce(a.last_attempt_at,'epoch'::timestamptz),
   (c.provider_date<(now() at time zone 'UTC')::date-2),
   coalesce(a.attempt_count,0),
   c.provider_date desc limit 1
$$;

revoke all on function futbeat_private.results_retry_delay(date,integer),
  futbeat_private.next_goal_results_candidate() from public,anon,authenticated;

do $outer$ declare v_job bigint; v_command text; begin
  if to_regnamespace('cron') is null then return; end if;
  select jobid,command into v_job,v_command from cron.job where jobname='futbeat-goal-results-cron';
  if v_job is null then return; end if;
  perform cron.alter_job(v_job,schedule:='13,43 * * * *');
end $outer$;

notify pgrst,'reload schema';
