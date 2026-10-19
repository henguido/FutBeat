-- Rollback of 20261019100000_player_club_national_membership.sql (manual,
-- NOT a migration). Restores the previous squad writer and entity detail
-- read (they were renamed, not changed). Data written meanwhile stays and
-- is harmless to the old code: payload.nationalTeamId is ignored and the
-- restored club memberships are ordinary team_squad_members rows.
-- Ship the previous app build's filter or keep the new one: both work
-- with either server (the app falls back to teamId + nationalTeamId).
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';
drop function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb);
alter function futbeat_private.store_team_squad_before_national_context(text,text,timestamptz,jsonb)
  rename to futbeat_store_team_squad;
drop function futbeat_private.futbeat_read_entity_detail(text,text);
alter function futbeat_private.read_entity_detail_before_player_teams(text,text)
  rename to futbeat_read_entity_detail;
drop function if exists futbeat_private.player_team_ids(text);
drop function if exists futbeat_private.team_is_national(text);
drop index if exists futbeat_private.canonical_events_player_idx;
revoke all on function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb),
  futbeat_private.futbeat_read_entity_detail(text,text) from public,anon,authenticated;
grant execute on function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb),
  futbeat_private.futbeat_read_entity_detail(text,text) to service_role;
notify pgrst, 'reload schema';
commit;
