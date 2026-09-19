-- GOAL-native news v2.
-- Reuse the already provisioned GOAL API key instead of requiring a second
-- NewsData secret. One low-priority team/competition news call is allowed at a
-- bounded cadence and remains behind the LIVE/detail/squad quota reserve.

create or replace function futbeat_private.futbeat_goal_news_plan(
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
  if p_limit<1 or p_limit>10 then
    raise exception 'Invalid GOAL news plan limit';
  end if;

  with recent_team_ids as (
    select external_id,max(received_at) as last_seen_at
    from (
      select
        coalesce(raw_payload#>>'{homeTeam,id}',raw_payload->>'homeTeamId') as external_id,
        received_at
      from futbeat_private.provider_observations
      where provider='goal_api'
        and received_at>=now()-interval '180 days'
      union all
      select
        coalesce(raw_payload#>>'{awayTeam,id}',raw_payload->>'awayTeamId'),
        received_at
      from futbeat_private.provider_observations
      where provider='goal_api'
        and received_at>=now()-interval '180 days'
    ) observed
    where nullif(external_id,'') is not null
    group by external_id
  ),
  candidates as (
    select
      ci.subject_type,
      futbeat_private.futbeat_resolve_entity_id(ci.subject_type,ci.subject_id) as subject_id,
      ci.priority_score,
      case when ci.explicit_followers>0 then 'follow' else 'temporary' end as reason
    from futbeat_private.coverage_interests ci
    where ci.subject_type in ('team','competition')

    union all

    select
      'team',
      futbeat_private.futbeat_resolve_entity_id('team',t.id),
      50000,
      'costa_rica'
    from futbeat_private.entities t
    join futbeat_private.entities c
      on c.id=t.payload->>'competitionId' and c.kind='competition'
    where t.kind='team'
      and lower(coalesce(c.payload->>'country','')) in ('costa rica','cr')

    union all

    select
      'competition',
      futbeat_private.futbeat_resolve_entity_id('competition',c.id),
      50000,
      'costa_rica'
    from futbeat_private.entities c
    where c.kind='competition'
      and lower(coalesce(c.payload->>'country','')) in ('costa rica','cr')
  ),
  ranked as (
    select
      subject_type,
      subject_id,
      max(priority_score) as priority_score,
      min(reason) as reason
    from candidates
    group by subject_type,subject_id
  ),
  mapped as (
    select
      r.subject_type,
      r.subject_id,
      r.priority_score,
      r.reason,
      cov.fetched_at,
      e.payload->>'name' as name,
      coalesce(e.payload->>'country','') as country,
      selected.external_id
    from ranked r
    join futbeat_private.entities e
      on e.id=r.subject_id and e.kind=r.subject_type
    left join futbeat_private.news_subject_coverage cov
      on cov.subject_type=r.subject_type and cov.subject_id=r.subject_id
    join lateral (
      select pe.external_id
      from futbeat_private.provider_entities pe
      left join recent_team_ids recent
        on r.subject_type='team' and recent.external_id=pe.external_id
      where pe.provider='goal_api'
        and pe.kind=r.subject_type
        and pe.canonical_id=r.subject_id
      order by
        case when r.subject_type='team' then recent.last_seen_at end desc nulls last,
        pe.external_id desc
      limit 1
    ) selected on true
    where cov.fetched_at is null
       or cov.fetched_at<now()-interval '12 hours'
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'subjectType',subject_type,
        'subjectId',subject_id,
        'externalId',external_id,
        'name',name,
        'country',country,
        'priority',priority_score,
        'reason',reason,
        'lastFetchedAt',fetched_at
      )
      order by priority_score desc,fetched_at nulls first,subject_type,subject_id
    ),
    '[]'::jsonb
  )
  into result
  from (
    select *
    from mapped
    order by priority_score desc,fetched_at nulls first,subject_type,subject_id
    limit p_limit
  ) due;

  return result;
end
$$;

create or replace function public.futbeat_goal_news_plan(
  p_limit integer default 1
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_goal_news_plan(p_limit)
$$;

create or replace function futbeat_private.futbeat_reserve_goal_news_call(
  p_subject_type text,
  p_subject_id text,
  p_external_id text,
  p_trigger_source text default 'supabase-cron'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_day_start timestamptz :=
    date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  v_remaining integer;
  v_used integer;
  v_last timestamptz;
  v_id bigint;
  v_retry integer;
begin
  if p_subject_type not in ('team','competition')
     or nullif(p_subject_id,'') is null
     or nullif(p_external_id,'') is null
     or nullif(btrim(p_trigger_source),'') is null
     or not exists(
       select 1
       from futbeat_private.provider_entities pe
       where pe.provider='goal_api'
         and pe.kind=p_subject_type
         and pe.external_id=p_external_id
         and pe.canonical_id=p_subject_id
     )
  then
    raise exception 'Invalid GOAL news reservation';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('futbeat-provider-quota:goal_api:'||v_day_start::date::text)
  );

  select provider_remaining
  into v_remaining
  from futbeat_private.provider_call_ledger
  where provider='goal_api'
    and provider_remaining is not null
    and reserved_at>=v_day_start
    and reserved_at<v_day_start+interval '1 day'
  order by coalesce(completed_at,reserved_at) desc,id desc
  limit 1;

  select count(*)::integer,max(reserved_at)
  into v_used,v_last
  from futbeat_private.provider_call_ledger
  where provider='goal_api'
    and call_kind='news-goal'
    and reserved_at>=v_day_start
    and reserved_at<v_day_start+interval '1 day';

  if v_remaining is not null and v_remaining<=350 then
    return jsonb_build_object(
      'allowed',false,'reason','provider_remaining_reserve',
      'providerRemaining',v_remaining,'reserve',350,
      'usedToday',v_used,'limit',24
    );
  end if;

  if v_used>=24 then
    return jsonb_build_object(
      'allowed',false,'reason','news_daily_limit',
      'providerRemaining',v_remaining,'reserve',350,
      'usedToday',v_used,'limit',24
    );
  end if;

  if v_last is not null and v_last>now()-interval '45 minutes' then
    v_retry:=greatest(
      1,
      ceil(extract(epoch from (
        v_last+interval '45 minutes'-now()
      )))::integer
    );
    return jsonb_build_object(
      'allowed',false,'reason','min_interval',
      'providerRemaining',v_remaining,'reserve',350,
      'usedToday',v_used,'limit',24,
      'retryAfterSeconds',v_retry
    );
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at,metadata
  )
  values(
    'goal_api','news-goal',left(p_trigger_source,40),now(),
    jsonb_build_object(
      'subjectType',p_subject_type,
      'subjectId',p_subject_id,
      'externalId',p_external_id
    )
  )
  returning id into v_id;

  return jsonb_build_object(
    'allowed',true,
    'reservationId',v_id,
    'subjectType',p_subject_type,
    'subjectId',p_subject_id,
    'externalId',p_external_id,
    'providerRemaining',v_remaining,
    'reserve',350,
    'usedToday',v_used+1,
    'limit',24
  );
end
$$;

create or replace function public.futbeat_reserve_goal_news_call(
  p_subject_type text,
  p_subject_id text,
  p_external_id text,
  p_trigger_source text default 'supabase-cron'
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_reserve_goal_news_call(
    p_subject_type,p_subject_id,p_external_id,p_trigger_source
  )
$$;

create or replace function futbeat_private.futbeat_store_goal_news_batch(
  p_subject_type text,
  p_subject_id text,
  p_received_at timestamptz,
  p_external_id text,
  p_articles jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  item jsonb;
  v_external text;
  v_id text;
  v_title text;
  v_url text;
  v_source text;
  v_source_url text;
  v_description text;
  v_language text;
  v_published timestamptz;
  v_count integer:=0;
begin
  if p_subject_type not in ('team','competition')
     or p_received_at is null
     or jsonb_typeof(p_articles)<>'array'
     or jsonb_array_length(p_articles)>20
     or not exists(
       select 1
       from futbeat_private.provider_entities pe
       where pe.provider='goal_api'
         and pe.kind=p_subject_type
         and pe.external_id=p_external_id
         and pe.canonical_id=p_subject_id
     )
  then
    raise exception 'Invalid GOAL news batch';
  end if;

  for item in select value from jsonb_array_elements(p_articles)
  loop
    v_external:=nullif(btrim(coalesce(item->>'id','')),'');
    v_title:=nullif(btrim(coalesce(item->>'title','')),'');
    v_url:=nullif(btrim(coalesce(item->>'url','')),'');
    v_source:=nullif(btrim(coalesce(item->>'sourceName','')),'');
    v_source_url:=nullif(btrim(coalesce(item->>'sourceUrl','')),'');
    v_description:=nullif(btrim(coalesce(item->>'description','')),'');
    v_language:=nullif(btrim(coalesce(item->>'language','')),'');
    begin
      v_published:=nullif(item->>'publishedAt','')::timestamptz;
    exception when others then
      v_published:=null;
    end;

    if v_external is null
       or v_title is null
       or v_url is null
       or v_source is null
       or v_published is null
       or v_url !~ '^https://'
       or (v_source_url is not null and v_source_url !~ '^https://')
       or v_published>now()+interval '1 day'
       or v_published<now()-interval '35 days'
    then
      continue;
    end if;

    v_id:='goal_api:'||left(v_external,200);

    insert into futbeat_private.news_articles(
      id,provider,external_id,title,description,url,
      source_name,source_url,published_at,language,fetched_at
    )
    values(
      v_id,'goal_api',left(v_external,200),left(v_title,500),
      left(v_description,2000),left(v_url,2000),
      left(v_source,300),left(v_source_url,1000),
      v_published,left(v_language,40),p_received_at
    )
    on conflict(provider,external_id) do update set
      title=excluded.title,
      description=excluded.description,
      url=excluded.url,
      source_name=excluded.source_name,
      source_url=excluded.source_url,
      published_at=excluded.published_at,
      language=excluded.language,
      fetched_at=excluded.fetched_at;

    insert into futbeat_private.news_subjects(
      article_id,subject_type,subject_id,matched_at
    )
    values(v_id,p_subject_type,p_subject_id,p_received_at)
    on conflict(article_id,subject_type,subject_id) do update
      set matched_at=excluded.matched_at;

    v_count:=v_count+1;
  end loop;

  insert into futbeat_private.news_subject_coverage(
    subject_type,subject_id,fetched_at,last_query,article_count
  )
  values(
    p_subject_type,p_subject_id,p_received_at,
    'GOAL API:'||left(p_external_id,80),v_count
  )
  on conflict(subject_type,subject_id) do update set
    fetched_at=excluded.fetched_at,
    last_query=excluded.last_query,
    article_count=excluded.article_count;

  delete from futbeat_private.news_articles
  where published_at<now()-interval '35 days';

  return jsonb_build_object(
    'subjectType',p_subject_type,
    'subjectId',p_subject_id,
    'externalId',p_external_id,
    'articles',v_count,
    'fetchedAt',p_received_at
  );
end
$$;

create or replace function public.futbeat_store_goal_news_batch(
  p_subject_type text,
  p_subject_id text,
  p_received_at timestamptz,
  p_external_id text,
  p_articles jsonb
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_store_goal_news_batch(
    p_subject_type,p_subject_id,p_received_at,p_external_id,p_articles
  )
$$;

revoke all on function
  public.futbeat_goal_news_plan(integer),
  public.futbeat_reserve_goal_news_call(text,text,text,text),
  public.futbeat_store_goal_news_batch(text,text,timestamptz,text,jsonb)
from public,anon,authenticated;

grant execute on function
  public.futbeat_goal_news_plan(integer),
  public.futbeat_reserve_goal_news_call(text,text,text,text),
  public.futbeat_store_goal_news_batch(text,text,timestamptz,text,jsonb)
to service_role;

notify pgrst,'reload schema';
