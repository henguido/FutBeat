-- Rollback of 20261105110000_guest_account_merge.sql (manual, NOT a
-- migration). Merged follows/preferences stay with the accounts that
-- redeemed them (they are the user's data now); only the ticket machinery
-- and its audit go. Ship an app that no longer calls these RPCs first.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';
drop function if exists public.futbeat_redeem_guest_merge_ticket(text);
drop function if exists public.futbeat_issue_guest_merge_ticket();
drop function if exists futbeat_private.session_is_anonymous();
drop table if exists futbeat_private.guest_account_merges;
drop table if exists futbeat_private.guest_merge_tickets;
notify pgrst, 'reload schema';
commit;
