-- PUSH TRANSPORT TTL HARDENING 69 (2026-10-16), on top of 20261016120000.
--
-- 1. futbeat_private.quota_setting_bounded: reads a numeric policy knob, falls
--    back to its default when the value is missing, non-numeric or NaN, and
--    clamps it. The claim reads matchPushMaxDelayMinutes [1,120],
--    lineupAlertLateMinutes [0,180] and contentPushMaxAgeHours [1,168] with it,
--    so a wrong setting can no longer make the claim raise (which stopped every
--    push, LIVE included) nor cancel all content (0 / negative hours).
-- 2. futbeat_claim_notifications_v2 returns expiresAt per claimed row, from the
--    event's own time and with the same clocks as its expiry rules: match events
--    created_at + delay, lineups kickoff + late (created_at + 6 h if the kickoff
--    is unknown), content the older of created_at / enqueued_at + content age.
--    The dispatcher cancels an expired row before the send boundary and the
--    transports send android.ttl / apns-expiration (backend/notifications).
-- Everything else in the claim is byte-identical to 20261016120000.
-- Rollback: supabase/manual/20261016130000_push_ttl_hardening_rollback.sql
--
-- Self-sufficient (review 70): the claim below reads enqueued_at, created by
-- 20261016120000 (PUSH68). Applied alone (out of order), the first claim with
-- a pending content row raised 'record "row" has no field "enqueued_at"' and
-- stopped every push. Idempotent: a no-op when PUSH68 is already applied.
alter table futbeat_private.notification_outbox
  add column if not exists enqueued_at timestamptz not null default now();

create or replace function futbeat_private.quota_setting_bounded(
  p_provider text,p_key text,p_default numeric,p_min numeric,p_max numeric)
returns numeric language plpgsql stable set search_path='' as $f$
declare v numeric;
begin
  begin
    select (freshness->>p_key)::numeric into v from futbeat_private.provider_quota_policy where provider=p_provider;
  exception when others then
    v:=null; -- a non-numeric setting never breaks the caller
  end;
  if v is null or v='NaN'::numeric then v:=p_default; end if;
  return least(greatest(v,p_min),p_max);
end $f$;
revoke all on function futbeat_private.quota_setting_bounded(text,text,numeric,numeric,numeric) from public,anon,authenticated;

create or replace function public.futbeat_claim_notifications_v2(
  p_mode text default 'dry_run',
  p_limit int default 20
) returns jsonb
language plpgsql
-- NOTIFICATIONS V2: definer (reads the policy settings and preferences);
-- still executable by service_role only.
security definer
set search_path=''
as $$
declare
  row record;
  rows jsonb:='[]';
  attempt uuid;
  still_following boolean;
  -- NOTIFICATIONS V2
  v_reason text;
  v_annul boolean;
  v_scanned integer:=0;
  v_push_mode text;
  -- PUSH TTL 69: bounded knobs; an invalid value falls back to its default and
  -- can never make the claim raise (which would also stop LIVE pushes).
  v_delay interval:=make_interval(mins=>futbeat_private.quota_setting_bounded('goal_api','matchPushMaxDelayMinutes',10,1,120)::integer);
  v_late interval:=make_interval(mins=>futbeat_private.quota_setting_bounded('goal_api','lineupAlertLateMinutes',20,0,180)::integer);
  -- CONTENT PUSH AGE (20261016120000)
  v_content_age interval:=interval '1 hour'*futbeat_private.quota_setting_bounded('goal_api','contentPushMaxAgeHours',24,1,168);
  v_expires timestamptz;
