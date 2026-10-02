-- National teams under their localized name (Spanish UI).
--
-- The provider stores national teams as plain teams: an English name
-- ("Poland U19", "Netherlands W"), an empty country and no national-team flag.
-- The app can only localize a country it can identify, so every team payload
-- the API returns may carry `nationalTeamCode` (a country_catalog code) and
-- `nationalTeamSuffix` ("U19", "W", "U20 W"). The identity is derived once
-- per catalog revision here (cached, at most every 10 minutes) and attached
-- by the API to team objects; no read model computes it per row.
--
-- Everything is derived from catalog data: no team, league or country is
-- named in the SQL below.
--
-- A team is a national team when BOTH hold:
-- (a) its name, minus a recognised age/gender suffix (U17..U23, W, Women),
--     is exactly one country's catalogued canonical name or alias (a term
--     shared by two countries is ambiguous and never used), and
-- (b) it takes part in an international national-team competition: one
--     classified international_national, or a non-domestic one (no country,
--     or a supranational region) whose participants are mostly teams named
--     after countries. The second branch is what futbeat_read_country_explore
--     calls "other, non-domestic", made robust to the catalog classifying
--     mixed friendlies and youth qualifiers as club competitions: club
--     tournaments have (almost) no country-named participants, national-team
--     tournaments almost only those.
-- A club that shares a country's name plays domestic competitions (or club
-- tournaments) and is never flagged.

-- Provider spellings of catalogued countries seen on national teams.
with extra(country_code,aliases) as (values
 ('AE','["uae"]'::jsonb),('AG','["antigua and barbuda"]'::jsonb),
 ('BA','["bosnia-herzegovina"]'::jsonb),('CD','["congo dr","dr congo"]'::jsonb),
 ('HK','["hong kong, china"]'::jsonb),('IR','["ir iran"]'::jsonb),
 ('KN','["st. kitts and nevis"]'::jsonb),('KP','["korea dpr"]'::jsonb),
 ('MF','["saint martin"]'::jsonb),('MO','["macau","macao"]'::jsonb),
 ('MP','["n. mariana islands"]'::jsonb),('PS','["palestine"]'::jsonb),
 ('PF','["tahiti"]'::jsonb),
 ('TC','["turks and caicos islands"]'::jsonb),('TT','["trinidad and tobago"]'::jsonb),
 ('VC','["st. vincent / grenadines"]'::jsonb),('VI','["us virgin islands"]'::jsonb)
)
update futbeat_private.country_catalog c
 set aliases=(select jsonb_agg(value order by value)
   from (select distinct value from jsonb_array_elements(c.aliases||extra.aliases)) a)
 from extra where c.country_code=extra.country_code and not c.aliases @> extra.aliases;

