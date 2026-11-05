-- Guest -> account: favourites and preferences survive signing in.
--
-- Guests are Supabase anonymous users (product decision, 2026-11-05). Two
-- ways out of guest mode:
--   1. The guest CREATES an account (email, Google) by linking it to the
--      anonymous user: Supabase keeps the same user id, so follows,
--      temporary interests and preferences stay where they are. Nothing to do
--      here.
--   2. The guest signs in to an EXISTING account (e.g. created on another
--      phone): the session switches to another user id. Before switching,
--      the guest session asks for a one-time ticket; after signing in, the
--      account session redeems it and the guest's data is merged:
--        * follows: union (the account's rows are kept as they are);
--        * temporary interests: union, the later expiry wins;
--        * preferences: the account's values win; only empty account
--          fields (or a missing row) take the guest's;
--        * the guest's push devices are disabled (the app registers the
--          device again under the account), so nobody is notified twice.
--      The guest's own rows are not deleted (Supabase's anonymous-user
--      cleanup, or account deletion, removes them).
-- A ticket is 256 random bits, stored only as a SHA-256 hash, valid for 10
-- minutes, single use, issued only to an anonymous session and redeemable
-- only by a non-anonymous one, never into the same user.
--
-- No provider call, cron, quota, push dispatch or Preview change.
-- Rollback: supabase/manual/20261105110000_guest_account_merge_rollback.sql

create table if not exists futbeat_private.guest_merge_tickets (
  ticket_hash text primary key check(ticket_hash ~ '^[0-9a-f]{64}$'),
  guest_user_id uuid not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  redeemed_at timestamptz,
  redeemed_by uuid,
  check(expires_at>created_at)
);
create index if not exists guest_merge_tickets_guest_idx
  on futbeat_private.guest_merge_tickets(guest_user_id,created_at desc);

create table if not exists futbeat_private.guest_account_merges (
  id bigint generated always as identity primary key,
  guest_user_id uuid not null,
  account_user_id uuid not null,
  merged_at timestamptz not null default now(),
  follows integer not null,
  interests integer not null,
  preferences text not null check(preferences in ('copied','filled','kept')),
  devices_disabled integer not null,
  check(guest_user_id<>account_user_id)
);

alter table futbeat_private.guest_merge_tickets enable row level security;
alter table futbeat_private.guest_account_merges enable row level security;
revoke all on futbeat_private.guest_merge_tickets,futbeat_private.guest_account_merges
  from public,anon,authenticated;

-- plpgsql: auth.jwt() is resolved at call time (Supabase provides it).
create or replace function futbeat_private.session_is_anonymous()
returns boolean language plpgsql stable set search_path='' as $$
begin
  return coalesce((auth.jwt()->>'is_anonymous')::boolean,false);
end $$;

create or replace function public.futbeat_issue_guest_merge_ticket()
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); v_ticket text; v_expires timestamptz:=now()+interval '10 minutes';
begin
  if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if not futbeat_private.session_is_anonymous() then
    raise exception 'Only a guest session can issue a merge ticket' using errcode='42501';
  end if;
  if (select count(*) from futbeat_private.guest_merge_tickets
      where guest_user_id=uid and redeemed_at is null and expires_at>now())>=3 then
    raise exception 'Too many open merge tickets' using errcode='54000';
  end if;
  v_ticket:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  insert into futbeat_private.guest_merge_tickets(ticket_hash,guest_user_id,expires_at)
  values(encode(sha256(convert_to(v_ticket,'UTF8')),'hex'),uid,v_expires);
  return jsonb_build_object('ticket',v_ticket,'expiresAt',v_expires);
end $$;

create or replace function public.futbeat_redeem_guest_merge_ticket(p_ticket text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  uid uuid:=auth.uid(); t futbeat_private.guest_merge_tickets;
  n_follows integer; n_interests integer; n_devices integer; v_prefs text;
begin
  if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if futbeat_private.session_is_anonymous() then
    raise exception 'Sign in to an account to redeem a merge ticket' using errcode='42501';
  end if;
  if coalesce(p_ticket,'') !~ '^[0-9a-f]{64}$' then raise exception 'Invalid merge ticket'; end if;
  select * into t from futbeat_private.guest_merge_tickets
    where ticket_hash=encode(sha256(convert_to(p_ticket,'UTF8')),'hex') for update;
  if not found or t.redeemed_at is not null or t.expires_at<=now() or t.guest_user_id=uid then
    raise exception 'Invalid merge ticket';
  end if;
  update futbeat_private.guest_merge_tickets set redeemed_at=now(),redeemed_by=uid
    where ticket_hash=t.ticket_hash;

  insert into futbeat_private.push_follows(user_id,entity_type,entity_id,created_at)
  select uid,f.entity_type,f.entity_id,f.created_at from futbeat_private.push_follows f
  where f.user_id=t.guest_user_id
  on conflict do nothing;
  get diagnostics n_follows=row_count;

  insert into futbeat_private.temporary_interests as ti(user_id,entity_type,entity_id,touched_at,expires_at)
  select uid,i.entity_type,i.entity_id,i.touched_at,i.expires_at from futbeat_private.temporary_interests i
  where i.user_id=t.guest_user_id and i.expires_at>now()
  on conflict(user_id,entity_type,entity_id) do update set
    touched_at=greatest(ti.touched_at,excluded.touched_at),
    expires_at=greatest(ti.expires_at,excluded.expires_at);
  get diagnostics n_interests=row_count;

  if not exists(select 1 from futbeat_private.user_preferences where user_id=t.guest_user_id) then
    v_prefs:='kept';
  elsif not exists(select 1 from futbeat_private.user_preferences where user_id=uid) then
    insert into futbeat_private.user_preferences
    select (jsonb_populate_record(null::futbeat_private.user_preferences,
      to_jsonb(g)||jsonb_build_object('user_id',uid,'updated_at',now()))).*
    from futbeat_private.user_preferences g where g.user_id=t.guest_user_id;
    v_prefs:='copied';
  else
    -- The account's choices win; only its empty fields take the guest's.
    update futbeat_private.user_preferences a set
      selected_country=coalesce(a.selected_country,g.selected_country),
      detected_country=coalesce(a.detected_country,g.detected_country),
      updated_at=now()
    from futbeat_private.user_preferences g
    where a.user_id=uid and g.user_id=t.guest_user_id
      and ((a.selected_country is null and g.selected_country is not null)
        or (a.detected_country is null and g.detected_country is not null));
    v_prefs:=case when found then 'filled' else 'kept' end;
  end if;

  update futbeat_private.push_devices set enabled=false,disabled_at=now(),disabled_reason='merged_into_account'
  where user_id=t.guest_user_id and enabled;
  get diagnostics n_devices=row_count;

  insert into futbeat_private.guest_account_merges(guest_user_id,account_user_id,follows,interests,preferences,devices_disabled)
  values(t.guest_user_id,uid,n_follows,n_interests,v_prefs,n_devices);

  return jsonb_build_object('merged',true,'follows',n_follows,'interests',n_interests,
    'preferences',v_prefs,'devicesDisabled',n_devices);
end $$;

revoke all on function futbeat_private.session_is_anonymous() from public,anon,authenticated,service_role;
revoke all on function public.futbeat_issue_guest_merge_ticket(),
  public.futbeat_redeem_guest_merge_ticket(text) from public,anon;
grant execute on function public.futbeat_issue_guest_merge_ticket(),
  public.futbeat_redeem_guest_merge_ticket(text) to authenticated;

notify pgrst,'reload schema';
