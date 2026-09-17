-- Recovery imports may be newer than the provider data they restore. Freshness
-- must reflect the source timestamp carried by the snapshot.
create or replace function public.futbeat_read_snapshot() returns jsonb
language sql stable security invoker set search_path = ''
as $$
 select snapshot||jsonb_build_object('freshness',jsonb_build_object(
  'stale',coalesce((snapshot->>'updatedAt')::timestamptz,received_at)<now()-interval '6 hours'
 )) from futbeat_private.imports order by received_at desc,job_id desc limit 1
$$;
revoke all on function public.futbeat_read_snapshot() from public,anon,authenticated;
grant execute on function public.futbeat_read_snapshot() to service_role;
notify pgrst, 'reload schema';
