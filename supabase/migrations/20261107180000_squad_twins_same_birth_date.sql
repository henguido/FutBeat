-- BE10 P0.3 (+ BE11 A2 v2): also hide GOAL duplicate ids of the same person inside one squad.
-- GOAL sometimes lists one player under two ids (29 pairs in 26 squads in prod, 2026-11-07):
-- same normalized name, same dateOfBirth, same team. The original rule only catches
-- sparse/rich twins with a shirt number. Presentation only: team_squad_twins is recomputed per
-- team on every squad store; nothing is merged or deleted, stats/history stay on both ids (the
-- hidden id keeps its own detail, reachable from lineups/search), and a rollback restores the
-- previous functions and recomputes the same squads.
-- Kept id: player_identity_richness, then more matchesPlayed, then a valid photo, then min(id).
-- Never hidden: groups of 3+, different/missing birth date, redirected ids, a player that any
-- user follows (checked when stored AND live on every read).
-- team_squad_hidden_twins must change too: it hid only SPARSE aliases (no photo/birth date/age)
-- and a birth-date twin is never sparse, so without it the new twins were stored but NOT hidden.
-- It now also hides a twin whose same-name + same-birth-date evidence still holds live.
-- Note: the manual merge script 2026-10-01_squad_player_identity_merge.sql takes its candidates
-- from team_squad_hidden_twins, so its dry-run will also list these pairs. Do not merge them.
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
      case when jsonb_typeof(e.payload->'matchesPlayed')='number'
        then (e.payload->>'matchesPlayed')::numeric else -1 end played,
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
      (array_agg(id order by richness, played, has_photo, id desc))[1] alias_id,
      (array_agg(id order by richness desc, played desc, has_photo desc, id))[1] canonical_id
    from members
    where dob is not null and dob_name_key is not null
    group by dob_name_key,dob
    having count(*)=2
  )
  select alias_id,canonical_id from groups
  union all
  select d.alias_id,d.canonical_id from dob_groups d
  where not exists(select 1 from groups g
    where d.alias_id in (g.alias_id,g.canonical_id) or d.canonical_id=g.alias_id)
    and not exists(select 1 from futbeat_private.push_follows f
      where f.entity_type='player' and f.entity_id=d.alias_id)
$function$;

create or replace function futbeat_private.team_squad_hidden_twins(p_team_id text)
 returns table(alias_id text, canonical_id text)
 language sql
 stable
 set search_path to ''
as $function$
  select t.alias_id,t.canonical_id
  from futbeat_private.team_squad_twins t
  join futbeat_private.team_squad_members alias_sm
    on alias_sm.team_id=p_team_id and alias_sm.player_id=t.alias_id
  join futbeat_private.team_squad_members partner_sm
    on partner_sm.team_id=p_team_id and partner_sm.player_id=t.canonical_id
  join futbeat_private.entities e on e.id=t.alias_id and e.kind='player'
  left join futbeat_private.entities c on c.id=t.canonical_id and c.kind='player'
  where t.team_id=any(futbeat_private.team_identity_ids(p_team_id))
    and (futbeat_private.squad_player_sparse(e.payload)
      or (nullif(btrim(e.payload->>'dateOfBirth'),'') is not null
        and btrim(e.payload->>'dateOfBirth')=btrim(c.payload->>'dateOfBirth')
        and coalesce(futbeat_private.squad_name_key(e.payload->>'name'),nullif(lower(btrim(e.payload->>'name')),''))
          =coalesce(futbeat_private.squad_name_key(c.payload->>'name'),nullif(lower(btrim(c.payload->>'name')),''))))
    and not exists(select 1 from futbeat_private.entity_redirects r
      where r.kind='player' and r.alias_id in (t.alias_id,t.canonical_id))
    and not exists(select 1 from futbeat_private.push_follows f
      where f.entity_type='player' and f.entity_id=t.alias_id)
$function$;
