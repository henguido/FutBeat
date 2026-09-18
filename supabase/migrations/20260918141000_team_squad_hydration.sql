-- Team/player detail hydration driven by centralized FutBeat interests.

alter table futbeat_private.provider_entities
  drop constraint if exists provider_entities_kind_check;

create table if not exists futbeat_private.team_squad_members(
  team_id text not null references futbeat_private.entities(id) on delete cascade,
  player_id text not null references futbeat_private.entities(id) on delete cascade,
  provider text not null,
  updated_at timestamptz not null default now(),
  primary key(team_id,player_id)
);

create table if not exists futbeat_private.team_detail_coverage(
  team_id text primary key references futbeat_private.entities(id) on delete cascade,
  provider text not null,
  fetched_at timestamptz not null,
  player_count integer not null check(player_count>=0)
);

alter table futbeat_private.team_squad_members enable row level security;
alter table futbeat_private.team_detail_coverage enable row level security;

revoke all on futbeat_private.team_squad_members from public,anon,authenticated;
revoke all on futbeat_private.team_detail_coverage from public,anon,authenticated;

create index if not exists team_squad_members_player_idx
  on futbeat_private.team_squad_members(player_id);

create index if not exists team_detail_coverage_fetched_idx
  on futbeat_private.team_detail_coverage(fetched_at);

create or replace function futbeat_private.futbeat_resolve_global_entity(
  p_provider text,
  p_kind text,
  p_external text,
  p_name text default '',
  p_country text default '',
  p_short_name text default ''
) returns text
language plpgsql
security definer
set search_path=''
as $$
declare
  result text;
  matched text;
  matches integer;
begin
  if p_provider not in ('sofascore','espn','goal_api')
     or p_kind not in ('competition','team','match','player')
     or nullif(p_external,'') is null
  then
    raise exception 'Invalid global provider identity';
  end if;

  select canonical_id into result
    from futbeat_private.provider_entities
   where provider=p_provider
     and kind=p_kind
     and external_id=p_external;

  if result is not null then
    return result;
  end if;

  if p_kind in ('competition','team') and nullif(p_name,'') is not null then
    select count(*),min(id)
      into matches,matched
      from futbeat_private.entities
     where kind=p_kind
       and (
         lower(coalesce(payload->>'name',''))=lower(p_name)
         or (
           nullif(p_short_name,'') is not null
           and lower(coalesce(payload->>'shortName',''))=lower(p_short_name)
         )
       )
       and (
         nullif(p_country,'') is null
         or nullif(payload->>'country','') is null
         or lower(payload->>'country')=lower(p_country)
       );

    if matches=1 then
      result:=matched;
    end if;
  end if;

  if result is null then
    result:='fb_' || p_kind || '_' || replace(gen_random_uuid()::text,'-','');
    insert into futbeat_private.entities(id,kind,payload)
    values(
      result,
      p_kind,
      jsonb_build_object(
        'id',result,
        'name',coalesce(p_name,''),
        'country',coalesce(p_country,''),
        'shortName',coalesce(p_short_name,'')
      )
    )
    on conflict(id) do nothing;
  end if;

  insert into futbeat_private.provider_entities(
    provider,kind,external_id,canonical_id
  )
  values(p_provider,p_kind,p_external,result)
  on conflict(provider,kind,external_id)
  do update set canonical_id=excluded.canonical_id;

  return result;
end;
$$;

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
set search_path=''
as $$
declare
  item record;
  resolved text;
begin
  if p_provider not in ('sofascore','espn','goal_api')
     or jsonb_typeof(p_items)<>'array'
     or jsonb_array_length(p_items)>10000
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
    where kind in ('competition','team','match','player')
      and nullif(external,'') is not null
    group by kind,external
    order by kind,external
  loop
    resolved:=futbeat_private.futbeat_resolve_global_entity(
      p_provider,
      item.kind,
      item.external,
      item.name,
      item.country,
      item.short_name
    );

    entity_kind:=item.kind;
    external_id:=item.external;
    canonical_id:=resolved;
    return next;
  end loop;
end;
$$;

