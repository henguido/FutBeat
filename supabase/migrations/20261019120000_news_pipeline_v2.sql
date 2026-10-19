-- News pipeline v2 (#104): sources with rights, story clusters, no
-- redundant writes, its own budget. Additive: the v1 NewsData path
-- (futbeat_store_news_batch, futbeat_news_plan, the goal-live-sync
-- collector) is untouched and keeps working.
--
-- Evidence in v1 (reproduced locally, tests/news_pipeline_v2_store):
--   * every refresh rewrites every returned article (unconditional
--     ON CONFLICT DO UPDATE) and re-updates news_subjects.matched_at; that
--     UPDATE fires news_subject_push again for the same article;
--   * dedup is per provider id only: the same story from two providers or
--     two publishers is two cards and two notifications;
--   * no source role, rights, category or story state.
--
-- v2 model:
--   news_sources          publisher domain -> role + rights (snippet/image
--                         only once rights_reviewed_at is set).
--   news_provider_config  provider terms, enable flag, own daily budget.
--   news_feeds            publisher RSS/Atom feeds (conditional GET state).
--   news_collector_calls  the news budget/health ledger. Never shares the
--                         sports provider_call_ledger budget.
--   news_articles (+cols) one row per canonical URL (url_key), content_hash
--                         decides whether anything is written.
--   news_article_entities entity mentions of every member (no trigger).
--   news_clusters         one row per story; anchor = first member from an
--                         official or established source, set once.
--   news_subjects         (existing, push-triggering) receives ONLY the
--                         anchor's verified mentions, inserted once
--                         (DO NOTHING): one story = one push key, and an
--                         unverified-only story never notifies.
--
-- Nothing is enabled: every provider and feed ships disabled until its
-- terms are reviewed. No cron, push, quota-policy or GOAL change. Mobile
-- never calls a provider: it reads futbeat_read_news_feed through the API.

-- ---------------------------------------------------------------------------
-- Governance
-- ---------------------------------------------------------------------------

create table if not exists futbeat_private.news_sources (
  domain text primary key check(domain=lower(domain) and domain ~ '^[a-z0-9.-]+\.[a-z]{2,}$'),
  display_name text not null check(char_length(display_name) between 1 and 120),
  role text not null check(role in ('FIRST_PARTY_OFFICIAL','ESTABLISHED_MEDIA','AGGREGATOR','UNVERIFIED')),
  country_code text check(country_code is null or country_code ~ '^[A-Z]{2}$'),
  snippet_allowed boolean not null default false,
  max_snippet_chars integer not null default 0 check(max_snippet_chars between 0 and 300),
  image_allowed boolean not null default false,
  attribution_required boolean not null default true,
  rights_reviewed_at timestamptz,
  notes text,
  -- Rights are granted only by an explicit review.
  check((not snippet_allowed and not image_allowed) or rights_reviewed_at is not null)
);

create table if not exists futbeat_private.news_provider_config (
  provider text primary key check(provider ~ '^[a-z0-9_]{2,40}$'),
  enabled boolean not null default false,
  role text not null default 'DEVELOPMENT_ONLY'
    check(role in ('PRIMARY_DISCOVERY','SECONDARY_DISCOVERY','FALLBACK','DEVELOPMENT_ONLY')),
  production_allowed boolean not null default false,
  snippet_allowed boolean not null default false,
  image_allowed boolean not null default false,
  attribution_text text,
  daily_limit integer not null check(daily_limit between 0 and 10000),
  min_interval_seconds integer not null default 300 check(min_interval_seconds>=0),
  query_interval_hours integer not null default 6 check(query_interval_hours between 1 and 168),
  terms_reviewed_at timestamptz,
  notes text,
  check((not snippet_allowed and not image_allowed and not production_allowed) or terms_reviewed_at is not null)
);

create table if not exists futbeat_private.news_feeds (
  id text primary key check(id ~ '^[a-z0-9_-]{2,60}$'),
  provider text not null default 'rss' references futbeat_private.news_provider_config(provider),
  url text not null unique check(url ~ '^https://'),
  source_domain text not null references futbeat_private.news_sources(domain),
  cadence_minutes integer not null default 30 check(cadence_minutes>=15),
  enabled boolean not null default false,
  etag text,
  last_modified text,
  last_fetched_at timestamptz,
  last_status text,
  consecutive_failures integer not null default 0 check(consecutive_failures>=0),
  next_fetch_at timestamptz
);

create table if not exists futbeat_private.news_collector_calls (
  id bigint generated always as identity primary key,
  provider text not null references futbeat_private.news_provider_config(provider),
  target text not null,
  reserved_at timestamptz not null default now(),
  completed_at timestamptz,
  status text not null default 'RESERVED'
    check(status in ('RESERVED','SUCCEEDED','NOT_MODIFIED','FAILED')),
  http_status integer,
  items integer,
  inserted integer,
  updated integer,
  unchanged integer,
  error_code text
);
create index if not exists news_collector_calls_provider_idx
  on futbeat_private.news_collector_calls(provider,reserved_at desc);

create table if not exists futbeat_private.news_query_coverage (
  provider text not null references futbeat_private.news_provider_config(provider),
  subject_type text not null check(subject_type in ('team','player','competition')),
  subject_id text not null references futbeat_private.entities(id) on delete cascade,
  fetched_at timestamptz not null,
  article_count integer not null default 0,
  primary key(provider,subject_type,subject_id)
);

-- Seeds: roles from the #104 source research. Rights are NOT granted
-- (headline + link only) until each publisher's terms are reviewed.
insert into futbeat_private.news_sources(domain,display_name,role,country_code,notes) values
  ('fcrf.cr','FCRF','FIRST_PARTY_OFFICIAL','CR','Federation; ingestion method/terms pending'),
  ('saprissa.com','Deportivo Saprissa','FIRST_PARTY_OFFICIAL','CR','Club site; terms pending'),
  ('lda.cr','Liga Deportiva Alajuelense','FIRST_PARTY_OFFICIAL','CR','Club site; terms pending'),
  ('herediano.com','Club Sport Herediano','FIRST_PARTY_OFFICIAL','CR','Club site; terms pending'),
  ('cscartagines.com','Club Sport Cartaginés','FIRST_PARTY_OFFICIAL','CR','Club site; terms pending'),
  ('concacaf.com','Concacaf','FIRST_PARTY_OFFICIAL',null,'Confederation; terms pending'),
  ('fifa.com','FIFA','FIRST_PARTY_OFFICIAL',null,'Federation; terms pending'),
  ('teletica.com','Teletica','ESTABLISHED_MEDIA','CR','RSS available; terms/attribution pending'),
  ('nacion.com','La Nación','ESTABLISHED_MEDIA','CR','Link-out only; terms pending')
on conflict(domain) do nothing;

insert into futbeat_private.news_provider_config(provider,role,attribution_text,daily_limit,min_interval_seconds,query_interval_hours,notes) values
  ('currents','DEVELOPMENT_ONLY','Currents API',200,300,6,
   'Free tier 250/day advertised; terms require Currents attribution. Validate CR coverage before any role change.'),
  ('rss','DEVELOPMENT_ONLY',null,500,60,6,'Publisher feeds; each feed has its own cadence and enable flag.'),
  ('newsdata','FALLBACK',null,120,600,6,'v1 path (goal-live-sync) keeps its own reservation; listed for governance only.')
on conflict(provider) do nothing;

insert into futbeat_private.news_feeds(id,url,source_domain,cadence_minutes) values
  ('teletica-futbol','https://www.teletica.com/rss/feed/deportes/futbol','teletica.com',30)
on conflict(id) do nothing;

-- ---------------------------------------------------------------------------
-- Article model
-- ---------------------------------------------------------------------------

alter table futbeat_private.news_articles
  add column if not exists url_key text,
  add column if not exists source_domain text,
  add column if not exists source_role text,
  add column if not exists image_url text,
  add column if not exists category text,
  add column if not exists transfer_status text,
  add column if not exists cluster_id text,
  add column if not exists title_tokens text[],
  add column if not exists name_tokens text[],
  add column if not exists content_hash text,
  add column if not exists attribution jsonb,
  add column if not exists contract_version smallint,
  add column if not exists updated_at timestamptz;

create unique index if not exists news_articles_url_key_idx
  on futbeat_private.news_articles(url_key) where url_key is not null;
create index if not exists news_articles_cluster_idx
  on futbeat_private.news_articles(cluster_id,published_at) where cluster_id is not null;

create table if not exists futbeat_private.news_article_entities (
  article_id text not null references futbeat_private.news_articles(id) on delete cascade,
  subject_type text not null check(subject_type in ('team','player','competition')),
  subject_id text not null references futbeat_private.entities(id) on delete cascade,
  primary key(article_id,subject_type,subject_id)
);
create index if not exists news_article_entities_subject_idx
  on futbeat_private.news_article_entities(subject_type,subject_id);

create table if not exists futbeat_private.news_clusters (
  cluster_id text primary key,
  anchor_article_id text references futbeat_private.news_articles(id) on delete set null,
  category text not null,
  first_published_at timestamptz not null,
  last_published_at timestamptz not null,
  member_count integer not null default 0,
  story_state text not null default 'DEVELOPING' check(story_state in ('OFFICIAL','REPORT','DEVELOPING')),
  transfer_status text check(transfer_status is null or transfer_status in ('RUMOR','REPORT','CONFIRMED')),
  updated_at timestamptz not null default now()
);
create index if not exists news_clusters_recent_idx
  on futbeat_private.news_clusters(last_published_at desc);

alter table futbeat_private.news_sources enable row level security;
alter table futbeat_private.news_provider_config enable row level security;
alter table futbeat_private.news_feeds enable row level security;
alter table futbeat_private.news_collector_calls enable row level security;
alter table futbeat_private.news_query_coverage enable row level security;
alter table futbeat_private.news_article_entities enable row level security;
alter table futbeat_private.news_clusters enable row level security;
revoke all on futbeat_private.news_sources,futbeat_private.news_provider_config,
  futbeat_private.news_feeds,futbeat_private.news_collector_calls,
  futbeat_private.news_query_coverage,futbeat_private.news_article_entities,
  futbeat_private.news_clusters
  from public,anon,authenticated;

create or replace function futbeat_private.news_role_rank(p_role text)
returns integer language sql immutable set search_path='' as $$
  select case p_role when 'FIRST_PARTY_OFFICIAL' then 0 when 'ESTABLISHED_MEDIA' then 1
    when 'AGGREGATOR' then 2 else 3 end
$$;

-- The most specific source policy for a host (exact or parent domain).
create or replace function futbeat_private.news_source_for(p_host text)
returns futbeat_private.news_sources language sql stable set search_path='' as $$
  select s.* from futbeat_private.news_sources s
  where lower(p_host)=s.domain or lower(p_host) like '%.'||s.domain
  order by length(s.domain) desc limit 1
$$;

-- Story state and transfer status of a cluster from its members (mirrors
-- storyState in _shared/news_pipeline.ts): repetition never confirms.
create or replace function futbeat_private.refresh_news_cluster(p_cluster_id text)
returns void language plpgsql security definer set search_path='' as $$
declare
  v_count integer; v_first timestamptz; v_last timestamptz; v_official boolean; v_media boolean;
  v_transfer text; v_category text; v_state text; v_anchor text;
begin
  select count(*),min(published_at),max(published_at),
    bool_or(source_role='FIRST_PARTY_OFFICIAL'),bool_or(source_role='ESTABLISHED_MEDIA'),
    case when count(transfer_status)=0 then null
      when bool_or(transfer_status='CONFIRMED' and source_role='FIRST_PARTY_OFFICIAL') then 'CONFIRMED'
      when bool_or(transfer_status='REPORT') then 'REPORT' else 'RUMOR' end,
    (array_agg(category order by published_at,id))[1],
    (array_agg(id order by published_at,id) filter (
      where source_role in ('FIRST_PARTY_OFFICIAL','ESTABLISHED_MEDIA')))[1]
  into v_count,v_first,v_last,v_official,v_media,v_transfer,v_category,v_anchor
  from futbeat_private.news_articles where cluster_id=p_cluster_id;
  if v_count=0 then
    delete from futbeat_private.news_clusters where cluster_id=p_cluster_id;
    return;
  end if;
  v_state:=case when v_official then 'OFFICIAL' when v_media then 'REPORT' else 'DEVELOPING' end;
  insert into futbeat_private.news_clusters as c(cluster_id,anchor_article_id,category,
    first_published_at,last_published_at,member_count,story_state,transfer_status)
  values(p_cluster_id,v_anchor,coalesce(v_category,'GENERAL'),v_first,v_last,v_count,v_state,v_transfer)
  on conflict(cluster_id) do update set
    -- The anchor is set once (push key stability); never re-pointed.
    anchor_article_id=coalesce(c.anchor_article_id,excluded.anchor_article_id),
    category=excluded.category,
    first_published_at=excluded.first_published_at,
    last_published_at=excluded.last_published_at,
    member_count=excluded.member_count,
    story_state=excluded.story_state,
    transfer_status=excluded.transfer_status,
    updated_at=now()
  where (c.anchor_article_id is null and excluded.anchor_article_id is not null)
    or (c.category,c.first_published_at,c.last_published_at,c.member_count,c.story_state,c.transfer_status)
      is distinct from (excluded.category,excluded.first_published_at,excluded.last_published_at,
        excluded.member_count,excluded.story_state,excluded.transfer_status);
  -- The anchor carries the verified members' mentions (push-triggering
  -- table; inserted once, never updated).
  insert into futbeat_private.news_subjects(article_id,subject_type,subject_id,matched_at)
  select c.anchor_article_id,ae.subject_type,ae.subject_id,now()
  from futbeat_private.news_clusters c
  join futbeat_private.news_articles a on a.cluster_id=c.cluster_id
    and a.source_role in ('FIRST_PARTY_OFFICIAL','ESTABLISHED_MEDIA')
  join futbeat_private.news_article_entities ae on ae.article_id=a.id
  where c.cluster_id=p_cluster_id and c.anchor_article_id is not null
  on conflict(article_id,subject_type,subject_id) do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- Collector RPCs (service_role only)
