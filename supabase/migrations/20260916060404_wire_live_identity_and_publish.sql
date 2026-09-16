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

  -- Automatic identity linking is intentionally restricted to competitions
  -- already tracked by FutBeat. Unknown world fixtures remain provider-only.
  if v_competition is null then return null; end if;

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
      and e.payload ->> 'competitionId' = v_competition
      and futbeat_private.normalize_team_name(e.payload ->> 'name') = futbeat_private.normalize_team_name(v_home_name)
    limit 1;
  end if;
  if v_away_canonical is null and v_away_name is not null then
    select e.id into v_away_canonical
    from futbeat_private.entities e
    where e.kind='team'
      and e.payload ->> 'competitionId' = v_competition
      and futbeat_private.normalize_team_name(e.payload ->> 'name') = futbeat_private.normalize_team_name(v_away_name)
    limit 1;
  end if;

  if v_home_canonical is null or v_away_canonical is null or v_start is null then return null; end if;

  select e.id into v_match
  from futbeat_private.entities e
  where e.kind='match'
    and e.payload ->> 'competitionId' = v_competition
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

create or replace function public.futbeat_record_live_batch(
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
    v_observation_id := null;
    v_canonical_match_id := null;

    if v_external_match_id is null then raise exception 'externalMatchId is required'; end if;
    if v_payload_hash is null or v_payload_hash !~ '^[0-9a-f]{64}$' then raise exception 'invalid payloadHash'; end if;
    if v_status is null then raise exception 'status is required'; end if;
    if jsonb_typeof(v_events) <> 'array' then raise exception 'events must be an array'; end if;

    perform pg_advisory_xact_lock(hashtext(p_provider || ':' || v_external_match_id));

    if p_provider = 'api_football' then
      v_canonical_match_id := futbeat_private.try_link_api_football_match(obs);
    else
      select pe.canonical_id into v_canonical_match_id
        from futbeat_private.provider_entities pe
       where pe.provider = p_provider and pe.kind = 'match' and pe.external_id = v_external_match_id;
    end if;

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
      update futbeat_private.live_match_state
         set last_seen_at = greatest(last_seen_at, p_received_at),
             canonical_match_id = coalesce(v_canonical_match_id, canonical_match_id)
       where provider = p_provider and external_match_id = v_external_match_id;
      if v_canonical_match_id is not null then
        update futbeat_private.provider_observations set canonical_match_id=v_canonical_match_id
         where provider=p_provider and external_match_id=v_external_match_id and canonical_match_id is null;
        update futbeat_private.live_events set canonical_match_id=v_canonical_match_id
         where provider=p_provider and external_match_id=v_external_match_id and canonical_match_id is null;
        perform public.futbeat_publish_live_state(p_provider, v_external_match_id);
      end if;
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

    if v_canonical_match_id is not null then
      update futbeat_private.provider_observations set canonical_match_id=v_canonical_match_id
       where provider=p_provider and external_match_id=v_external_match_id and canonical_match_id is null;
      update futbeat_private.live_events set canonical_match_id=v_canonical_match_id
       where provider=p_provider and external_match_id=v_external_match_id and canonical_match_id is null;
      perform public.futbeat_publish_live_state(p_provider, v_external_match_id);
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
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.futbeat_record_live_batch(text, timestamptz, jsonb) to service_role;
  end if;
end $$;
