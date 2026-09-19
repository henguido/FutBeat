-- Post-match videos v1.
-- Search is optional and only runs when an API key exists AND the match is
-- associated with a manually verified official YouTube channel.

create table if not exists futbeat_private.youtube_channels (
  subject_type text not null check(subject_type in ('team','competition')),
  subject_id text not null references futbeat_private.entities(id) on delete cascade,
  channel_id text not null check(channel_id ~ '^UC[A-Za-z0-9_-]{22}$'),
  channel_name text not null,
  verification_source_url text not null check(verification_source_url like 'https://%'),
  verified_at timestamptz not null default now(),
  active boolean not null default true,
  primary key(subject_type,subject_id,channel_id)
);

create table if not exists futbeat_private.match_videos (
  match_id text primary key references futbeat_private.entities(id) on delete cascade,
  youtube_video_id text not null unique
    check(youtube_video_id ~ '^[A-Za-z0-9_-]{11}$'),
  channel_id text not null check(channel_id ~ '^UC[A-Za-z0-9_-]{22}$'),
  channel_name text not null,
  title text not null,
  url text not null check(url like 'https://www.youtube.com/watch?v=%'),
  published_at timestamptz not null,
  fetched_at timestamptz not null,
  source_label text not null default 'YouTube · canal oficial',
  verification_status text not null default 'VERIFIED_CHANNEL'
    check(verification_status='VERIFIED_CHANNEL')
);

create table if not exists futbeat_private.video_coverage (
  match_id text primary key references futbeat_private.entities(id) on delete cascade,
  channel_id text not null,
  attempted_at timestamptz not null,
  attempts integer not null default 1 check(attempts>=1),
  result_count integer not null default 0 check(result_count between 0 and 1)
);

create index if not exists youtube_channels_subject_idx
  on futbeat_private.youtube_channels(subject_id,active);
create index if not exists match_videos_published_idx
  on futbeat_private.match_videos(published_at desc);

alter table futbeat_private.youtube_channels enable row level security;
alter table futbeat_private.match_videos enable row level security;
alter table futbeat_private.video_coverage enable row level security;

revoke all on
  futbeat_private.youtube_channels,
  futbeat_private.match_videos,
  futbeat_private.video_coverage
from public,anon,authenticated;

grant select,insert,update,delete on
  futbeat_private.youtube_channels,
  futbeat_private.match_videos,
  futbeat_private.video_coverage
to service_role;

