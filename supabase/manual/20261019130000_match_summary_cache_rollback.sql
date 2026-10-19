-- Rollback of 20261019130000_match_summary_cache.sql (manual, NOT a
-- migration). Undeploy the /v1/match-summary route first. The cache holds
-- only derived data (rebuilt on demand), so dropping it loses nothing.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';
drop function if exists public.futbeat_read_match_summary_input(text);
drop function if exists public.futbeat_store_match_summary(text,jsonb);
drop function if exists futbeat_private.futbeat_read_match_summary_input(text);
drop function if exists futbeat_private.futbeat_store_match_summary(text,jsonb);
drop function if exists futbeat_private.semver_parts(text);
drop table if exists futbeat_private.match_summaries;
notify pgrst, 'reload schema';
commit;
