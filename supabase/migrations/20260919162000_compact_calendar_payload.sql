-- Reduce the mobile calendar payload without changing visible match data.
-- Keep every match and the fields consumed by Flutter while stripping internal
-- ingestion/rights metadata that the calendar feed never reads.

create or replace function public.futbeat_read_calendar_range(
  p_from_date date,
  p_to_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  with source as materialized (
    select futbeat_private.futbeat_apply_entity_redirects_snapshot(
      futbeat_private.futbeat_read_calendar_range(
        p_from_date,
        p_to_date,
        p_timezone
      )
    ) as value
  ),
  compact_teams as (
    select coalesce(
      jsonb_agg(
        jsonb_strip_nulls(
          jsonb_build_object(
            'id', item->'id',
            'name', item->'name',
            'shortName', item->'shortName',
            'country', item->'country',
            'competitionId', item->'competitionId',
            'media', case
              when item->'media' is null then null
              else jsonb_strip_nulls(
                jsonb_build_object(
                  'url', item#>'{media,url}',
                  'verificationStatus',
                    item#>'{media,verificationStatus}'
                )
              )
            end
          )
        )
        order by item->>'name', item->>'id'
      ),
      '[]'::jsonb
    ) as value
    from source
    cross join lateral jsonb_array_elements(
      coalesce(source.value->'teams','[]'::jsonb)
    ) item
  ),
  compact_competitions as (
    select coalesce(
      jsonb_agg(
        jsonb_strip_nulls(
          jsonb_build_object(
            'id', item->'id',
            'name', item->'name',
            'country', item->'country',
            'media', case
              when item->'media' is null then null
              else jsonb_strip_nulls(
                jsonb_build_object(
                  'url', item#>'{media,url}',
                  'verificationStatus',
                    item#>'{media,verificationStatus}'
                )
              )
            end
          )
        )
        order by item->>'country', item->>'name', item->>'id'
      ),
      '[]'::jsonb
    ) as value
    from source
    cross join lateral jsonb_array_elements(
      coalesce(source.value->'competitions','[]'::jsonb)
    ) item
  ),
  compact_matches as (
    select coalesce(
      jsonb_agg(
        jsonb_strip_nulls(
          jsonb_build_object(
            'id', item->'id',
            'competitionId', item->'competitionId',
            'homeTeamId', item->'homeTeamId',
            'awayTeamId', item->'awayTeamId',
            'startTime', item->'startTime',
            'status', item->'status',
            'score', item->'score',
            'minute', item->'minute',
            'events', coalesce(item->'events','[]'::jsonb),
            'statistics', coalesce(item->'statistics','[]'::jsonb),
            'venue', item->'venue',
            'season', item->'season',
            'provenance', case
              when item->'provenance' is null then null
              else jsonb_strip_nulls(
                jsonb_build_object(
                  'source', item#>'{provenance,source}',
                  'receivedAt', item#>'{provenance,receivedAt}'
                )
              )
            end
          )
        )
        order by item->>'startTime', item->>'id'
      ),
      '[]'::jsonb
    ) as value
    from source
    cross join lateral jsonb_array_elements(
      coalesce(source.value->'matches','[]'::jsonb)
    ) item
  )
  select
    (
      source.value
      - 'teams'
      - 'competitions'
      - 'matches'
    )
    || jsonb_build_object(
      'teams', compact_teams.value,
      'competitions', compact_competitions.value,
      'matches', compact_matches.value
    )
  from source, compact_teams, compact_competitions, compact_matches
$$;

revoke all on function public.futbeat_read_calendar_range(date,date,text)
from public,anon,authenticated;

grant execute on function public.futbeat_read_calendar_range(date,date,text)
to service_role;

notify pgrst,'reload schema';
