-- Content push send-time age (PUSH OUTBOX SAFETY 68, audit 67, 2026-10-16).
--
-- futbeat_claim_notifications_v2 (20261002130000) expires match pushes after
-- matchPushMaxDelayMinutes and lineup alerts after kickoff+lineupAlertLateMinutes,
-- but content pushes (NEWS / TRANSFER: event_id null, not a GOAL_ANNULLED, not
-- a lineup:% key) had no age rule: rows held back by push_settings.mode=dry_run
-- or a paused cron would be delivered days late on go-live.
--
-- Which clock: created_at is the content's own time (enqueue_news_notification
-- writes news_articles.published_at, enqueue_transfer_notification writes
-- transfer_events.detected_at; both NOT NULL, so created_at is never null).
-- That is the age a reader cares about, and it already absorbs late ingestion
-- (news enqueue also refuses articles published >6 h ago). A provider clock
-- can however put published_at in the future, and such a row would never age
-- by created_at. enqueued_at (new, insert time; the enqueue upsert keeps it on
-- a duplicate) bounds that case: a content row is cancelled once EITHER clock
-- is older than goal_api freshness.contentPushMaxAgeHours (default 24).
--
-- Rows are cancelled at claim time, inside the claim's row lock, before any
-- transport call: state='cancelled', provider_receipt='expired'; never deleted.
-- Existing rows get enqueued_at = this migration's time, so their created_at
-- decides. The 43 real-device rows pending since 2026-10-05 are not scanned
-- while the database is dry_run; the first live claim cancels them in its own
-- transaction, before any transport call.
--
-- The function is otherwise byte-identical to 20261002130000 (match, kickoff,
-- red card, full time, substitution, lineup and goal-annulled rules unchanged;
-- backend/test/notifications_v2.test.mjs checks this). No settings, cron,
-- push_settings or Quota36 change: the knob is read with its default.
-- create or replace keeps the existing service_role-only grants.
-- Rollback: supabase/manual/20261016120000_content_push_send_age_rollback.sql

alter table futbeat_private.notification_outbox
  add column if not exists enqueued_at timestamptz not null default now();

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
  v_delay interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','matchPushMaxDelayMinutes',10)::integer);
  v_late interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','lineupAlertLateMinutes',20)::integer);
  -- CONTENT PUSH AGE (20261016120000)
  v_content_age interval:=interval '1 hour'*futbeat_private.quota_setting('goal_api','contentPushMaxAgeHours',24);
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
        'message',row.message
      )
    );
  end loop;

  return jsonb_build_object('rows',rows,'scanned',v_scanned);
end
$$;
