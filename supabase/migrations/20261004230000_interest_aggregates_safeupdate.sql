-- Account follows / country sync were rejected for every user.
--
-- PostgREST's `authenticator` role preloads the `safeupdate` extension,
-- which refuses a DELETE without a WHERE clause. refresh_interest_aggregates
-- (called at the end of futbeat_sync_push_follows and
-- futbeat_sync_user_preference_fields) emptied coverage_interests with a
-- bare `delete from ...;`, so both RPCs failed with SQLSTATE 21000
-- ("DELETE requires a WHERE clause") whenever the app called them, and no
-- favourite or country ever reached an account. Direct SQL sessions (cron,
-- CLI) do not load safeupdate, which is why it never showed up there.
--
-- Same function, same behaviour; only the full-table delete gets an
-- explicit `where true`.
create or replace function futbeat_private.refresh_interest_aggregates()
returns void
language plpgsql
security definer
set search_path to ''
as $function$
begin
 perform pg_advisory_xact_lock(hashtext('futbeat-interest-aggregates'));
 delete from futbeat_private.temporary_interests where expires_at<=now();
 -- Explicit predicate: safeupdate (PostgREST sessions) rejects bare deletes.
 delete from futbeat_private.coverage_interests where true;
 insert into futbeat_private.coverage_interests(subject_type,subject_id,country_code,selected_country_users,
  detected_country_users,priority_score,depth,next_refresh_at,calculated_at)
 select 'country',country_code,country_code,count(*) filter(where source='selected'),
  count(*) filter(where source='detected'),
  case when count(*) filter(where source='selected')>0 then 100000+least(count(*) filter(where source='selected'),9999)
   else 10000+least(count(*),999) end,
  'BASE',now()+interval '12 hours',now()
 from (select selected_country country_code,'selected' source from futbeat_private.user_preferences where selected_country is not null
  union all select detected_country,'detected' from futbeat_private.user_preferences where selected_country is null and detected_country is not null) c
 group by country_code;
 insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,temporary_users,
  priority_score,depth,next_refresh_at,calculated_at)
 select entity_type,entity_id,explicit_followers,temporary_users,
  case when explicit_followers>0 then 1000000+least(explicit_followers,99999) else 1000+least(temporary_users,999) end,
  case when explicit_followers>0 then 'DEEP' else 'TEMPORARY' end,
  now()+case when entity_type='match' then interval '2 minutes' when explicit_followers>0 then interval '1 hour' else interval '15 minutes' end,now()
 from (select coalesce(f.entity_type,t.entity_type) entity_type,coalesce(f.entity_id,t.entity_id) entity_id,
  count(distinct f.user_id)::int explicit_followers,count(distinct t.user_id)::int temporary_users
  from futbeat_private.push_follows f full join futbeat_private.temporary_interests t
   on t.entity_type=f.entity_type and t.entity_id=f.entity_id and t.expires_at>now()
  group by coalesce(f.entity_type,t.entity_type),coalesce(f.entity_id,t.entity_id)) i;
 insert into futbeat_private.coverage_interests(subject_type,subject_id,country_code,priority_score,depth,next_refresh_at)
 values('country','CR','CR',10000,'BASE',now()+interval '12 hours') on conflict(subject_type,subject_id) do nothing;
end $function$;
