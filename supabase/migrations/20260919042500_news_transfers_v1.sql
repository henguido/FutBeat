-- News + roster-change transfers v1.
-- NewsData is optional: no call is made until a key is provisioned in Vault.
-- Transfer rows represent provider-confirmed roster changes, not fees/contracts.

create table if not exists futbeat_private.news_articles (
  id text primary key,
  provider text not null,
  external_id text not null,
  title text not null,
  description text,
  url text not null,
  source_name text not null,
  source_url text,
  published_at timestamptz not null,
  language text,
  fetched_at timestamptz not null default now(),
  unique(provider,external_id)
);

create table if not exists futbeat_private.news_subjects (
  article_id text not null
    references futbeat_private.news_articles(id) on delete cascade,
  subject_type text not null
    check(subject_type in ('team','player','competition')),
  subject_id text not null
    references futbeat_private.entities(id) on delete cascade,
  matched_at timestamptz not null default now(),
  primary key(article_id,subject_type,subject_id)
);

create table if not exists futbeat_private.news_subject_coverage (
  subject_type text not null
    check(subject_type in ('team','player','competition')),
  subject_id text not null
    references futbeat_private.entities(id) on delete cascade,
  fetched_at timestamptz not null,
  last_query text not null,
  article_count integer not null default 0 check(article_count>=0),
  primary key(subject_type,subject_id)
);

create table if not exists futbeat_private.transfer_events (
  id bigint generated always as identity primary key,
  player_id text not null
    references futbeat_private.entities(id),
  from_team_id text not null
    references futbeat_private.entities(id),
  to_team_id text not null
    references futbeat_private.entities(id),
  detected_at timestamptz not null,
  detected_period date not null,
  provider text not null,
  status text not null check(status in ('ROSTER_CHANGE')),
  source_label text not null,
  check(from_team_id<>to_team_id),
  unique(player_id,from_team_id,to_team_id,detected_period)
);

create index if not exists news_articles_published_idx
  on futbeat_private.news_articles(published_at desc);
create index if not exists news_subjects_subject_idx
  on futbeat_private.news_subjects(subject_type,subject_id,matched_at desc);
create index if not exists transfer_events_player_idx
  on futbeat_private.transfer_events(player_id,detected_at desc);
create index if not exists transfer_events_from_idx
  on futbeat_private.transfer_events(from_team_id,detected_at desc);
create index if not exists transfer_events_to_idx
  on futbeat_private.transfer_events(to_team_id,detected_at desc);

alter table futbeat_private.news_articles enable row level security;
alter table futbeat_private.news_subjects enable row level security;
alter table futbeat_private.news_subject_coverage enable row level security;
alter table futbeat_private.transfer_events enable row level security;

revoke all on
  futbeat_private.news_articles,
  futbeat_private.news_subjects,
  futbeat_private.news_subject_coverage,
  futbeat_private.transfer_events
from public,anon,authenticated;

grant select,insert,update,delete on
  futbeat_private.news_articles,
  futbeat_private.news_subjects,
  futbeat_private.news_subject_coverage,
  futbeat_private.transfer_events
to service_role;

create or replace function futbeat_private.futbeat_news_plan(
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
    raise exception 'Invalid news plan limit';
  end if;

  with candidates as (
    select
      ci.subject_type,
      futbeat_private.futbeat_resolve_entity_id(
        ci.subject_type,ci.subject_id
      ) as subject_id,
      ci.priority_score,
      case
        when ci.explicit_followers>0 then 'follow'
        else 'temporary'
      end as reason
    from futbeat_private.coverage_interests ci
    where ci.subject_type in ('team','player','competition')

    union all

    select
      'team',
      futbeat_private.futbeat_resolve_entity_id('team',t.id),
      50000,
      'costa_rica'
    from futbeat_private.entities t
    join futbeat_private.entities c
      on c.id=t.payload->>'competitionId'
     and c.kind='competition'
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
  due as (
    select
      r.subject_type,
      r.subject_id,
      r.priority_score,
      r.reason,
      cov.fetched_at,
      e.payload->>'name' as name,
      coalesce(e.payload->>'country','') as country
    from ranked r
    join futbeat_private.entities e
      on e.id=r.subject_id and e.kind=r.subject_type
    left join futbeat_private.news_subject_coverage cov
      on cov.subject_type=r.subject_type
     and cov.subject_id=r.subject_id
    where cov.fetched_at is null
       or cov.fetched_at<now()-interval '6 hours'
    order by
      r.priority_score desc,
      cov.fetched_at nulls first,
      r.subject_type,
      r.subject_id
    limit p_limit
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'subjectType',subject_type,
        'subjectId',subject_id,
        'name',name,
        'country',country,
        'query',
        left(
          case
            when subject_type='competition' and nullif(country,'') is not null
              then name||' '||country
            else name
          end,
          90
        ),
        'priority',priority_score,
        'reason',reason,
        'lastFetchedAt',fetched_at
      )
      order by priority_score desc,fetched_at nulls first,subject_type,subject_id
    ),
    '[]'::jsonb
  )
  into result
  from due;

  return result;
