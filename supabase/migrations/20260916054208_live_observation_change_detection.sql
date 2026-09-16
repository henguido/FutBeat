create table futbeat_private.provider_observations (
  id bigint generated always as identity primary key,
  provider text not null,
  external_match_id text not null,
  canonical_match_id text references futbeat_private.entities(id) on delete set null,
  received_at timestamptz not null,
  provider_observed_at timestamptz,
  status text not null,
  minute integer check (minute is null or minute >= 0),
  home_score integer check (home_score is null or home_score >= 0),
  away_score integer check (away_score is null or away_score >= 0),
  events jsonb not null default '[]'::jsonb check (jsonb_typeof(events) = 'array'),
  payload_hash text not null check (payload_hash ~ '^[0-9a-f]{64}$'),
  raw_payload jsonb not null,
  unique (provider, external_match_id, payload_hash)
);

create index provider_observations_match_received_idx
  on futbeat_private.provider_observations (provider, external_match_id, received_at desc);
create index provider_observations_received_idx
  on futbeat_private.provider_observations (received_at desc);

create table futbeat_private.live_events (
  provider text not null,
  external_match_id text not null,
  event_key text not null,
  canonical_match_id text references futbeat_private.entities(id) on delete set null,
  event_type text not null,
  minute integer check (minute is null or minute >= 0),
  team_external_id text,
  player_external_id text,
  payload jsonb not null,
  first_seen_at timestamptz not null,
  primary key (provider, external_match_id, event_key)
);

create index live_events_match_seen_idx
  on futbeat_private.live_events (provider, external_match_id, first_seen_at, event_key);

create table futbeat_private.live_match_state (
  provider text not null,
  external_match_id text not null,
  canonical_match_id text references futbeat_private.entities(id) on delete set null,
  status text not null,
  minute integer check (minute is null or minute >= 0),
  home_score integer check (home_score is null or home_score >= 0),
  away_score integer check (away_score is null or away_score >= 0),
  event_count integer not null default 0 check (event_count >= 0),
  last_payload_hash text not null check (last_payload_hash ~ '^[0-9a-f]{64}$'),
  revision bigint not null default 1 check (revision >= 1),
  first_seen_at timestamptz not null,
  last_seen_at timestamptz not null,
  changed_at timestamptz not null,
  primary key (provider, external_match_id)
);

alter table futbeat_private.provider_observations enable row level security;
alter table futbeat_private.live_events enable row level security;
alter table futbeat_private.live_match_state enable row level security;
revoke all on futbeat_private.provider_observations from public;
revoke all on futbeat_private.live_events from public;
revoke all on futbeat_private.live_match_state from public;

