-- NEWS119: P3 was amended after its first publication under the same version.
-- Re-apply only the private v2 reader so databases that recorded the older P3
-- receive the final country and metadata contract. No tables or data change.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

do $$
begin
  if to_regprocedure('futbeat_private.futbeat_read_news_feed(text,text,jsonb,integer,integer)') is null
     or to_regprocedure('futbeat_private.news_feed_current_rights(jsonb)') is null
     or to_regclass('futbeat_private.news_sources') is null then
    raise exception 'NEWS119 precondition failed: P3 and NEWS115 must be applied first';
  end if;
  -- Fail closed for a third, manually altered reader. These are the original
  -- P3 and final main definitions (CRLF normalized); replacement is additive
  -- to migration history, not a rewrite of the already-applied P3 version.
  if not exists (
    select 1 from pg_catalog.pg_proc p
    where p.oid='futbeat_private.futbeat_read_news_feed(text,text,jsonb,integer,integer)'::regprocedure
      and pg_catalog.md5(pg_catalog.replace(p.prosrc,chr(13),'')) in (
        '0073fe6b0bd1fad59d526cccaf9fb03b',
        '85ede30c7ad35dc049d62042f42d65f8'
      )
  ) then
    raise exception 'NEWS119 precondition failed: unrecognized P3 reader body';
  end if;
end $$;

create or replace function futbeat_private.futbeat_read_news_feed(
  p_tab text,p_country text,p_follows jsonb,
  p_offset integer,p_limit integer
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
      -- Only a tagged canonical team/competition establishes story country.
      -- Publisher country and feed coverage are not evidence about the story.
      (v_country is not null and (
        exists(select 1 from entities e join futbeat_private.entities x on x.id=e.id
          where e.cluster_id=c.cluster_id and e.subject_type in ('team','competition')
            and lower(coalesce(x.payload->>'country','')) = any(v_country_names)))) in_country
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
      'sourceRole',card.source_role,'sourceCountryCode',src.country_code,
      'language',card.language,'inSelectedCountry',p.in_country,
      'publishedAt',card.published_at,'updatedAt',p.last_published_at,
      'snippet',card.description,'imageUrl',card.image_url,'attribution',card.attribution,
      'category',p.category,'storyState',p.story_state,'transferStatus',p.transfer_status,
      'memberCount',p.member_count,
      'storyCountryNames',coalesce((select jsonb_agg(distinct x.payload->>'country')
        from entities e join futbeat_private.entities x on x.id=e.id
        where e.cluster_id=p.cluster_id and e.subject_type in ('team','competition')
          and nullif(x.payload->>'country','') is not null),'[]'::jsonb),
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
  ) card
  left join futbeat_private.news_sources src on src.domain=card.source_domain;

  return jsonb_build_object('schemaVersion',2,'tab',p_tab,'country',v_country,
    'updatedAt',now(),'offset',p_offset,'hasMore',p_offset+p_limit<coalesce(total,0),
    'stories',result);
end $$;

commit;
