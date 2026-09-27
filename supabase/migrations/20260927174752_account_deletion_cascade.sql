-- Account deletion is initiated by the authenticated futbeat-delete-account
-- Edge Function, which removes auth.users through the server-only Admin API.
-- These constraints make that single Auth deletion the atomic owner of all
-- private FutBeat cleanup. Shared canonical sports data is intentionally not
-- linked to auth.users and is preserved.

alter table futbeat_private.notification_outbox
  drop constraint if exists notification_outbox_device_id_fkey;
alter table futbeat_private.notification_outbox
  add constraint notification_outbox_device_id_fkey
  foreign key(device_id) references futbeat_private.push_devices(id)
  on delete cascade;

do $$
begin
  -- auth.users is guaranteed by Supabase. The guard keeps the migration
  -- loadable in lightweight SQL-only test harnesses that intentionally omit
  -- the Auth schema.
  if to_regclass('auth.users') is null then
    return;
  end if;

  -- Historical rows for accounts that no longer exist cannot be owned or
  -- exposed. Remove them before validating the new ownership constraints.
  delete from futbeat_private.notification_outbox o
  where not exists (select 1 from auth.users u where u.id=o.user_id);
  delete from futbeat_private.push_follows f
  where not exists (select 1 from auth.users u where u.id=f.user_id);
  delete from futbeat_private.temporary_interests i
  where not exists (select 1 from auth.users u where u.id=i.user_id);
  delete from futbeat_private.user_preferences p
  where not exists (select 1 from auth.users u where u.id=p.user_id);
  delete from futbeat_private.push_devices d
  where not exists (select 1 from auth.users u where u.id=d.user_id);

  alter table futbeat_private.push_devices
    add constraint push_devices_auth_user_fkey
    foreign key(user_id) references auth.users(id) on delete cascade;
  alter table futbeat_private.push_follows
    add constraint push_follows_auth_user_fkey
    foreign key(user_id) references auth.users(id) on delete cascade;
  alter table futbeat_private.user_preferences
    add constraint user_preferences_auth_user_fkey
    foreign key(user_id) references auth.users(id) on delete cascade;
  alter table futbeat_private.temporary_interests
    add constraint temporary_interests_auth_user_fkey
    foreign key(user_id) references auth.users(id) on delete cascade;
  alter table futbeat_private.notification_outbox
    add constraint notification_outbox_auth_user_fkey
    foreign key(user_id) references auth.users(id) on delete cascade;
end
$$;
