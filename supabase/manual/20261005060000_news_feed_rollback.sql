-- NEWS113 v1: remove only the read endpoint; preserve shared tables and rows.
drop function if exists public.futbeat_read_news_feed(text[],text);
notify pgrst,'reload schema';
