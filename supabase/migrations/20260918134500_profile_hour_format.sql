-- Profile v2: synchronize the user's preferred clock format across devices.

alter table futbeat_private.user_preferences
  add column if not exists hour_format text not null default 'system';

alter table futbeat_private.user_preferences
  drop constraint if exists user_preferences_hour_format_check,
  add constraint user_preferences_hour_format_check
    check(hour_format in ('system','12h','24h'));

create or replace function futbeat_private.sync_user_profile_v2(
  p_display_name text,
  p_language_code text,
  p_timezone text,
  p_hour_format text,
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
  normalized_hour_format text:=coalesce(nullif(trim(p_hour_format),''),'system');
begin
  if uid is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;
  if normalized_hour_format not in ('system','12h','24h') then
    raise exception 'Invalid hour format';
  end if;

  perform futbeat_private.sync_user_profile(
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
  );

  update futbeat_private.user_preferences
     set hour_format=normalized_hour_format,
         updated_at=now()
   where user_id=uid;
end;
$$;

create or replace function public.futbeat_sync_user_profile_v2(
  p_display_name text,
  p_language_code text,
  p_timezone text,
  p_hour_format text,
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
  select futbeat_private.sync_user_profile_v2(
    p_display_name,
    p_language_code,
    p_timezone,
    p_hour_format,
    p_notify_kickoff,
    p_notify_goals,
    p_notify_final,
    p_notify_cards,
    p_notify_lineups,
    p_notify_news,
    p_notify_transfers
  )
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
      'hourFormat',pref.hour_format,
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

revoke all on function
  futbeat_private.sync_user_profile_v2(
    text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean
  ),
  public.futbeat_sync_user_profile_v2(
    text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean
  )
from public,anon,authenticated;

grant execute on function
  futbeat_private.sync_user_profile_v2(
    text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean
  ),
  public.futbeat_sync_user_profile_v2(
    text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean
  )
to authenticated;

notify pgrst,'reload schema';
