-- Calendar ingest silently skipped every run (stale SCHEDULED root cause).
--
-- Evidence (read-only production + GitHub Actions logs, 2026-10-05):
--   * The "FutBeat global fixtures" workflow runs every 3 h and fetches
--     /fixtures/date/{d} for yesterday/today/tomorrow (Costa Rica) with
--     working offset pagination (2,102 fixtures, ~22 GOAL requests), plus
--     calendar expansion pages. It then POSTs them to futbeat-global-ingest.
--   * The ingest reserves through public.futbeat_reserve_provider_call with
--     p_daily_limit 24 (hot) / 64 (calendar), and that function counts EVERY
--     goal_api ledger row of the UTC day. The detail lane alone makes
--     ~700/day (~190/h right after 00:00 UTC), so the reservation answers
--     {allowed:false, reason:'daily_limit'} and the ingest returns
--     'skipped' ("GLOBAL_INGEST_OK accepted=" with an empty count in the
--     logs). The ledger (kept since 2026-09-27) holds ZERO global-ingest /
--     calendar-ingest rows; calendar_coverage was last written 2026-09-19.
--   * So the fixtures the workflow already paid for (FINISHED statuses and
--     scores of yesterday/today, beyond GOAL's 500-row /results cap) never
--     reach the database, and the workflow keeps spending GOAL requests.
--
-- Fix: for goal_api the legacy daily limit counts only rows of the SAME
-- call_kind (the central quota manager governs GOAL by kind). Other
-- providers (thesportsdb, sofascore, api_football) keep the per-provider
-- count unchanged. Body otherwise identical to production.
-- Operational note: resuming the ingest writes up to ~2,100 fixtures per
-- hot run (as before 2026-09-19); watch PostgREST/DB load after applying.
-- Rollback: re-create the function without the call_kind predicate.

create or replace function public.futbeat_reserve_provider_call(p_provider text, p_call_kind text DEFAULT 'live'::text, p_trigger_source text DEFAULT 'manual'::text, p_daily_limit integer DEFAULT 95, p_min_interval_seconds integer DEFAULT 120, p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_now timestamptz := now();
  v_day_start timestamptz := date_trunc('day', now() at time zone 'UTC') at time zone 'UTC';
  v_today integer;
  v_last_reserved timestamptz;
  v_next_start timestamptz;
  v_active_window boolean := false;
  v_id bigint;
begin
  if p_provider is null or btrim(p_provider) = '' then raise exception 'provider is required'; end if;
  if p_call_kind is null or btrim(p_call_kind) = '' then raise exception 'call_kind is required'; end if;
  if p_trigger_source is null or btrim(p_trigger_source) = '' then raise exception 'trigger_source is required'; end if;
  if p_daily_limit < 1 or p_daily_limit > 100 then raise exception 'daily_limit must be between 1 and 100'; end if;
  if p_min_interval_seconds < 0 then raise exception 'min_interval_seconds must be >= 0'; end if;

  perform pg_advisory_xact_lock(hashtext('futbeat-provider-quota:' || p_provider || ':' || v_day_start::date::text));

  select count(*)::integer, max(reserved_at)
    into v_today, v_last_reserved
    from futbeat_private.provider_call_ledger
   where provider = p_provider
     and reserved_at >= v_day_start
     and reserved_at < v_day_start + interval '1 day'
     -- GOAL calls are governed per kind by the central quota manager; this
     -- legacy limit only bounds the same kind (else ~700 match-detail calls
     -- a day exhausted the calendar ingest's 24/64 before it ever ran).
     and (p_provider <> 'goal_api' or call_kind = p_call_kind);

  select min(nullif(payload ->> 'startTime', '')::timestamptz)
    into v_next_start
    from futbeat_private.entities
   where kind = 'match'
     and payload ->> 'competitionId' = 'fb_comp_cr'
     and nullif(payload ->> 'startTime', '') is not null
     and nullif(payload ->> 'startTime', '')::timestamptz >= v_now - interval '3 hours'
     and coalesce(payload ->> 'status', '') not in ('VERIFIED','CANCELLED','ABANDONED','POSTPONED');

  select exists (
    select 1
      from futbeat_private.entities
     where kind = 'match'
       and payload ->> 'competitionId' = 'fb_comp_cr'
       and nullif(payload ->> 'startTime', '') is not null
       and v_now between nullif(payload ->> 'startTime', '')::timestamptz - interval '2 minutes'
                     and nullif(payload ->> 'startTime', '')::timestamptz + interval '3 hours'
       and coalesce(payload ->> 'status', '') not in ('VERIFIED','CANCELLED','ABANDONED','POSTPONED')
  ) into v_active_window;

  if v_today >= p_daily_limit then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'daily_limit',
      'usedToday', v_today,
      'limit', p_daily_limit,
      'nextTrackedStart', v_next_start
    );
  end if;

  if not p_force and not v_active_window then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'outside_tracked_window',
      'usedToday', v_today,
      'limit', p_daily_limit,
      'nextTrackedStart', v_next_start
    );
  end if;

  if not p_force and v_last_reserved is not null
     and v_last_reserved > v_now - make_interval(secs => p_min_interval_seconds) then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'min_interval',
      'usedToday', v_today,
      'limit', p_daily_limit,
      'retryAfterSeconds', greatest(0, p_min_interval_seconds - extract(epoch from (v_now - v_last_reserved))::integer),
      'nextTrackedStart', v_next_start
    );
  end if;

  insert into futbeat_private.provider_call_ledger(provider, call_kind, trigger_source, reserved_at)
  values (p_provider, p_call_kind, p_trigger_source, v_now)
  returning id into v_id;

  return jsonb_build_object(
    'allowed', true,
    'reservationId', v_id,
    'usedToday', v_today + 1,
    'limit', p_daily_limit,
    'activeTrackedWindow', v_active_window,
    'nextTrackedStart', v_next_start
  );
end;
$function$;
