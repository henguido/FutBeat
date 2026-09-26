-- #132: terminal recovery must never race through the user_high/LIVE reserve.
--
-- The worker-side quota read introduced by PR #133 was only an optimization:
-- two overlapping workers could both observe the same providerRemaining before
-- either reserved. Make the protected floor authoritative inside the same
-- provider quota lock as the ledger reservation, and conservatively subtract
-- still-open provider reservations from the latest provider-reported remaining.
--
-- This is intentionally stricter only for terminal recovery (background repair).
-- LIVE and explicit user demand keep their existing central quota classes.

create or replace function futbeat_private.reserve_terminal_recovery_call(p_trigger_source text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  r futbeat_private.live_terminal_recovery;
  v_decision jsonb;
  v_reservation bigint;
  v_provider_remaining integer;
  v_effective_remaining integer;
  v_committed_units integer:=0;
  v_protected_floor integer;
begin
  if p_trigger_source is null or btrim(p_trigger_source)='' then
    raise exception 'trigger_source is required';
  end if;

  -- One transaction at a time may decide/reserve GOAL capacity for this UTC
  -- day. The protected-floor decision below and the ledger insert are therefore
  -- serialized with every other GOAL reservation.
  perform futbeat_private.lock_provider_quota('goal_api');
  perform futbeat_private.settle_terminal_recovery();

  select (p.class_floors->>'user_high')::integer
    into v_protected_floor
  from futbeat_private.provider_quota_policy p
  where p.provider='goal_api';

  -- Missing policy/remaining is not permission for background cleanup.
  if v_protected_floor is null then
    return jsonb_build_object(
      'allowed',false,
      'reason','protected_floor_unknown',
      'quotaClass','recovery'
    );
  end if;

  v_provider_remaining:=futbeat_private.provider_remaining('goal_api');
  if v_provider_remaining is null then
    return jsonb_build_object(
      'allowed',false,
      'reason','provider_remaining_unknown',
      'providerRemaining',null,
      'effectiveProviderRemaining',null,
      'committedUnits',0,
      'floor',v_protected_floor,
      'quotaClass','recovery'
    );
  end if;

  -- providerRemaining comes from the latest completed provider response.
  -- Reservations that have not completed yet may still consume provider units
  -- after that observation. Count them conservatively so concurrent workers
  -- cannot all spend the same last unit above user_high.
  select coalesce(sum(futbeat_private.provider_call_units(l.metadata)),0)::integer
    into v_committed_units
  from futbeat_private.provider_call_ledger l
  where l.provider='goal_api'
    and l.completed_at is null
    and l.reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';

  v_effective_remaining:=greatest(0,v_provider_remaining-v_committed_units);
  if v_effective_remaining<=v_protected_floor then
    return jsonb_build_object(
      'allowed',false,
      'reason','provider_remaining_reserve',
      'providerRemaining',v_provider_remaining,
      'effectiveProviderRemaining',v_effective_remaining,
      'committedUnits',v_committed_units,
      'floor',v_protected_floor,
      'quotaClass','recovery'
    );
  end if;

  select t.* into r
  from futbeat_private.live_terminal_recovery t
  join futbeat_private.provider_entities pe
    on pe.provider='goal_api' and pe.kind='match'
    and pe.external_id=t.external_match_id
    and pe.canonical_id=t.canonical_match_id
  where t.provider='goal_api'
    and t.state='PENDING'
    and t.next_attempt_at<=now()
    and not futbeat_private.detail_inflight(t.canonical_match_id)
  order by t.next_attempt_at,t.external_match_id
  limit 1
  for update of t skip locked;

  if not found then
    return jsonb_build_object('allowed',false,'reason','no_recovery_due');
  end if;

  -- Keep the central match-detail safety cap and lower results floor as a
  -- second line of defense. The stricter user_high guard above is recovery-
  -- specific and already ran under the same provider lock.
  v_decision:=futbeat_private.quota_decision('goal_api','match-detail','results');
  if not (v_decision->>'allowed')::boolean then
    return v_decision||jsonb_build_object(
      'allowed',false,
      'matchId',r.canonical_match_id,
      'quotaClass','recovery'
    );
  end if;

  perform pg_advisory_xact_lock(
    hashtext('futbeat-match-detail-inflight'),
    hashtext(r.canonical_match_id)
  );
  if futbeat_private.detail_inflight(r.canonical_match_id) then
    return jsonb_build_object(
      'allowed',false,
      'reason','detail_inflight',
      'matchId',r.canonical_match_id
    );
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at,metadata
  )
  values(
    'goal_api',
    'match-detail',
    left(p_trigger_source,40),
    now(),
    jsonb_build_object(
      'matchId',r.canonical_match_id,
      'externalMatchId',r.external_match_id,
      'status',r.last_live_status,
      'quotaClass','results',
      'bucket','recovery',
      'source','recovery',
      'recoveryReason',r.reason,
      'attempt',r.attempts+1,
      'providerRequests',1
    )
  )
  returning id into v_reservation;

  update futbeat_private.live_terminal_recovery t
  set attempts=t.attempts+1,
      last_attempt_at=now(),
      next_attempt_at=now()+futbeat_private.recovery_backoff(t.attempts+1)
  where t.provider=r.provider
    and t.external_match_id=r.external_match_id;

  return jsonb_build_object(
    'allowed',true,
    'reservationId',v_reservation,
    'matchId',r.canonical_match_id,
    'externalMatchId',r.external_match_id,
    'reason',r.reason,
    'attempt',r.attempts+1,
    'quotaClass','results',
    'bucket','recovery',
    'providerRemaining',v_provider_remaining,
    'effectiveProviderRemaining',v_effective_remaining,
    'committedUnits',v_committed_units,
    'protectedFloor',v_protected_floor
  );
end $$;

notify pgrst,'reload schema';
