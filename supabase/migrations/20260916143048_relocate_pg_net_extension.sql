do $$
begin
  if exists (
    select 1
    from pg_extension e
    join pg_namespace n on n.oid = e.extnamespace
    where e.extname = 'pg_net' and n.nspname = 'public'
  ) and exists (select 1 from pg_namespace where nspname = 'extensions') then
    execute 'drop extension pg_net';
    execute 'create extension pg_net with schema extensions';
  end if;
end $$;
