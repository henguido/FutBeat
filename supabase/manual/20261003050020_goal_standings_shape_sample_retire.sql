-- MANUAL, NOT A DEPLOY MIGRATION. Run only after both Edge capture call sites
-- have been removed/deployed and the #147 provider contract has been reviewed.
-- This physically purges all diagnostic samples, including unexpired ones.
-- No GOAL call, cron, or secret change is involved.
begin;

delete from futbeat_private.goal_standings_shape_samples;
drop function public.futbeat_record_goal_standings_shape(text, text, jsonb);
drop table futbeat_private.goal_standings_shape_samples;

notify pgrst,'reload schema';
commit;
