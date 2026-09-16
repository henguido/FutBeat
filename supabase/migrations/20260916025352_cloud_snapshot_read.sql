create index imports_received_at_idx on futbeat_private.imports (received_at desc, job_id desc);

-- Invoker rights: callers need table access too. Only the server role receives it.
create function public.futbeat_read_snapshot() returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select snapshot || jsonb_build_object('freshness', jsonb_build_object(
    'stale', received_at < now() - interval '6 hours'
  )) from futbeat_private.imports order by received_at desc, job_id desc limit 1
$$;
revoke all on function public.futbeat_read_snapshot() from public;
do $$ begin
  -- PGlite does not provide Supabase platform roles.
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on function public.futbeat_read_snapshot() from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke all on function public.futbeat_read_snapshot() from authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant usage on schema futbeat_private to service_role;
    grant select on futbeat_private.imports to service_role;
    grant execute on function public.futbeat_read_snapshot() to service_role;
  end if;
end $$;