end
$$;

create or replace function public.futbeat_news_plan(
  p_limit integer default 1
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_news_plan(p_limit)
$$;

create or replace function futbeat_private.futbeat_reserve_newsdata_call(
  p_subject_type text,
  p_subject_id text,
  p_query text,
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
  v_last timestamptz;
  v_id bigint;
  v_retry integer;
begin
  if p_subject_type not in ('team','player','competition')
     or nullif(p_subject_id,'') is null
     or nullif(btrim(p_query),'') is null
     or length(p_query)>100
     or nullif(btrim(p_trigger_source),'') is null
     or not exists(
       select 1
       from futbeat_private.entities
       where id=p_subject_id and kind=p_subject_type
     )
  then
    raise exception 'Invalid NewsData reservation';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('futbeat-provider-quota:newsdata:'||v_day_start::date::text)
  );

  select count(*)::integer,max(reserved_at)
  into v_used,v_last
  from futbeat_private.provider_call_ledger
  where provider='newsdata'
    and call_kind='news'
    and reserved_at>=v_day_start
    and reserved_at<v_day_start+interval '1 day';

  if v_used>=120 then
    return jsonb_build_object(
      'allowed',false,'reason','news_daily_limit',
      'usedToday',v_used,'limit',120
    );
  end if;

  if v_last is not null and v_last>now()-interval '10 minutes' then
    v_retry:=greatest(
      1,
      ceil(extract(epoch from (
        v_last+interval '10 minutes'-now()
      )))::integer
    );
    return jsonb_build_object(
      'allowed',false,'reason','min_interval',
      'usedToday',v_used,'limit',120,
      'retryAfterSeconds',v_retry
    );
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at,metadata
  )
  values(
    'newsdata','news',left(p_trigger_source,40),now(),
    jsonb_build_object(
      'subjectType',p_subject_type,
      'subjectId',p_subject_id,
      'query',p_query
    )
  )
  returning id into v_id;

  return jsonb_build_object(
    'allowed',true,
    'reservationId',v_id,
    'usedToday',v_used+1,
    'limit',120,
    'subjectType',p_subject_type,
    'subjectId',p_subject_id,
    'query',p_query
  );
end
$$;

