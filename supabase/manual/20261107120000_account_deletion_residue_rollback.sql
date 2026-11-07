-- Rollback of 20261107120000_account_deletion_residue (BE11-A5). Drops only the
-- four foreign keys; rows removed as orphans (if any) are not restored.
alter table if exists futbeat_private.guest_merge_tickets drop constraint if exists guest_merge_tickets_guest_user_fk;
alter table if exists futbeat_private.guest_merge_tickets drop constraint if exists guest_merge_tickets_redeemed_by_fk;
alter table if exists futbeat_private.guest_account_merges drop constraint if exists guest_account_merges_guest_user_fk;
alter table if exists futbeat_private.guest_account_merges drop constraint if exists guest_account_merges_account_user_fk;
