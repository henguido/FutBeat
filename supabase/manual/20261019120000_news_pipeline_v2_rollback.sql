-- Rollback of 20261019120000_news_pipeline_v2.sql (manual, NOT a
-- migration). Undeploy futbeat-news-collect and the /v1/news route first.
-- Removes ONLY v2 data: articles stored by the v2 store (contract_version=2)
-- and, through ON DELETE CASCADE, their news_subjects / entity rows. v1
-- NewsData articles and their subjects are untouched. Notifications already
-- queued stay in notification_outbox (push dispatch is not touched).
begin;
set local lock_timeout = '5s';
set local statement_timeout = '300s';
drop function if exists public.futbeat_read_news_feed(text,text,jsonb,integer,integer);
drop function if exists public.futbeat_store_news_batch_v2(text,timestamptz,jsonb,text,text);
drop function if exists public.futbeat_reserve_news_call(text,text);
drop function if exists public.futbeat_complete_news_call(bigint,text,integer,jsonb,text);
drop function if exists public.futbeat_news_policies(text);
drop function if exists public.futbeat_news_query_plan(text,integer);
drop function if exists public.futbeat_news_feed_due();
drop function if exists public.futbeat_news_feed_result(text,boolean,text,text,text);
drop function if exists public.futbeat_news_tagging_dictionary(integer);
drop function if exists public.futbeat_news_recent_fingerprints(integer);
drop function if exists public.futbeat_news_health();
drop function if exists futbeat_private.futbeat_read_news_feed(text,text,jsonb,integer,integer);
drop function if exists futbeat_private.futbeat_store_news_batch_v2(text,timestamptz,jsonb,text,text);
drop function if exists futbeat_private.futbeat_reserve_news_call(text,text);
drop function if exists futbeat_private.futbeat_complete_news_call(bigint,text,integer,jsonb,text);
drop function if exists futbeat_private.futbeat_news_policies(text);
drop function if exists futbeat_private.futbeat_news_query_plan(text,integer);
drop function if exists futbeat_private.futbeat_news_feed_due();
drop function if exists futbeat_private.futbeat_news_feed_result(text,boolean,text,text,text);
drop function if exists futbeat_private.futbeat_news_tagging_dictionary(integer);
drop function if exists futbeat_private.futbeat_news_recent_fingerprints(integer);
drop function if exists futbeat_private.futbeat_news_health();
drop function if exists futbeat_private.refresh_news_cluster(text);
drop function if exists futbeat_private.news_source_for(text);
drop function if exists futbeat_private.news_role_rank(text);
delete from futbeat_private.news_articles where contract_version=2;
drop table if exists futbeat_private.news_clusters;
drop table if exists futbeat_private.news_article_entities;
drop table if exists futbeat_private.news_query_coverage;
drop table if exists futbeat_private.news_collector_calls;
drop table if exists futbeat_private.news_feeds;
drop table if exists futbeat_private.news_provider_config;
drop table if exists futbeat_private.news_sources;
drop index if exists futbeat_private.news_articles_url_key_idx;
drop index if exists futbeat_private.news_articles_cluster_idx;
alter table futbeat_private.news_articles
  drop column if exists url_key, drop column if exists source_domain,
  drop column if exists source_role, drop column if exists image_url,
  drop column if exists category, drop column if exists transfer_status,
  drop column if exists cluster_id, drop column if exists title_tokens,
  drop column if exists name_tokens, drop column if exists content_hash,
  drop column if exists attribution, drop column if exists contract_version,
  drop column if exists updated_at;
notify pgrst, 'reload schema';
commit;
