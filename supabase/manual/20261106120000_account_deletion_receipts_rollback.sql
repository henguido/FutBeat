-- Rollback of 20261106120000_account_deletion_receipts (R05).
-- Deploy the previous futbeat-delete-account FIRST (it does not use the
-- receipts), then run this. Receipts are lost: apps holding a deletion id
-- then read "unknown" and must not infer a deletion from it.
drop function if exists public.futbeat_account_deletion_status(uuid);
drop function if exists public.futbeat_account_deletion_finish(uuid, uuid);
drop function if exists public.futbeat_account_deletion_begin(uuid, uuid);
drop function if exists futbeat_private.deletion_digest(text);
drop table if exists futbeat_private.account_deletion_receipts;