-- ---------------------------------------------------------------------------

-- Reserve one call of the news budget. Never touches provider_call_ledger.
create or replace function futbeat_private.futbeat_reserve_news_call(p_provider text,p_target text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  cfg futbeat_private.news_provider_config;
  v_day timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  v_used integer; v_last timestamptz; v_id bigint;
begin
  if nullif(btrim(p_target),'') is null or length(p_target)>300 then
    raise exception 'Invalid news reservation';
  end if;
  select * into cfg from futbeat_private.news_provider_config where provider=p_provider;
  if not found or not cfg.enabled then
    return jsonb_build_object('allowed',false,'reason','provider_disabled');
  end if;
  perform pg_catalog.pg_advisory_xact_lock(hashtextextended('news-budget:'||p_provider,0));
  select count(*)::integer,max(reserved_at) into v_used,v_last
  from futbeat_private.news_collector_calls
  where provider=p_provider and reserved_at>=v_day;
  if v_used>=cfg.daily_limit then
    return jsonb_build_object('allowed',false,'reason','news_daily_limit','usedToday',v_used,'limit',cfg.daily_limit);
  end if;
  if v_last is not null and v_last>now()-make_interval(secs=>cfg.min_interval_seconds) then
    return jsonb_build_object('allowed',false,'reason','min_interval','usedToday',v_used);
  end if;
  insert into futbeat_private.news_collector_calls(provider,target)
  values(p_provider,left(p_target,300)) returning id into v_id;
  return jsonb_build_object('allowed',true,'reservationId',v_id,'usedToday',v_used+1,'limit',cfg.daily_limit);
end $$;

create or replace function futbeat_private.futbeat_complete_news_call(
  p_reservation_id bigint,p_status text,p_http_status integer,p_result jsonb,p_error_code text
) returns void language sql security definer set search_path='' as $$
  update futbeat_private.news_collector_calls set
    completed_at=now(),status=p_status,http_status=p_http_status,
    items=(p_result->>'items')::integer,inserted=(p_result->>'inserted')::integer,
    updated=(p_result->>'updated')::integer,unchanged=(p_result->>'unchanged')::integer,
    error_code=left(p_error_code,80)
  where id=p_reservation_id and status='RESERVED'
$$;

-- Policies the collector applies (the store re-checks them).
create or replace function futbeat_private.futbeat_news_policies(p_provider text)
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'provider',(select jsonb_build_object('provider',provider,'snippetAllowed',snippet_allowed,
       'imageAllowed',image_allowed,'attribution',attribution_text,'enabled',enabled)
       from futbeat_private.news_provider_config where provider=p_provider),
    'sources',coalesce((select jsonb_agg(jsonb_build_object('domain',domain,'displayName',display_name,
       'role',role,'snippetAllowed',snippet_allowed,'maxSnippetChars',max_snippet_chars,
       'imageAllowed',image_allowed) order by domain) from futbeat_private.news_sources),'[]'::jsonb))
