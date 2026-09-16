do $$ begin
  if exists (select 1 from pg_publication where pubname='supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname='supabase_realtime'
         and schemaname='public'
         and tablename='live_match_updates'
     ) then
    alter publication supabase_realtime add table public.live_match_updates;
  end if;
end $$;
