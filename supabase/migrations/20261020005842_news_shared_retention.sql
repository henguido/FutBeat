-- News105: v1 and v2 share news_articles, but not ownership of retention.
-- Replaces only the legacy private writer and public v2 reader. No table,
-- index, collector, provider enablement or cron change.

create or replace function futbeat_private.futbeat_store_news_batch(
  p_subject_type text,p_subject_id text,p_received_at timestamptz,
  p_query text,p_articles jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  item jsonb;
  v_external text; v_id text; v_title text; v_url text; v_source text;
  v_source_url text; v_language text;
  v_published timestamptz; v_count integer:=0;
begin
  if p_subject_type not in ('team','player','competition')
     or nullif(p_subject_id,'') is null or p_received_at is null
     or nullif(btrim(p_query),'') is null or length(p_query)>100
     or jsonb_typeof(p_articles)<>'array' or jsonb_array_length(p_articles)>20
     or not exists(select 1 from futbeat_private.entities
       where id=p_subject_id and kind=p_subject_type)
  then
    raise exception 'Invalid NewsData batch';
  end if;

  for item in select value from jsonb_array_elements(p_articles) loop
    v_external:=nullif(btrim(coalesce(item->>'id','')),'');
    v_title:=nullif(btrim(coalesce(item->>'title','')),'');
    v_url:=nullif(btrim(coalesce(item->>'url','')),'');
    v_source:=nullif(btrim(coalesce(item->>'sourceName','')),'');
    v_source_url:=nullif(btrim(coalesce(item->>'sourceUrl','')),'');
    v_language:=nullif(btrim(coalesce(item->>'language','')),'');
    begin
      v_published:=nullif(item->>'publishedAt','')::timestamptz;
    exception when others then
      v_published:=null;
    end;
    if v_external is null or v_title is null or v_url is null or v_source is null
       or v_published is null or v_url !~ '^https://'
       or (v_source_url is not null and v_source_url !~ '^https://')
       or v_published>now()+interval '1 day'
       or v_published<now()-interval '60 days'
    then
      continue;
    end if;

    v_id:='newsdata:'||left(v_external,200);
    insert into futbeat_private.news_articles as a(
      id,provider,external_id,title,description,url,
      source_name,source_url,published_at,language,fetched_at
    ) values(
      v_id,'newsdata',left(v_external,200),left(v_title,500),
      null,left(v_url,2000),left(v_source,300),
      left(v_source_url,1000),v_published,left(v_language,40),p_received_at
    ) on conflict(provider,external_id) do update set
      title=excluded.title,description=null,url=excluded.url,
      source_name=excluded.source_name,source_url=excluded.source_url,
      published_at=excluded.published_at,language=excluded.language,
      fetched_at=excluded.fetched_at
    where a.contract_version is null;

    select id into v_id from futbeat_private.news_articles
    where provider='newsdata' and external_id=left(v_external,200)
      and contract_version is null;
    if v_id is null then continue; end if;
    insert into futbeat_private.news_subjects(article_id,subject_type,subject_id,matched_at)
    values(v_id,p_subject_type,p_subject_id,p_received_at)
    on conflict(article_id,subject_type,subject_id) do update
      set matched_at=excluded.matched_at;
    v_count:=v_count+1;
  end loop;

  insert into futbeat_private.news_subject_coverage(
    subject_type,subject_id,fetched_at,last_query,article_count
  ) values(p_subject_type,p_subject_id,p_received_at,left(p_query,100),v_count)
  on conflict(subject_type,subject_id) do update set
    fetched_at=excluded.fetched_at,last_query=excluded.last_query,
    article_count=excluded.article_count;

  -- Never prune v2 or a future contract. Bounded to keep WAL and cascades
  -- predictable; an empty response does not perform cleanup work.
  if v_count>0 then
    with expired as (
      select id from futbeat_private.news_articles
      where provider='newsdata' and contract_version is null
        and published_at<now()-interval '35 days'
      order by published_at,id limit 50
    )
    delete from futbeat_private.news_articles a using expired e where a.id=e.id;
  end if;

  return jsonb_build_object('subjectType',p_subject_type,'subjectId',p_subject_id,
    'articles',v_count,'fetchedAt',p_received_at);
end $$;
