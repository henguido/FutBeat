-- Separate fixture discovery from historical result closure. Results are
-- reconciled by provider date and never require one request per match.

alter table futbeat_private.calendar_coverage
  add column if not exists fixtures_complete boolean not null default true,
  add column if not exists results_complete boolean not null default false,
  add column if not exists results_checked_at timestamptz,
  add column if not exists result_count integer not null default 0
    check(result_count>=0);

update futbeat_private.calendar_coverage c
set results_complete=not exists(
  select 1 from futbeat_private.calendar_matches cm
  join futbeat_private.entities e on e.id=cm.match_id and e.kind='match'
  where cm.start_time>=c.provider_date::timestamp at time zone 'UTC'
    and cm.start_time<(c.provider_date+1)::timestamp at time zone 'UTC'
    and coalesce(e.payload->>'status','') not in (
      'VERIFIED','FINISHED_PENDING_VERIFICATION','POSTPONED','CANCELLED',
      'SUSPENDED','ABANDONED'
    )
), results_checked_at=case when not exists(
  select 1 from futbeat_private.calendar_matches cm
  join futbeat_private.entities e on e.id=cm.match_id and e.kind='match'
  where cm.start_time>=c.provider_date::timestamp at time zone 'UTC'
    and cm.start_time<(c.provider_date+1)::timestamp at time zone 'UTC'
    and coalesce(e.payload->>'status','') not in (
      'VERIFIED','FINISHED_PENDING_VERIFICATION','POSTPONED','CANCELLED',
      'SUSPENDED','ABANDONED'
    )
) then c.fetched_at else null end;

create table if not exists futbeat_private.player_media_coverage(
  player_id text primary key references futbeat_private.entities(id) on delete cascade,
  provider text not null,
  status text not null check(status in ('AVAILABLE','NOT_AVAILABLE','TEMPORARY_ERROR')),
  last_checked_at timestamptz not null,
  retry_after timestamptz not null,
  source text not null check(source in ('lineup','squad','player_profile'))
);
alter table futbeat_private.player_media_coverage enable row level security;
revoke all on futbeat_private.player_media_coverage from public,anon,authenticated;

create or replace function futbeat_private.preserve_verified_player_media()
returns trigger language plpgsql set search_path='' as $$
begin
  if new.kind='player' and old.kind='player'
     and (new.payload->'media' is null or new.payload->'media'='null'::jsonb)
     and old.payload#>>'{media,verificationStatus}'='VERIFIED'
  then
    new.payload:=jsonb_set(new.payload,'{media}',old.payload->'media',true);
  end if;
  return new;
end $$;

drop trigger if exists futbeat_preserve_player_media on futbeat_private.entities;
create trigger futbeat_preserve_player_media before update of payload
on futbeat_private.entities for each row
execute function futbeat_private.preserve_verified_player_media();

