-- MANUAL, ONE-OFF REPAIR PROPOSAL (not a migration; never run by `supabase db push`).
-- NOT EXECUTED. Requires explicit authorization; run AFTER migration
-- 20261005020000_identity_same_provider_guard.sql is applied (otherwise the
-- next ingest re-merges by name).
--
-- Problem: canonical teams/competitions holding several ids of ONE provider
-- because the name fallback merged same-named, different entities (club vs
-- national side "Andorra CF"; Nacional UY/PY; River Plate AR/UY; ...).
-- Production 2026-10-05: 65 teams / 143 GOAL ids, 1 competition / 2 ids,
-- 1,333 fixtures (373 future), 1 follow.
--
-- Plan (per affected canonical C with ids e1..en of provider P):
--   0. DRY RUN (section A) and review the list by hand; nothing is guessed.
--   1. Keep on C the id with the most observed fixtures (ties: lowest id).
--   2. For every other id ek: create a NEW entity (same name/country/badge,
--      no aliases), remap provider_entities(P,kind,ek) to it, and record
--      (C, ek, new id) in futbeat_private.identity_split_audit.
--   3. Fixtures: a match whose GOAL observation names ek as home/away moves
--      that side to the new entity (section C, evidence only). Matches with
--      no observation are corrected by re-ingesting their dates/team
--      fixtures (the normal ingest now resolves ek to the new entity).
--   4. Follows on C stay on C (the user followed what they saw; 1 row).
--   5. Invalidate the compact calendar cache for the affected dates.
-- Rollback: section D (remaps every ek back to C from the audit table and
-- restores the saved match payload sides). New entities are left orphaned
-- and harmless until deleted.

-- A. DRY RUN (read-only) ---------------------------------------------------
with multi as (
  select provider,kind,canonical_id,count(*) ids
  from futbeat_private.provider_entities
  where kind in ('team','competition')
  group by 1,2,3 having count(*)>1
), ext as (
  select m.provider,m.kind,m.canonical_id,pe.external_id,
    (select count(*) from futbeat_private.provider_observations o
      where o.provider=m.provider
        and (o.raw_payload->'homeTeam'->>'id'=pe.external_id
          or o.raw_payload->'awayTeam'->>'id'=pe.external_id)) observed_matches,
    (select string_agg(distinct o.raw_payload->'league'->>'name',' | ')
      from futbeat_private.provider_observations o
      where o.provider=m.provider
        and (o.raw_payload->'homeTeam'->>'id'=pe.external_id
          or o.raw_payload->'awayTeam'->>'id'=pe.external_id)) leagues
  from multi m
  join futbeat_private.provider_entities pe
    on pe.provider=m.provider and pe.kind=m.kind and pe.canonical_id=m.canonical_id
)
select e.payload->>'name' name,x.*
from ext x join futbeat_private.entities e on e.id=x.canonical_id
order by name,observed_matches desc,external_id;

-- B. SPLIT (write; run inside one transaction only after review) ------------
-- begin;
-- create table if not exists futbeat_private.identity_split_audit(
--   provider text,kind text,external_id text,old_canonical text,new_canonical text,
--   split_at timestamptz default now(),primary key(provider,kind,external_id));
-- with multi as (
--   select provider,kind,canonical_id from futbeat_private.provider_entities
--   where kind in ('team','competition') group by 1,2,3 having count(*)>1
-- ), ranked as (
--   select pe.*,row_number() over (partition by pe.provider,pe.kind,pe.canonical_id
--     order by (select count(*) from futbeat_private.provider_observations o
--       where o.provider=pe.provider
--         and (o.raw_payload->'homeTeam'->>'id'=pe.external_id
--           or o.raw_payload->'awayTeam'->>'id'=pe.external_id)) desc,pe.external_id) rn
--   from futbeat_private.provider_entities pe join multi using(provider,kind,canonical_id)
-- ), moved as (
--   select r.*,'fb_'||r.kind||'_'||replace(gen_random_uuid()::text,'-','') new_id
--   from ranked r where rn>1
-- ), ins as (
--   insert into futbeat_private.entities(id,kind,payload)
--   select m.new_id,m.kind,jsonb_build_object('id',m.new_id,
--     'name',e.payload->>'name','country',coalesce(e.payload->>'country',''),
--     'shortName',coalesce(e.payload->>'shortName',''))
--   from moved m join futbeat_private.entities e on e.id=m.canonical_id
--   returning id
-- ), aud as (
--   insert into futbeat_private.identity_split_audit(provider,kind,external_id,old_canonical,new_canonical)
--   select provider,kind,external_id,canonical_id,new_id from moved returning 1
-- )
-- update futbeat_private.provider_entities pe set canonical_id=m.new_id
-- from moved m where pe.provider=m.provider and pe.kind=m.kind and pe.external_id=m.external_id;
-- -- C. fixtures with evidence: move the side named by an observation.
-- update futbeat_private.entities x set payload=jsonb_set(x.payload,'{homeTeamId}',to_jsonb(a.new_canonical))
-- from futbeat_private.identity_split_audit a
-- where a.kind='team' and x.kind='match' and x.payload->>'homeTeamId'=a.old_canonical
--   and exists(select 1 from futbeat_private.provider_observations o
--     where o.canonical_match_id=x.id and o.raw_payload->'homeTeam'->>'id'=a.external_id);
-- (same statement for awayTeamId / awayTeam)
-- commit;

-- D. ROLLBACK (write) --------------------------------------------------------
-- begin;
-- update futbeat_private.provider_entities pe set canonical_id=a.old_canonical
-- from futbeat_private.identity_split_audit a
-- where pe.provider=a.provider and pe.kind=a.kind and pe.external_id=a.external_id;
-- update futbeat_private.entities x set payload=jsonb_set(x.payload,'{homeTeamId}',to_jsonb(a.old_canonical))
-- from futbeat_private.identity_split_audit a where x.kind='match' and x.payload->>'homeTeamId'=a.new_canonical;
-- (same for awayTeamId)
-- commit;
