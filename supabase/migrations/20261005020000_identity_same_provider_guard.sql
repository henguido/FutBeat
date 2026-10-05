-- Canonical identity: a name alone never merges two ids of one provider.
--
-- Evidence (read-only production, 2026-10-05): GOAL names Andorra's national
-- side "Andorra CF" (its country field equals its own name) and the Spanish
-- club is also "Andorra CF". The base identity path sends GOAL teams with an
-- empty country, and the name fallback treats an empty country as
-- compatible, so the national side's id was mapped onto the club. Same
-- pattern, generic: 65 canonical teams carry 143 GOAL team ids (Al Nasr,
-- Nacional, River Plate, Everton, Olimpia, Platense, Police...); every one of
-- the 17 with observations for several ids plays disjoint competitions per
-- id (different clubs). 1,333 fixtures (373 future) and 1 follow touch them.
-- One competition is affected the same way (Ykkonen, Finland: 2 ids).
--
-- Fix: the name / shortName / alias fallback never merges into an entity
-- that already holds a DIFFERENT id of the same provider (directly or
-- through a redirected alias) unless both sides carry the same country.
-- Ambiguity is still decided over all name matches (two candidates = new
-- entity, as before).
-- Cross-provider matching by name is unchanged. Only future resolutions are
-- affected: existing mappings are left as they are (repair is a separate,
-- authorized data operation; see supabase/manual/20261005020000_identity_split_proposal.sql).
-- Rollback: re-create this function without the "SAME provider" block below
-- (the rest of the body is the production body of 2026-10-05, verbatim).

create or replace function futbeat_private.resolve_global_entity_before_player_lock(
  p_provider text,p_kind text,p_external text,
  p_name text default '',p_country text default '',p_short_name text default ''
) returns text language plpgsql security definer set search_path='' as $$
declare
  result text;
  matched text;
  matches integer;
  v_guard_ok boolean;
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
    return futbeat_private.futbeat_resolve_entity_id(p_kind,result);
  end if;

  if p_kind in ('competition','team') and nullif(p_name,'') is not null then
    -- Ambiguity is decided over ALL compatible name matches; the guard then
    -- applies to the single match (filtering first would turn an ambiguous
    -- name into a "unique" one and merge into the wrong entity).
    select count(*),min(e.id),bool_and(
      -- A second id of the SAME provider is a different team/competition
      -- unless a country corroborates it (both sides carry the same
      -- country): a name alone never merges two provider ids (GOAL sends
      -- teams without country; same-named clubs, or a club and a national
      -- side, are distinct ids).
      (nullif(p_country,'') is not null
        and lower(coalesce(e.payload->>'country',''))=lower(p_country))
      or not exists(
        select 1
        from futbeat_private.provider_entities pe
        where pe.provider=p_provider
          and pe.kind=p_kind
          and pe.external_id<>p_external
          and (
            pe.canonical_id=e.id
            or pe.canonical_id in (
              select r.alias_id
              from futbeat_private.entity_redirects r
              where r.canonical_id=e.id and r.kind=p_kind
            )
          )
      ))
    into matches,matched,v_guard_ok
    from futbeat_private.entities e
    where e.kind=p_kind
      and not exists(
        select 1
        from futbeat_private.entity_redirects r
        where r.alias_id=e.id and r.kind=p_kind
      )
      and (
        lower(coalesce(e.payload->>'name',''))=lower(p_name)
        or (
          nullif(p_short_name,'') is not null
          and lower(coalesce(e.payload->>'shortName',''))=lower(p_short_name)
        )
        or exists(
          select 1
          from jsonb_array_elements_text(
            case
            when jsonb_typeof(e.payload->'aliases')='array'
              then e.payload->'aliases'
            else '[]'::jsonb
          end
          ) a(value)
          where lower(a.value)=lower(p_name)
        )
      )
      and (
        nullif(p_country,'') is null
        or nullif(e.payload->>'country','') is null
        or lower(e.payload->>'country')=lower(p_country)
      );


    if matches=1 and v_guard_ok then
      result:=futbeat_private.futbeat_resolve_entity_id(p_kind,matched);
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
end
$$;
