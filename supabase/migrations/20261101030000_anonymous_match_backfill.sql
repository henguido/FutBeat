-- BE-244: fills the empty match entities left behind by failed global stores.
--
-- Nothing runs on apply. The queue is seeded by an explicit list, and each call
-- takes a small batch, so an operator decides every step. Identity comes only from
-- hydrate_goal_anonymous_match: provider ids, never names. Empties without an
-- observation have no fixture to read: they are not queued, a stored ingest fills them.
--
-- Rollback restores prior_payload only while the row is still the backfill's own:
-- a match rewritten by a real ingest since then is kept.

create table if not exists futbeat_private.anonymous_match_backfill(
  match_id text primary key,
  external_id text not null unique,
  kickoff timestamptz not null,
  state text not null default 'PENDING',
  prior_payload jsonb,
  attempts integer not null default 0,
  updated_at timestamptz not null default now()
);
create index if not exists anonymous_match_backfill_pending_idx
  on futbeat_private.anonymous_match_backfill(kickoff,external_id) where state='PENDING';
alter table futbeat_private.anonymous_match_backfill enable row level security;
revoke all on futbeat_private.anonymous_match_backfill from public,anon,authenticated;

create or replace function futbeat_private.backfill_anonymous_matches(p_limit integer default 25)
returns jsonb
language plpgsql
security definer
set search_path to ''
set lock_timeout to '500ms'
as $function$
declare
  -- Ordered by kickoff, so a batch dirties few calendar dates.
  v_lim integer:=greatest(1,least(coalesce(p_limit,25),100));
  v_deadline timestamptz:=clock_timestamp()+interval '3 seconds';
  r record; v_fixture jsonb; v_prior jsonb; v_out text; v_mapped text;
  v_counts jsonb:='{}'::jsonb;
begin
  for r in select * from futbeat_private.anonymous_match_backfill
      where state='PENDING' order by kickoff,external_id limit v_lim for update skip locked
  loop
    exit when clock_timestamp()>v_deadline;
    v_out:=null; v_prior:=null; v_fixture:=null;
    select canonical_id into v_mapped from futbeat_private.provider_entities
     where provider='goal_api' and kind='match' and external_id=r.external_id;
    if v_mapped is distinct from r.match_id then
      v_out:='remapped';
    else
      select p.raw_payload into v_fixture from futbeat_private.provider_observations p
       where p.provider='goal_api' and p.external_match_id=r.external_id
       order by p.received_at desc limit 1;
      if coalesce(v_fixture->>'apiId',v_fixture->>'id') is distinct from r.external_id then
        v_out:='no_observation';
      else
        select payload into v_prior from futbeat_private.entities where id=r.match_id and kind='match';
        begin
          v_out:=futbeat_private.hydrate_goal_anonymous_match(v_fixture,r.match_id,'backfill');
        exception when lock_not_available then
          update futbeat_private.anonymous_match_backfill
             set attempts=attempts+1,updated_at=now() where match_id=r.match_id;
          v_counts:=v_counts||jsonb_build_object('locked',coalesce((v_counts->>'locked')::integer,0)+1);
          continue;
        end;
      end if;
    end if;
    update futbeat_private.anonymous_match_backfill
       set state=v_out,attempts=attempts+1,updated_at=now(),
           prior_payload=case when v_out='hydrated' then v_prior end
     where match_id=r.match_id;
    v_counts:=v_counts||jsonb_build_object(v_out,coalesce((v_counts->>v_out)::integer,0)+1);
  end loop;
  return v_counts||jsonb_build_object('pending',(select count(*) from futbeat_private.anonymous_match_backfill where state='PENDING'));
end $function$;

create or replace function futbeat_private.rollback_anonymous_match_backfill(p_limit integer default 25)
returns jsonb
language plpgsql
security definer
set search_path to ''
set lock_timeout to '500ms'
as $function$
declare
  v_lim integer:=greatest(1,least(coalesce(p_limit,25),100));
  v_deadline timestamptz:=clock_timestamp()+interval '3 seconds';
  r record; v_state text; v_counts jsonb:='{}'::jsonb;
begin
  for r in select * from futbeat_private.anonymous_match_backfill
      where state='hydrated' order by kickoff desc,external_id limit v_lim for update skip locked
  loop
    exit when clock_timestamp()>v_deadline;
    update futbeat_private.entities e set payload=r.prior_payload
     where e.id=r.match_id and e.kind='match'
       and e.payload#>>'{provenance,discoveredVia}'='backfill';
    v_state:=case when found then 'ROLLED_BACK' else 'KEPT_REWRITTEN' end;
    update futbeat_private.anonymous_match_backfill
       set state=v_state,updated_at=now() where match_id=r.match_id;
    v_counts:=v_counts||jsonb_build_object(v_state,coalesce((v_counts->>v_state)::integer,0)+1);
  end loop;
  return v_counts||jsonb_build_object('hydrated',(select count(*) from futbeat_private.anonymous_match_backfill where state='hydrated'));
end $function$;

revoke all on function futbeat_private.backfill_anonymous_matches(integer) from public,anon,authenticated;
revoke all on function futbeat_private.rollback_anonymous_match_backfill(integer) from public,anon,authenticated;
