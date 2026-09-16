create or replace function futbeat_private.normalize_team_name(value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select trim(regexp_replace(
    regexp_replace(
      translate(lower(coalesce(value, '')), 'áéíóúüñ', 'aeiouun'),
      '(^|\s)(club|deportivo|deportiva|asociacion|liga|ld|lda|cs|ad|fc|cf)(\s|$)',
      ' ', 'g'
    ),
    '[^a-z0-9]+', ' ', 'g'
  ));
$$;

create table public.live_match_updates (
  match_id text primary key references futbeat_private.entities(id) on delete cascade,
  provider text not null,
  external_match_id text not null,
  status text not null,
  minute integer check (minute is null or minute >= 0),
  home_score integer check (home_score is null or home_score >= 0),
  away_score integer check (away_score is null or away_score >= 0),
  revision bigint not null check (revision >= 1),
  event_count integer not null default 0 check (event_count >= 0),
  latest_events jsonb not null default '[]'::jsonb check (jsonb_typeof(latest_events) = 'array'),
  changed_at timestamptz not null,
  updated_at timestamptz not null default now(),
  unique (provider, external_match_id)
);

alter table public.live_match_updates enable row level security;
revoke all on public.live_match_updates from public;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant select on public.live_match_updates to anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on public.live_match_updates to authenticated;
  end if;
end $$;

create policy "live match updates are public read only"
on public.live_match_updates
for select
to public
using (true);

do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.live_match_updates;
  end if;
end $$;

create or replace function futbeat_private.try_link_api_football_match(obs jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fixture text := nullif(obs ->> 'externalMatchId', '');
  v_home_external text := nullif(obs #>> '{homeTeam,externalId}', '');
  v_away_external text := nullif(obs #>> '{awayTeam,externalId}', '');
  v_home_name text := nullif(obs #>> '{homeTeam,name}', '');
  v_away_name text := nullif(obs #>> '{awayTeam,name}', '');
  v_start timestamptz := nullif(obs ->> 'startTime', '')::timestamptz;
  v_competition text := nullif(obs ->> 'competitionId', '');
  v_home_canonical text;
  v_away_canonical text;
  v_match text;
begin
  if v_fixture is null then return null; end if;

  select canonical_id into v_match
  from futbeat_private.provider_entities
  where provider='api_football' and kind='match' and external_id=v_fixture;
  if v_match is not null then return v_match; end if;

  if v_home_external is not null then
    select canonical_id into v_home_canonical
    from futbeat_private.provider_entities
    where provider='api_football' and kind='team' and external_id=v_home_external;
  end if;
  if v_away_external is not null then
    select canonical_id into v_away_canonical
    from futbeat_private.provider_entities
    where provider='api_football' and kind='team' and external_id=v_away_external;
  end if;

  if v_home_canonical is null and v_home_name is not null then
    select e.id into v_home_canonical
    from futbeat_private.entities e
    where e.kind='team'
      and (v_competition is null or e.payload ->> 'competitionId' = v_competition)
      and futbeat_private.normalize_team_name(e.payload ->> 'name') = futbeat_private.normalize_team_name(v_home_name)
    limit 1;
  end if;
  if v_away_canonical is null and v_away_name is not null then
    select e.id into v_away_canonical
    from futbeat_private.entities e
    where e.kind='team'
      and (v_competition is null or e.payload ->> 'competitionId' = v_competition)
      and futbeat_private.normalize_team_name(e.payload ->> 'name') = futbeat_private.normalize_team_name(v_away_name)
    limit 1;
  end if;

  if v_home_canonical is null or v_away_canonical is null or v_start is null then return null; end if;

  select e.id into v_match
  from futbeat_private.entities e
  where e.kind='match'
    and e.payload ->> 'homeTeamId' = v_home_canonical
    and e.payload ->> 'awayTeamId' = v_away_canonical
    and abs(extract(epoch from ((e.payload ->> 'startTime')::timestamptz - v_start))) <= 10800
  order by abs(extract(epoch from ((e.payload ->> 'startTime')::timestamptz - v_start)))
  limit 1;

  if v_match is null then return null; end if;

  if v_home_external is not null then
    insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
    values ('api_football','team',v_home_external,v_home_canonical)
    on conflict (provider,kind,external_id) do update set canonical_id=excluded.canonical_id;
  end if;
  if v_away_external is not null then
    insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
    values ('api_football','team',v_away_external,v_away_canonical)
    on conflict (provider,kind,external_id) do update set canonical_id=excluded.canonical_id;
  end if;
  insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
  values ('api_football','match',v_fixture,v_match)
  on conflict (provider,kind,external_id) do update set canonical_id=excluded.canonical_id;
  return v_match;
end;
$$;

create or replace function public.futbeat_publish_live_state(
  p_provider text,
  p_external_match_id text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  s futbeat_private.live_match_state%rowtype;
  ev jsonb;
begin
  select * into s from futbeat_private.live_match_state
  where provider=p_provider and external_match_id=p_external_match_id;
  if not found or s.canonical_match_id is null then return; end if;

  select coalesce(jsonb_agg(payload order by first_seen_at desc, event_key desc),'[]'::jsonb)
  into ev
  from (
    select payload, first_seen_at, event_key
    from futbeat_private.live_events
    where provider=p_provider and external_match_id=p_external_match_id
    order by first_seen_at desc, event_key desc
    limit 10
  ) recent;

  insert into public.live_match_updates(
    match_id,provider,external_match_id,status,minute,home_score,away_score,
    revision,event_count,latest_events,changed_at,updated_at
  ) values (
    s.canonical_match_id,s.provider,s.external_match_id,s.status,s.minute,s.home_score,s.away_score,
    s.revision,s.event_count,ev,s.changed_at,now()
  )
  on conflict(match_id) do update set
    provider=excluded.provider,
    external_match_id=excluded.external_match_id,
    status=excluded.status,
    minute=excluded.minute,
    home_score=excluded.home_score,
    away_score=excluded.away_score,
    revision=excluded.revision,
    event_count=excluded.event_count,
    latest_events=excluded.latest_events,
    changed_at=excluded.changed_at,
    updated_at=excluded.updated_at;
end;
$$;

revoke all on function public.futbeat_publish_live_state(text,text) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.futbeat_publish_live_state(text,text) to service_role;
  end if;
end $$;