$$;

-- Subjects due for a provider's query, highest interest first. Interest is
-- aggregated centrally (coverage_interests); never one query per user.
create or replace function futbeat_private.futbeat_news_query_plan(p_provider text,p_limit integer default 1)
returns jsonb language sql stable security definer set search_path='' as $$
  with cfg as (
    select * from futbeat_private.news_provider_config where provider=p_provider and enabled
  ), interests as (
    select ci.subject_type,futbeat_private.futbeat_resolve_entity_id(ci.subject_type,ci.subject_id) subject_id,
      ci.priority_score
    from futbeat_private.coverage_interests ci
    where ci.subject_type in ('team','player','competition')
  ), ranked as (
    select subject_type,subject_id,max(priority_score) priority from interests group by 1,2
  )
  select coalesce(jsonb_agg(x order by (x->>'priority')::numeric desc,x->>'subjectId'),'[]'::jsonb)
  from (
    select jsonb_build_object('subjectType',r.subject_type,'subjectId',r.subject_id,
      'query',left(e.payload->>'name',90),'priority',r.priority) x
    from ranked r cross join cfg
    join futbeat_private.entities e on e.id=r.subject_id and e.kind=r.subject_type
    left join futbeat_private.news_query_coverage q on q.provider=p_provider
      and q.subject_type=r.subject_type and q.subject_id=r.subject_id
    where nullif(btrim(e.payload->>'name'),'') is not null
      and (q.fetched_at is null or q.fetched_at<now()-make_interval(hours=>cfg.query_interval_hours))
    order by r.priority desc,q.fetched_at nulls first,r.subject_id
    limit greatest(1,least(coalesce(p_limit,1),10))
  ) due