create or replace function futbeat_private.track_player_media_coverage()
returns trigger language plpgsql set search_path='' as $$
declare v_available boolean:=coalesce(new.payload#>>'{media,url}','') like 'https://media.goal-api.com/%';
begin
  if new.kind='player' and coalesce(new.payload->'provenance'->>'source','')='GOAL API' then
    insert into futbeat_private.player_media_coverage(
      player_id,provider,status,last_checked_at,retry_after,source
    ) values(
      new.id,'goal_api',case when v_available then 'AVAILABLE' else 'NOT_AVAILABLE' end,
      now(),now()+case when v_available then interval '90 days' else interval '30 days' end,'squad'
    ) on conflict(player_id) do update set
      status=excluded.status,last_checked_at=excluded.last_checked_at,
      retry_after=excluded.retry_after,source=excluded.source
    where futbeat_private.player_media_coverage.status<>'AVAILABLE' or v_available;
  end if;
  return new;
end $$;

drop trigger if exists futbeat_player_media_coverage on futbeat_private.entities;
create trigger futbeat_player_media_coverage after insert or update of payload
on futbeat_private.entities for each row
execute function futbeat_private.track_player_media_coverage();

insert into futbeat_private.player_media_coverage(
  player_id,provider,status,last_checked_at,retry_after,source
)
select id,'goal_api',
  case when coalesce(payload#>>'{media,url}','') like 'https://media.goal-api.com/%'
    then 'AVAILABLE' else 'NOT_AVAILABLE' end,
  now(),now()+case when coalesce(payload#>>'{media,url}','') like 'https://media.goal-api.com/%'
    then interval '90 days' else interval '30 days' end,'squad'
from futbeat_private.entities
where kind='player' and coalesce(payload->'provenance'->>'source','')='GOAL API'
on conflict(player_id) do nothing;

create or replace function futbeat_private.competition_relevance_score(
  p_name text,p_country text
) returns integer language plpgsql immutable set search_path='' as $$
declare n text:=lower(coalesce(p_name,'')); c text:=lower(coalesce(p_country,''));
begin
  if n like '%club world cup%' or n like '%fifa world cup%' then return 1000; end if;
  if n like '%champions league%' then return 970; end if;
  if n like '%libertadores%' then return 950; end if;
  if c='england' and n='premier league' then return 930; end if;
  if c='spain' and n in ('laliga','la liga') then return 920; end if;
  if c='italy' and n='serie a' then return 910; end if;
  if c='germany' and n='bundesliga' then return 900; end if;
  if c='france' and n='ligue 1' then return 890; end if;
  if n like '%europa league%' then return 880; end if;
  if n like '%sudamericana%' then return 860; end if;
  if n like '%conference league%' then return 830; end if;
  if c in ('brazil','brasil') and (n like '%serie a%' or n like '%brasileir%') then return 820; end if;
  if c='argentina' and (n like '%liga profesional%' or n like '%primera%') then return 810; end if;
  if c in ('mexico','méxico') and n like '%liga%mx%' then return 800; end if;
  if c='portugal' and n like '%primeira liga%' then return 790; end if;
  if c='netherlands' and n like '%eredivisie%' then return 780; end if;
  if n in ('major league soccer','mls') then return 770; end if;
  if n like '%concacaf champions cup%' or n like '%concacaf champions league%' then return 760; end if;
  if n like '%copa del rey%' or n like '%fa cup%' then return 750; end if;
  if n like '%coppa italia%' or n like '%dfb pokal%' then return 730; end if;
  if n like '%central american cup%' then return 700; end if;
  if c='costa rica' and (n like '%liga promerica%' or n like '%primera%') then return 660; end if;
  if n like '%friendly%' or n like '%amistoso%' then return 40; end if;
  if n like '%second%' or n like '%segunda%' or n like '%liga 2%' then return 180; end if;
  if n like '%premier league%' or n like '%primera%' or n='serie a' then return 480; end if;
  if n like '%cup%' or n like '%copa%' or n like '%league%' or n like '%liga%' then return 260; end if;
  return 100;
end $$;

create or replace function futbeat_private.apply_competition_relevance()
returns trigger language plpgsql set search_path='' as $$
begin
  if new.kind='competition' then
    if coalesce(new.payload->>'relevanceSource','')<>'editorial' then
      new.payload:=jsonb_set(jsonb_set(new.payload,'{relevanceScore}',to_jsonb(
        futbeat_private.competition_relevance_score(
          new.payload->>'name',new.payload->>'country'
        )
      ),true),'{relevanceSource}','"derived"'::jsonb,true);
    end if;
  end if;
  return new;
end $$;

drop trigger if exists futbeat_competition_relevance on futbeat_private.entities;
create trigger futbeat_competition_relevance before insert or update of payload
on futbeat_private.entities for each row
execute function futbeat_private.apply_competition_relevance();

update futbeat_private.entities set payload=payload where kind='competition';

create or replace function futbeat_private.reserve_goal_results_date(
  p_trigger_source text default 'supabase-cron'
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_date date; v_id bigint; v_remaining integer; v_used integer; v_results_used integer;
begin
  perform pg_advisory_xact_lock(hashtext('futbeat-provider-quota:goal_api:'||(now() at time zone 'UTC')::date::text));
  select provider_remaining into v_remaining from futbeat_private.provider_call_ledger
   where provider='goal_api' and provider_remaining is not null
     and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'
   order by coalesce(completed_at,reserved_at) desc,id desc limit 1;
  select coalesce(sum(case when status='SUCCEEDED' then
    greatest(coalesce((metadata->>'providerRequests')::integer,1),1) else 1 end),0)::integer
  into v_used from futbeat_private.provider_call_ledger
   where provider='goal_api'
     and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  select count(*)::integer into v_results_used from futbeat_private.provider_call_ledger
   where provider='goal_api' and call_kind='results-date'
     and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  if v_results_used>=60 or v_used>=880 or (v_remaining is not null and v_remaining<=120) then
    return jsonb_build_object('allowed',false,'reason','results_quota_guard',
      'usedToday',v_used,'resultsUsedToday',v_results_used,
      'providerRemaining',v_remaining,'reserve',120);
  end if;
  select provider_date into v_date from futbeat_private.calendar_coverage
   where provider='goal_api' and fixtures_complete and not results_complete
     and provider_date<(now() at time zone 'UTC')::date
     and (results_checked_at is null or results_checked_at<now()-interval '6 hours')
   order by provider_date desc limit 1;
  if v_date is null then
    return jsonb_build_object('allowed',false,'reason','no_results_due',
      'usedToday',v_used,'resultsUsedToday',v_results_used,'providerRemaining',v_remaining);
  end if;
  insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
  values('goal_api','results-date',left(p_trigger_source,40),now(),jsonb_build_object('date',v_date))
  returning id into v_id;
  update futbeat_private.calendar_coverage set results_checked_at=now()
   where provider='goal_api' and provider_date=v_date;
  return jsonb_build_object('allowed',true,'reservationId',v_id,'date',v_date,
    'usedToday',v_used,'resultsUsedToday',v_results_used,
    'providerRemaining',v_remaining,'reserve',120);
end $$;

create or replace function futbeat_private.try_timestamptz(p_value text)
returns timestamptz language plpgsql immutable set search_path='' as $$
begin
  if nullif(trim(p_value),'') is null then return null; end if;
  return p_value::timestamptz;
exception when others then return null;
end $$;

create or replace function futbeat_private.finalize_goal_results_date(
  p_provider_date date,p_received_at timestamptz
) returns jsonb language plpgsql security definer set search_path='' as $$
declare r record; v_payload jsonb; v_events jsonb; v_complete boolean; v_updated integer:=0; v_kickoff timestamptz;
begin
  if p_provider_date is null or p_received_at is null then raise exception 'Invalid result batch'; end if;
  for r in
    select distinct on(o.canonical_match_id) o.*
    from futbeat_private.provider_observations o
    where o.provider='goal_api' and o.canonical_match_id is not null
      and o.received_at>=p_received_at-interval '2 seconds'
    order by o.canonical_match_id,o.received_at desc,o.id desc
  loop
    if r.status not in ('FINISHED_PENDING_VERIFICATION','VERIFIED','POSTPONED','CANCELLED','SUSPENDED','ABANDONED') then continue; end if;
    select coalesce(jsonb_agg(payload order by first_seen_at,id),'[]'::jsonb)
      into v_events from futbeat_private.canonical_events where match_id=r.canonical_match_id;
    select payload into v_payload from futbeat_private.entities
      where id=r.canonical_match_id and kind='match' for update;
    if v_payload is null then continue; end if;
    v_kickoff:=futbeat_private.try_timestamptz(r.raw_payload->>'kickoffUtc');
    v_payload:=v_payload||jsonb_strip_nulls(jsonb_build_object(
      'status',r.status,
      'score',case when r.home_score is not null and r.away_score is not null
        then jsonb_build_object('home',r.home_score,'away',r.away_score) else v_payload->'score' end,
      'startTime',case when v_kickoff is not null
        then to_jsonb(v_kickoff) else v_payload->'startTime' end,
      'minute',coalesce(to_jsonb(r.minute),v_payload->'minute'),
      'venue',coalesce(nullif(r.raw_payload->>'matchStadium',''),v_payload->>'venue'),
      'events',case when jsonb_array_length(v_events)>0 then v_events else coalesce(v_payload->'events','[]'::jsonb) end,
      'provenance',coalesce(v_payload->'provenance','{}'::jsonb)||jsonb_build_object(
        'receivedAt',p_received_at,'verificationStatus','VERIFIED')
    ));
    update futbeat_private.entities set payload=v_payload where id=r.canonical_match_id;
    v_updated:=v_updated+1;
  end loop;
  select not exists(
    select 1 from futbeat_private.calendar_matches cm
    join futbeat_private.entities e on e.id=cm.match_id and e.kind='match'
    where cm.start_time>=p_provider_date::timestamp at time zone 'UTC'
      and cm.start_time<(p_provider_date+1)::timestamp at time zone 'UTC'
      and coalesce(e.payload->>'status','') not in (
        'VERIFIED','FINISHED_PENDING_VERIFICATION','POSTPONED','CANCELLED','SUSPENDED','ABANDONED')
  ) into v_complete;
  update futbeat_private.calendar_coverage set results_complete=v_complete,
    results_checked_at=p_received_at,result_count=v_updated
   where provider='goal_api' and provider_date=p_provider_date;
  return jsonb_build_object('date',p_provider_date,'updated',v_updated,'resultsComplete',v_complete,
    'unresolved',(select count(*) from futbeat_private.calendar_matches cm join futbeat_private.entities e on e.id=cm.match_id
      where cm.start_time>=p_provider_date::timestamp at time zone 'UTC'
        and cm.start_time<(p_provider_date+1)::timestamp at time zone 'UTC'
        and coalesce(e.payload->>'status','') not in ('VERIFIED','FINISHED_PENDING_VERIFICATION','POSTPONED','CANCELLED','SUSPENDED','ABANDONED')));
end $$;

create or replace function public.futbeat_reserve_goal_results_date(p_trigger_source text default 'supabase-cron')
returns jsonb language sql security definer set search_path='' as $$
 select futbeat_private.reserve_goal_results_date(p_trigger_source) $$;
create or replace function public.futbeat_finalize_goal_results_date(p_provider_date date,p_received_at timestamptz)
returns jsonb language sql security definer set search_path='' as $$
 select futbeat_private.finalize_goal_results_date(p_provider_date,p_received_at) $$;

revoke all on function futbeat_private.reserve_goal_results_date(text),
 futbeat_private.finalize_goal_results_date(date,timestamptz),
 public.futbeat_reserve_goal_results_date(text),
 public.futbeat_finalize_goal_results_date(date,timestamptz)
from public,anon,authenticated;
grant execute on function public.futbeat_reserve_goal_results_date(text),
 public.futbeat_finalize_goal_results_date(date,timestamptz) to service_role;

do $outer$ declare v_job bigint; v_command text; begin
  if to_regnamespace('vault') is null or to_regnamespace('cron') is null or to_regnamespace('net') is null then return; end if;
  select jobid into v_job from cron.job where jobname='futbeat-goal-results-cron';
  if v_job is not null then perform cron.unschedule(v_job); end if;
  v_command:=$cmd$select net.http_post(
    url:='https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-goal-live-sync',
    headers:=jsonb_build_object('Content-Type','application/json','x-futbeat-cron-token',(
      select decrypted_secret from vault.decrypted_secrets where name='futbeat_goal_live_cron_token'
      order by updated_at desc nulls last,created_at desc limit 1)),
    body:='{"trigger":"results-only"}'::jsonb,timeout_milliseconds:=55000)$cmd$;
  perform cron.schedule('futbeat-goal-results-cron','43 */2 * * *',v_command);
end $outer$;

notify pgrst,'reload schema';
