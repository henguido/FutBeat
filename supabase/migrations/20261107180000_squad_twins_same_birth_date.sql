-- BE10 P0.3: also hide GOAL duplicate ids of the same person inside one squad.
-- GOAL sometimes lists one player under two ids (25 squads in prod, 2026-11-07):
-- same normalized name, same dateOfBirth, same team. The original rule only
-- catches sparse/rich twins with a shirt number. The new rule is presentation
-- only (team_squad_twins is recomputed per team on every squad store): nothing is
-- merged or deleted, stats/history stay on both ids, a rollback restores the
-- previous function and recomputes the same squads. The kept id is the richer
-- one (player_identity_richness), then the one with a valid photo, then min(id).
create or replace function futbeat_private.team_squad_twin_aliases(p_team_id text)
 returns table(alias_id text, canonical_id text)
 language sql
 stable
 set search_path to ''
as $function$
  with members as (
    select sm.updated_at,e.id,
      futbeat_private.squad_shirt_number(e.payload->'shirtNumber') shirt,
      futbeat_private.squad_name_key(e.payload->>'name') name_key,
      futbeat_private.squad_player_sparse(e.payload) sparse,
      futbeat_private.squad_player_rich(e.payload) rich,
      nullif(btrim(e.payload->>'dateOfBirth'),'') dob,
      coalesce(futbeat_private.squad_name_key(e.payload->>'name'),
        nullif(lower(btrim(e.payload->>'name')),'')) dob_name_key,
      futbeat_private.player_identity_richness(e.payload) richness,
      futbeat_private.valid_player_media(e.payload->'media') has_photo
    from futbeat_private.team_squad_members sm
    join futbeat_private.entities e on e.id=sm.player_id and e.kind='player'
    where sm.team_id=p_team_id
      and not exists(select 1 from futbeat_private.entity_redirects r
        where r.alias_id=sm.player_id and r.kind='player')
  ), groups as (
    select
      min(id) filter (where sparse) alias_id,
      min(id) filter (where rich and not sparse) canonical_id
    from members
    where shirt is not null and name_key is not null
    group by updated_at,shirt,name_key
    having count(*)=2
      and count(*) filter (where sparse)=1
      and count(*) filter (where rich and not sparse)=1
  ), dob_groups as (
    select
      (array_agg(id order by richness, has_photo, id desc))[1] alias_id,
      (array_agg(id order by richness desc, has_photo desc, id))[1] canonical_id
    from members
    where dob is not null and dob_name_key is not null
    group by dob_name_key,dob
    having count(*)=2
  )
  select alias_id,canonical_id from groups
  union all
  select d.alias_id,d.canonical_id from dob_groups d
  where not exists(select 1 from groups g
    where d.alias_id in (g.alias_id,g.canonical_id) or d.canonical_id in (g.alias_id,g.canonical_id))
$function$;