$$;

-- The next enabled feed due, or null.
create or replace function futbeat_private.futbeat_news_feed_due()
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',f.id,'provider',f.provider,'url',f.url,'sourceDomain',f.source_domain,
    'sourceName',s.display_name,'etag',f.etag,'lastModified',f.last_modified)
  from futbeat_private.news_feeds f
  join futbeat_private.news_sources s on s.domain=f.source_domain
  join futbeat_private.news_provider_config p on p.provider=f.provider and p.enabled
  where f.enabled and coalesce(f.next_fetch_at,'-infinity')<=now()
  order by f.next_fetch_at nulls first,f.id limit 1
$$;

create or replace function futbeat_private.futbeat_news_feed_result(
  p_feed_id text,p_ok boolean,p_etag text,p_last_modified text,p_status text
) returns void language sql security definer set search_path='' as $$
  update futbeat_private.news_feeds set
    etag=case when p_ok then coalesce(left(p_etag,300),etag) else etag end,
    last_modified=case when p_ok then coalesce(left(p_last_modified,100),last_modified) else last_modified end,
    last_fetched_at=now(),last_status=left(p_status,40),
    consecutive_failures=case when p_ok then 0 else consecutive_failures+1 end,
    -- Failures back off exponentially (max 24 h).
    next_fetch_at=now()+case when p_ok then make_interval(mins=>cadence_minutes)
      else least(interval '24 hours',make_interval(mins=>cadence_minutes*(2^least(consecutive_failures+1,6))::integer)) end
  where id=p_feed_id
$$;