create or replace function futbeat_private.futbeat_team_squad_plan(
  p_limit integer default 5
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  result jsonb;
begin
  if p_limit<1 or p_limit>25 then
    raise exception 'Invalid squad plan limit';
  end if;

  perform futbeat_private.refresh_interest_aggregates();

  with candidates as (
    select
      ci.subject_id as team_id,
      ci.priority_score,
      case
        when ci.explicit_followers>0 then 'follow'
        else 'temporary'
      end as reason
    from futbeat_private.coverage_interests ci
    where ci.subject_type='team'

    union all

    select
      t.id,
      50000 as priority_score,
      'costa_rica' as reason
    from futbeat_private.entities t
    join futbeat_private.entities c
      on c.id=t.payload->>'competitionId'
     and c.kind='competition'
    where t.kind='team'
      and lower(coalesce(c.payload->>'country','')) in ('costa rica','cr')
  ),
  ranked as (
    select
      team_id,
      max(priority_score) as priority_score,
      min(reason) filter(where priority_score=(
        select max(c2.priority_score)
        from candidates c2
        where c2.team_id=candidates.team_id
      )) as reason
    from candidates
    group by team_id
  ),
  due as (
    select
      r.team_id,
      pe.external_id,
      r.priority_score,
      coalesce(r.reason,'interest') as reason,
      cov.fetched_at
    from ranked r
    join futbeat_private.provider_entities pe
      on pe.canonical_id=r.team_id
     and pe.provider='goal_api'
     and pe.kind='team'
    left join futbeat_private.team_detail_coverage cov
      on cov.team_id=r.team_id
    where cov.fetched_at is null
       or cov.fetched_at < now()-interval '7 days'
    order by
      r.priority_score desc,
      cov.fetched_at nulls first,
      r.team_id
    limit p_limit
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'teamId',team_id,
        'externalTeamId',external_id,
        'priority',priority_score,
        'reason',reason,
        'lastFetchedAt',fetched_at
      )
      order by priority_score desc,fetched_at nulls first,team_id
    ),
    '[]'::jsonb
  )
  into result
  from due;

  return result;
end;
$$;

create or replace function futbeat_private.futbeat_store_team_squad(
  p_team_id text,
  p_provider text,
  p_received_at timestamptz,
  p_players jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  player_count integer;
begin
  if p_provider<>'goal_api'
     or jsonb_typeof(p_players)<>'array'
     or jsonb_array_length(p_players)>100
     or not exists(
       select 1
       from futbeat_private.entities
       where id=p_team_id and kind='team'
     )
  then
    raise exception 'Invalid team squad payload';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_players) p
    where nullif(p->>'id','') is null
       or p->>'teamId'<>p_team_id
       or p->'provenance'->>'source'<>'GOAL API'
  ) then
    raise exception 'Invalid player entity';
  end if;

  insert into futbeat_private.entities as e(id,kind,payload)
  select p->>'id','player',p
  from jsonb_array_elements(p_players) p
  on conflict(id) do update
    set payload=excluded.payload
    where e.kind='player'
      and e.payload is distinct from excluded.payload;

  delete from futbeat_private.team_squad_members
   where team_id=p_team_id
     and provider=p_provider;

  insert into futbeat_private.team_squad_members(
    team_id,player_id,provider,updated_at
  )
  select p_team_id,p->>'id',p_provider,p_received_at
  from jsonb_array_elements(p_players) p
  on conflict(team_id,player_id) do update set
    provider=excluded.provider,
    updated_at=excluded.updated_at;

  player_count:=jsonb_array_length(p_players);

  insert into futbeat_private.team_detail_coverage(
    team_id,provider,fetched_at,player_count
  )
  values(p_team_id,p_provider,p_received_at,player_count)
  on conflict(team_id) do update set
    provider=excluded.provider,
    fetched_at=excluded.fetched_at,
    player_count=excluded.player_count;

  return jsonb_build_object(
    'teamId',p_team_id,
    'players',player_count,
    'fetchedAt',p_received_at
  );
end;
$$;

