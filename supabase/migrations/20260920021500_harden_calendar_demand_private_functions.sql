-- Private implementations are only callable through their service-role-only
-- public wrappers. Revoke PostgreSQL's default function EXECUTE grant.
revoke all on function futbeat_private.futbeat_request_calendar_date(date,text)
from public,anon,authenticated;

revoke all on function futbeat_private.futbeat_requested_calendar_dates(integer)
from public,anon,authenticated;
