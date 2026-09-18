-- User profile v1: account preferences, cross-device follows and per-event notifications.

alter table futbeat_private.user_preferences
  add column if not exists display_name text,
  add column if not exists language_code text not null default 'es',
  add column if not exists timezone text not null default 'America/Costa_Rica',
  add column if not exists notify_kickoff boolean not null default true,
  add column if not exists notify_goals boolean not null default true,
  add column if not exists notify_final boolean not null default true,
  add column if not exists notify_cards boolean not null default true,
  add column if not exists notify_lineups boolean not null default true,
  add column if not exists notify_news boolean not null default true,
  add column if not exists notify_transfers boolean not null default true;

alter table futbeat_private.user_preferences
  drop constraint if exists user_preferences_display_name_check,
  add constraint user_preferences_display_name_check
    check(display_name is null or char_length(display_name) between 1 and 80),
  drop constraint if exists user_preferences_language_code_check,
  add constraint user_preferences_language_code_check
    check(language_code ~ '^[a-z]{2}(-[A-Z]{2})?$'),
  drop constraint if exists user_preferences_timezone_check,
  add constraint user_preferences_timezone_check
    check(char_length(timezone) between 1 and 80);

-- The original country-only RPC used positional INSERT values. Keep it compatible
-- after adding profile columns by naming the columns explicitly.
create or replace function futbeat_private.sync_user_preferences(
  p_detected text,
  p_selected text
) returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  uid uuid:=auth.uid();
begin
  if uid is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;

  p_detected:=nullif(upper(trim(p_detected)),'');
  p_selected:=nullif(upper(trim(p_selected)),'');

  if (p_detected is not null and p_detected!~'^[A-Z]{2}$')
     or (p_selected is not null and p_selected!~'^[A-Z]{2}$') then
    raise exception 'Invalid country';
  end if;

  insert into futbeat_private.user_preferences(
    user_id,
    detected_country,
    selected_country,
    updated_at
  )
  values(uid,p_detected,p_selected,now())
  on conflict(user_id) do update
    set detected_country=excluded.detected_country,
        selected_country=excluded.selected_country,
        updated_at=now();

  perform futbeat_private.refresh_interest_aggregates();
end;
$$;

create or replace function futbeat_private.sync_user_profile(
  p_display_name text,
  p_language_code text,
  p_timezone text,
  p_notify_kickoff boolean,
  p_notify_goals boolean,
  p_notify_final boolean,
  p_notify_cards boolean,
  p_notify_lineups boolean,
  p_notify_news boolean,
  p_notify_transfers boolean
) returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  display_name text:=nullif(trim(p_display_name),'');
  language_code text:=coalesce(nullif(trim(p_language_code),''),'es');
  timezone_name text:=coalesce(nullif(trim(p_timezone),''),'America/Costa_Rica');
begin
  if uid is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;
  if display_name is not null and char_length(display_name)>80 then
    raise exception 'Display name too long';
  end if;
  if language_code!~'^[a-z]{2}(-[A-Z]{2})?$' then
    raise exception 'Invalid language';
  end if;
  if char_length(timezone_name)>80 then
    raise exception 'Invalid timezone';
  end if;

  insert into futbeat_private.user_preferences(
    user_id,
    display_name,
    language_code,
    timezone,
    notify_kickoff,
    notify_goals,
    notify_final,
    notify_cards,
    notify_lineups,
    notify_news,
    notify_transfers,
    updated_at
  )
  values(
    uid,
    display_name,
    language_code,
    timezone_name,
    coalesce(p_notify_kickoff,true),
    coalesce(p_notify_goals,true),
    coalesce(p_notify_final,true),
    coalesce(p_notify_cards,true),
    coalesce(p_notify_lineups,true),
    coalesce(p_notify_news,true),
    coalesce(p_notify_transfers,true),
    now()
  )
  on conflict(user_id) do update set
    display_name=excluded.display_name,
    language_code=excluded.language_code,
    timezone=excluded.timezone,
    notify_kickoff=excluded.notify_kickoff,
    notify_goals=excluded.notify_goals,
    notify_final=excluded.notify_final,
    notify_cards=excluded.notify_cards,
    notify_lineups=excluded.notify_lineups,
    notify_news=excluded.notify_news,
    notify_transfers=excluded.notify_transfers,
    updated_at=now();
end;
$$;

create or replace function futbeat_private.read_user_profile() returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  pref futbeat_private.user_preferences;
  follows jsonb;
