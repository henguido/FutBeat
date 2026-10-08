-- Rollback of 20261008010000_calendar_date_finalize.sql (manual, NOT a
-- migration). New functions only: nothing else was redefined. Deploy the
-- previous futbeat-global-ingest (v38, without sub-batches) BEFORE running
-- this, or a large calendar date would fail at its finalize call.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';
drop function if exists public.futbeat_finalize_calendar_date(text,timestamptz,date,integer,jsonb);
drop function if exists futbeat_private.futbeat_finalize_calendar_date(text,timestamptz,date,integer,jsonb);
notify pgrst, 'reload schema';
commit;
