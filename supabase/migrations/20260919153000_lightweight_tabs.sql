-- Lightweight data surfaces for Explore and Favorites.
-- These functions keep large fixture catalogs off tabs that only need entity
-- search results or explicitly followed items.

create or replace function public.futbeat_search_catalog(
  p_query text default '',
  p_country text default null,
  p_limit integer default 50
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  with params as (
    select
      lower(btrim(coalesce(p_query,''))) as q,
      case upper(btrim(coalesce(p_country,'')))
        when 'CR' then 'costa rica'
        when 'MX' then 'mexico'
        when 'AR' then 'argentina'
        when 'BR' then 'brazil'
        when 'ES' then 'spain'
        when 'US' then 'united states'
        when 'GB' then 'england'
        when 'DE' then 'germany'
        when 'IT' then 'italy'
        when 'FR' then 'france'
        when 'PT' then 'portugal'
        when 'NL' then 'netherlands'
        else lower(btrim(coalesce(p_country,'')))
      end as country,
      greatest(1,least(coalesce(p_limit,50),75)) as item_limit
  ),
  base as (
    select
      e.id,e.kind,e.payload,
      lower(coalesce(e.payload->>'name','')) as name,
      lower(coalesce(e.payload->>'shortName','')) as short_name,
      lower(coalesce(e.payload->>'country','')) as country
    from futbeat_private.entities e
    where e.kind in ('competition','team','player')
      and not exists(
        select 1
        from futbeat_private.entity_redirects r
        where r.kind=e.kind and r.alias_id=e.id
      )
  ),
  scored as (
    select
      b.*,
      case
        when p.q='' then 0
        when b.name=p.q or b.short_name=p.q then 1000
        when exists(
          select 1
          from jsonb_array_elements_text(
            case
              when jsonb_typeof(b.payload->'aliases')='array'
                then b.payload->'aliases'
              else '[]'::jsonb
            end
          ) a(value)
          where lower(a.value)=p.q
        ) then 980
        when b.name like p.q||'%' or b.short_name like p.q||'%' then 820
        when b.name like '%'||p.q||'%' or b.short_name like '%'||p.q||'%' then 620
        when exists(
          select 1
          from jsonb_array_elements_text(
            case
              when jsonb_typeof(b.payload->'aliases')='array'
                then b.payload->'aliases'
              else '[]'::jsonb
            end
          ) a(value)
          where lower(a.value) like '%'||p.q||'%'
        ) then 600
        when b.country like '%'||p.q||'%' then 320
        else -1
      end as query_score,
      case
        when p.country<>'' and b.country=p.country then
          case when p.q='' then 2200 else 1500 end
        else 0
      end as country_bonus
    from base b
    cross join params p
  ),
  matched as (
    select s.*
    from scored s
    cross join params p
    where p.q='' or s.query_score>=0
  ),
  competitions as (
    select coalesce(
      jsonb_agg(payload order by score desc,name,id),
      '[]'::jsonb
    ) value
    from (
      select
        m.*,
        query_score*100+country_bonus+
        case
          when name like '%champions league%' then 970
          when name like '%libertadores%' then 950
          when country='england' and name='premier league' then 930
          when country='spain' and (name like '%laliga%' or name like '%la liga%') then 920
          when country='italy' and name='serie a' then 910
          when country='germany' and name='bundesliga' then 900
          when country='france' and name='ligue 1' then 890
          when name like '%europa league%' then 880
          when name like '%concacaf champions%' then 760
          when name like '%central american cup%' then 700
          when country='costa rica'
            and (name like '%primera division%' or name like '%promerica%')
            then 660
          when name like '%friendly%' then 40
          when name like '%league%' or name like '%liga%'
            or name like '%copa%' or name like '%cup%' then 260
          else 100
        end as score
      from matched m
      where kind='competition'
      order by score desc,name,id
      limit (select item_limit from params)
    ) ranked
  ),
  team_scores as (
    select
      m.*,
      m.query_score*100+m.country_bonus+
      case
        when lower(coalesce(c.payload->>'name','')) like '%champions league%' then 485
        when lower(coalesce(c.payload->>'name','')) like '%libertadores%' then 475
        when lower(coalesce(c.payload->>'country',''))='england'
          and lower(coalesce(c.payload->>'name',''))='premier league' then 465
        when lower(coalesce(c.payload->>'country',''))='spain'
          and lower(coalesce(c.payload->>'name','')) like '%liga%' then 460
        when lower(coalesce(c.payload->>'country',''))='costa rica' then 330
        else 50
      end as score
    from matched m
    left join futbeat_private.entities c
      on c.id=m.payload->>'competitionId'
     and c.kind='competition'
    where m.kind='team'
  ),
  teams as (
    select coalesce(
      jsonb_agg(payload order by score desc,name,id),
      '[]'::jsonb
    ) value
    from (
      select *
      from team_scores
      order by score desc,name,id
      limit (select item_limit from params)
    ) ranked
  ),
  players as (
    select coalesce(
      jsonb_agg(payload order by score desc,name,id),
      '[]'::jsonb
    ) value
    from (
      select
        m.*,
        m.query_score*100+m.country_bonus as score
      from matched m
      cross join params p
      where m.kind='player'
        and p.q<>''
      order by score desc,name,id
      limit (select item_limit from params)
    ) ranked
  )
  select jsonb_build_object(
    'schemaVersion',1,
    'demo',false,
    'updatedAt',now(),
    'coverage',jsonb_build_object('partial',true),
    'freshness',jsonb_build_object('stale',false),
    'entityRedirects','{}'::jsonb,
    'competitions',competitions.value,
    'teams',teams.value,
    'players',players.value,
    'matches','[]'::jsonb,
    'standings','[]'::jsonb,
    'news','[]'::jsonb,
    'transfers','[]'::jsonb
  )
  from competitions,teams,players
$$;

create or replace function public.futbeat_read_favorites(
  p_keys text[]
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  with parsed as (
    select
      split_part(value,':',1) as kind,
      split_part(value,':',2) as original_id
    from unnest(coalesce(p_keys,array[]::text[])) value
    where split_part(value,':',1) in ('team','player','competition','match')
      and split_part(value,':',2) like 'fb_%'
  ),
  resolved as (
    select
      kind,
      original_id,
      case
        when kind='match' then original_id
        else futbeat_private.futbeat_resolve_entity_id(kind,original_id)
      end as id
    from parsed
  ),
  target_matches as (
    select e.payload
    from futbeat_private.entities e
    join resolved r
      on r.kind='match'
     and r.id=e.id
    where e.kind='match'
  ),
  team_ids as (
    select id from resolved where kind='team'
    union
    select payload->>'homeTeamId' from target_matches
    union
    select payload->>'awayTeamId' from target_matches
  ),
  competition_ids as (
    select id from resolved where kind='competition'
    union
    select payload->>'competitionId' from target_matches
  ),
  teams as (
    select coalesce(jsonb_agg(e.payload order by e.id),'[]'::jsonb) value
    from futbeat_private.entities e
    where e.kind='team'
      and e.id in (select id from team_ids where id is not null)
  ),
  players as (
    select coalesce(jsonb_agg(e.payload order by e.id),'[]'::jsonb) value
    from futbeat_private.entities e
    where e.kind='player'
      and e.id in (select id from resolved where kind='player')
  ),
  competitions as (
    select coalesce(jsonb_agg(e.payload order by e.id),'[]'::jsonb) value
    from futbeat_private.entities e
    where e.kind='competition'
      and e.id in (
        select id from competition_ids where id is not null
      )
  ),
  matches as (
    select coalesce(
      jsonb_agg(payload order by payload->>'id'),
      '[]'::jsonb
    ) value
    from target_matches
  ),
  redirects as (
    select coalesce(
      jsonb_object_agg(original_id,id) filter(where original_id<>id),
      '{}'::jsonb
    ) value
    from resolved
  )
  select jsonb_build_object(
    'schemaVersion',1,
    'demo',false,
    'updatedAt',now(),
    'coverage',jsonb_build_object('partial',true),
    'freshness',jsonb_build_object('stale',false),
    'entityRedirects',redirects.value,
    'competitions',competitions.value,
    'teams',teams.value,
    'players',players.value,
    'matches',matches.value,
    'standings','[]'::jsonb,
    'news','[]'::jsonb,
    'transfers','[]'::jsonb
  )
  from teams,players,competitions,matches,redirects
$$;

revoke all on function
  public.futbeat_search_catalog(text,text,integer),
  public.futbeat_read_favorites(text[])
from public,anon,authenticated;

grant execute on function
  public.futbeat_search_catalog(text,text,integer),
  public.futbeat_read_favorites(text[])
to service_role;

notify pgrst,'reload schema';