create or replace function futbeat_private.futbeat_register_youtube_channel(
  p_subject_type text,
  p_subject_id text,
  p_channel_id text,
  p_channel_name text,
  p_verification_source_url text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_subject_id text;
begin
  v_subject_id:=futbeat_private.futbeat_resolve_entity_id(
    p_subject_type,p_subject_id
  );

  if p_subject_type not in ('team','competition')
     or p_channel_id !~ '^UC[A-Za-z0-9_-]{22}$'
     or nullif(btrim(p_channel_name),'') is null
     or p_verification_source_url not like 'https://%'
     or not exists(
       select 1 from futbeat_private.entities
       where id=v_subject_id and kind=p_subject_type
     )
  then
    raise exception 'Invalid verified YouTube channel';
  end if;

  insert into futbeat_private.youtube_channels(
    subject_type,subject_id,channel_id,channel_name,
    verification_source_url,verified_at,active
  )
  values(
    p_subject_type,v_subject_id,p_channel_id,
    left(btrim(p_channel_name),200),
    left(p_verification_source_url,1000),now(),true
  )
  on conflict(subject_type,subject_id,channel_id) do update set
    channel_name=excluded.channel_name,
    verification_source_url=excluded.verification_source_url,
    verified_at=excluded.verified_at,
    active=true;

  return jsonb_build_object(
    'subjectType',p_subject_type,
    'subjectId',v_subject_id,
    'channelId',p_channel_id,
    'verified',true
  );
end
$$;

create or replace function public.futbeat_register_youtube_channel(
  p_subject_type text,
  p_subject_id text,
  p_channel_id text,
  p_channel_name text,
  p_verification_source_url text
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_register_youtube_channel(
    p_subject_type,p_subject_id,p_channel_id,p_channel_name,
    p_verification_source_url
  )
$$;

create or replace function futbeat_private.futbeat_video_plan(
  p_limit integer default 1
) returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  result jsonb;
begin
  if p_limit<1 or p_limit>5 then
    raise exception 'Invalid video plan limit';
  end if;

  with candidates as (
    select
      m.id as match_id,
      m.payload,
      (m.payload->>'startTime')::timestamptz as start_time,
      c.payload->>'name' as competition_name,
      coalesce(c.payload->>'country','') as country,
      h.payload->>'name' as home_name,
      a.payload->>'name' as away_name,
      coalesce(
        (
          select max(ci.priority_score)
          from futbeat_private.coverage_interests ci
          where
            (ci.subject_type='match' and ci.subject_id=m.id)
            or (
              ci.subject_type='team'
              and ci.subject_id in (
                m.payload->>'homeTeamId',
                m.payload->>'awayTeamId'
              )
            )
            or (
              ci.subject_type='competition'
              and ci.subject_id=m.payload->>'competitionId'
            )
        ),
        0
      ) as interest_priority,
      case
        when lower(coalesce(c.payload->>'country','')) in ('costa rica','cr')
          then 100000
        else 0
      end as country_priority
    from futbeat_private.entities m
    join futbeat_private.entities c
      on c.id=m.payload->>'competitionId' and c.kind='competition'
    join futbeat_private.entities h
      on h.id=m.payload->>'homeTeamId' and h.kind='team'
    join futbeat_private.entities a
      on a.id=m.payload->>'awayTeamId' and a.kind='team'
    where m.kind='match'
      and m.payload->>'status' in (
        'FINISHED_PENDING_VERIFICATION','VERIFIED'
      )
      and nullif(m.payload->>'startTime','') is not null
      and (m.payload->>'startTime')::timestamptz
          between now()-interval '72 hours' and now()-interval '15 minutes'
      and not exists(
        select 1 from futbeat_private.match_videos v
        where v.match_id=m.id
      )
      and not exists(
        select 1 from futbeat_private.video_coverage vc
        where vc.match_id=m.id
          and vc.attempted_at>=now()-interval '6 hours'
      )
  ),
  planned as (
    select
      c.*,
      channel.channel_id,
      channel.channel_name
    from candidates c
    join lateral (
      select yc.channel_id,yc.channel_name
      from futbeat_private.youtube_channels yc
      where yc.active
        and (
          (
            yc.subject_type='competition'
            and yc.subject_id=futbeat_private.futbeat_resolve_entity_id(
              'competition',c.payload->>'competitionId'
            )
          )
          or (
            yc.subject_type='team'
            and yc.subject_id in (
              futbeat_private.futbeat_resolve_entity_id(
                'team',c.payload->>'homeTeamId'
              ),
              futbeat_private.futbeat_resolve_entity_id(
                'team',c.payload->>'awayTeamId'
              )
            )
          )
        )
      order by
        case when yc.subject_type='competition' then 0 else 1 end,
        yc.verified_at desc,
        yc.channel_id
      limit 1
    ) channel on true
    order by
      c.country_priority desc,
      c.interest_priority desc,
      c.start_time desc,
      c.match_id
    limit p_limit
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'matchId',match_id,
        'channelId',channel_id,
        'channelName',channel_name,
        'homeName',home_name,
        'awayName',away_name,
        'competitionName',competition_name,
        'country',country,
        'query',left(home_name||' '||away_name||' resumen highlights',120),
        'publishedAfter',start_time-interval '30 minutes',
        'publishedBefore',start_time+interval '4 days'
      )
      order by country_priority desc,interest_priority desc,start_time desc
    ),
    '[]'::jsonb
  )
  into result
  from planned;

  return result;
end
$$;

create or replace function public.futbeat_video_plan(
  p_limit integer default 1
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_video_plan(p_limit)
$$;

create or replace function futbeat_private.futbeat_reserve_youtube_search_call(
  p_match_id text,
  p_channel_id text,
  p_trigger_source text default 'supabase-cron'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_day_start timestamptz :=
    date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  v_used integer;
  v_id bigint;
begin
  if nullif(p_match_id,'') is null
     or p_channel_id !~ '^UC[A-Za-z0-9_-]{22}$'
     or nullif(btrim(p_trigger_source),'') is null
     or not exists(
       select 1
       from futbeat_private.entities m
       join futbeat_private.youtube_channels yc
         on yc.active
        and yc.channel_id=p_channel_id
        and (
          (yc.subject_type='competition'
           and yc.subject_id=m.payload->>'competitionId')
          or
          (yc.subject_type='team'
           and yc.subject_id in (
             m.payload->>'homeTeamId',m.payload->>'awayTeamId'
           ))
        )
       where m.id=p_match_id and m.kind='match'
     )
  then
    raise exception 'Invalid YouTube search reservation';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('futbeat-provider-quota:youtube:'||v_day_start::date::text)
  );

  select count(*)::integer
  into v_used
  from futbeat_private.provider_call_ledger
  where provider='youtube'
    and call_kind='video-search'
    and reserved_at>=v_day_start
    and reserved_at<v_day_start+interval '1 day';

  if v_used>=40 then
    return jsonb_build_object(
      'allowed',false,
      'reason','youtube_daily_search_limit',
      'usedToday',v_used,
      'limit',40
    );
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at,metadata
  )
  values(
    'youtube','video-search',left(p_trigger_source,40),now(),
    jsonb_build_object(
      'matchId',p_match_id,
      'channelId',p_channel_id
    )
  )
  returning id into v_id;

  return jsonb_build_object(
    'allowed',true,
    'reservationId',v_id,
    'usedToday',v_used+1,
    'limit',40
  );
