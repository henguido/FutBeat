-- BE11-A5: account deletion leaves no uid behind in the guest-merge tables.
--
-- Deleting the Auth record cascades to every per-user table except the two
-- guest-merge tables of 20261105110000_guest_account_merge (applied in
-- production 2026-11-05; its source is on claude/futbeat-backend-local-d2nnav):
--   guest_merge_tickets.guest_user_id / redeemed_by and
--   guest_account_merges.guest_user_id / account_user_id
-- have no foreign key, so a deleted account's uid stayed there forever.
-- Now:
--   * tickets: removed with the guest; redeemed_by is cleared with the account;
--   * merge audit rows: removed when either side is deleted.
-- Production check 2026-11-07 (read-only): 1 ticket, 1 merge, 0 orphans, so
-- validation cannot fail today. NOT VALID + VALIDATE keeps the lock on
-- auth.users to the brief ADD (lock_timeout bounded by the launcher).
-- Guarded: a database without the guest-merge tables is left unchanged.
-- Rollback: supabase/manual/20261107120000_account_deletion_residue_rollback.sql

do $$
begin
  if to_regclass('futbeat_private.guest_merge_tickets') is not null then
    delete from futbeat_private.guest_merge_tickets t
     where not exists (select 1 from auth.users u where u.id = t.guest_user_id);
    update futbeat_private.guest_merge_tickets t set redeemed_by = null
     where redeemed_by is not null and not exists (select 1 from auth.users u where u.id = t.redeemed_by);
    if not exists (select 1 from pg_constraint where conname = 'guest_merge_tickets_guest_user_fk') then
      alter table futbeat_private.guest_merge_tickets
        add constraint guest_merge_tickets_guest_user_fk foreign key (guest_user_id)
        references auth.users(id) on delete cascade not valid;
    end if;
    if not exists (select 1 from pg_constraint where conname = 'guest_merge_tickets_redeemed_by_fk') then
      alter table futbeat_private.guest_merge_tickets
        add constraint guest_merge_tickets_redeemed_by_fk foreign key (redeemed_by)
        references auth.users(id) on delete set null not valid;
    end if;
    alter table futbeat_private.guest_merge_tickets validate constraint guest_merge_tickets_guest_user_fk;
    alter table futbeat_private.guest_merge_tickets validate constraint guest_merge_tickets_redeemed_by_fk;
  end if;

  if to_regclass('futbeat_private.guest_account_merges') is not null then
    delete from futbeat_private.guest_account_merges m
     where not exists (select 1 from auth.users u where u.id = m.guest_user_id)
        or not exists (select 1 from auth.users u where u.id = m.account_user_id);
    if not exists (select 1 from pg_constraint where conname = 'guest_account_merges_guest_user_fk') then
      alter table futbeat_private.guest_account_merges
        add constraint guest_account_merges_guest_user_fk foreign key (guest_user_id)
        references auth.users(id) on delete cascade not valid;
    end if;
    if not exists (select 1 from pg_constraint where conname = 'guest_account_merges_account_user_fk') then
      alter table futbeat_private.guest_account_merges
        add constraint guest_account_merges_account_user_fk foreign key (account_user_id)
        references auth.users(id) on delete cascade not valid;
    end if;
    alter table futbeat_private.guest_account_merges validate constraint guest_account_merges_guest_user_fk;
    alter table futbeat_private.guest_account_merges validate constraint guest_account_merges_account_user_fk;
  end if;
end;
$$;