-- Entities the collector may tag (bounded): central interests and the
-- teams/competitions of countries users selected. Names from the search
-- index (name, short name, aliases).
create or replace function futbeat_private.futbeat_news_tagging_dictionary(p_limit integer default 3000)
returns jsonb language sql stable security definer set search_path='' as $$
  with countries as (
    select distinct lower(c.canonical_name) n from futbeat_private.user_preferences u
    join futbeat_private.country_catalog c on c.country_code=coalesce(u.selected_country,u.detected_country)
  ), wanted as (
    select ci.subject_type kind,futbeat_private.futbeat_resolve_entity_id(ci.subject_type,ci.subject_id) id
    from futbeat_private.coverage_interests ci where ci.subject_type in ('team','player','competition')
    union
    select e.kind,e.id from futbeat_private.entities e
    where e.kind in ('team','competition') and lower(coalesce(e.payload->>'country','')) in (select n from countries)
    union
    select 'player',sm.player_id from futbeat_private.team_squad_members sm
    join futbeat_private.coverage_interests ci on ci.subject_type='team' and ci.subject_id=sm.team_id
  ), named as (
    select w.kind,w.id,array_agg(distinct s.term order by s.term) names
    from wanted w join futbeat_private.entity_search_index s on s.entity_id=w.id
    group by w.kind,w.id
  )
  select coalesce(jsonb_agg(jsonb_build_object('type',kind,'id',id,'names',to_jsonb(names)) order by kind,id),'[]'::jsonb)
  from (select * from named order by kind,id limit greatest(1,least(p_limit,5000))) x
$$;

-- Recent stored fingerprints for clustering (compact; no text bodies).
create or replace function futbeat_private.futbeat_news_recent_fingerprints(p_hours integer default 72)
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'clusterId',a.cluster_id,'urlKey',a.url_key,
      'titleTokens',to_jsonb(coalesce(a.title_tokens,'{}')),'nameTokens',to_jsonb(coalesce(a.name_tokens,'{}')),
      'category',a.category,'publishedAt',a.published_at,
      'subjects',coalesce((select jsonb_agg(jsonb_build_object('type',ae.subject_type,'id',ae.subject_id)
        order by ae.subject_type,ae.subject_id) from futbeat_private.news_article_entities ae
        where ae.article_id=a.id),'[]'::jsonb)) order by a.published_at,a.id),'[]'::jsonb)
  from (select * from futbeat_private.news_articles
    where cluster_id is not null and published_at>=now()-make_interval(hours=>greatest(1,least(p_hours,168)))
    order by published_at desc limit 3000) a
$$;

