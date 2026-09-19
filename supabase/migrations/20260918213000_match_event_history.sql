-- Event/history hydration policy.
-- Keep LIVE as the highest-priority GOAL API consumer, but allow shared on-demand
-- detail hydration for recent historical matches so Match Center can show
-- goals/cards/substitutions after the final whistle.

create or replace function futbeat_private.request_match_detail(
  p_match_id text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_start timestamptz;
  v_goal_mapped boolean;
begin
  select nullif(payload->>'startTime','')::timestamptz
  into v_start
  from futbeat_private.entities
  where id=p_match_id and kind='match';

  if p_match_id is null or v_start is null then
    raise exception 'Unknown canonical match';
  end if;

  select exists(
    select 1
    from futbeat_private.provider_entities
    where provider='goal_api'
      and kind='match'
      and canonical_id=p_match_id
  ) into v_goal_mapped;

  -- Anonymous requests only enqueue trusted canonical matches. Historical
  -- hydration is intentionally bounded to the indexed calendar horizon.
  if v_goal_mapped
     and v_start between now()-interval '90 days' and now()+interval '24 hours'
  then
    insert into futbeat_private.match_detail_requests(
      match_id,requested_at,expires_at,request_count
    )
    values(p_match_id,now(),now()+interval '15 minutes',1)
    on conflict(match_id) do update
      set requested_at=now(),
          expires_at=now()+interval '15 minutes',
          request_count=futbeat_private.match_detail_requests.request_count+1;
  end if;

  return futbeat_private.read_match_detail(p_match_id);
end
$$;

create or replace function futbeat_private.reserve_match_detail_call(
  p_trigger_source text default 'github-actions'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_day_start timestamptz :=
    date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  v_detail_used integer;
  v_remaining integer;
  v_match_id text;
  v_external text;
  v_reservation bigint;
  v_status text;
  v_fetched timestamptz;
begin
  if p_trigger_source is null or btrim(p_trigger_source)='' then
    raise exception 'trigger_source is required';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('futbeat-provider-quota:goal_api:'||v_day_start::date::text)
  );

  delete from futbeat_private.match_detail_requests
  where expires_at<=now();

  select count(*)::integer
  into v_detail_used
  from futbeat_private.provider_call_ledger
  where provider='goal_api'
    and call_kind='match-detail'
    and reserved_at>=v_day_start
    and reserved_at<v_day_start+interval '1 day';

  select provider_remaining
  into v_remaining
  from futbeat_private.provider_call_ledger
  where provider='goal_api'
    and provider_remaining is not null
    and reserved_at>=v_day_start
    and reserved_at<v_day_start+interval '1 day'
  order by coalesce(completed_at,reserved_at) desc,id desc
  limit 1;

  if v_detail_used>=24 then
    return jsonb_build_object(
      'allowed',false,'reason','detail_daily_limit',
      'detailUsed',v_detail_used,'detailLimit',24,
      'providerRemaining',v_remaining
    );
  end if;

  -- LIVE itself keeps a 20-call emergency reserve. Match detail stops much
  -- earlier, leaving an additional 60-call operational cushion.
  if v_remaining is not null and v_remaining<=80 then
    return jsonb_build_object(
      'allowed',false,'reason','provider_remaining_reserve',
      'detailUsed',v_detail_used,'providerRemaining',v_remaining,'reserve',80
    );
  end if;

  select
    r.match_id,
    pe.external_id,
    coalesce(l.status,e.payload->>'status'),
    c.fetched_at
  into v_match_id,v_external,v_status,v_fetched
  from futbeat_private.match_detail_requests r
  join futbeat_private.entities e
    on e.id=r.match_id and e.kind='match'
  join futbeat_private.provider_entities pe
    on pe.provider='goal_api'
   and pe.kind='match'
   and pe.canonical_id=r.match_id
  left join public.live_match_updates l
    on l.match_id=r.match_id and l.provider='goal_api'
  left join futbeat_private.match_detail_cache c
    on c.match_id=r.match_id
  where r.expires_at>now()
    and (
      c.fetched_at is null
      or (
        coalesce(l.status,e.payload->>'status') in (
          'LIVE','HALFTIME','EXTRA_TIME','PENALTIES'
        )
        and c.fetched_at<now()-interval '5 minutes'
      )
      or (
        coalesce(l.status,e.payload->>'status') not in (
          'LIVE','HALFTIME','EXTRA_TIME','PENALTIES',
          'FINISHED_PENDING_VERIFICATION','VERIFIED',
          'CANCELLED','ABANDONED','POSTPONED'
        )
        and c.fetched_at<now()-interval '30 minutes'
      )
      or (
        coalesce(l.status,e.payload->>'status')='FINISHED_PENDING_VERIFICATION'
        and c.fetched_at<now()-interval '30 minutes'
      )
    )
  order by
    case
      when coalesce(l.status,e.payload->>'status') in (
        'LIVE','HALFTIME','EXTRA_TIME','PENALTIES'
      ) then 0
      when coalesce(l.status,e.payload->>'status')='FINISHED_PENDING_VERIFICATION'
        then 1
      else 2
    end,
    r.requested_at desc
  limit 1;

  if v_match_id is null then
    return jsonb_build_object(
      'allowed',false,'reason','no_detail_due',
      'detailUsed',v_detail_used,'providerRemaining',v_remaining
    );
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at,metadata
  )
  values(
    'goal_api','match-detail',left(p_trigger_source,40),now(),
    jsonb_build_object(
      'matchId',v_match_id,
      'externalMatchId',v_external,
      'status',v_status
    )
  )
  returning id into v_reservation;

  return jsonb_build_object(
    'allowed',true,
    'reservationId',v_reservation,
    'matchId',v_match_id,
    'externalMatchId',v_external,
    'status',v_status,
    'detailUsed',v_detail_used+1,
    'detailLimit',24,
    'providerRemaining',v_remaining,
    'reserve',80
  );
