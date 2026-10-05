-- Noticias v1: a real feed from stored articles (no new provider).
--
-- Evidence (read-only production, 2026-10-05): the NewsData.io pipeline
-- (planner, reservation, store, dedupe by provider id, profile tabs) exists
-- but the vault secret futbeat_newsdata_api_key is absent, so news_articles
-- holds 0 rows and the main "Noticias" tab is a static placeholder.
-- transfer_events holds 100 real roster changes (GOAL squads).
--
-- 1. news_articles.image_url (optional, https only), stored from the
--    NewsData image_url the worker now forwards as imageUrl.
-- 2. futbeat_read_news_feed(p_subjects, p_country): <= 40 articles of the
--    last 14 days (followed subjects first, then the country's teams and
--    competitions, then the rest; newest first inside each tier; the same
--    title from several sources is listed once) and <= 30 transfers of the
--    last 30 days (followed teams/players first). Read-only; never invents.
-- Rollback: drop function public.futbeat_read_news_feed(text[],text);
-- re-create futbeat_store_news_batch from 20260919042500; the column can stay.

alter table futbeat_private.news_articles add column if not exists image_url text;

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
  v_image text;
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
    -- Optional image: https only, never required.
    v_image:=nullif(btrim(coalesce(item->>'imageUrl','')),'');
    if v_image is not null and (v_image !~ '^https://[^[:space:]]+$' or length(v_image)>2000) then
      v_image:=null;
    end if;
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
      source_name,source_url,published_at,language,fetched_at,image_url
    )
    values(
      v_id,'newsdata',left(v_external,200),left(v_title,500),
      left(v_description,2000),left(v_url,2000),
      left(v_source,300),left(v_source_url,1000),
      v_published,left(v_language,40),p_received_at,v_image
    )
    on conflict(provider,external_id) do update set
      title=excluded.title,
      description=excluded.description,
      url=excluded.url,
      source_name=excluded.source_name,
      source_url=excluded.source_url,
      published_at=excluded.published_at,
      language=excluded.language,
      fetched_at=excluded.fetched_at,
      image_url=coalesce(excluded.image_url,futbeat_private.news_articles.image_url);

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

create or replace function public.futbeat_read_news_feed(
  p_subjects text[] default '{}',p_country text default null
) returns jsonb language sql stable security definer set search_path='' as $$
 with followed as (
   select split_part(k,':',1) subject_type,
     futbeat_private.futbeat_resolve_entity_id(split_part(k,':',1),split_part(k,':',2)) subject_id
   from unnest(coalesce(p_subjects,'{}'::text[])) with ordinality s(k,ord)
   where s.ord<=50 and k ~ '^(team|player|competition):fb_[A-Za-z0-9_]+$'
 ), recent as (
   select a.* from futbeat_private.news_articles a
   where a.published_at>=now()-interval '14 days' and a.published_at<=now()+interval '1 hour'
 ), tagged as (
   select a.id,
     min(case
       when exists(select 1 from followed f where f.subject_type=ns.subject_type
         and f.subject_id=futbeat_private.futbeat_resolve_entity_id(ns.subject_type,ns.subject_id)) then 1
       when p_country ~ '^[A-Z]{2}$' and (
         (ns.subject_type='team' and exists(select 1 from futbeat_private.entities t
           join futbeat_private.competition_editorial_metadata m on m.competition_id=t.payload->>'competitionId'
           where t.kind='team' and t.id=futbeat_private.futbeat_resolve_entity_id('team',ns.subject_id)
             and m.country_code=p_country))
         or (ns.subject_type='competition' and exists(select 1 from futbeat_private.competition_editorial_metadata m
           where m.competition_id=futbeat_private.futbeat_resolve_entity_id('competition',ns.subject_id)
             and m.country_code=p_country))) then 2
       else 3 end) tier,
     jsonb_agg(distinct jsonb_build_object('type',ns.subject_type,
       'id',futbeat_private.futbeat_resolve_entity_id(ns.subject_type,ns.subject_id))) subjects
   from recent a join futbeat_private.news_subjects ns on ns.article_id=a.id
   group by a.id
 ), unique_titles as (
   -- The same story from several sources is listed once (the best tier,
   -- then the newest copy).
   select distinct on (lower(regexp_replace(btrim(a.title),'\s+',' ','g')))
     a.*,coalesce(t.tier,3) tier,coalesce(t.subjects,'[]'::jsonb) subjects
   from recent a left join tagged t on t.id=a.id
   order by lower(regexp_replace(btrim(a.title),'\s+',' ','g')),coalesce(t.tier,3),a.published_at desc,a.id
 ), picked as (
   select * from unique_titles order by tier,published_at desc,id limit 40
 ), transfers as (
   select tr.*,p.payload->>'name' player_name,ft.payload->>'name' from_team_name,
     tt.payload->>'name' to_team_name,
     case when exists(select 1 from followed f where
       (f.subject_type='player' and f.subject_id=tr.player_id)
       or (f.subject_type='team' and f.subject_id in (tr.from_team_id,tr.to_team_id))) then 1 else 2 end tier
   from futbeat_private.transfer_events tr
   left join futbeat_private.entities p on p.id=tr.player_id and p.kind='player'
   left join futbeat_private.entities ft on ft.id=tr.from_team_id and ft.kind='team'
   left join futbeat_private.entities tt on tt.id=tr.to_team_id and tt.kind='team'
   where tr.detected_at>=now()-interval '30 days'
     and p.payload->>'name' is not null
   order by tier,tr.detected_at desc,tr.id desc limit 30
 )
 select jsonb_build_object('schemaVersion',1,'demo',false,'updatedAt',now(),
   'coverage',jsonb_build_object('partial',false),'freshness',jsonb_build_object('stale',false),
   'competitions','[]'::jsonb,'teams','[]'::jsonb,'players','[]'::jsonb,
   'matches','[]'::jsonb,'standings','[]'::jsonb,
   'news',(select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
       'id',id,'title',title,'description',description,'url',url,
       'sourceName',source_name,'sourceUrl',source_url,'publishedAt',published_at,
       'language',language,'imageUrl',image_url,'subjects',subjects,
       'followed',tier=1)) order by tier,published_at desc,id),'[]'::jsonb) from picked),
   'transfers',(select coalesce(jsonb_agg(jsonb_build_object(
       'id',id,'playerId',player_id,'playerName',player_name,
       'fromTeamId',from_team_id,'fromTeamName',from_team_name,
       'toTeamId',to_team_id,'toTeamName',to_team_name,
       'detectedAt',detected_at,'status',status,'source',source_label)
       order by tier,detected_at desc,id desc),'[]'::jsonb) from transfers))
$$;

revoke all on function public.futbeat_read_news_feed(text[],text) from public,anon,authenticated;
grant execute on function public.futbeat_read_news_feed(text[],text) to service_role;

notify pgrst,'reload schema';