begin
  if p_mode not in ('dry_run','live') then
    raise exception 'Invalid mode';
  end if;
  select mode into v_push_mode from futbeat_private.push_settings where id=true;

  update futbeat_private.notification_outbox
  set state=case when transport_started_at is null then 'pending' else 'uncertain' end,
    finished_at=case when transport_started_at is null then null else now() end,
    attempt_id=case when transport_started_at is null then null else attempt_id end,
    attempt_token=case when transport_started_at is null then null else attempt_token end,
    attempt_at=case when transport_started_at is null then now() else attempt_at end,
    provider_receipt=case when transport_started_at is null then 'VALIDATION_RETRY' else provider_receipt end
  where state='sending'
    and attempt_at<now()-interval '5 minutes';

  for row in
    select
      o.*,
      d.transport,
      d.token,
      d.enabled,
      p.notify_kickoff,p.notify_goals,p.notify_final,p.notify_cards,p.notify_red_cards,
      p.notify_player_sub_out,p.notify_player_sub_in,p.notify_lineups,
      p.notify_player_starter,p.notify_player_bench,p.notify_goal_annulled,
      p.notify_news,p.notify_transfers,
      m.payload as match,
      e.retracted_at as event_retracted_at,
      e.retraction_reason as event_retraction_reason
    from futbeat_private.notification_outbox o
    join futbeat_private.push_devices d
      on d.id=o.device_id and d.user_id=o.user_id
    left join futbeat_private.user_preferences p on p.user_id=o.user_id
    left join futbeat_private.canonical_events e
      -- NOTIFICATIONS V2: a GOAL_ANNULLED row reads its goal.
      on e.id=coalesce(o.event_id,o.message->>'annulsEventId')
    left join futbeat_private.entities m
      on m.id=e.match_id
    where o.state='pending'
      and (o.attempt_at is null or o.attempt_at<now()-interval '1 minute')
      and (d.transport='test' or (p_mode='live' and v_push_mode='live'))
      and not exists(select 1 from futbeat_private.notification_outbox active
        where active.device_id=o.device_id and active.id<>o.id and active.state='sending'
          and o.message ? 'collapseKey'
          and active.message->>'collapseKey'=o.message->>'collapseKey')
    order by o.created_at,o.id
    for update of o,d skip locked
    limit least(greatest(p_limit,1),100)
  loop
    v_scanned:=v_scanned+1;
    -- Any subject carried by the message (#106 player alerts, news,
    -- transfers, lineups) that is still followed keeps the row.
    select exists(
      select 1
      from futbeat_private.push_follows f
      join lateral jsonb_array_elements(
        coalesce(row.message->'subjectRefs','[]'::jsonb)
      ) ref on true
      where f.user_id=row.user_id
        and f.entity_type=ref->>'type'
        and f.entity_id=ref->>'id'
    )
    into still_following;

    -- NOTIFICATIONS V2: a GOAL_ANNULLED row follows its match like the goal.
    v_annul:=row.event_id is null and row.message ? 'annulsEventId';
    if (row.event_id is not null or v_annul) and not still_following then
      select exists(
        select 1
        from futbeat_private.push_follows f
        where f.user_id=row.user_id
          and (
            f.entity_id=row.message->>'matchId'
            or (
              row.match is not null
              and f.entity_id in (
                row.match->>'homeTeamId',
                row.match->>'awayTeamId'
              )
            )
          )
      )
      into still_following;
    end if;

    -- P0-A: an event retracted before dispatch (annulled goal, deleted card,
    -- score decrease) is never sent; a correction's twin keeps its push.
    -- NOTIFICATIONS V2: one cancellation decision with its reason (receipt).
    v_reason:=case
      when not row.enabled then 'device_disabled'
      when not coalesce(still_following,false) then 'unfollowed'
      when row.message->>'type'='KICKOFF' and not coalesce(row.notify_kickoff,true) then 'preference_disabled'
      when row.message->>'type'='GOAL' and not coalesce(row.notify_goals,true) then 'preference_disabled'
      when row.message->>'type'='FULL_TIME' and not coalesce(row.notify_final,true) then 'preference_disabled'
      when row.message->>'type'='RED_CARD' and not (coalesce(row.notify_red_cards,true) and coalesce(row.notify_cards,true)) then 'preference_disabled'
      when row.message->>'type'='SUBSTITUTION' and row.message->>'playerRole'='primary'
        and not coalesce(row.notify_player_sub_out,true) then 'preference_disabled'
      when row.message->>'type'='SUBSTITUTION' and row.message->>'playerRole'='assist'
        and not coalesce(row.notify_player_sub_in,true) then 'preference_disabled'
      when row.message->>'type'='LINEUP' and not (coalesce(row.notify_lineups,true)
        and case row.message->>'playerRole' when 'starter' then coalesce(row.notify_player_starter,true)
          when 'bench' then coalesce(row.notify_player_bench,true) else false end) then 'preference_disabled'
      when row.message->>'type'='GOAL_ANNULLED' and not coalesce(row.notify_goal_annulled,true) then 'preference_disabled'
      when row.message->>'type'='NEWS' and not coalesce(row.notify_news,true) then 'preference_disabled'
      when row.message->>'type'='TRANSFER' and not coalesce(row.notify_transfers,true) then 'preference_disabled'
      when row.event_id is not null and row.event_retracted_at is not null
         and coalesce(row.event_retraction_reason,'') not in ('corrected','superseded','legacy_superseded') then 'retracted'
      -- Types no longer pushed (rows queued before this migration).
      when row.event_id is not null and not (row.message->>'type' in ('KICKOFF','GOAL','RED_CARD','FULL_TIME')
         or (row.message->>'type'='SUBSTITUTION' and row.message ? 'playerRole')) then 'type_disabled'
      when row.event_id is not null and row.message->>'type'='RED_CARD' and row.message ? 'playerRole'
         and row.message->>'playerRole'<>'primary' then 'type_disabled'
      -- An annulment whose goal came back, or whose goal push never left.
      when v_annul and row.event_retracted_at is null then 'restored'
      when v_annul and not exists(select 1 from futbeat_private.notification_outbox g
         where g.event_id=row.message->>'annulsEventId' and g.user_id=row.user_id and g.device_id=row.device_id
           and g.state in ('sent','simulated','uncertain','sending')) then 'goal_not_delivered'
      -- Send-time age: a late match push is worse than none.
      when (row.event_id is not null or v_annul) and row.created_at<now()-v_delay then 'expired'
      when row.notification_key like 'lineup:%' and now()>coalesce((
         select futbeat_private.try_timestamptz(x.payload->>'startTime') from futbeat_private.entities x
         where x.id=row.message->>'matchId' and x.kind='match'),'infinity'::timestamptz)+v_late then 'expired'
      -- CONTENT PUSH AGE: news / transfers held back (dry_run, paused cron)
      -- are cancelled rather than delivered days late.
      when row.event_id is null and not v_annul and row.notification_key not like 'lineup:%'
         and (row.created_at<now()-v_content_age or row.enqueued_at<now()-v_content_age) then 'expired'
    end;
    if v_reason is not null then
      update futbeat_private.notification_outbox
      set state='cancelled',finished_at=now(),provider_receipt=v_reason
      where id=row.id;
      continue;
    end if;

    -- PUSH TTL 69: the same clocks as the expiry rules above, from the event's
    -- own time; the transport turns it into android.ttl / apns-expiration.
    v_expires:=case
      when row.event_id is not null or v_annul then row.created_at+v_delay
      when row.notification_key like 'lineup:%' then coalesce((
        select futbeat_private.try_timestamptz(x.payload->>'startTime') from futbeat_private.entities x
        where x.id=row.message->>'matchId' and x.kind='match')+v_late,row.created_at+interval '6 hours')
      else least(row.created_at,row.enqueued_at)+v_content_age
    end;

    attempt:=gen_random_uuid();
    update futbeat_private.notification_outbox
    set state='sending',attempt_id=attempt,attempt_at=now(),
      attempt_token=row.token,transport_started_at=null
    where id=row.id;

    rows:=rows||jsonb_build_array(
      jsonb_build_object(
        'id',row.id,
        'deviceId',row.device_id,
        'attemptId',attempt,
        'retryCount',row.retry_count,
        'transport',row.transport,
        'token',row.token,
        'message',row.message,
        'expiresAt',v_expires
      )
    );
  end loop;

  return jsonb_build_object('rows',rows,'scanned',v_scanned);
end
$$;
