-- Keep the hot snapshot read O(1) with respect to provider/media lookup tables.
-- Provider normalization now persists verified media on canonical entities/snapshots,
-- so dynamic media enrichment on every read is no longer part of the critical path.

create or replace function public.futbeat_read_snapshot()
returns jsonb
language sql
stable
set search_path=''
as $$
  with latest as (
    select snapshot, received_at
    from futbeat_private.imports
    order by received_at desc, job_id desc
    limit 1
  )
  select snapshot || jsonb_build_object(
    'freshness',
    jsonb_build_object(
      'stale',
      coalesce((snapshot->>'updatedAt')::timestamptz, received_at)
        < now() - interval '6 hours'
    )
  )
  from latest;
$$;

notify pgrst,'reload schema';