create function public.futbeat_record_live_batch(
  p_provider text,
  p_received_at timestamptz,
  p_observations jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  obs jsonb;
  evt jsonb;
  v_external_match_id text;
  v_canonical_match_id text;
  v_payload_hash text;
  v_status text;
  v_minute integer;
  v_home_score integer;
  v_away_score integer;
  v_events jsonb;
  v_provider_observed_at timestamptz;
  v_observation_id bigint;
  v_initial boolean;
  v_score_changed boolean;
  v_status_changed boolean;
  v_minute_changed boolean;
  v_any_changed boolean;
  v_new_events integer;
  v_inserted integer;
  v_revision bigint;
  v_existing futbeat_private.live_match_state%rowtype;
  v_changes jsonb := '[]'::jsonb;
  v_inserted_observations integer := 0;
  v_duplicates integer := 0;
begin
  if p_provider is null or btrim(p_provider) = '' then raise exception 'provider is required'; end if;
  if p_received_at is null then raise exception 'received_at is required'; end if;
  if p_observations is null or jsonb_typeof(p_observations) <> 'array' then raise exception 'observations must be an array'; end if;

  for obs in select value from jsonb_array_elements(p_observations)
  loop
    v_external_match_id := nullif(obs ->> 'externalMatchId', '');
    v_payload_hash := nullif(obs ->> 'payloadHash', '');
    v_status := nullif(obs ->> 'status', '');
    v_minute := nullif(obs ->> 'minute', '')::integer;
    v_home_score := nullif(obs #>> '{score,home}', '')::integer;
    v_away_score := nullif(obs #>> '{score,away}', '')::integer;
    v_events := coalesce(obs -> 'events', '[]'::jsonb);
    v_provider_observed_at := nullif(obs ->> 'providerObservedAt', '')::timestamptz;

    if v_external_match_id is null then raise exception 'externalMatchId is required'; end if;
    if v_payload_hash is null or v_payload_hash !~ '^[0-9a-f]{64}$' then raise exception 'invalid payloadHash'; end if;
    if v_status is null then raise exception 'status is required'; end if;
    if jsonb_typeof(v_events) <> 'array' then raise exception 'events must be an array'; end if;

    perform pg_advisory_xact_lock(hashtext(p_provider || ':' || v_external_match_id));

    select pe.canonical_id into v_canonical_match_id
      from futbeat_private.provider_entities pe
     where pe.provider = p_provider and pe.kind = 'match' and pe.external_id = v_external_match_id;

    insert into futbeat_private.provider_observations (
      provider, external_match_id, canonical_match_id, received_at, provider_observed_at,
      status, minute, home_score, away_score, events, payload_hash, raw_payload
    ) values (
      p_provider, v_external_match_id, v_canonical_match_id, p_received_at, v_provider_observed_at,
      v_status, v_minute, v_home_score, v_away_score, v_events, v_payload_hash,
      coalesce(obs -> 'rawPayload', '{}'::jsonb)
    )
    on conflict (provider, external_match_id, payload_hash) do nothing
    returning id into v_observation_id;

    if v_observation_id is null then
      v_duplicates := v_duplicates + 1;
      update futbeat_private.live_match_state set last_seen_at = greatest(last_seen_at, p_received_at)
       where provider = p_provider and external_match_id = v_external_match_id;
      continue;
    end if;

    v_inserted_observations := v_inserted_observations + 1;
    select * into v_existing from futbeat_private.live_match_state
     where provider = p_provider and external_match_id = v_external_match_id for update;
    v_initial := not found;

    v_new_events := 0;
    for evt in select value from jsonb_array_elements(v_events)
    loop
      if nullif(evt ->> 'eventKey', '') is null then raise exception 'eventKey is required'; end if;
      insert into futbeat_private.live_events (
        provider, external_match_id, event_key, canonical_match_id, event_type, minute,
        team_external_id, player_external_id, payload, first_seen_at
      ) values (
        p_provider, v_external_match_id, evt ->> 'eventKey', v_canonical_match_id,
        coalesce(nullif(evt ->> 'type', ''), 'OTHER'), nullif(evt ->> 'minute', '')::integer,
        nullif(evt ->> 'teamExternalId', ''), nullif(evt ->> 'playerExternalId', ''), evt, p_received_at
      ) on conflict (provider, external_match_id, event_key) do nothing;
      get diagnostics v_inserted = row_count;
      v_new_events := v_new_events + v_inserted;
    end loop;

    if v_initial then
      insert into futbeat_private.live_match_state (
        provider, external_match_id, canonical_match_id, status, minute, home_score, away_score,
        event_count, last_payload_hash, revision, first_seen_at, last_seen_at, changed_at
      ) values (
        p_provider, v_external_match_id, v_canonical_match_id, v_status, v_minute,
        v_home_score, v_away_score, v_new_events, v_payload_hash, 1,
        p_received_at, p_received_at, p_received_at
      );
      v_revision := 1;
      v_score_changed := false;
      v_status_changed := false;
      v_minute_changed := false;
      v_any_changed := true;
    else
      v_score_changed := v_existing.home_score is distinct from v_home_score or v_existing.away_score is distinct from v_away_score;
      v_status_changed := v_existing.status is distinct from v_status;
      v_minute_changed := v_existing.minute is distinct from v_minute;
      v_any_changed := v_score_changed or v_status_changed or v_minute_changed or v_new_events > 0;
      v_revision := v_existing.revision + case when v_any_changed then 1 else 0 end;
      update futbeat_private.live_match_state
         set canonical_match_id = coalesce(v_canonical_match_id, canonical_match_id),
             status = v_status, minute = v_minute, home_score = v_home_score, away_score = v_away_score,
             event_count = event_count + v_new_events, last_payload_hash = v_payload_hash,
             revision = v_revision, last_seen_at = p_received_at,
             changed_at = case when v_any_changed then p_received_at else changed_at end
       where provider = p_provider and external_match_id = v_external_match_id;
    end if;

    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'externalMatchId', v_external_match_id,
      'canonicalMatchId', v_canonical_match_id,
      'initial', v_initial,
      'stateChanged', v_any_changed,
      'scoreChanged', v_score_changed,
      'statusChanged', v_status_changed,
      'minuteChanged', v_minute_changed,
      'newEvents', case when v_initial then 0 else v_new_events end,
      'storedEvents', v_new_events,
      'notifyCandidate', (not v_initial) and (v_score_changed or v_status_changed or v_new_events > 0),
      'revision', v_revision
    ));
  end loop;

  return jsonb_build_object(
    'provider', p_provider,
    'insertedObservations', v_inserted_observations,
    'duplicates', v_duplicates,
    'changes', v_changes
  );
end;
$$;

revoke all on function public.futbeat_record_live_batch(text, timestamptz, jsonb) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on function public.futbeat_record_live_batch(text, timestamptz, jsonb) from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke all on function public.futbeat_record_live_batch(text, timestamptz, jsonb) from authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.futbeat_record_live_batch(text, timestamptz, jsonb) to service_role;
  end if;
end $$;
