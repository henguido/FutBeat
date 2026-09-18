create or replace function public.futbeat_read_snapshot()
returns jsonb
language sql
stable
set search_path to ''
as $function$
with latest as (
  select snapshot, received_at
  from futbeat_private.imports
  order by received_at desc, job_id desc
  limit 1
),
country_raw as (
  select raw_payload, received_at
  from futbeat_private.imports
  where raw_payload ? 'league'
  order by received_at desc
  limit 1
),
cr_events as (
  select event
  from country_raw,
       lateral jsonb_array_elements(coalesce(raw_payload->'next'->'events','[]'::jsonb)) event
  union all
  select event
  from country_raw,
       lateral jsonb_array_elements(coalesce(raw_payload->'past'->'events','[]'::jsonb)) event
),
cr_badges as (
  select event->>'idHomeTeam' as external_id, event->>'strHomeTeamBadge' as url
  from cr_events
  union all
  select event->>'idAwayTeam', event->>'strAwayTeamBadge'
  from cr_events
),
cr_badge_map as (
  select distinct on (external_id) external_id, url
  from cr_badges
  where external_id is not null
    and url like 'https://%.thesportsdb.com/%'
  order by external_id
),
cr_league as (
  select raw_payload->'league'->'leagues'->0->>'strBadge' as url
  from country_raw
),
base as (
  select snapshot || jsonb_build_object(
    'freshness',
    jsonb_build_object(
      'stale',
      coalesce((snapshot->>'updatedAt')::timestamptz, received_at) < now() - interval '6 hours'
    )
  ) as s
  from latest
),
enriched as (
  select jsonb_set(
    jsonb_set(
      s,
      '{competitions}',
      coalesce((
        select jsonb_agg(
          case
            when coalesce(c->'media','null'::jsonb) <> 'null'::jsonb then c
            when pe.external_id is not null then jsonb_set(
              c,
              '{media}',
              jsonb_build_object(
                'url','https://media.api-sports.io/football/leagues/' || pe.external_id || '.png',
                'kind','COMPETITION_LOGO',
                'source','API-Football',
                'receivedAt',s->>'updatedAt',
                'verificationStatus','VERIFIED',
                'rightsStatus','REVIEW_REQUIRED',
                'usageScope','DEVELOPMENT_ONLY'
              )
            )
            when c->>'id' = 'fb_comp_cr' and (select url from cr_league) is not null then jsonb_set(
              c,
              '{media}',
              jsonb_build_object(
                'url',(select url from cr_league),
                'kind','COMPETITION_LOGO',
                'source','TheSportsDB',
                'receivedAt',s->>'updatedAt',
                'verificationStatus','VERIFIED',
                'rightsStatus','REVIEW_REQUIRED',
                'usageScope','DEVELOPMENT_ONLY'
              )
            )
            else c
          end
          order by ord
        )
        from jsonb_array_elements(coalesce(s->'competitions','[]'::jsonb)) with ordinality x(c,ord)
        left join futbeat_private.provider_entities pe
          on pe.provider = 'api_football'
         and pe.kind = 'competition'
         and pe.canonical_id = c->>'id'
      ), coalesce(s->'competitions','[]'::jsonb)),
      true
    ),
    '{teams}',
    coalesce((
      select jsonb_agg(
        case
          when coalesce(t->'media','null'::jsonb) <> 'null'::jsonb then t
          when pe.external_id is not null then jsonb_set(
            t,
            '{media}',
            jsonb_build_object(
              'url','https://media.api-sports.io/football/teams/' || pe.external_id || '.png',
              'kind','TEAM_LOGO',
              'source','API-Football',
              'receivedAt',s->>'updatedAt',
              'verificationStatus','VERIFIED',
              'rightsStatus','REVIEW_REQUIRED',
              'usageScope','DEVELOPMENT_ONLY'
            )
          )
          when cb.url is not null then jsonb_set(
            t,
            '{media}',
            jsonb_build_object(
              'url',cb.url,
              'kind','TEAM_LOGO',
              'source','TheSportsDB',
              'receivedAt',s->>'updatedAt',
              'verificationStatus','VERIFIED',
              'rightsStatus','REVIEW_REQUIRED',
              'usageScope','DEVELOPMENT_ONLY'
            )
          )
          else t
        end
        order by ord
      )
      from jsonb_array_elements(coalesce(s->'teams','[]'::jsonb)) with ordinality x(t,ord)
      left join futbeat_private.provider_entities pe
        on pe.provider = 'api_football'
       and pe.kind = 'team'
       and pe.canonical_id = t->>'id'
      left join futbeat_private.provider_entities crpe
        on crpe.provider = 'thesportsdb'
       and crpe.kind = 'team'
       and crpe.canonical_id = t->>'id'
      left join cr_badge_map cb
        on cb.external_id = crpe.external_id
    ), coalesce(s->'teams','[]'::jsonb)),
    true
  ) as s
  from base
)
select s from enriched
$function$;

revoke all on function public.futbeat_read_snapshot() from public, anon, authenticated;
grant execute on function public.futbeat_read_snapshot() to service_role;
