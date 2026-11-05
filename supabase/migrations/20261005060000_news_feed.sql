-- NEWS113: read-only Noticias v1 from the existing news/transfer tables.
-- No collector, source activation, image ingestion or retention side effects.
create or replace function public.futbeat_read_news_feed(
  p_subjects text[] default '{}', p_country text default null
) returns jsonb language sql stable security definer set search_path='' as $$
  with followed as (
    select split_part(k,':',1) subject_type,
      futbeat_private.futbeat_resolve_entity_id(
        split_part(k,':',1),split_part(k,':',2)
      ) subject_id
    from unnest(coalesce(p_subjects,'{}'::text[])) with ordinality s(k,ord)
    where s.ord<=50 and k ~ '^(team|player|competition):fb_[A-Za-z0-9_]+$'
  ), recent as (
    select a.* from futbeat_private.news_articles a
    where a.published_at>=now()-interval '14 days'
      and a.published_at<=now()+interval '1 hour'
  ), tagged as (
    select a.id,
      min(case
        when exists(select 1 from followed f
          where f.subject_type=ns.subject_type
            and f.subject_id=futbeat_private.futbeat_resolve_entity_id(
              ns.subject_type,ns.subject_id)) then 1
        when p_country ~ '^[A-Z]{2}$' and (
          (ns.subject_type='team' and exists(
            select 1 from futbeat_private.entities t
            join futbeat_private.competition_editorial_metadata m
              on m.competition_id=t.payload->>'competitionId'
            where t.kind='team'
              and t.id=futbeat_private.futbeat_resolve_entity_id(
                'team',ns.subject_id)
              and m.country_code=p_country))
          or (ns.subject_type='competition' and exists(
            select 1 from futbeat_private.competition_editorial_metadata m
            where m.competition_id=futbeat_private.futbeat_resolve_entity_id(
              'competition',ns.subject_id)
              and m.country_code=p_country))) then 2
        else 3 end) tier
    from recent a join futbeat_private.news_subjects ns on ns.article_id=a.id
    group by a.id
  ), unique_titles as (
    select distinct on (lower(regexp_replace(btrim(a.title),'\s+',' ','g')))
      a.*,coalesce(t.tier,3) tier
    from recent a left join tagged t on t.id=a.id
    order by lower(regexp_replace(btrim(a.title),'\s+',' ','g')),
      coalesce(t.tier,3),a.published_at desc,a.id
  ), picked as (
    select * from unique_titles order by tier,published_at desc,id limit 40
  ), transfers as (
    select tr.*,p.payload->>'name' player_name,
      ft.payload->>'name' from_team_name,
      tt.payload->>'name' to_team_name,
      case when exists(select 1 from followed f where
        (f.subject_type='player' and f.subject_id=tr.player_id)
        or (f.subject_type='team' and f.subject_id in
          (tr.from_team_id,tr.to_team_id))) then 1 else 2 end tier
    from futbeat_private.transfer_events tr
    left join futbeat_private.entities p on p.id=tr.player_id and p.kind='player'
    left join futbeat_private.entities ft on ft.id=tr.from_team_id and ft.kind='team'
    left join futbeat_private.entities tt on tt.id=tr.to_team_id and tt.kind='team'
    where tr.detected_at>=now()-interval '30 days'
      and p.payload->>'name' is not null
    order by tier,tr.detected_at desc,tr.id desc limit 30
  )
  select jsonb_build_object(
    'schemaVersion',1,'demo',false,'updatedAt',now(),
    'coverage',jsonb_build_object('partial',false),
    'freshness',jsonb_build_object('stale',false),
    'competitions','[]'::jsonb,'teams','[]'::jsonb,
    'players','[]'::jsonb,'matches','[]'::jsonb,
    'standings','[]'::jsonb,
    'news',(select coalesce(jsonb_agg(jsonb_build_object(
      'id',id,'title',title,'url',url,'sourceName',source_name,
      'publishedAt',published_at,'language',language,'followed',tier=1)
      order by tier,published_at desc,id),'[]'::jsonb) from picked),
    'transfers',(select coalesce(jsonb_agg(jsonb_build_object(
      'id',id,'playerId',player_id,'playerName',player_name,
      'fromTeamId',from_team_id,'fromTeamName',from_team_name,
      'toTeamId',to_team_id,'toTeamName',to_team_name,
      'detectedAt',detected_at,'status',status,'source',source_label)
      order by tier,detected_at desc,id desc),'[]'::jsonb) from transfers)
  )
$$;

revoke all on function public.futbeat_read_news_feed(text[],text)
  from public,anon,authenticated;
grant execute on function public.futbeat_read_news_feed(text[],text)
  to service_role;

notify pgrst,'reload schema';
