-- Manual fail-closed rollback for News105. Stop/undeploy the v2 news API and
-- collector before running this. It intentionally removes the public v2 feed
-- instead of restoring a reader that could expose revoked snippets/images.
-- Keep the bounded v1 writer: restoring its old global DELETE would allow it
-- to erase v2 rows while the shared table exists.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
drop function if exists public.futbeat_read_news_feed(text,text,jsonb,integer,integer);
drop function if exists futbeat_private.news_feed_current_rights(jsonb);
commit;

-- If P3 must also be rolled back, run its separate rollback afterwards.
-- Do not re-enable v2 reading until the current-rights filter is restored.
