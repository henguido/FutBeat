-- Emergency rollback candidate for an isolated staging database only.
-- Never run against production without a separate reviewed change window.
-- Leave RSS permanently disabled after rollback: the old planner did not
-- enforce per-source collection authorization.
update futbeat_private.news_provider_config set enabled=false where provider='rss';
update futbeat_private.news_feeds set enabled=false where provider='rss';

create or replace function futbeat_private.futbeat_news_feed_due()
returns jsonb language sql stable security definer set search_path='' as $$
  select null::jsonb
$$;

alter table futbeat_private.news_sources
  drop constraint news_sources_collection_permission_pair,
  drop column collection_permission_ref,
  drop column collection_authorized_at;