end
$$;


-- GOAL live snapshots do not carry scorer/card/substitution arrays. Preserve a
-- useful realtime timeline anyway by deriving a provisional GOAL event whenever
-- the authoritative score increases. Rich Match Center detail supersedes this
-- provisional event in the mobile merged timeline.
create or replace function futbeat_private.synthesize_goal_from_score_change()
returns trigger
language plpgsql
security definer
set search_path=''
as $event$
declare
  m jsonb;
  ev jsonb;
  baseline boolean;
begin
  if new.provider<>'goal_api'
     or new.canonical_match_id is null
     or (
       coalesce(new.home_score,0)<=coalesce(old.home_score,0)
       and coalesce(new.away_score,0)<=coalesce(old.away_score,0)
     )
  then
    return new;
  end if;

  select payload into m
  from futbeat_private.entities
  where id=new.canonical_match_id and kind='match';

  if m is null then
    return new;
  end if;

  select exists(
    select 1
    from futbeat_private.event_baselines
    where match_id=new.canonical_match_id
  ) into baseline;

  if coalesce(new.home_score,0)>coalesce(old.home_score,0) then
    ev:=jsonb_build_object(
      'id','fb_event_'||md5(concat_ws(
        '|',new.canonical_match_id,'goal_api','GOAL','home',
        new.revision,new.minute,new.home_score,new.away_score
      )),
      'matchId',new.canonical_match_id,
      'type','GOAL',
      'minute',new.minute,
      'teamId',m->>'homeTeamId',
      'score',jsonb_build_object(
        'home',new.home_score,
        'away',new.away_score
      ),
      'detail','Marcador actualizado',
      'synthetic',true
    );
    perform futbeat_private.store_canonical_event(
      ev,'goal_api',baseline,new.changed_at,m
    );
  end if;

  if coalesce(new.away_score,0)>coalesce(old.away_score,0) then
    ev:=jsonb_build_object(
      'id','fb_event_'||md5(concat_ws(
        '|',new.canonical_match_id,'goal_api','GOAL','away',
        new.revision,new.minute,new.home_score,new.away_score
      )),
      'matchId',new.canonical_match_id,
      'type','GOAL',
      'minute',new.minute,
      'teamId',m->>'awayTeamId',
      'score',jsonb_build_object(
        'home',new.home_score,
        'away',new.away_score
      ),
      'detail','Marcador actualizado',
      'synthetic',true
    );
    perform futbeat_private.store_canonical_event(
      ev,'goal_api',baseline,new.changed_at,m
    );
  end if;

  return new;
end
$event$;

drop trigger if exists futbeat_goal_from_score_change
  on futbeat_private.live_match_state;
create trigger futbeat_goal_from_score_change
after update of home_score,away_score
on futbeat_private.live_match_state
for each row
execute function futbeat_private.synthesize_goal_from_score_change();

revoke all on function
  futbeat_private.synthesize_goal_from_score_change()
from public,anon,authenticated;

notify pgrst,'reload schema';