create or replace function public.futbeat_reserve_newsdata_call(
  p_subject_type text,
  p_subject_id text,
  p_query text,
  p_trigger_source text default 'supabase-cron'
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_reserve_newsdata_call(
    p_subject_type,p_subject_id,p_query,p_trigger_source
  )
$$;

create or replace function futbeat_private.futbeat_store_news_batch(
  p_subject_type text,
  p_subject_id text,
  p_received_at timestamptz,
  p_query text,
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
  if p_subject_type not in ('team','player','competition')
     or nullif(p_subject_id,'') is null
     or p_received_at is null
     or nullif(btrim(p_query),'') is null
     or length(p_query)>100
     or jsonb_typeof(p_articles)<>'array'
     or jsonb_array_length(p_articles)>20
     or not exists(
       select 1 from futbeat_private.entities
       where id=p_subject_id and kind=p_subject_type
     )
  then
    raise exception 'Invalid NewsData batch';
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
       or v_published<now()-interval '60 days'
    then
      continue;
    end if;

    v_id:='newsdata:'||left(v_external,200);

    insert into futbeat_private.news_articles(
      id,provider,external_id,title,description,url,
      source_name,source_url,published_at,language,fetched_at
    )
    values(
      v_id,'newsdata',left(v_external,200),left(v_title,500),
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

    select id into v_id
    from futbeat_private.news_articles
    where provider='newsdata' and external_id=left(v_external,200);

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
  values(p_subject_type,p_subject_id,p_received_at,left(p_query,100),v_count)
  on conflict(subject_type,subject_id) do update set
    fetched_at=excluded.fetched_at,
    last_query=excluded.last_query,
    article_count=excluded.article_count;

  delete from futbeat_private.news_articles
  where published_at<now()-interval '35 days';

  return jsonb_build_object(
    'subjectType',p_subject_type,
    'subjectId',p_subject_id,
    'articles',v_count,
    'fetchedAt',p_received_at
  );
end
$$;

create or replace function public.futbeat_store_news_batch(
  p_subject_type text,
  p_subject_id text,
  p_received_at timestamptz,
  p_query text,
  p_articles jsonb
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_store_news_batch(
    p_subject_type,p_subject_id,p_received_at,p_query,p_articles
  )
$$;

create or replace function futbeat_private.futbeat_store_team_squad(
  p_team_id text,
  p_provider text,
  p_received_at timestamptz,
  p_players jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  player_count integer;
begin
  if p_provider<>'goal_api'
     or jsonb_typeof(p_players)<>'array'
     or jsonb_array_length(p_players)>100
     or not exists(
       select 1
       from futbeat_private.entities
       where id=p_team_id and kind='team'
     )
  then
    raise exception 'Invalid team squad payload';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_players) p
    where nullif(p->>'id','') is null
       or p->>'teamId'<>p_team_id
       or p->'provenance'->>'source'<>'GOAL API'
  ) then
    raise exception 'Invalid player entity';
  end if;

  insert into futbeat_private.transfer_events(
    player_id,from_team_id,to_team_id,detected_at,detected_period,
    provider,status,source_label
  )
  select
    p->>'id',
    futbeat_private.futbeat_resolve_entity_id(
      'team',existing.payload->>'teamId'
    ),
    p_team_id,
    p_received_at,
    date_trunc('month',p_received_at)::date,
    'goal_api',
    'ROSTER_CHANGE',
    'GOAL API · plantilla de equipo'
  from jsonb_array_elements(p_players) p
  join futbeat_private.entities existing
    on existing.id=p->>'id' and existing.kind='player'
  where nullif(existing.payload->>'teamId','') is not null
    and existing.payload->'provenance'->>'source'='GOAL API'
    and futbeat_private.futbeat_resolve_entity_id(
      'team',existing.payload->>'teamId'
    )<>p_team_id
    and exists(
      select 1 from futbeat_private.entities old_team
      where old_team.id=futbeat_private.futbeat_resolve_entity_id(
        'team',existing.payload->>'teamId'
      )
        and old_team.kind='team'
    )
  on conflict(player_id,from_team_id,to_team_id,detected_period)
  do nothing;

  -- A canonical player can belong to only one current GOAL squad. Remove the
  -- previous membership immediately instead of waiting for that team's refresh.
  delete from futbeat_private.team_squad_members sm
  using jsonb_array_elements(p_players) p
  where sm.player_id=p->>'id'
    and sm.provider=p_provider
    and sm.team_id<>p_team_id;

  insert into futbeat_private.entities as e(id,kind,payload)
  select p->>'id','player',p
  from jsonb_array_elements(p_players) p
  on conflict(id) do update
    set payload=excluded.payload
    where e.kind='player'
      and e.payload is distinct from excluded.payload;

  delete from futbeat_private.team_squad_members
   where team_id=p_team_id
     and provider=p_provider;

  insert into futbeat_private.team_squad_members(
    team_id,player_id,provider,updated_at
  )
  select p_team_id,p->>'id',p_provider,p_received_at
  from jsonb_array_elements(p_players) p
  on conflict(team_id,player_id) do update set
    provider=excluded.provider,
    updated_at=excluded.updated_at;

  player_count:=jsonb_array_length(p_players);

  insert into futbeat_private.team_detail_coverage(
    team_id,provider,fetched_at,player_count
  )
  values(p_team_id,p_provider,p_received_at,player_count)
  on conflict(team_id) do update set
    provider=excluded.provider,
    fetched_at=excluded.fetched_at,
    player_count=excluded.player_count;

  return jsonb_build_object(
    'teamId',p_team_id,
    'players',player_count,
    'fetchedAt',p_received_at
  );
end
$$;

create or replace function public.futbeat_store_team_squad(
  p_team_id text,
  p_provider text,
  p_received_at timestamptz,
  p_players jsonb
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_store_team_squad(
    p_team_id,p_provider,p_received_at,p_players
  )
$$;

create or replace function public.futbeat_read_entity_detail(
  p_type text,
  p_id text
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  with request as (
    select futbeat_private.futbeat_resolve_entity_id(
      p_type,p_id
    ) as resolved_id
  ),
  base as (
    select
      futbeat_private.futbeat_read_entity_detail(
        p_type,request.resolved_id
      ) as snapshot,
      request.resolved_id
    from request
  ),
  competition_ids as (
    select distinct value->>'competitionId' as id
    from base
    cross join lateral jsonb_array_elements(
      coalesce(base.snapshot->'matches','[]'::jsonb)
    )
    where nullif(value->>'competitionId','') is not null

    union

    select distinct value->>'id'
    from base
    cross join lateral jsonb_array_elements(
      coalesce(base.snapshot->'competitions','[]'::jsonb)
    )
    where nullif(value->>'id','') is not null

    union

    select resolved_id from base where p_type='competition'
  ),
  tables as (
    select coalesce(jsonb_agg(item),'[]'::jsonb) as value
    from (
      select legacy.value as item
      from base
      cross join lateral jsonb_array_elements(
        coalesce(base.snapshot->'standings','[]'::jsonb)
      ) legacy
      where legacy.value->>'competitionId' in (
        select id from competition_ids where id is not null
      )
      and not exists(
        select 1
        from futbeat_private.standings_cache sc
        where sc.competition_id=legacy.value->>'competitionId'
      )

      union all

      select futbeat_private.futbeat_apply_provisional_standings(
        sc.table_payload,
        sc.fetched_at
      )
      from futbeat_private.standings_cache sc
      where sc.competition_id in (
        select id from competition_ids where id is not null
      )
    ) selected_tables(item)
  ),
  news_rows as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id',x.id,
          'title',x.title,
          'description',x.description,
          'url',x.url,
          'sourceName',x.source_name,
          'sourceUrl',x.source_url,
          'publishedAt',x.published_at,
          'language',x.language
        )
        order by x.published_at desc,x.id
      ),
      '[]'::jsonb
    ) as value
    from (
      select a.*
      from base
      join futbeat_private.news_subjects ns
        on ns.subject_type=p_type
       and futbeat_private.futbeat_resolve_entity_id(
         ns.subject_type,ns.subject_id
       )=base.resolved_id
      join futbeat_private.news_articles a
        on a.id=ns.article_id
      where a.published_at>=now()-interval '30 days'
      order by a.published_at desc,a.id
      limit 30
    ) x
  ),
  transfer_rows as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id',x.id,
          'playerId',x.player_id,
          'playerName',x.player_name,
          'fromTeamId',x.from_team_id,
          'fromTeamName',x.from_team_name,
          'toTeamId',x.to_team_id,
          'toTeamName',x.to_team_name,
          'detectedAt',x.detected_at,
          'status',x.status,
          'source',x.source_label
        )
        order by x.detected_at desc,x.id desc
      ),
      '[]'::jsonb
    ) as value
    from (
      select
        tr.id,tr.player_id,tr.from_team_id,tr.to_team_id,
        tr.detected_at,tr.status,tr.source_label,
        p.payload->>'name' as player_name,
        ft.payload->>'name' as from_team_name,
        tt.payload->>'name' as to_team_name
      from base
      join futbeat_private.transfer_events tr on (
        (p_type='player' and tr.player_id=base.resolved_id)
        or
        (
          p_type='team'
          and (
            tr.from_team_id=base.resolved_id
            or tr.to_team_id=base.resolved_id
          )
        )
        or
        (
          p_type='competition'
          and (
            exists(
              select 1 from futbeat_private.entities ct
              where ct.id=tr.from_team_id
                and ct.kind='team'
                and ct.payload->>'competitionId'=base.resolved_id
            )
            or exists(
              select 1 from futbeat_private.entities ct
              where ct.id=tr.to_team_id
                and ct.kind='team'
                and ct.payload->>'competitionId'=base.resolved_id
            )
          )
        )
      )
      join futbeat_private.entities p
        on p.id=tr.player_id and p.kind='player'
      join futbeat_private.entities ft
        on ft.id=tr.from_team_id and ft.kind='team'
      join futbeat_private.entities tt
        on tt.id=tr.to_team_id and tt.kind='team'
      order by tr.detected_at desc,tr.id desc
      limit 50
    ) x
  ),
  assembled as (
    select case
      when base.snapshot is null then null
      else (
        base.snapshot-'standings'-'news'-'transfers'
      ) || jsonb_build_object(
        'standings',tables.value,
        'news',news_rows.value,
        'transfers',transfer_rows.value
      )
    end as snapshot
    from base,tables,news_rows,transfer_rows
  )
  select case
    when snapshot is null then null
    else futbeat_private.futbeat_apply_entity_redirects_snapshot(snapshot)
  end
  from assembled