-- Live derivation (team_id, country_code, suffix). Canonical teams first;
-- redirected aliases answer their canonical team's identity.
create or replace function futbeat_private.national_team_identities()
returns table(team_id text,country_code text,suffix text)
language sql stable security invoker set search_path='' as $$
 with terms as (
   select n.term,min(c.country_code) country_code
   from futbeat_private.country_catalog c
   cross join lateral (select lower(c.canonical_name)
     union select lower(a) from jsonb_array_elements_text(c.aliases) a) n(term)
   where not c.is_supranational
   group by n.term having count(distinct c.country_code)=1
 ), parsed as materialized (
   -- Parsed once per team (a lateral regexp joined to the terms would run it
   -- once per (team, term) pair).
   select e.id team_id,regexp_match(lower(btrim(e.payload->>'name')),
     '^(.+?)(?:\s+(u\d{2}))?(?:\s+(w|women))?$') m
   from futbeat_private.entities e
   where e.kind='team'
     and not exists(select 1 from futbeat_private.entity_redirects r
       where r.kind='team' and r.alias_id=e.id)
 ), named as materialized (
   select p.team_id,t.country_code,
     nullif(concat_ws(' ',upper(p.m[2]),case when p.m[3] is not null then 'W' end),'') suffix
   from parsed p join terms t on t.term=p.m[1]
 ), sides as (
   select m.payload->>'competitionId' competition_id,s.team_id
   from futbeat_private.entities m
   cross join lateral (values(m.payload->>'homeTeamId'),(m.payload->>'awayTeamId')) s(team_id)
   where m.kind='match' and s.team_id is not null
   union
   select e.payload->>'competitionId',e.id from futbeat_private.entities e where e.kind='team'
 ), participants as materialized (
   select distinct coalesce(rc.canonical_id,s.competition_id) competition_id,
     coalesce(rt.canonical_id,s.team_id) team_id
   from sides s
   left join futbeat_private.entity_redirects rc
     on rc.kind='competition' and rc.alias_id=s.competition_id
   left join futbeat_private.entity_redirects rt on rt.kind='team' and rt.alias_id=s.team_id
   where s.competition_id is not null
 ), national_competitions as (
   select p.competition_id
   from participants p
   join futbeat_private.competition_editorial_metadata meta on meta.competition_id=p.competition_id
   left join futbeat_private.country_catalog region on region.country_code=meta.country_code
   left join named n on n.team_id=p.team_id
   where meta.competition_class='international_national' or meta.country_code is null
     or region.is_supranational
   group by p.competition_id,meta.competition_class
   having meta.competition_class='international_national'
     or (count(n.team_id)>=2 and 2*count(n.team_id)>=count(*))
 ), national as (
   select n.team_id,n.country_code,n.suffix from named n
   where exists(select 1 from participants p
     join national_competitions c using(competition_id) where p.team_id=n.team_id)
 )
 select team_id,country_code,suffix from national
 union all
 select r.alias_id,n.country_code,n.suffix from national n
 join futbeat_private.entity_redirects r on r.kind='team' and r.canonical_id=n.team_id
$$;

create table futbeat_private.national_team_cache (
 singleton boolean primary key default true check(singleton),
 version bigint not null,computed_at timestamptz not null,payload jsonb not null
);
alter table futbeat_private.national_team_cache enable row level security;
revoke all on futbeat_private.national_team_cache from public,anon,authenticated;

-- {schemaVersion, version, teams: {teamId: {code, suffix?}}}. Served from the
-- cache while the catalog revision is unchanged; a changed revision is
-- recomputed at most every 10 minutes (the identity of a team practically
-- never changes, and catalog revisions move with every ingested team).
create or replace function public.futbeat_read_national_teams() returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare v_version bigint; v_payload jsonb;
begin
 select revision into v_version from futbeat_private.catalog_cache_version;
 select payload into v_payload from futbeat_private.national_team_cache
   where version=v_version or computed_at>now()-interval '10 minutes';
 if found then return v_payload; end if;
 perform pg_catalog.pg_advisory_xact_lock(hashtextextended('futbeat:national-teams',0));
 select payload into v_payload from futbeat_private.national_team_cache
   where version=v_version or computed_at>now()-interval '10 minutes';
 if found then return v_payload; end if;
 select jsonb_build_object('schemaVersion',1,'version',v_version,
   'teams',coalesce(jsonb_object_agg(i.team_id,jsonb_strip_nulls(jsonb_build_object(
     'code',i.country_code,'suffix',i.suffix))),'{}'::jsonb))
 into v_payload from futbeat_private.national_team_identities() i;
 insert into futbeat_private.national_team_cache values(true,v_version,now(),v_payload)
 on conflict(singleton) do update set version=excluded.version,computed_at=excluded.computed_at,
   payload=excluded.payload;
 return v_payload;
end $$;

revoke all on function futbeat_private.national_team_identities() from public,anon,authenticated;
revoke all on function public.futbeat_read_national_teams() from public,anon,authenticated;
grant execute on function public.futbeat_read_national_teams() to service_role;

notify pgrst,'reload schema';