end
$$;

create or replace function public.futbeat_reserve_youtube_search_call(
  p_match_id text,
  p_channel_id text,
  p_trigger_source text default 'supabase-cron'
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_reserve_youtube_search_call(
    p_match_id,p_channel_id,p_trigger_source
  )
$$;

create or replace function futbeat_private.futbeat_store_youtube_search_result(
  p_match_id text,
  p_channel_id text,
  p_fetched_at timestamptz,
  p_video jsonb default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_start timestamptz;
  v_video_id text;
  v_title text;
  v_channel_name text;
  v_published timestamptz;
  v_count integer:=0;
begin
  select nullif(payload->>'startTime','')::timestamptz
  into v_start
  from futbeat_private.entities
  where id=p_match_id and kind='match';

  select channel_name
  into v_channel_name
  from futbeat_private.youtube_channels
  where active and channel_id=p_channel_id
    and (
      (subject_type='competition' and subject_id=(
        select payload->>'competitionId'
        from futbeat_private.entities where id=p_match_id
      ))
      or
      (subject_type='team' and subject_id in (
        select payload->>'homeTeamId'
        from futbeat_private.entities where id=p_match_id
        union all
        select payload->>'awayTeamId'
        from futbeat_private.entities where id=p_match_id
      ))
    )
  order by case when subject_type='competition' then 0 else 1 end
  limit 1;

  if v_start is null or v_channel_name is null or p_fetched_at is null then
    raise exception 'Invalid YouTube video result';
  end if;

  if p_video is not null and p_video<>'null'::jsonb then
    v_video_id:=nullif(p_video->>'videoId','');
    v_title:=nullif(btrim(p_video->>'title'),'');
    begin
      v_published:=nullif(p_video->>'publishedAt','')::timestamptz;
    exception when others then
      raise exception 'Invalid YouTube publish time';
    end;

    if v_video_id !~ '^[A-Za-z0-9_-]{11}$'
       or v_title is null
       or p_video->>'channelId'<>p_channel_id
       or v_published is null
       or v_published<v_start-interval '30 minutes'
       or v_published>v_start+interval '4 days'
    then
      raise exception 'Invalid verified YouTube video';
    end if;

    insert into futbeat_private.match_videos(
      match_id,youtube_video_id,channel_id,channel_name,title,url,
      published_at,fetched_at,source_label,verification_status
    )
    values(
      p_match_id,v_video_id,p_channel_id,left(v_channel_name,200),
      left(v_title,500),
      'https://www.youtube.com/watch?v='||v_video_id,
      v_published,p_fetched_at,'YouTube · canal oficial','VERIFIED_CHANNEL'
    )
    on conflict(match_id) do update set
      youtube_video_id=excluded.youtube_video_id,
      channel_id=excluded.channel_id,
      channel_name=excluded.channel_name,
      title=excluded.title,
      url=excluded.url,
      published_at=excluded.published_at,
      fetched_at=excluded.fetched_at,
      source_label=excluded.source_label,
      verification_status=excluded.verification_status;

    v_count:=1;
  end if;

  insert into futbeat_private.video_coverage(
    match_id,channel_id,attempted_at,attempts,result_count
  )
  values(p_match_id,p_channel_id,p_fetched_at,1,v_count)
  on conflict(match_id) do update set
    channel_id=excluded.channel_id,
    attempted_at=excluded.attempted_at,
    attempts=futbeat_private.video_coverage.attempts+1,
    result_count=excluded.result_count;

  return jsonb_build_object(
    'matchId',p_match_id,
    'stored',v_count,
    'channelId',p_channel_id,
    'fetchedAt',p_fetched_at
  );
end
$$;

create or replace function public.futbeat_store_youtube_search_result(
  p_match_id text,
  p_channel_id text,
  p_fetched_at timestamptz,
  p_video jsonb default null
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_store_youtube_search_result(
    p_match_id,p_channel_id,p_fetched_at,p_video
  )
$$;

create or replace function public.futbeat_read_match_videos(
  p_match_id text
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'videoId',youtube_video_id,
        'title',title,
        'url',url,
        'channelId',channel_id,
        'channelName',channel_name,
        'publishedAt',published_at,
        'source',source_label,
        'verificationStatus',verification_status
      )
      order by published_at desc
    ),
    '[]'::jsonb
  )
  from futbeat_private.match_videos
  where match_id=p_match_id
$$;

do $vault$
begin
  if to_regnamespace('vault') is null then
    return;
  end if;

  execute $sql$
    create or replace function futbeat_private.futbeat_read_youtube_api_key()
    returns text
    language sql
    stable
    security definer
    set search_path=''
    as $body$
      select decrypted_secret
      from vault.decrypted_secrets
      where name='futbeat_youtube_api_key'
      limit 1
    $body$
  $sql$;

  execute $sql$
    create or replace function futbeat_private.futbeat_store_youtube_api_key(
      p_secret text
    ) returns jsonb
    language plpgsql
    security definer
    set search_path=''
    as $body$
    declare
      v_value text:=btrim(coalesce(p_secret,''));
      v_id uuid;
    begin
      if length(v_value)<20 or length(v_value)>500 then
        raise exception 'Invalid YouTube API key';
      end if;

      select id into v_id
      from vault.secrets
      where name='futbeat_youtube_api_key'
      limit 1;

      if v_id is null then
        perform vault.create_secret(
          v_value,'futbeat_youtube_api_key',
          'YouTube Data API key for FutBeat official post-match videos'
        );
      else
        perform vault.update_secret(
          v_id,v_value,'futbeat_youtube_api_key',
          'YouTube Data API key for FutBeat official post-match videos'
        );
      end if;

      return jsonb_build_object('stored',true,'provider','youtube');
    end
    $body$
  $sql$;

  execute $sql$
    create or replace function public.futbeat_read_youtube_api_key()
    returns text
    language sql
    security definer
    set search_path=''
    as $body$
      select futbeat_private.futbeat_read_youtube_api_key()
    $body$
  $sql$;

  execute $sql$
    create or replace function public.futbeat_store_youtube_api_key(
      p_secret text
    ) returns jsonb
    language sql
    security definer
    set search_path=''
    as $body$
      select futbeat_private.futbeat_store_youtube_api_key(p_secret)
    $body$
  $sql$;

  execute 'revoke all on function futbeat_private.futbeat_read_youtube_api_key() from public,anon,authenticated';
  execute 'revoke all on function futbeat_private.futbeat_store_youtube_api_key(text) from public,anon,authenticated';
  execute 'revoke all on function public.futbeat_read_youtube_api_key() from public,anon,authenticated';
  execute 'revoke all on function public.futbeat_store_youtube_api_key(text) from public,anon,authenticated';

  execute 'grant execute on function futbeat_private.futbeat_read_youtube_api_key() to service_role';
  execute 'grant execute on function futbeat_private.futbeat_store_youtube_api_key(text) to service_role';
  execute 'grant execute on function public.futbeat_read_youtube_api_key() to service_role';
  execute 'grant execute on function public.futbeat_store_youtube_api_key(text) to service_role';
end
$vault$;

revoke all on function
  futbeat_private.futbeat_register_youtube_channel(text,text,text,text,text),
  public.futbeat_register_youtube_channel(text,text,text,text,text),
  futbeat_private.futbeat_video_plan(integer),
  public.futbeat_video_plan(integer),
  futbeat_private.futbeat_reserve_youtube_search_call(text,text,text),
  public.futbeat_reserve_youtube_search_call(text,text,text),
  futbeat_private.futbeat_store_youtube_search_result(text,text,timestamptz,jsonb),
  public.futbeat_store_youtube_search_result(text,text,timestamptz,jsonb),
  public.futbeat_read_match_videos(text)
from public,anon,authenticated;

grant execute on function
  futbeat_private.futbeat_register_youtube_channel(text,text,text,text,text),
  public.futbeat_register_youtube_channel(text,text,text,text,text),
  futbeat_private.futbeat_video_plan(integer),
  public.futbeat_video_plan(integer),
  futbeat_private.futbeat_reserve_youtube_search_call(text,text,text),
  public.futbeat_reserve_youtube_search_call(text,text,text),
  futbeat_private.futbeat_store_youtube_search_result(text,text,timestamptz,jsonb),
  public.futbeat_store_youtube_search_result(text,text,timestamptz,jsonb),
  public.futbeat_read_match_videos(text)
to service_role;

notify pgrst,'reload schema';