$$;

do $vault$
begin
  if to_regnamespace('vault') is null then
    return;
  end if;

  execute $ddl$
    create or replace function futbeat_private.futbeat_read_newsdata_secret()
    returns text language sql stable security definer set search_path=''
    as $fn$
      select decrypted_secret
      from vault.decrypted_secrets
      where name='futbeat_newsdata_api_key'
      order by updated_at desc nulls last,created_at desc
      limit 1
    $fn$
  $ddl$;

  execute $ddl$
    create or replace function futbeat_private.futbeat_store_newsdata_secret(
      p_secret text
    ) returns jsonb language plpgsql security definer set search_path=''
    as $fn$
    declare
      v_value text:=btrim(coalesce(p_secret,''));
      v_id uuid;
    begin
      if length(v_value)<10 or length(v_value)>1024 then
        raise exception 'Invalid NewsData API key';
      end if;

      select id into v_id
      from vault.secrets
      where name='futbeat_newsdata_api_key'
      order by updated_at desc nulls last,created_at desc
      limit 1;

      if v_id is null then
        perform vault.create_secret(
          v_value,'futbeat_newsdata_api_key',
          'NewsData.io key for FutBeat news cache'
        );
      else
        perform vault.update_secret(
          v_id,v_value,'futbeat_newsdata_api_key',
          'NewsData.io key for FutBeat news cache'
        );
      end if;

      return jsonb_build_object('stored',true,'provider','newsdata');
    end
    $fn$
  $ddl$;

  execute $ddl$
    create or replace function public.futbeat_read_newsdata_secret()
    returns text language sql stable security definer set search_path=''
    as $fn$
      select futbeat_private.futbeat_read_newsdata_secret()
    $fn$
  $ddl$;

  execute $ddl$
    create or replace function public.futbeat_store_newsdata_secret(p_secret text)
    returns jsonb language sql security definer set search_path=''
    as $fn$
      select futbeat_private.futbeat_store_newsdata_secret(p_secret)
    $fn$
  $ddl$;

  execute 'revoke all on function futbeat_private.futbeat_read_newsdata_secret() from public,anon,authenticated';
  execute 'revoke all on function futbeat_private.futbeat_store_newsdata_secret(text) from public,anon,authenticated';
  execute 'revoke all on function public.futbeat_read_newsdata_secret() from public,anon,authenticated';
  execute 'revoke all on function public.futbeat_store_newsdata_secret(text) from public,anon,authenticated';

  execute 'grant execute on function futbeat_private.futbeat_read_newsdata_secret() to service_role';
  execute 'grant execute on function futbeat_private.futbeat_store_newsdata_secret(text) to service_role';
  execute 'grant execute on function public.futbeat_read_newsdata_secret() to service_role';
  execute 'grant execute on function public.futbeat_store_newsdata_secret(text) to service_role';
