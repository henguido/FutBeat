-- NEWS115: NEWS107 read-time rights only. NEWS114 already includes bounded v1/v2 retention.
-- All providers and feeds remain disabled. This is local and unapplied remotely.
-- Apply live policies after assembling one page. The base reader still
-- performs all ranking, grouping and canonical association work. This adds
-- one bounded, set-based policy check over at most 50 cards, not a new
-- provider request or an article rewrite.
create or replace function futbeat_private.news_feed_current_rights(p_feed jsonb)
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_set(p_feed,'{stories}',coalesce((
    select jsonb_agg(
      (case
        when rights.snippet_ok and rights.image_ok then story.value
        when rights.snippet_ok then story.value-'imageUrl'
        when rights.image_ok then story.value-'snippet'
        else story.value-'snippet'-'imageUrl'
       end)
        || jsonb_build_object('rights',jsonb_build_object(
          'version',1,
          'checkedAt',current_timestamp,
          'expiresAt',current_timestamp + interval '30 seconds',
          'snippet',case
            when rights.snippet_ok then 'ALLOWED'
            when cfg.terms_reviewed_at is null or src.rights_reviewed_at is null
              then 'UNVERIFIED'
            else 'REVOKED' end,
          'image',case
            when rights.image_ok then 'ALLOWED'
            when cfg.terms_reviewed_at is null or src.rights_reviewed_at is null
              then 'UNVERIFIED'
            else 'REVOKED' end
        )) order by story.ordinality)
    from jsonb_array_elements(coalesce(p_feed->'stories','[]'::jsonb)) with ordinality story(value,ordinality)
    left join lateral (
      select a.provider,a.source_domain from futbeat_private.news_articles a
      where a.cluster_id=story.value->>'clusterId'
      order by futbeat_private.news_role_rank(a.source_role),a.published_at,a.id limit 1
    ) card on true
    left join futbeat_private.news_provider_config cfg on cfg.provider=card.provider
    left join lateral futbeat_private.news_source_for(card.source_domain) src on true
    cross join lateral (select
      coalesce(cfg.snippet_allowed,false) and coalesce(src.snippet_allowed,false)
        and cfg.terms_reviewed_at is not null and src.rights_reviewed_at is not null as snippet_ok,
      coalesce(cfg.image_allowed,false) and coalesce(src.image_allowed,false)
        and cfg.terms_reviewed_at is not null and src.rights_reviewed_at is not null as image_ok
    ) rights
  ),'[]'::jsonb))
$$;

create or replace function public.futbeat_read_news_feed(
  p_tab text,p_country text,p_follows jsonb,
  p_offset integer,p_limit integer
) returns jsonb language sql stable security definer set search_path='' as $$
  select futbeat_private.news_feed_current_rights(
    futbeat_private.futbeat_read_news_feed(p_tab,p_country,p_follows,p_offset,p_limit))
$$;
revoke all on function futbeat_private.news_feed_current_rights(jsonb)
  from public,anon,authenticated,service_role;