begin
  if uid is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;

  insert into futbeat_private.user_preferences(user_id)
  values(uid)
  on conflict(user_id) do nothing;

  select * into pref
    from futbeat_private.user_preferences
   where user_id=uid;

  select coalesce(
    jsonb_agg(
      jsonb_build_object('type',entity_type,'id',entity_id)
      order by entity_type,entity_id
    ),
    '[]'::jsonb
  )
  into follows
  from futbeat_private.push_follows
  where user_id=uid;

  return jsonb_build_object(
    'preferences',
    jsonb_build_object(
      'detectedCountry',pref.detected_country,
      'selectedCountry',pref.selected_country,
      'displayName',pref.display_name,
      'languageCode',pref.language_code,
      'timezone',pref.timezone,
      'notifyKickoff',pref.notify_kickoff,
      'notifyGoals',pref.notify_goals,
      'notifyFinal',pref.notify_final,
      'notifyCards',pref.notify_cards,
      'notifyLineups',pref.notify_lineups,
      'notifyNews',pref.notify_news,
      'notifyTransfers',pref.notify_transfers,
      'updatedAt',pref.updated_at
    ),
    'follows',follows
  );
end;
$$;

create or replace function public.futbeat_sync_user_profile(
  p_display_name text,
  p_language_code text,
  p_timezone text,
  p_notify_kickoff boolean,
  p_notify_goals boolean,
  p_notify_final boolean,
  p_notify_cards boolean,
  p_notify_lineups boolean,
  p_notify_news boolean,
  p_notify_transfers boolean
) returns void
language sql
security invoker
set search_path=''
as $$
  select futbeat_private.sync_user_profile(
    p_display_name,
    p_language_code,
    p_timezone,
    p_notify_kickoff,
    p_notify_goals,
    p_notify_final,
    p_notify_cards,
    p_notify_lineups,
    p_notify_news,
    p_notify_transfers
  )
$$;

create or replace function public.futbeat_read_user_profile() returns jsonb
language sql
security invoker
set search_path=''
as $$
  select futbeat_private.read_user_profile()
$$;

-- Respect user notification preferences when materializing the outbox.
create or replace function futbeat_private.store_canonical_event(
  ev jsonb,
  p_provider text,
  p_notify boolean,
  p_at timestamptz,
  m jsonb
) returns void
language plpgsql
security invoker
set search_path=''
as $$
declare
  inserted integer;
  msg jsonb;
begin
  insert into futbeat_private.canonical_events
  values(ev->>'id',ev->>'matchId',p_provider,ev->>'type',ev,p_notify,p_at)
  on conflict(id) do nothing;

  get diagnostics inserted=row_count;
  if inserted=0 or not p_notify then return; end if;

  msg:=futbeat_private.event_message(ev,m);
  if msg is null then return; end if;

  insert into futbeat_private.notification_outbox(event_id,device_id,user_id,message)
  select ev->>'id',d.id,d.user_id,msg
  from futbeat_private.push_devices d
  left join futbeat_private.user_preferences p on p.user_id=d.user_id
  where d.enabled
    and d.registered_at<=p_at
    and case ev->>'type'
      when 'KICKOFF' then coalesce(p.notify_kickoff,true)
      when 'GOAL' then coalesce(p.notify_goals,true)
      when 'FULL_TIME' then coalesce(p.notify_final,true)
      when 'YELLOW_CARD' then coalesce(p.notify_cards,true)
      when 'RED_CARD' then coalesce(p.notify_cards,true)
      else true
    end
    and exists(
      select 1
      from futbeat_private.push_follows f
      where f.user_id=d.user_id
        and f.created_at<=p_at
        and (
          (f.entity_type='match' and f.entity_id=ev->>'matchId')
          or (
            f.entity_type='team'
            and f.entity_id in (m->>'homeTeamId',m->>'awayTeamId')
          )
        )
    )
  on conflict(event_id,user_id,device_id) do nothing;
end;
$$;

revoke all on function
  futbeat_private.sync_user_profile(text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean),
  futbeat_private.read_user_profile(),
  public.futbeat_sync_user_profile(text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean),
  public.futbeat_read_user_profile()
from public;

do $$
begin
  if exists(select 1 from pg_roles where rolname='authenticated') then
    grant usage on schema futbeat_private to authenticated;
    grant execute on function
      futbeat_private.sync_user_profile(text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean),
      futbeat_private.read_user_profile(),
      public.futbeat_sync_user_profile(text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean),
      public.futbeat_read_user_profile()
    to authenticated;
  end if;
end
$$;

notify pgrst,'reload schema';
