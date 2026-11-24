-- Local reconstruction assertion only: no grants or production operations.
do $check$
declare n integer; ok boolean;
begin
 select count(*),bool_and(has_function_privilege('service_role',p.oid,'execute')
   and not has_function_privilege('anon',p.oid,'execute')
   and not has_function_privilege('authenticated',p.oid,'execute'))
 into n,ok from pg_proc p join pg_namespace s on s.oid=p.pronamespace
 where s.nspname='public' and p.proname in (
   'futbeat_try_worker_lease','futbeat_release_worker_lease','futbeat_read_passive_api_policy',
   'futbeat_read_qa_stored_calendar','futbeat_read_qa_stored_explore',
   'futbeat_read_qa_stored_national_teams','futbeat_read_qa_stored_search','futbeat_store_global_fixture_entities');
 if n<>8 or ok is distinct from true then raise exception 'Expected eight fail-closed service RPCs, got %',n; end if;
 select count(*),bool_and(c.relrowsecurity
   and not has_table_privilege('anon',c.oid,'select')
   and not has_table_privilege('authenticated',c.oid,'select')) into n,ok
 from pg_class c join pg_namespace s on s.oid=c.relnamespace
 where s.nspname='futbeat_private' and c.relname in ('worker_lane_leases','passive_api_policy');
 if n<>2 or ok is distinct from true then raise exception 'Private policy/lease tables are not isolated'; end if;
end $check$;
