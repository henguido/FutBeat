-- Rollback of 20261105100000_public_api_access.sql (manual, NOT a
-- migration). Restores every demand entry point exactly as before (the
-- originals were only renamed and moved) and drops the admission objects.
-- Deploy a futbeat-api that does not call futbeat_api_admit FIRST.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';
do $$
declare f record;
begin
  for f in select * from (values
    ('futbeat_request_match_detail','text'),('futbeat_request_calendar_date','date,text'),
    ('futbeat_request_player_profile','text'),('futbeat_request_terminal_result','text'),
    ('futbeat_request_lineup_hydration','text[],text[]'),('futbeat_request_match_standings','text'),
    ('futbeat_request_team_squad','text'),('futbeat_request_team_matches','text,date'),
    ('futbeat_request_match_h2h','text'),('futbeat_request_match_h2h_history','text')
  ) v(name,args) loop
    execute format('drop function public.%I(%s)',f.name,f.args);
    execute format('alter function futbeat_private.%I(%s) set schema public',f.name||'__ungated',f.args);
    execute format('alter function public.%I(%s) rename to %I',f.name||'__ungated',f.args,f.name);
    execute format('revoke all on function public.%I(%s) from public,anon,authenticated',f.name,f.args);
    execute format('grant execute on function public.%I(%s) to service_role',f.name,f.args);
  end loop;
end $$;
drop function futbeat_private.note_player_search_demand(text);
alter function futbeat_private.note_player_search_demand__ungated(text) rename to note_player_search_demand;
drop function if exists public.futbeat_api_admit(text,text,text,integer);
drop function if exists futbeat_private.futbeat_api_admit(text,text,text,integer);
drop function if exists futbeat_private.api_rate_take(text,timestamptz,integer);
drop function if exists futbeat_private.navigation_demands_enabled();
drop table if exists futbeat_private.api_rate_counters;
drop table if exists futbeat_private.api_access_policy;
notify pgrst, 'reload schema';
commit;
