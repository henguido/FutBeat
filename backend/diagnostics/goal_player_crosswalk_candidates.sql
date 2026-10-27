-- READ ONLY. Candidate report for the audited Barcelona v Real Madrid match.
-- It never inserts a bridge. Exact name/team/shirt/position agreement is
-- descriptive evidence only; an official/provider crosswalk is still needed.
begin transaction read only;
set local statement_timeout='3s';
with match_row as (
  select payload->>'homeTeamId' home_id,payload->>'awayTeamId' away_id
  from futbeat_private.entities
  where kind='match' and id='fb_match_ad5abdbec78e47fba57deb558a06cf53'
), lineup as (
  select x->>'team' side,x->>'lineupPlayer' lineup_name,
    coalesce(nullif(x->>'playerId',''),nullif(x->>'playerKey','')) numeric_id,
    nullif(x->>'lineupNumber','') shirt_number,nullif(x->>'lineupPosition','') position,
    pe.canonical_id lineup_canonical_id,
    case x->>'team' when 'home' then m.home_id when 'away' then m.away_id end team_id
  from futbeat_private.match_detail_cache c cross join match_row m
  cross join lateral jsonb_array_elements(c.payload->'lineups') x
  left join futbeat_private.provider_entities pe on pe.provider='goal_api'
    and pe.kind='player' and pe.external_id=coalesce(nullif(x->>'playerId',''),nullif(x->>'playerKey',''))
  where c.match_id='fb_match_ad5abdbec78e47fba57deb558a06cf53'
), squad as (
  select sm.team_id,e.id squad_canonical_id,e.payload->>'name' squad_name,
    e.payload->>'shirtNumber' shirt_number,e.payload->>'position' position,
    e.payload->>'dateOfBirth' date_of_birth,e.payload->>'country' country,
    pe.external_id catalog_id,
    futbeat_private.valid_player_media(e.payload->'media') has_verified_media
  from futbeat_private.team_squad_members sm
  join futbeat_private.entities e on e.id=sm.player_id and e.kind='player'
  join futbeat_private.provider_entities pe on pe.provider='goal_api'
    and pe.kind='player' and pe.canonical_id=e.id and pe.external_id !~ '^[0-9]+$'
  where sm.team_id in ((select home_id from match_row),(select away_id from match_row))
), candidates as (
  select l.*,s.squad_canonical_id,s.squad_name,s.catalog_id,s.date_of_birth,s.country,
    s.has_verified_media,s.shirt_number squad_shirt,s.position squad_position,
    count(*) over(partition by l.numeric_id) candidate_count
  from lineup l join squad s on s.team_id=l.team_id
    and futbeat_private.normalize_live_name(s.squad_name)=futbeat_private.normalize_live_name(l.lineup_name)
)
select *,case when candidate_count>1 then 'AMBIGUOUS'
  else 'CANDIDATE_ONLY_NEEDS_PROVIDER_OR_OFFICIAL_CROSSWALK' end decision
from candidates order by side,lineup_name,catalog_id limit 100;
rollback;

