-- Short-lived, private observations of the GOAL standings field contract.
-- The worker sends only field names and bounded numeric/UUID phase IDs from
-- an already-budgeted response, never the provider payload or team/player data.
-- expires_at is a logical TTL: reads must filter it. Physical deletion happens
-- on the next successful capture, NOT at exactly 7 days if traffic stops.
-- After the contract is verified, remove both capture call sites and run the
-- reviewed retirement script in supabase/manual/20261003050020_goal_standings_shape_sample_retire.sql.
create table futbeat_private.goal_standings_shape_samples (
  competition_id text not null,
  source text not null check (source in ('scheduled', 'demand')),
  shape jsonb not null check (
    jsonb_typeof(shape) = 'object'
    and (shape->>'version') is not distinct from '1'
    and octet_length(shape::text) <= 4096
  ),
  captured_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  primary key (competition_id, source)
);

create index goal_standings_shape_samples_expires_idx
  on futbeat_private.goal_standings_shape_samples (expires_at);

alter table futbeat_private.goal_standings_shape_samples enable row level security;
revoke all on futbeat_private.goal_standings_shape_samples
  from public, anon, authenticated;
grant select, insert, update, delete on futbeat_private.goal_standings_shape_samples
  to service_role;

-- Invoker privileges stay with service_role; no SECURITY DEFINER bypass.
-- Prune expired samples during normal writes, without another provider fetch.
create function public.futbeat_record_goal_standings_shape(
  p_competition_id text, p_source text, p_shape jsonb
) returns void language plpgsql security invoker set search_path = '' as $$
begin
  if p_competition_id !~ '^fb_comp' or p_source not in ('scheduled', 'demand')
    or p_shape is null or jsonb_typeof(p_shape) <> 'object'
    or (p_shape->>'version') is distinct from '1'
    or octet_length(p_shape::text) > 4096 then
    raise exception 'Invalid standings shape sample';
  end if;

  delete from futbeat_private.goal_standings_shape_samples
  where expires_at <= now();

  insert into futbeat_private.goal_standings_shape_samples
    (competition_id, source, shape, captured_at, expires_at)
  values (p_competition_id, p_source, p_shape, now(), now() + interval '7 days')
  on conflict (competition_id, source) do update set
    shape = excluded.shape,
    captured_at = excluded.captured_at,
    expires_at = excluded.expires_at;
end $$;

revoke all on function public.futbeat_record_goal_standings_shape(text, text, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.futbeat_record_goal_standings_shape(text, text, jsonb)
  to service_role;

notify pgrst,'reload schema';
