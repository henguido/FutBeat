-- APPLIED IN PRODUCTION 2026-11-27 04:46Z via ops ledger op 'fb07-install' (FB-PLAY-17). Recorded here for reproducibility;
-- source kit: fb07/fb07_follow_gate.sql

-- Ships inert: h2h_follow_policy enabled=false, daily_cap=0.
-- FB-07 DRAFT (local only, NOT a production op; spends GOAL calls once enabled -> needs explicit GOAL authorization).
-- Head-to-head history extension today: public.futbeat_request_match_h2h_history is fully blocked by the passive gate
-- (navigation_demands_enabled()=false -> {passive:true}). This adds ONE narrow exception, inert by default:
--   the extension may run while passive only if ALL hold:
--     * policy row enabled=true and today's used < daily_cap (ships enabled=false, daily_cap=0 -> no behaviour change),
--     * the match is upcoming (kickoff in [now, now+7d]) and someone follows the match, one of its teams
--       (canonical or redirect alias) or its competition (push_follows),
--     * recovery_headroom() allows it (same GOAL reserve floor the planner uses),
--     * the existing ungated function actually records a step (canExtend and not already extending);
--       only then is one unit counted. The team-matches planner still applies its own throttle, dedup and quota floor.
-- Cost bound: <= 2 team-fixtures demands per counted unit (home+away), so <= 2*daily_cap GOAL calls/day.
-- Rollback: fb07_follow_gate_rollback.sql (prod definition of the public wrapper; drop the new objects).

create table if not exists futbeat_private.h2h_follow_policy(
  id boolean primary key default true check (id),
  enabled boolean not null default false,
  daily_cap integer not null default 0 check (daily_cap between 0 and 100),
  updated_at timestamptz not null default now());
insert into futbeat_private.h2h_follow_policy(id) values(true) on conflict do nothing;

create table if not exists futbeat_private.h2h_follow_usage(
  day date primary key, used integer not null default 0);

create or replace function futbeat_private.h2h_match_followed(p_match_id text)
returns boolean language sql stable security definer set search_path='' as $$
  with t as (select e.payload p from futbeat_private.entities e where e.id=p_match_id and e.kind='match'),
  ids as (
    select p_match_id id
    union select nullif(t.p->>'competitionId','') from t
    union select unnest(futbeat_private.team_identity_ids(
            futbeat_private.futbeat_resolve_entity_id('team',nullif(t.p->>'homeTeamId','')))) from t
    union select unnest(futbeat_private.team_identity_ids(
            futbeat_private.futbeat_resolve_entity_id('team',nullif(t.p->>'awayTeamId','')))) from t)
  select exists(select 1 from futbeat_private.push_follows f where f.entity_id in (select id from ids where id is not null))
$$;

create or replace function futbeat_private.h2h_follow_try(p_match_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare pol futbeat_private.h2h_follow_policy; v_used integer; ko timestamptz; hr jsonb; out jsonb;
  d date:=(now() at time zone 'UTC')::date;
begin
  select * into pol from futbeat_private.h2h_follow_policy where id;
  if pol.id is null or not pol.enabled or pol.daily_cap<=0 then return null; end if;
  select nullif(e.payload->>'startTime','')::timestamptz into ko from futbeat_private.entities e
   where e.id=p_match_id and e.kind='match';
  if ko is null or ko<now() or ko>now()+interval '7 days' then return null; end if;
  if not futbeat_private.h2h_match_followed(p_match_id) then return null; end if;
  -- serialize per day so two callers cannot both take the last unit
  insert into futbeat_private.h2h_follow_usage(day) values(d) on conflict do nothing;
  select u.used into v_used from futbeat_private.h2h_follow_usage u where u.day=d for update;
  if v_used>=pol.daily_cap then return jsonb_build_object('passive',true,'requested',false,'scope','followed','reason','daily_cap'); end if;
  hr:=futbeat_private.recovery_headroom();
  if not coalesce((hr->>'allowed')::boolean,false) then
    return jsonb_build_object('passive',true,'requested',false,'scope','followed','reason','headroom');
  end if;
  out:=futbeat_private.futbeat_request_match_h2h_history__ungated(p_match_id);
  if out ? 'home' or out ? 'away' then
    update futbeat_private.h2h_follow_usage u set used=u.used+1 where u.day=d;
  end if;
  return out||jsonb_build_object('scope','followed');
end $$;

create or replace function public.futbeat_request_match_h2h_history(p_match_id text)
 returns jsonb language plpgsql security definer set search_path='' as $function$
declare f jsonb;
begin
  if futbeat_private.navigation_demands_enabled() then
    return futbeat_private.futbeat_request_match_h2h_history__ungated(p_match_id);
  end if;
  f:=futbeat_private.h2h_follow_try(p_match_id);
  if f is not null then return f; end if;
  return jsonb_build_object('passive',true,'requested',false);
end $function$;

revoke all on function futbeat_private.h2h_match_followed(text), futbeat_private.h2h_follow_try(text) from public, anon, authenticated;
revoke all on table futbeat_private.h2h_follow_policy, futbeat_private.h2h_follow_usage from public, anon, authenticated;
