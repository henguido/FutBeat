-- Content push v2.
-- Extend the existing durable outbox so NEWS and TRANSFER notifications can use
-- the same dispatcher/cron without inventing match events or another scheduler.

alter table futbeat_private.notification_outbox
  alter column event_id drop not null;

alter table futbeat_private.notification_outbox
  add column if not exists notification_key text;

update futbeat_private.notification_outbox
set notification_key=event_id
where notification_key is null;

alter table futbeat_private.notification_outbox
  alter column notification_key set default gen_random_uuid()::text;

alter table futbeat_private.notification_outbox
  alter column notification_key set not null;

create unique index if not exists notification_outbox_key_user_device_idx
  on futbeat_private.notification_outbox(notification_key,user_id,device_id);

create or replace function futbeat_private.enqueue_news_notification(
  p_article_id text
) returns integer
language plpgsql
security definer
set search_path=''
as $$
declare
  a futbeat_private.news_articles%rowtype;
  refs jsonb;
  msg jsonb;
  inserted integer:=0;
begin
  select * into a
  from futbeat_private.news_articles
  where id=p_article_id;

  if not found or a.published_at<now()-interval '6 hours' then
    return 0;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'type',ns.subject_type,
        'id',futbeat_private.futbeat_resolve_entity_id(
          ns.subject_type,ns.subject_id
        )
      )
      order by ns.subject_type,ns.subject_id
    ),
    '[]'::jsonb
  )
  into refs
  from futbeat_private.news_subjects ns
  where ns.article_id=p_article_id;

  if jsonb_array_length(refs)=0 then
    return 0;
  end if;

  msg:=jsonb_build_object(
    'type','NEWS',
    'title','📰 '||left(a.title,180),
    'articleId',a.id,
    'url',a.url,
    'source',a.source_name,
    'publishedAt',a.published_at,
    'subjectRefs',refs
  );

  insert into futbeat_private.notification_outbox(
    event_id,notification_key,device_id,user_id,message,created_at
  )
  select
    null,
    'news:'||a.id,
    d.id,
    d.user_id,
    msg,
    a.published_at
  from futbeat_private.push_devices d
  left join futbeat_private.user_preferences p
    on p.user_id=d.user_id
  where d.enabled
    and coalesce(p.notify_news,true)
    and d.registered_at<=a.published_at
    and exists(
      select 1
      from futbeat_private.push_follows f
      join lateral jsonb_array_elements(refs) ref on true
      where f.user_id=d.user_id
        and f.created_at<=a.published_at
        and f.entity_type=ref->>'type'
        and f.entity_id=ref->>'id'
    )
  on conflict(notification_key,user_id,device_id) do update
    set message=excluded.message;

  get diagnostics inserted=row_count;
  return inserted;
end
$$;

create or replace function futbeat_private.enqueue_transfer_notification(
  p_transfer_id bigint
) returns integer
language plpgsql
security definer
set search_path=''
as $$
declare
  tr futbeat_private.transfer_events%rowtype;
  player_name text;
  from_name text;
  to_name text;
  from_comp text;
  to_comp text;
  refs jsonb:='[]'::jsonb;
  msg jsonb;
  inserted integer:=0;
begin
  select * into tr
  from futbeat_private.transfer_events
  where id=p_transfer_id;

  if not found then
    return 0;
  end if;

  select payload->>'name' into player_name
  from futbeat_private.entities
  where id=tr.player_id and kind='player';

  select payload->>'name',
         nullif(payload->>'competitionId','')
  into from_name,from_comp
  from futbeat_private.entities
  where id=tr.from_team_id and kind='team';

  select payload->>'name',
         nullif(payload->>'competitionId','')
  into to_name,to_comp
  from futbeat_private.entities
  where id=tr.to_team_id and kind='team';

  refs:=jsonb_build_array(
    jsonb_build_object('type','player','id',tr.player_id),
    jsonb_build_object('type','team','id',tr.from_team_id),
    jsonb_build_object('type','team','id',tr.to_team_id)
  );

  if from_comp is not null then
    refs:=refs||jsonb_build_array(
      jsonb_build_object(
        'type','competition',
        'id',futbeat_private.futbeat_resolve_entity_id(
          'competition',from_comp
        )
      )
    );
  end if;

  if to_comp is not null then
    refs:=refs||jsonb_build_array(
      jsonb_build_object(
        'type','competition',
        'id',futbeat_private.futbeat_resolve_entity_id(
          'competition',to_comp
        )
      )
    );
  end if;

  msg:=jsonb_build_object(
    'type','TRANSFER',
    'title','🔄 '||coalesce(player_name,'Jugador')||': '||
      coalesce(from_name,'Equipo')||' → '||coalesce(to_name,'Equipo'),
    'transferId',tr.id,
    'playerId',tr.player_id,
    'fromTeamId',tr.from_team_id,
    'toTeamId',tr.to_team_id,
    'detectedAt',tr.detected_at,
    'source',tr.source_label,
    'subjectRefs',refs
  );

  insert into futbeat_private.notification_outbox(
    event_id,notification_key,device_id,user_id,message,created_at
  )
  select
    null,
    'transfer:'||tr.id::text,
    d.id,
    d.user_id,
    msg,
    tr.detected_at
  from futbeat_private.push_devices d
  left join futbeat_private.user_preferences p
    on p.user_id=d.user_id
  where d.enabled
    and coalesce(p.notify_transfers,true)
    and d.registered_at<=tr.detected_at
    and exists(
      select 1
      from futbeat_private.push_follows f
      join lateral jsonb_array_elements(refs) ref on true
      where f.user_id=d.user_id
        and f.created_at<=tr.detected_at
        and f.entity_type=ref->>'type'
        and f.entity_id=ref->>'id'
    )
  on conflict(notification_key,user_id,device_id) do update
    set message=excluded.message;

  get diagnostics inserted=row_count;
  return inserted;
