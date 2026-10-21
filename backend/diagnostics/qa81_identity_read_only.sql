-- QA81 (#222) — READ-ONLY verification queries. SELECT only; no writes,
-- no provider calls. For an authorized operator; Claude did not run this
-- against production.
--
-- Usage (psql): set the variables, then run the file.
--   \set player_name '%Acu_a%'
--   \set club_id 'fb_team_car'
--   \set match_day '2026-10-14'
--
-- Names below are used ONLY to locate candidate rows for a human. No
-- decision may be taken from a name match: compare provider ids, birth date,
-- memberships and events.

-- 1. Player identities matching the name, with provider ids and context.
select e.id,
  e.payload->>'name' name,
  e.payload->>'dateOfBirth' dob,
  e.payload->>'teamId' team_id,
  e.payload->>'nationalTeamId' national_team_id,
  (select array_agg(pe.provider||':'||pe.external_id) from futbeat_private.provider_entities pe
    where pe.kind='player' and pe.canonical_id=e.id) provider_ids,
  (select r.canonical_id from futbeat_private.entity_redirects r where r.alias_id=e.id) redirected_to
from futbeat_private.entities e
where e.kind='player' and e.payload->>'name' ilike :'player_name'
order by e.id;

-- 2. Squad memberships of those players (club AND national team expected).
select sm.player_id,sm.team_id,t.payload->>'name' team_name,sm.provider,sm.updated_at
from futbeat_private.team_squad_members sm
join futbeat_private.entities t on t.id=sm.team_id
where sm.player_id in (select id from futbeat_private.entities
  where kind='player' and payload->>'name' ilike :'player_name')
order by sm.player_id,sm.team_id;

-- 3. Club <-> national "transfers" recorded for them (expected: none after
--    20261019100000; existing rows are evidence of the bug).
select te.*
from futbeat_private.transfer_events te
where te.player_id in (select id from futbeat_private.entities
  where kind='player' and payload->>'name' ilike :'player_name')
order by te.detected_at;

-- 4. Matches where they have canonical events (goals, cards, subs).
select ce.match_id,ce.event_type,ce.payload->>'minute' minute,ce.payload->>'teamId' team_id,
  m.payload->>'homeTeamId' home,m.payload->>'awayTeamId' away,m.payload->>'startTime' start
from futbeat_private.canonical_events ce
join futbeat_private.entities m on m.id=ce.match_id
where ce.payload->>'playerId' in (select id from futbeat_private.entities
  where kind='player' and payload->>'name' ilike :'player_name')
order by m.payload->>'startTime' desc
limit 50;

-- 5. Every stored fixture of the club on that UTC day +-1, with mappings.
select m.id,m.payload->>'startTime' start,m.payload->>'status' status,
  m.payload->'score' score,m.payload->>'homeTeamId' home,m.payload->>'awayTeamId' away,
  m.payload->>'competitionId' comp,m.payload#>>'{provenance,verificationStatus}' verification,
  (select array_agg(pe.provider||':'||pe.external_id) from futbeat_private.provider_entities pe
    where pe.kind='match' and pe.canonical_id=m.id) match_provider_ids,
  exists(select 1 from futbeat_private.provider_observations o where o.canonical_match_id=m.id) observed
from futbeat_private.entities m
where m.kind='match'
  and (m.payload->>'homeTeamId'=any(futbeat_private.team_identity_ids(:'club_id'))
    or m.payload->>'awayTeamId'=any(futbeat_private.team_identity_ids(:'club_id')))
  and futbeat_private.try_timestamptz(m.payload->>'startTime')
    between (:'match_day')::date-1 and (:'match_day')::date+2
order by start;

-- 6. Twin team identities with structural evidence (requires migration
--    20261019110000; review only — never apply a redirect from this alone).
-- select * from futbeat_private.team_identity_twin_candidates(current_date-60,current_date+7)
-- order by evidence desc,team_a;
