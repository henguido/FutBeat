-- ARCH-155: bounded calendar stores (57014 under the 8 s authenticator timeout).
--
-- futbeat-global-ingest v43 stores the calendar one UTC date per call; a full date
-- (~1,000 GOAL fixtures on match days) still runs every competition/team/match upsert, its
-- row triggers and the coverage delete in ONE statement sequence. Production failed once at
-- 12.7 s in futbeat_store_calendar_range (PRO 150 ledger). Same remedy as the hot window
-- (PRO 152, 20261029150000): the Edge writes the entities first in chunks of <= 300
-- fixtures through futbeat_store_calendar_entities, then the date store finds them stored
-- and only compares, deletes stale GOAL rows of the covered date and records coverage.
--
-- futbeat_store_calendar_entities runs exactly the three upserts of the date store (insert
-- of new rows included: an expansion of unseen dates is mostly inserts; same compares and
-- merge). In an upsert EXCLUDED already carries the BEFORE trigger's relevance keys, so
-- unchanged competitions are not rewritten (unlike the UPDATE ... FROM of the hot window).
-- The date store (production md5 37e00ed2a44cb82b5db1afcc468945e6) is not modified.
-- Rollback: drop both functions (ARCH-155 kit rollback_c1.sql); the v43 Edge never calls them.

create or replace function futbeat_private.futbeat_store_calendar_entities(p_provider text, p_snapshot jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_competitions integer; v_teams integer; v_matches integer;
begin
  if p_provider <> 'goal_api'
     or p_snapshot->>'demo' <> 'false'
     or p_snapshot->>'schemaVersion' <> '1'
     or jsonb_typeof(p_snapshot->'competitions') <> 'array'
     or jsonb_typeof(p_snapshot->'teams') <> 'array'
     or jsonb_typeof(p_snapshot->'matches') <> 'array'
     or jsonb_array_length(p_snapshot->'matches') > 500
  then
    raise exception 'Invalid calendar entity batch';
  end if;
  if exists(select 1 from jsonb_array_elements(p_snapshot->'matches') m
    where m->'provenance'->>'source' is distinct from 'GOAL API') then
    raise exception 'Unexpected calendar fixture source';
  end if;

  insert into futbeat_private.entities as e(id,kind,payload)
  select item->>'id','competition',item from jsonb_array_elements(p_snapshot->'competitions') x(item)
  on conflict(id) do update set payload=excluded.payload
    where e.kind='competition' and e.payload is distinct from excluded.payload;
  get diagnostics v_competitions=row_count;

  insert into futbeat_private.entities as e(id,kind,payload)
  select item->>'id','team',item from jsonb_array_elements(p_snapshot->'teams') x(item)
  on conflict(id) do update set payload=excluded.payload
    where e.kind='team' and e.payload is distinct from excluded.payload;
  get diagnostics v_teams=row_count;

  -- Never degrade stored terminal evidence of the same fixture (same merge as the date store).
  insert into futbeat_private.entities as e(id,kind,payload)
  select item->>'id','match',item from jsonb_array_elements(p_snapshot->'matches') x(item)
  on conflict(id) do update
    set payload=futbeat_private.merge_calendar_match_payload(e.payload,excluded.payload)
    where e.kind='match'
      and e.payload is distinct from
        futbeat_private.merge_calendar_match_payload(e.payload,excluded.payload);
  get diagnostics v_matches=row_count;

  return jsonb_build_object('competitions',v_competitions,'teams',v_teams,'matches',v_matches);
end $$;

create or replace function public.futbeat_store_calendar_entities(p_provider text, p_snapshot jsonb)
returns jsonb language sql security definer set search_path='' as $$
  select futbeat_private.futbeat_store_calendar_entities(p_provider,p_snapshot)
$$;

revoke all on function futbeat_private.futbeat_store_calendar_entities(text,jsonb) from public;
revoke all on function public.futbeat_store_calendar_entities(text,jsonb) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname='anon') then
    revoke all on function public.futbeat_store_calendar_entities(text,jsonb) from anon;
  end if;
  if exists (select 1 from pg_roles where rolname='authenticated') then
    revoke all on function public.futbeat_store_calendar_entities(text,jsonb) from authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname='service_role') then
    grant execute on function public.futbeat_store_calendar_entities(text,jsonb) to service_role;
  end if;
end $$;

notify pgrst,'reload schema';