-- Stores prepared articles (contract v2). Rights and roles are re-derived
-- here from the governance tables; client values never grant rights.
-- Writes only what changed (content_hash); news_subjects only through the
-- cluster anchor, inserted once.
create or replace function futbeat_private.futbeat_store_news_batch_v2(
  p_provider text,p_received_at timestamptz,p_articles jsonb,
  p_subject_type text default null,p_subject_id text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  cfg futbeat_private.news_provider_config;
  src futbeat_private.news_sources;
  item jsonb; v_id text; v_ext text; v_url text; v_key text; v_title text; v_published timestamptz;
  v_host text; v_role text; v_snippet text; v_image text; v_transfer text; v_cluster text;
  v_hash text; existing futbeat_private.news_articles; touched text[]:=array[]::text[];
  n_inserted integer:=0; n_updated integer:=0; n_unchanged integer:=0; n_skipped integer:=0;
begin
  select * into cfg from futbeat_private.news_provider_config where provider=p_provider;
  if not found or p_received_at is null or jsonb_typeof(p_articles) is distinct from 'array'
     or jsonb_array_length(p_articles)>100 then
    raise exception 'Invalid news batch v2';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(hashtextextended('news-store-v2',0));

  -- Oldest first: a story's first member is stored before the rest.
  for item in select value from jsonb_array_elements(p_articles)
    order by value->>'publishedAt',value->>'externalId' loop
    v_ext:=left(nullif(btrim(item->>'externalId'),''),200);
    v_url:=nullif(btrim(item->>'url'),'');
    v_key:=nullif(btrim(item->>'urlKey'),'');
    v_title:=left(nullif(btrim(item->>'title'),''),300);
    v_published:=futbeat_private.try_timestamptz(item->>'publishedAt');
    v_hash:=nullif(btrim(item->>'contentHash'),'');
    if v_ext is null or v_url is null or v_url!~'^https://' or v_key is null or v_title is null
       or v_hash is null or v_published is null
       or v_published>now()+interval '1 day' or v_published<now()-interval '35 days'
       or coalesce(item->>'provider','')<>p_provider then
      n_skipped:=n_skipped+1;
      continue;
    end if;
    v_id:=p_provider||':'||v_ext;
    v_host:=lower(substring(v_url from '^https://([^/?#:]+)'));
    src:=futbeat_private.news_source_for(v_host);
    v_role:=coalesce(src.role,'UNVERIFIED');
    v_snippet:=case when cfg.snippet_allowed and coalesce(src.snippet_allowed,false)
      and nullif(btrim(item->>'snippet'),'') is not null
      then left(btrim(item->>'snippet'),least(src.max_snippet_chars,300)) end;
    v_image:=case when cfg.image_allowed and coalesce(src.image_allowed,false)
      and coalesce(item->>'imageUrl','') ~ '^https://' then left(item->>'imageUrl',1000) end;
    v_transfer:=case
      when item->>'category'<>'TRANSFER' then null
      when item->>'transferStatus'='CONFIRMED' and v_role<>'FIRST_PARTY_OFFICIAL'
        then case when v_role='ESTABLISHED_MEDIA' then 'REPORT' else 'RUMOR' end
      when item->>'transferStatus' in ('RUMOR','REPORT','CONFIRMED') then item->>'transferStatus'
      else 'RUMOR' end;

    -- One row per canonical URL: another provider's copy is the same article.
    select * into existing from futbeat_private.news_articles where url_key=v_key;
    if found and existing.id<>v_id then
      n_unchanged:=n_unchanged+1;
      continue;
    end if;
    select * into existing from futbeat_private.news_articles where id=v_id;
    if found and existing.content_hash is not distinct from v_hash then
      n_unchanged:=n_unchanged+1;
      continue;
    end if;

    -- Cluster: the collector's choice when it names a stored recent story
    -- (or this article); a stored article keeps its cluster.
    v_cluster:=coalesce(existing.cluster_id,case
      when item->>'clusterId'=v_id then v_id
      when exists(select 1 from futbeat_private.news_articles c where c.cluster_id=item->>'clusterId'
        and c.published_at>=v_published-interval '72 hours') then item->>'clusterId'
      else v_id end);

    insert into futbeat_private.news_articles as a(id,provider,external_id,title,description,url,
      source_name,source_url,published_at,language,fetched_at,url_key,source_domain,source_role,
      image_url,category,transfer_status,cluster_id,title_tokens,name_tokens,content_hash,
      attribution,contract_version,updated_at)
    values(v_id,p_provider,v_ext,v_title,v_snippet,left(v_url,2000),
      left(coalesce(src.display_name,nullif(btrim(item->>'sourceName'),''),v_host),300),
      'https://'||v_host,v_published,left(nullif(item->>'language',''),40),p_received_at,v_key,v_host,v_role,
      v_image,coalesce(nullif(item->>'category',''),'GENERAL'),v_transfer,v_cluster,
      array(select jsonb_array_elements_text(coalesce(item->'titleTokens','[]'::jsonb)) limit 40),
      array(select jsonb_array_elements_text(coalesce(item->'nameTokens','[]'::jsonb)) limit 20),
      v_hash,
      jsonb_strip_nulls(jsonb_build_object('publisher',coalesce(src.display_name,item#>>'{attribution,publisher}',v_host),
        'provider',cfg.attribution_text)),
      2,p_received_at)
    on conflict(id) do update set
      title=excluded.title,description=excluded.description,url=excluded.url,
      source_name=excluded.source_name,published_at=excluded.published_at,language=excluded.language,
      fetched_at=excluded.fetched_at,url_key=excluded.url_key,source_domain=excluded.source_domain,
      source_role=excluded.source_role,image_url=excluded.image_url,category=excluded.category,
      transfer_status=excluded.transfer_status,title_tokens=excluded.title_tokens,
      name_tokens=excluded.name_tokens,content_hash=excluded.content_hash,
      attribution=excluded.attribution,contract_version=2,updated_at=excluded.updated_at
    where a.content_hash is distinct from excluded.content_hash;
    if existing.id is null then n_inserted:=n_inserted+1; else n_updated:=n_updated+1; end if;

    insert into futbeat_private.news_article_entities(article_id,subject_type,subject_id)
    select v_id,s->>'type',futbeat_private.futbeat_resolve_entity_id(s->>'type',s->>'id')
    from jsonb_array_elements(coalesce(item->'subjects','[]'::jsonb)) s
    where s->>'type' in ('team','player','competition')
      and exists(select 1 from futbeat_private.entities e
        where e.id=futbeat_private.futbeat_resolve_entity_id(s->>'type',s->>'id') and e.kind=s->>'type')
    on conflict do nothing;

    if not v_cluster=any(touched) then touched:=array_append(touched,v_cluster); end if;
  end loop;

  perform futbeat_private.refresh_news_cluster(c) from unnest(touched) c;

  if p_subject_type is not null then
    insert into futbeat_private.news_query_coverage(provider,subject_type,subject_id,fetched_at,article_count)
    values(p_provider,p_subject_type,futbeat_private.futbeat_resolve_entity_id(p_subject_type,p_subject_id),
      p_received_at,n_inserted+n_updated+n_unchanged)
    on conflict(provider,subject_type,subject_id) do update set
      fetched_at=excluded.fetched_at,article_count=excluded.article_count;
  end if;

  -- Retention (35 days), only when something new arrived.
  if n_inserted>0 then
    delete from futbeat_private.news_articles where published_at<now()-interval '35 days';
    delete from futbeat_private.news_clusters c where not exists(
      select 1 from futbeat_private.news_articles a where a.cluster_id=c.cluster_id);
  end if;

  return jsonb_build_object('items',jsonb_array_length(p_articles),'inserted',n_inserted,
    'updated',n_updated,'unchanged',n_unchanged,'skipped',n_skipped,'clusters',cardinality(touched));
end $$;

-- ---------------------------------------------------------------------------
-- Feed read (contract v2): one card per story.
-- ---------------------------------------------------------------------------

-- p_tab: for_you | latest | country | transfers. p_follows: [{type,id}]
-- from the app's own follows (no upstream call). p_country: ISO alpha-2.
create or replace function futbeat_private.futbeat_read_news_feed(
  p_tab text,p_country text default null,p_follows jsonb default '[]'::jsonb,
  p_offset integer default 0,p_limit integer default 20
) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  v_country text:=upper(nullif(btrim(p_country),''));
  v_country_names text[];
  result jsonb; total integer;
begin
  if p_tab not in ('for_you','latest','country','transfers') or p_offset<0 or p_offset>200
     or p_limit<1 or p_limit>50 or (v_country is not null and v_country!~'^[A-Z]{2}$')
     or jsonb_typeof(coalesce(p_follows,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_follows,'[]'::jsonb))>200 then
    raise exception 'Invalid news feed request';
  end if;
  select array_agg(distinct n) into v_country_names from (
    select lower(canonical_name) n from futbeat_private.country_catalog where country_code=v_country
    union select lower(a) from futbeat_private.country_catalog c,jsonb_array_elements_text(c.aliases) a
    where c.country_code=v_country) x;

  with follows as (
    select f->>'type' t,futbeat_private.futbeat_resolve_entity_id(f->>'type',f->>'id') id
    from jsonb_array_elements(coalesce(p_follows,'[]'::jsonb)) f
    where f->>'type' in ('team','player','competition')
  ), clusters as (
    select c.* from futbeat_private.news_clusters c
    where c.last_published_at>=now()-interval '7 days'
      and (p_tab<>'transfers' or c.category='TRANSFER')
  ), members as (
    select a.*,futbeat_private.news_role_rank(a.source_role) rk from futbeat_private.news_articles a
    join clusters c on c.cluster_id=a.cluster_id
  ), entities as (
    select distinct m.cluster_id,ae.subject_type,futbeat_private.futbeat_resolve_entity_id(ae.subject_type,ae.subject_id) id
    from members m join futbeat_private.news_article_entities ae on ae.article_id=m.id
  ), scored as (
    select c.*,
      coalesce((select max(case when f.t='team' then 100 when f.t='player' then 90 else 70 end)
        from entities e join follows f on f.t=e.subject_type and f.id=e.id
        where e.cluster_id=c.cluster_id),0) follow_score,
      -- A tagged team/competition of the country decides; the publisher's
      -- country only when the story tags no team or competition.
      (v_country is not null and (
        exists(select 1 from entities e join futbeat_private.entities x on x.id=e.id
          where e.cluster_id=c.cluster_id and e.subject_type in ('team','competition')
            and lower(coalesce(x.payload->>'country','')) = any(v_country_names))
        or (not exists(select 1 from entities e where e.cluster_id=c.cluster_id
              and e.subject_type in ('team','competition'))
          and exists(select 1 from members m join futbeat_private.news_sources s on s.domain=m.source_domain
            where m.cluster_id=c.cluster_id and s.country_code=v_country)))) in_country
    from clusters c
  ), filtered as (
    select s.*,
      s.follow_score+case when s.in_country then 50 else 0 end
        +case s.story_state when 'OFFICIAL' then 15 when 'REPORT' then 10 else 0 end
        -extract(epoch from (now()-s.last_published_at))/3600.0/6.0 rank_score
    from scored s
    where p_tab<>'country' or s.in_country
  ), page as (
    select f.* from filtered f
    order by case when p_tab='for_you' then f.rank_score end desc nulls last,
      f.last_published_at desc,f.cluster_id
    offset p_offset limit p_limit
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'clusterId',p.cluster_id,
      'title',card.title,'url',card.url,'sourceName',card.source_name,'sourceDomain',card.source_domain,
      'sourceRole',card.source_role,'publishedAt',card.published_at,'updatedAt',p.last_published_at,
      'snippet',card.description,'imageUrl',card.image_url,'attribution',card.attribution,
      'category',p.category,'storyState',p.story_state,'transferStatus',p.transfer_status,
      'memberCount',p.member_count,
      'entities',coalesce((select jsonb_agg(jsonb_build_object('type',e.subject_type,'id',e.id,
          'name',x.payload->>'name') order by e.subject_type,e.id)
        from entities e join futbeat_private.entities x on x.id=e.id where e.cluster_id=p.cluster_id),'[]'::jsonb),
      'alsoReportedBy',coalesce((select jsonb_agg(jsonb_build_object('sourceName',m.source_name,'url',m.url,
          'sourceRole',m.source_role,'publishedAt',m.published_at) order by m.rk,m.published_at,m.id)
        from members m where m.cluster_id=p.cluster_id and m.id<>card.id),'[]'::jsonb)))
      order by case when p_tab='for_you' then p.rank_score end desc nulls last,p.last_published_at desc,p.cluster_id),
      '[]'::jsonb),
    (select count(*) from filtered)
  into result,total
  from page p
  cross join lateral (
    -- The card shows the most trusted member (official > media > ...),
    -- earliest first among equals.
    select m.* from members m where m.cluster_id=p.cluster_id order by m.rk,m.published_at,m.id limit 1
  ) card;

  return jsonb_build_object('schemaVersion',2,'tab',p_tab,'country',v_country,
    'updatedAt',now(),'offset',p_offset,'hasMore',p_offset+p_limit<coalesce(total,0),
    'stories',result);
