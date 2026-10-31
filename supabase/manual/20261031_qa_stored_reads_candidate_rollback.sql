-- CANDIDATE, NOT APPLIED. Removes only what 20261031_qa_stored_reads_candidate.sql creates.
drop function if exists public.futbeat_read_qa_stored_calendar(date,text);
drop function if exists public.futbeat_read_qa_stored_explore(text);
drop function if exists public.futbeat_read_qa_stored_search(text,text,integer);
drop function if exists public.futbeat_read_qa_stored_national_teams();
