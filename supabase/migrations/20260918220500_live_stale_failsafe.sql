-- Fail-safe for delayed external LIVE polling.
-- Public realtime overlays are only authoritative while they are being refreshed.
-- If the provider transport stalls, remove stale active rows so clients do not
-- keep showing a match as LIVE indefinitely. Canonical/history data is preserved.

create or replace function futbeat_private.futbeat_prune_stale_live_updates(
  p_stale_after interval default interval '15 minutes'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_deleted integer;
  v_ids jsonb;
begin
  if p_stale_after < interval '5 minutes'
     or p_stale_after > interval '2 hours' then
    raise exception 'Invalid LIVE stale interval';
  end if;

  with removed as (
    delete from public.live_match_updates l
    using futbeat_private.entities m
    where m.id=l.match_id
      and m.kind='match'
      and l.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
      and l.updated_at < now()-p_stale_after
    returning l.match_id
  )
  select
    count(*)::integer,
    coalesce(jsonb_agg(match_id order by match_id),'[]'::jsonb)
  into v_deleted,v_ids
  from removed;

  return jsonb_build_object(
    'deleted',v_deleted,
    'matchIds',v_ids,
    'staleAfterSeconds',extract(epoch from p_stale_after)::integer,
    'checkedAt',now()
  );
end
$$;

revoke all on function
  futbeat_private.futbeat_prune_stale_live_updates(interval)
from public,anon,authenticated;

grant execute on function
  futbeat_private.futbeat_prune_stale_live_updates(interval)
to service_role;

do $$
begin
  if to_regnamespace('cron') is null then
    return;
  end if;

  perform cron.schedule(
    'futbeat-prune-stale-live',
    '* * * * *',
    $job$
      select futbeat_private.futbeat_prune_stale_live_updates(
        interval '15 minutes'
      );
    $job$
  );
end
$$;

notify pgrst,'reload schema';
