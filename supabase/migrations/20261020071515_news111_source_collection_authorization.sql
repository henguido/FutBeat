-- NEWS111: a feed being enabled is not evidence of permission to collect it.
-- Approval is per publisher; the existing feed.enabled flag remains per feed.
-- All existing and candidate sources start without approval.
alter table futbeat_private.news_sources
  add column collection_authorized_at timestamptz,
  add column collection_permission_ref text,
  add constraint news_sources_collection_permission_pair check (
    (collection_authorized_at is null and collection_permission_ref is null)
    or (collection_authorized_at is not null and
        nullif(btrim(collection_permission_ref),'') is not null)
  );

comment on column futbeat_private.news_sources.collection_permission_ref is
  'Reviewable reference to the publisher collection agreement; never an RSS URL alone.';

-- Fail closed even if someone enables the provider and an individual feed.
-- Revoking either approval field immediately removes all publisher feeds
-- from the due plan without deleting previously stored articles.
create or replace function futbeat_private.futbeat_news_feed_due()
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',f.id,'provider',f.provider,'url',f.url,'sourceDomain',f.source_domain,
    'sourceName',s.display_name,'etag',f.etag,'lastModified',f.last_modified)
  from futbeat_private.news_feeds f
  join futbeat_private.news_sources s on s.domain=f.source_domain
  join futbeat_private.news_provider_config p on p.provider=f.provider
    and p.enabled and p.production_allowed and p.terms_reviewed_at is not null
  where f.enabled
    and s.collection_authorized_at is not null
    and nullif(btrim(s.collection_permission_ref),'') is not null
    and coalesce(f.next_fetch_at,'-infinity')<=now()
  order by f.next_fetch_at nulls first,f.id limit 1
$$;