end $$;

-- Health: the news pipeline's own budget and freshness.
create or replace function futbeat_private.futbeat_news_health()
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'providers',coalesce((select jsonb_agg(jsonb_build_object('provider',p.provider,'enabled',p.enabled,
       'role',p.role,'dailyLimit',p.daily_limit,
       'usedToday',(select count(*) from futbeat_private.news_collector_calls c where c.provider=p.provider
          and c.reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'),
       'failedToday',(select count(*) from futbeat_private.news_collector_calls c where c.provider=p.provider
          and c.status='FAILED' and c.reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'),
       'lastSuccessAt',(select max(completed_at) from futbeat_private.news_collector_calls c
          where c.provider=p.provider and c.status in ('SUCCEEDED','NOT_MODIFIED'))) order by p.provider)
       from futbeat_private.news_provider_config p),'[]'::jsonb),
    'feeds',coalesce((select jsonb_agg(jsonb_build_object('id',id,'enabled',enabled,'lastStatus',last_status,
       'lastFetchedAt',last_fetched_at,'consecutiveFailures',consecutive_failures) order by id)
       from futbeat_private.news_feeds),'[]'::jsonb),
    'stories7d',(select count(*) from futbeat_private.news_clusters where last_published_at>=now()-interval '7 days'),
    'articles',(select count(*) from futbeat_private.news_articles where contract_version=2))
$$;

-- Public wrappers (service_role only), same convention as v1.
create or replace function public.futbeat_read_news_feed(
  p_tab text,p_country text default null,p_follows jsonb default '[]'::jsonb,
  p_offset integer default 0,p_limit integer default 20
) returns jsonb language sql stable security definer set search_path='' as $$
  select futbeat_private.futbeat_read_news_feed(p_tab,p_country,p_follows,p_offset,p_limit)
$$;
create or replace function public.futbeat_store_news_batch_v2(
  p_provider text,p_received_at timestamptz,p_articles jsonb,
  p_subject_type text default null,p_subject_id text default null
) returns jsonb language sql security definer set search_path='' as $$
  select futbeat_private.futbeat_store_news_batch_v2(p_provider,p_received_at,p_articles,p_subject_type,p_subject_id)
$$;
create or replace function public.futbeat_reserve_news_call(p_provider text,p_target text)
returns jsonb language sql security definer set search_path='' as $$
  select futbeat_private.futbeat_reserve_news_call(p_provider,p_target)
$$;
create or replace function public.futbeat_complete_news_call(
  p_reservation_id bigint,p_status text,p_http_status integer,p_result jsonb,p_error_code text
) returns void language sql security definer set search_path='' as $$
  select futbeat_private.futbeat_complete_news_call(p_reservation_id,p_status,p_http_status,p_result,p_error_code)
$$;
create or replace function public.futbeat_news_policies(p_provider text)
returns jsonb language sql stable security definer set search_path='' as $$
  select futbeat_private.futbeat_news_policies(p_provider)
$$;
create or replace function public.futbeat_news_query_plan(p_provider text,p_limit integer default 1)
returns jsonb language sql stable security definer set search_path='' as $$
  select futbeat_private.futbeat_news_query_plan(p_provider,p_limit)
$$;
create or replace function public.futbeat_news_feed_due()
returns jsonb language sql stable security definer set search_path='' as $$
  select futbeat_private.futbeat_news_feed_due()
$$;
create or replace function public.futbeat_news_feed_result(
  p_feed_id text,p_ok boolean,p_etag text,p_last_modified text,p_status text
) returns void language sql security definer set search_path='' as $$
  select futbeat_private.futbeat_news_feed_result(p_feed_id,p_ok,p_etag,p_last_modified,p_status)
$$;
create or replace function public.futbeat_news_tagging_dictionary(p_limit integer default 3000)
returns jsonb language sql stable security definer set search_path='' as $$
  select futbeat_private.futbeat_news_tagging_dictionary(p_limit)
$$;
create or replace function public.futbeat_news_recent_fingerprints(p_hours integer default 72)
returns jsonb language sql stable security definer set search_path='' as $$
  select futbeat_private.futbeat_news_recent_fingerprints(p_hours)
$$;
create or replace function public.futbeat_news_health()
returns jsonb language sql stable security definer set search_path='' as $$
  select futbeat_private.futbeat_news_health()
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'futbeat_private.news_role_rank(text)','futbeat_private.news_source_for(text)',
    'futbeat_private.refresh_news_cluster(text)',
    'futbeat_private.futbeat_reserve_news_call(text,text)',
    'futbeat_private.futbeat_complete_news_call(bigint,text,integer,jsonb,text)',
    'futbeat_private.futbeat_news_policies(text)','futbeat_private.futbeat_news_query_plan(text,integer)',
    'futbeat_private.futbeat_news_feed_due()','futbeat_private.futbeat_news_feed_result(text,boolean,text,text,text)',
    'futbeat_private.futbeat_news_tagging_dictionary(integer)','futbeat_private.futbeat_news_recent_fingerprints(integer)',
    'futbeat_private.futbeat_store_news_batch_v2(text,timestamptz,jsonb,text,text)',
    'futbeat_private.futbeat_read_news_feed(text,text,jsonb,integer,integer)',
    'futbeat_private.futbeat_news_health()'] loop
    execute format('revoke all on function %s from public,anon,authenticated,service_role',f);
  end loop;
  foreach f in array array[
    'public.futbeat_read_news_feed(text,text,jsonb,integer,integer)',
    'public.futbeat_store_news_batch_v2(text,timestamptz,jsonb,text,text)',
    'public.futbeat_reserve_news_call(text,text)',
    'public.futbeat_complete_news_call(bigint,text,integer,jsonb,text)',
    'public.futbeat_news_policies(text)','public.futbeat_news_query_plan(text,integer)',
    'public.futbeat_news_feed_due()','public.futbeat_news_feed_result(text,boolean,text,text,text)',
    'public.futbeat_news_tagging_dictionary(integer)','public.futbeat_news_recent_fingerprints(integer)',
    'public.futbeat_news_health()'] loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

notify pgrst,'reload schema';
