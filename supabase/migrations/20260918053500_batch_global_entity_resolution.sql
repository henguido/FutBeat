-- Resolve many global provider identities inside Postgres so the Edge Function
-- does not make one HTTP RPC per competition/team/match.

create or replace function futbeat_private.futbeat_resolve_global_entities(
  p_provider text,
  p_items jsonb
) returns table(
  entity_kind text,
  external_id text,
  canonical_id text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  item record;
  resolved text;
begin
  if p_provider not in ('sofascore','espn','goal_api')
     or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) > 10000
  then
    raise exception 'Invalid global provider identity batch';
  end if;

  for item in
    with parsed as (
      select
        value->>'kind' as kind,
        value->>'external' as external,
        coalesce(value->>'name','') as name,
        coalesce(value->>'country','') as country,
        coalesce(value->>'shortName','') as short_name
      from jsonb_array_elements(p_items)
    )
    select
      kind,
      external,
      coalesce(max(nullif(name,'')),'') as name,
      coalesce(max(nullif(country,'')),'') as country,
      coalesce(max(nullif(short_name,'')),'') as short_name
    from parsed
    where kind in ('competition','team','match')
      and nullif(external,'') is not null
    group by kind, external
    order by kind, external
  loop
    resolved := futbeat_private.futbeat_resolve_global_entity(
      p_provider,
      item.kind,
      item.external,
      item.name,
      item.country,
      item.short_name
    );

    entity_kind := item.kind;
    external_id := item.external;
    canonical_id := resolved;
    return next;
  end loop;
end;
$$;

create or replace function public.futbeat_resolve_global_entities(
  p_provider text,
  p_items jsonb
) returns table(
  entity_kind text,
  external_id text,
  canonical_id text
)
language sql
security definer
set search_path = ''
as $$
  select *
  from futbeat_private.futbeat_resolve_global_entities(p_provider,p_items)
$$;

revoke all on function
  futbeat_private.futbeat_resolve_global_entities(text,jsonb),
  public.futbeat_resolve_global_entities(text,jsonb)
from public,anon,authenticated;

grant execute on function
  futbeat_private.futbeat_resolve_global_entities(text,jsonb),
  public.futbeat_resolve_global_entities(text,jsonb)
to service_role;

notify pgrst,'reload schema';
