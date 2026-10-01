-- A stored final result is replaced by a later authoritative correction.
--
-- Cause: once the canonical match payload is terminal, its score is
-- authoritative for the read model (and for every payload reader: feed,
-- Match Center, standings, profiles). The only writer able to correct a
-- stored final was reconcile_goal_results_local, which runs per results
-- date. A corrected final arriving on any other path (a LIVE / detail
-- observation after full time, or after the date was already reconciled)
-- updated live_match_state and the public realtime row but never the
-- canonical payload, and the app ignores realtime for a terminal match
-- (#120): the old final stayed.
--
-- Rule (generic; identical to the terminal branch of
-- reconcile_goal_results_local, applied when the evidence arrives):
--   * only for a canonical match whose payload is already FINISHED_PENDING_
--     VERIFICATION or VERIFIED;
--   * only from a terminal observation of the PRIMARY provider (Provider
--     Hub config; GOAL today) with a complete score, not older than the
--     canonical evidence;
--   * the observation is not older than the fixture's kickoff nor than a
--     newer terminal observation already stored;
--   * the score is replaced; the status never regresses (VERIFIED is kept,
--     FPV may become VERIFIED); provenance records the correction and the
--     final it replaced (scoreCorrectedFrom).
-- The match row is only written (and locked) when a correction applies.
-- Non-terminal observations never touch a terminal payload (#120), and
-- CANCELLED / POSTPONED / ABANDONED payloads are left alone. No provider
-- call, cron, quota or ledger change; events are reconciled by #169.

-- The provider whose terminal evidence may correct a stored final: the
-- enabled PRIMARY of the Provider Hub (goal_api today). Falls back to
-- goal_api when the hub has no primary row.
create or replace function futbeat_private.primary_result_provider()
returns text language sql stable security definer set search_path='' as $$
  select coalesce((select c.provider from futbeat_private.provider_hub_config c
    where c.role='PRIMARY' and c.enabled order by c.priority,c.provider limit 1),'goal_api')
$$;

create or replace function futbeat_private.apply_terminal_score_correction()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_payload jsonb; v_canonical_at timestamptz; v_kickoff timestamptz; v_score jsonb;
begin
  if new.canonical_match_id is null
     or new.status not in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
     or new.home_score is null or new.away_score is null then
    return new;
  end if;
  -- Only the primary provider is authoritative for a stored final. A
  -- secondary or integration-only source never rewrites it here (its
  -- reconciled finals go through futbeat_record_secondary_observation).
  if new.provider is distinct from futbeat_private.primary_result_provider() then
    return new;
  end if;
  -- Plain read (no row lock): almost every terminal observation confirms
  -- the stored final, and the results reconciliation locks match rows in
  -- its own order.
  select payload into v_payload from futbeat_private.entities
   where id=new.canonical_match_id and kind='match';
  if v_payload is null
     or coalesce(v_payload->>'status','') not in ('FINISHED_PENDING_VERIFICATION','VERIFIED') then
    return new;
  end if;
  v_score:=jsonb_build_object('home',new.home_score,'away',new.away_score);
  if v_payload->'score' is not distinct from v_score
     and (v_payload->>'status'='VERIFIED' or new.status<>'VERIFIED') then
    return new;
  end if;
  -- Evidence of this fixture only: never before its kickoff.
  v_kickoff:=futbeat_private.try_timestamptz(v_payload->>'startTime');
  if v_kickoff is null or coalesce(new.provider_observed_at,new.received_at)<v_kickoff then
    return new;
  end if;
  -- Never let an older observation rewrite newer canonical evidence. Both
  -- sides are FutBeat receive times (the provider clock is only used against
  -- the kickoff above).
  v_canonical_at:=futbeat_private.try_timestamptz(v_payload#>>'{provenance,receivedAt}');
  if v_canonical_at is not null and new.received_at<v_canonical_at then
    return new;
  end if;
  -- ...nor an observation older than a newer terminal one already stored.
  if exists(
    select 1 from futbeat_private.provider_observations o
    where o.provider=new.provider and o.canonical_match_id=new.canonical_match_id
      and o.status in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
      and o.home_score is not null and o.away_score is not null
      and (o.received_at,o.id)>(new.received_at,new.id)) then
    return new;
  end if;
  -- One guarded UPDATE. Its WHERE is re-evaluated by PostgreSQL on the row
  -- version actually written (READ COMMITTED re-check after a concurrent
  -- writer commits), so the guards hold against whatever committed last:
  --   * still terminal;
  --   * the canonical evidence on that row is not newer than this
  --     observation (monotonic: a newer concurrent correction is never
  --     overwritten by an older one; an older one is overwritten by this);
  --   * something still changes (no write, no lock, when it is a no-op).
  -- Observations of one provider fixture are already serialized by the
  -- per-fixture advisory lock of futbeat_record_live_batch.
  update futbeat_private.entities e set payload=e.payload
    ||jsonb_build_object(
      'status',case when e.payload->>'status'='VERIFIED' or new.status='VERIFIED'
        then 'VERIFIED' else 'FINISHED_PENDING_VERIFICATION' end,
      'score',v_score)
    ||jsonb_build_object('provenance',coalesce(e.payload->'provenance','{}'::jsonb)
      ||jsonb_build_object('receivedAt',new.received_at,'reconciledLocally',true,'scoreCorrected',true)
      -- Audit: the final that was replaced (only when the score changes).
      ||case when e.payload->'score' is distinct from v_score
          and e.payload->'score' is not null and e.payload->'score'<>'null'::jsonb
        then jsonb_build_object('scoreCorrectedFrom',e.payload->'score') else '{}'::jsonb end)
   where e.id=new.canonical_match_id and e.kind='match'
     and e.payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
     and coalesce(futbeat_private.try_timestamptz(e.payload#>>'{provenance,receivedAt}'),
       '-infinity'::timestamptz)<=new.received_at
     and (e.payload->'score' is distinct from v_score
       or (new.status='VERIFIED' and e.payload->>'status'<>'VERIFIED'));
  return new;
end $$;

drop trigger if exists futbeat_terminal_score_correction
  on futbeat_private.provider_observations;
create trigger futbeat_terminal_score_correction
after insert or update of canonical_match_id
on futbeat_private.provider_observations
for each row
execute function futbeat_private.apply_terminal_score_correction();

revoke all on function
  futbeat_private.apply_terminal_score_correction(),
  futbeat_private.primary_result_provider()
from public,anon,authenticated;
