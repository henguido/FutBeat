do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    execute 'create extension if not exists pg_net';
  end if;
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    execute 'create extension if not exists pg_cron';
  end if;
end $$;