end
$$;

create or replace function futbeat_private.news_subject_push_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  perform futbeat_private.enqueue_news_notification(new.article_id);
  return new;
end
$$;

drop trigger if exists news_subject_push on futbeat_private.news_subjects;
create trigger news_subject_push
after insert or update on futbeat_private.news_subjects
for each row execute function futbeat_private.news_subject_push_trigger();

create or replace function futbeat_private.transfer_push_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  perform futbeat_private.enqueue_transfer_notification(new.id);
  return new;
end
$$;

drop trigger if exists transfer_push on futbeat_private.transfer_events;
create trigger transfer_push
after insert on futbeat_private.transfer_events
for each row execute function futbeat_private.transfer_push_trigger();

create or replace function public.futbeat_claim_notifications(
  p_mode text default 'dry_run',
  p_limit int default 20
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  row record;
  rows jsonb:='[]';
  attempt uuid;
  still_following boolean;
begin
  if p_mode not in ('dry_run','live') then
    raise exception 'Invalid mode';
  end if;

  update futbeat_private.notification_outbox
  set state='uncertain',finished_at=now()
  where state='sending'
    and attempt_at<now()-interval '5 minutes';

  for row in
    select
      o.*,
      d.transport,
      d.token,
      d.enabled,
      m.payload as match
    from futbeat_private.notification_outbox o
    join futbeat_private.push_devices d
      on d.id=o.device_id and d.user_id=o.user_id
    left join futbeat_private.canonical_events e
      on e.id=o.event_id
    left join futbeat_private.entities m
      on m.id=e.match_id
    where o.state='pending'
      and (p_mode='live' or d.transport='test')
    order by o.created_at
    for update of o skip locked
    limit least(greatest(p_limit,1),100)
  loop
    if row.event_id is not null then
      select exists(
        select 1
        from futbeat_private.push_follows f
        where f.user_id=row.user_id
          and (
            f.entity_id=row.message->>'matchId'
            or (
              row.match is not null
              and f.entity_id in (
                row.match->>'homeTeamId',
                row.match->>'awayTeamId'
              )
            )
          )
      )
      into still_following;
    else
      select exists(
        select 1
        from futbeat_private.push_follows f
        join lateral jsonb_array_elements(
          coalesce(row.message->'subjectRefs','[]'::jsonb)
        ) ref on true
        where f.user_id=row.user_id
          and f.entity_type=ref->>'type'
          and f.entity_id=ref->>'id'
      )
      into still_following;
    end if;

    if not row.enabled or not coalesce(still_following,false) then
      update futbeat_private.notification_outbox
      set state='cancelled',finished_at=now()
      where id=row.id;
      continue;
    end if;

    attempt:=gen_random_uuid();
    update futbeat_private.notification_outbox
    set state='sending',attempt_id=attempt,attempt_at=now()
    where id=row.id;

    rows:=rows||jsonb_build_array(
      jsonb_build_object(
        'id',row.id,
        'attemptId',attempt,
        'transport',row.transport,
        'token',row.token,
        'message',row.message
      )
    );
  end loop;

  return rows;
end
$$;

revoke all on function
  futbeat_private.enqueue_news_notification(text),
  futbeat_private.enqueue_transfer_notification(bigint),
  futbeat_private.news_subject_push_trigger(),
  futbeat_private.transfer_push_trigger()
from public,anon,authenticated;

grant execute on function
  futbeat_private.enqueue_news_notification(text),
  futbeat_private.enqueue_transfer_notification(bigint)
to service_role;

notify pgrst,'reload schema';
