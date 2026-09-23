-- Production incident: futbeat_reserve_goal_results_date (called by the
-- results-only worker before any provider fetch) failed at stage="reserve"
-- with "UPDATE requires a WHERE clause". That error only appears through
-- PostgREST (which connects as the `authenticator` role, whose
-- session_preload_libraries loads pg_safeupdate for the whole session, even
-- after a later SET ROLE service_role) -- never in a direct psql session
-- connected as a superuser, since session_preload_libraries is resolved at
-- connection time from the CONNECTING role, not the CURRENT role. This is
-- why futbeat_private.reserve_goal_results_date appeared to work when run
-- directly, including under `SET LOCAL ROLE service_role`.
--
-- Root cause traced by reading the actual call graph:
--   reserve_goal_results_date -> reconcile_goal_results_local -> (on any
--   match payload change) `update futbeat_private.entities ... where
--   id=r.match_id` -> fires the `invalidate_compact_calendar` AFTER trigger
--   on futbeat_private.entities -> futbeat_private.invalidate_calendar_cache()
--   -> `update futbeat_private.catalog_cache_version set revision=revision+1;`
--   with NO WHERE CLAUSE AT ALL (a genuine bug, not an upsert needing
--   compat -- catalog_cache_version is a permanent one-row singleton table,
--   seeded once and never deleted, so the fix is simply to filter by its own
--   primary key). This fires whenever reconcile_goal_results_local corrects
--   a match's startTime from provider evidence (the one payload field NOT in
--   invalidate_calendar_cache's "score/status/minute/events/statistics/
--   provenance" ignore-list), which is common for any results-due date with
--   a rescheduled or corrected kickoff -- explaining why the failure was not
--   occasional but effectively guaranteed on real data.
--
-- The production hotfix `results_reservation_safeupdate_compat_v2` (not in
-- git) guessed the cause was ON CONFLICT DO UPDATE clauses in
-- reserve_goal_results_date and added harmless-but-irrelevant `WHERE true`
-- there; pg_safeupdate does not flag INSERT ... ON CONFLICT DO UPDATE (it
-- only rejects a query whose top-level commandType is UPDATE/DELETE with no
-- WHERE), which is exactly why that hotfix did not resolve the failure. This
-- migration supersedes it completely: it replaces the actually-guilty
-- function, and touches nothing the hotfix guessed at.
--
-- No change to reserve_goal_results_date, reconcile_goal_results_local, or
-- any quota/backoff/retention/local-repair/user-priority logic: those were
-- never the problem. Advisory locks and existing concurrency are untouched.

create or replace function futbeat_private.invalidate_calendar_cache()
returns trigger language plpgsql security definer set search_path='' as $$
declare o jsonb; n jsonb; d date; v_match_id text;
begin
  if TG_OP<>'INSERT' then o:=to_jsonb(old); end if;
  if TG_OP<>'DELETE' then n:=to_jsonb(new); end if;
  if o is not distinct from n then return null; end if;
  if TG_TABLE_NAME='entities' then
    if coalesce(n->>'kind',o->>'kind')='match' then
      select (start_time at time zone 'UTC')::date into d
        from futbeat_private.calendar_matches where match_id=coalesce(n->>'id',o->>'id');
      if d is not null then perform futbeat_private.bump_calendar_date(d); end if;
      -- Activity changes affect suggestions; score/minute changes do not.
      if ((o->'payload')-array['score','status','minute','events','statistics','provenance'])
        is distinct from ((n->'payload')-array['score','status','minute','events','statistics','provenance']) then
        update futbeat_private.catalog_cache_version set revision=revision+1 where singleton;
      end if;
    elsif coalesce(n->>'kind',o->>'kind') in ('team','competition') then
      update futbeat_private.catalog_cache_version set revision=revision+1 where singleton;
    end if;
  elsif TG_TABLE_NAME='competition_editorial_metadata' then
    -- Ingestion may touch updated_at without changing the editorial contract.
    if (o-'updated_at') is distinct from (n-'updated_at') then
      update futbeat_private.catalog_cache_version set revision=revision+1 where singleton;
    end if;
  elsif TG_TABLE_NAME='entity_redirects' then
    update futbeat_private.catalog_cache_version set revision=revision+1 where singleton;
  elsif TG_TABLE_NAME='calendar_coverage' then
    for d in select distinct v::date from unnest(array[o->>'provider_date',n->>'provider_date']) v
      where v is not null order by 1 loop
      perform futbeat_private.bump_calendar_date(d);
    end loop;
  elsif TG_TABLE_NAME='calendar_matches' then
    for d in select distinct (v::timestamptz at time zone 'UTC')::date
      from unnest(array[o->>'start_time',n->>'start_time']) v
      where v is not null order by 1 loop
      perform futbeat_private.bump_calendar_date(d);
    end loop;
  else
    for v_match_id in select distinct v from unnest(array[
      o->>'canonical_match_id',n->>'canonical_match_id',o->>'match_id',n->>'match_id']) v
      where v is not null order by 1 loop
      select (start_time at time zone 'UTC')::date into d
        from futbeat_private.calendar_matches c where c.match_id=v_match_id;
      if d is not null then perform futbeat_private.bump_calendar_date(d); end if;
    end loop;
  end if;
  return null;
end $$;

notify pgrst,'reload schema';