end
$vault$;

revoke all on function
  futbeat_private.futbeat_news_plan(integer),
  public.futbeat_news_plan(integer),
  futbeat_private.futbeat_reserve_newsdata_call(text,text,text,text),
  public.futbeat_reserve_newsdata_call(text,text,text,text),
  futbeat_private.futbeat_store_news_batch(text,text,timestamptz,text,jsonb),
  public.futbeat_store_news_batch(text,text,timestamptz,text,jsonb),
  futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb),
  public.futbeat_store_team_squad(text,text,timestamptz,jsonb),
  public.futbeat_read_entity_detail(text,text)
from public,anon,authenticated;

grant execute on function
  futbeat_private.futbeat_news_plan(integer),
  public.futbeat_news_plan(integer),
  futbeat_private.futbeat_reserve_newsdata_call(text,text,text,text),
  public.futbeat_reserve_newsdata_call(text,text,text,text),
  futbeat_private.futbeat_store_news_batch(text,text,timestamptz,text,jsonb),
  public.futbeat_store_news_batch(text,text,timestamptz,text,jsonb),
  futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb),
  public.futbeat_store_team_squad(text,text,timestamptz,jsonb),
  public.futbeat_read_entity_detail(text,text)
to service_role;

notify pgrst,'reload schema';
