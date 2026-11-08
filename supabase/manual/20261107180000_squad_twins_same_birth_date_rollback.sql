CREATE OR REPLACE FUNCTION futbeat_private.team_squad_twin_aliases(p_team_id text)
 RETURNS TABLE(alias_id text, canonical_id text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with members as (
    select sm.updated_at,e.id,
      futbeat_private.squad_shirt_number(e.payload->'shirtNumber') shirt,
      futbeat_private.squad_name_key(e.payload->>'name') name_key,
      futbeat_private.squad_player_sparse(e.payload) sparse,
      futbeat_private.squad_player_rich(e.payload) rich
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
  )
  select alias_id,canonical_id from groups
$function$;

CREATE OR REPLACE FUNCTION futbeat_private.team_squad_hidden_twins(p_team_id text)
 RETURNS TABLE(alias_id text, canonical_id text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select t.alias_id,t.canonical_id
  from futbeat_private.team_squad_twins t
  join futbeat_private.team_squad_members alias_sm
    on alias_sm.team_id=p_team_id and alias_sm.player_id=t.alias_id
  join futbeat_private.team_squad_members partner_sm
    on partner_sm.team_id=p_team_id and partner_sm.player_id=t.canonical_id
  join futbeat_private.entities e on e.id=t.alias_id and e.kind='player'
  where t.team_id=any(futbeat_private.team_identity_ids(p_team_id))
    and futbeat_private.squad_player_sparse(e.payload)
    and not exists(select 1 from futbeat_private.entity_redirects r
      where r.kind='player' and r.alias_id in (t.alias_id,t.canonical_id))
$function$;