create or replace function futbeat_private.futbeat_read_entity_detail(
  p_type text,
  p_id text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  entity_row futbeat_private.entities;
  team_id text;
  competition_id text;
  matches_json jsonb;
  teams_json jsonb;
  competitions_json jsonb;
  players_json jsonb;
  detail_updated_at timestamptz;
begin
  if p_type not in ('team','player','competition')
     or nullif(p_id,'') is null
  then
    raise exception 'Invalid entity detail request';
  end if;

  select * into entity_row
  from futbeat_private.entities
  where id=p_id and kind=p_type;

  if not found then
    return null;
  end if;

  if p_type='competition' then
    competition_id:=p_id;
  elsif p_type='team' then
    team_id:=p_id;
    competition_id:=nullif(entity_row.payload->>'competitionId','');
  else
    team_id:=nullif(entity_row.payload->>'teamId','');
    if team_id is not null then
      select nullif(payload->>'competitionId','')
      into competition_id
      from futbeat_private.entities
      where id=team_id and kind='team';
    end if;
  end if;

  with relevant as (
    select e.payload,cm.start_time,cm.updated_at
    from futbeat_private.calendar_matches cm
    join futbeat_private.entities e
      on e.id=cm.match_id and e.kind='match'
    where (
      p_type='competition'
      and e.payload->>'competitionId'=competition_id
    ) or (
      p_type in ('team','player')
      and team_id is not null
      and (
        e.payload->>'homeTeamId'=team_id
        or e.payload->>'awayTeamId'=team_id
      )
    )
    order by abs(extract(epoch from (cm.start_time-now())))
    limit 100
  )
  select
    coalesce(jsonb_agg(payload order by start_time),'[]'::jsonb),
    max(updated_at)
  into matches_json,detail_updated_at
  from relevant;

  with ids as (
    select distinct value->>'homeTeamId' as id
    from jsonb_array_elements(matches_json)
    union
    select distinct value->>'awayTeamId'
    from jsonb_array_elements(matches_json)
    union
    select team_id where team_id is not null
  )
  select coalesce(
    jsonb_agg(e.payload order by e.payload->>'name',e.id),
    '[]'::jsonb
  )
  into teams_json
  from futbeat_private.entities e
  where e.kind='team'
    and (
      e.id in (select id from ids where id is not null)
      or (
        p_type='competition'
        and e.payload->>'competitionId'=competition_id
      )
    );

  with ids as (
    select distinct value->>'competitionId' as id
    from jsonb_array_elements(matches_json)
    union
    select competition_id where competition_id is not null
  )
  select coalesce(
    jsonb_agg(e.payload order by e.payload->>'country',e.payload->>'name',e.id),
    '[]'::jsonb
  )
  into competitions_json
  from futbeat_private.entities e
  where e.kind='competition'
    and e.id in (select id from ids where id is not null);

  if p_type='team' then
    select coalesce(
      jsonb_agg(e.payload order by e.payload->>'position',e.payload->>'name',e.id),
      '[]'::jsonb
    )
    into players_json
    from futbeat_private.team_squad_members sm
    join futbeat_private.entities e
      on e.id=sm.player_id and e.kind='player'
    where sm.team_id=p_id;
  elsif p_type='player' then
    players_json:=jsonb_build_array(entity_row.payload);
  else
    players_json:='[]'::jsonb;
  end if;

  if p_type='team' then
    select greatest(
      coalesce(detail_updated_at,'epoch'::timestamptz),
      coalesce(fetched_at,'epoch'::timestamptz)
    )
    into detail_updated_at
    from futbeat_private.team_detail_coverage cov
    where cov.team_id=p_id;
  end if;

  return jsonb_build_object(
    'schemaVersion',1,
    'demo',false,
    'updatedAt',coalesce(detail_updated_at,now()),
    'freshness',jsonb_build_object('stale',false),
    'coverage',jsonb_build_object(
      'source','FutBeat',
      'partial',false,
      'live',false,
      'developmentOnly',false,
      'sources',jsonb_build_array('GOAL API')
    ),
    'competitions',competitions_json,
    'teams',teams_json,
    'players',players_json,
    'matches',matches_json,
    'standings','[]'::jsonb
  );
end;
$$;

create or replace function public.futbeat_team_squad_plan(
  p_limit integer default 5
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_team_squad_plan(p_limit)
$$;

create or replace function public.futbeat_store_team_squad(
  p_team_id text,
  p_provider text,
  p_received_at timestamptz,
  p_players jsonb
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_store_team_squad(
    p_team_id,p_provider,p_received_at,p_players
  )
$$;

create or replace function public.futbeat_read_entity_detail(
  p_type text,
  p_id text
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_read_entity_detail(p_type,p_id)
$$;

revoke all on function futbeat_private.futbeat_team_squad_plan(integer)
  from public,anon,authenticated;
revoke all on function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb)
  from public,anon,authenticated;
revoke all on function futbeat_private.futbeat_read_entity_detail(text,text)
  from public,anon,authenticated;

grant execute on function futbeat_private.futbeat_team_squad_plan(integer)
  to service_role;
grant execute on function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb)
  to service_role;
grant execute on function futbeat_private.futbeat_read_entity_detail(text,text)
  to service_role;

revoke all on function public.futbeat_team_squad_plan(integer)
  from public,anon,authenticated;
revoke all on function public.futbeat_store_team_squad(text,text,timestamptz,jsonb)
  from public,anon,authenticated;
revoke all on function public.futbeat_read_entity_detail(text,text)
  from public,anon,authenticated;

grant execute on function public.futbeat_team_squad_plan(integer)
  to service_role;
grant execute on function public.futbeat_store_team_squad(text,text,timestamptz,jsonb)
  to service_role;
grant execute on function public.futbeat_read_entity_detail(text,text)
  to service_role;

notify pgrst,'reload schema';
