-- APPLIED IN PRODUCTION 2026-11-27 04:06Z via ops ledger op 'fb09-twins-v2-r4' (FB-PLAY-17). Recorded here for reproducibility;
-- source kit: fb09/kit-r3/fb09_twins_v2.sql

-- Data backfill (refresh of 506 teams) ran in 21 batches (r4+r5); every later squad store refreshes with v2 itself.
-- FB-09: squad twins v2 (read side only: nothing merged, no redirect, no provider call).
-- GOAL lists one person twice in one squad answer under two catalog ids, often with two name forms
-- ("A. Messi" / "Messi", "Y. Sato" / "Yuya Sato"). v1 (prod) pairs them only when the sorted >=2-token keys are equal,
-- so 1,404 pairs stayed visible. v2 keeps every v1 pair and adds, for a (team, squad answer, known shirt) holding
-- EXACTLY 2 members, neither a PID-1 redirect alias:
--   * compatible folded names (either may be the short form S): S has >=1 full token (len>=2), all of S's full tokens are tokens of
--     the other name, and every initial of S starts some other token of the longer name,
--   * at least one is sparse (no photo, dateOfBirth, age): that one is the alias (hidden); both sparse: fewer name
--     tokens, then smaller id,
--   * never two different known dates of birth; never a followed alias.
-- Reference implementation and impact: fb09/twins_ref.py (prod 2026-11-25: +694 pairs in 433 teams; ZED FC "A. Messi"
-- #14 hidden behind "Messi" #14 b. 1997-09-25). team_squad_hidden_twins / team_squad_player_ids are unchanged.
-- Rollback: fb09_rollback.sql (prod v1 definition) + rollback_<ts>.sql (exact twin rows).

create or replace function futbeat_private.squad_fold_name(p_name text)
returns text language sql immutable set search_path='' as $$
  select btrim(regexp_replace(translate(lower(coalesce(p_name,'')),
    'áàäâãåéèëêíìïîóòöôõúùüûñçý','aaaaaaeeeeiiiiooooouuuuncy'),'[[:space:].''’`´-]+',' ','g'))
$$;

create or replace function futbeat_private.squad_names_compatible(p_a text, p_b text)
returns boolean language sql immutable set search_path='' as $$
  with f as (select futbeat_private.squad_fold_name(p_a) a, futbeat_private.squad_fold_name(p_b) b),
  t as (select string_to_array(a,' ') ta, string_to_array(b,' ') tb from f where a ~ '^[a-z0-9 ]+$' and b ~ '^[a-z0-9 ]+$'),
  -- symmetric: either name may be the short form S of the other L
  sl as (select ta s, tb l from t union all select tb, ta from t),
  parts as (select l, array(select x from unnest(s) x where length(x)>=2) sf, array(select x from unnest(s) x where length(x)=1) si from sl)
  select coalesce((select bool_or(cardinality(sf)>=1
      and sf <@ array(select x from unnest(l) x where length(x)>=2)
      and not exists(select 1 from unnest(si) i where not exists(select 1 from unnest(l) lt where not lt=any(sf) and left(lt,1)=i)))
    from parts), false)
$$;

create or replace function futbeat_private.team_squad_twin_aliases(p_team_id text)
 returns table(alias_id text, canonical_id text) language sql stable set search_path='' as $function$
  with members as (
    select sm.updated_at,e.id,e.payload,
      futbeat_private.squad_shirt_number(e.payload->'shirtNumber') shirt,
      futbeat_private.squad_name_key(e.payload->>'name') name_key,
      futbeat_private.squad_player_sparse(e.payload) sparse,
      futbeat_private.squad_player_rich(e.payload) rich
    from futbeat_private.team_squad_members sm
    join futbeat_private.entities e on e.id=sm.player_id and e.kind='player'
    where sm.team_id=p_team_id
      and not exists(select 1 from futbeat_private.entity_redirects r
        where r.alias_id=sm.player_id and r.kind='player')
  ), v1 as (  -- unchanged prod rule
    select min(id) filter (where sparse) alias_id, min(id) filter (where rich and not sparse) canonical_id
    from members
    where shirt is not null and name_key is not null
    group by updated_at,shirt,name_key
    having count(*)=2 and count(*) filter (where sparse)=1 and count(*) filter (where rich and not sparse)=1
  ), g2 as (  -- v2: same answer + same known shirt, exactly 2 members
    select updated_at, shirt, array_agg(id order by id) ids from members where shirt is not null
    group by updated_at, shirt having count(*)=2
  ), p2 as (
    select a.id a_id, b.id b_id, a.sparse a_sp, b.sparse b_sp,
      cardinality(string_to_array(futbeat_private.squad_fold_name(a.payload->>'name'),' ')) a_n,
      cardinality(string_to_array(futbeat_private.squad_fold_name(b.payload->>'name'),' ')) b_n
    from g2 join members a on a.updated_at=g2.updated_at and a.id=g2.ids[1]
            join members b on b.updated_at=g2.updated_at and b.id=g2.ids[2]
    where futbeat_private.squad_names_compatible(a.payload->>'name', b.payload->>'name')
      and (a.sparse or b.sparse)
      and not (coalesce(btrim(a.payload->>'dateOfBirth'),'')<>'' and coalesce(btrim(b.payload->>'dateOfBirth'),'')<>''
               and btrim(a.payload->>'dateOfBirth')<>btrim(b.payload->>'dateOfBirth'))
  ), v2 as (
    select case when a_sp and not b_sp then a_id when b_sp and not a_sp then b_id
                when (a_n,a_id)<(b_n,b_id) then a_id else b_id end alias_id,
           case when a_sp and not b_sp then b_id when b_sp and not a_sp then a_id
                when (a_n,a_id)<(b_n,b_id) then b_id else a_id end canonical_id
    from p2
  ), allp as (
    select alias_id, canonical_id from v1 where alias_id is not null and canonical_id is not null
    union
    select alias_id, canonical_id from v2
     where not exists(select 1 from futbeat_private.push_follows f where f.entity_id=v2.alias_id)
  )
  -- one alias -> one canonical (a v1/v2 disagreement keeps the v1 pair)
  select distinct on (alias_id) alias_id, canonical_id from allp
  order by alias_id, (alias_id, canonical_id) in (select alias_id, canonical_id from v1) desc, canonical_id
$function$;

revoke all on function futbeat_private.squad_fold_name(text), futbeat_private.squad_names_compatible(text,text)
  from public, anon, authenticated;
