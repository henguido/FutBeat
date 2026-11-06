-- R05: durable, queryable account-deletion receipts (FutBeat 1.0).
--
-- Problem: the app deletes the account with futbeat-delete-account and only
-- then writes its local confirmation. If the ACK is lost (network, process
-- killed) and the access token expires, a reopened app only sees 401s, which
-- never prove a deletion. The server now keeps a receipt the app can query
-- WITHOUT a session.
--
-- Contract (packages/contracts/account-deletion-v1.md):
--   * the app generates a random deletion id (UUID v4), stores it durably
--     with the uid BEFORE calling the function, and sends it as
--     X-FutBeat-Deletion-Id;
--   * the function records the receipt (pending) before deleting anything,
--     and marks it deleted once the Auth record is gone;
--   * futbeat_account_deletion_status(id) answers deleted | pending | unknown
--     to anyone holding the id (a 122-bit random capability; it reveals no
--     user data).
--
-- Privacy: only the SHA-256 of the deletion id is stored. The account uid is
-- kept while the receipt is pending (the account still exists then) and is
-- erased when the deletion completes; afterwards only SHA-256(uid) remains,
-- to bind retries to the same subject. No email, IP or device data.
-- Receipts older than 30 days are purged. Idempotent: replaying an id for the
-- same subject returns its state; for another subject it is a conflict.

create table if not exists futbeat_private.account_deletion_receipts (
  deletion_hash bytea primary key,
  subject uuid,
  subject_hash bytea not null,
  status text not null check (status in ('pending', 'deleted')),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  check ((status = 'pending') = (subject is not null))
);
create index if not exists account_deletion_receipts_created
  on futbeat_private.account_deletion_receipts (created_at);

alter table futbeat_private.account_deletion_receipts enable row level security;
revoke all on futbeat_private.account_deletion_receipts from public, anon, authenticated;

create or replace function futbeat_private.deletion_digest(p_value text)
returns bytea language sql immutable strict set search_path = '' as $$
  select pg_catalog.sha256(pg_catalog.convert_to(p_value, 'UTF8'))
$$;

-- Edge function only (service_role): record the receipt before deleting.
create or replace function public.futbeat_account_deletion_begin(p_deletion_id uuid, p_subject uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_hash bytea := futbeat_private.deletion_digest(lower(p_deletion_id::text));
  v_subject_hash bytea := futbeat_private.deletion_digest(lower(p_subject::text));
  v_row futbeat_private.account_deletion_receipts;
begin
  delete from futbeat_private.account_deletion_receipts where created_at < now() - interval '30 days';
  insert into futbeat_private.account_deletion_receipts (deletion_hash, subject, subject_hash, status)
  values (v_hash, p_subject, v_subject_hash, 'pending')
  on conflict (deletion_hash) do nothing;
  select * into v_row from futbeat_private.account_deletion_receipts where deletion_hash = v_hash;
  if v_row.subject_hash <> v_subject_hash then
    return jsonb_build_object('status', 'conflict');
  end if;
  return jsonb_build_object('status', v_row.status);
end;
$$;

-- Edge function only (service_role): the Auth record is gone.
create or replace function public.futbeat_account_deletion_finish(p_deletion_id uuid, p_subject uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_count int;
begin
  update futbeat_private.account_deletion_receipts
     set status = 'deleted', subject = null, completed_at = coalesce(completed_at, now())
   where deletion_hash = futbeat_private.deletion_digest(lower(p_deletion_id::text))
     and subject_hash = futbeat_private.deletion_digest(lower(p_subject::text));
  get diagnostics v_count = row_count;
  return jsonb_build_object('status', case when v_count = 1 then 'deleted' else 'unknown' end);
end;
$$;

-- Anyone holding the id (the app, with only the publishable key): the state.
-- A pending receipt whose account no longer exists is completed here, so a
-- lost ACK after a successful delete still reads as deleted.
create or replace function public.futbeat_account_deletion_status(p_deletion_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_hash bytea := futbeat_private.deletion_digest(lower(p_deletion_id::text));
  v_row futbeat_private.account_deletion_receipts;
begin
  select * into v_row from futbeat_private.account_deletion_receipts where deletion_hash = v_hash;
  if not found then
    return jsonb_build_object('status', 'unknown');
  end if;
  if v_row.status = 'pending' and not exists (select 1 from auth.users u where u.id = v_row.subject) then
    update futbeat_private.account_deletion_receipts
       set status = 'deleted', subject = null, completed_at = now()
     where deletion_hash = v_hash and status = 'pending';
    v_row.status := 'deleted';
    v_row.completed_at := now();
  end if;
  return jsonb_build_object('status', v_row.status,
    'completedAt', case when v_row.status = 'deleted' then v_row.completed_at end);
end;
$$;

revoke all on function futbeat_private.deletion_digest(text) from public;
revoke all on function public.futbeat_account_deletion_begin(uuid, uuid) from public, anon, authenticated;
revoke all on function public.futbeat_account_deletion_finish(uuid, uuid) from public, anon, authenticated;
revoke all on function public.futbeat_account_deletion_status(uuid) from public;
grant execute on function public.futbeat_account_deletion_begin(uuid, uuid) to service_role;
grant execute on function public.futbeat_account_deletion_finish(uuid, uuid) to service_role;
grant execute on function public.futbeat_account_deletion_status(uuid) to anon, authenticated, service_role;
