-- Match-detail (lineups/statistics) central hydration priority.
-- Read-only planner change: no new tables, no squad/player-media logic touched.
-- Reuses match_detail_cache/match_detail_requests/reserve_match_detail_call
-- exactly as before; only the enqueuer's candidate selection is extended.

create or replace function futbeat_private.enqueue_stale_interested_match_detail()
returns text
language plpgsql
security definer
set search_path=''
as $$
declare
  v_match_id text;
begin
  -- Serialize the whole check+insert against a concurrent invocation of this
  -- same function (for example the dedicated per-minute detail cron and the
  -- default cron cascade landing in the same window). Reuses the exact
  -- pg_advisory_xact_lock idiom already used by every GOAL quota guard in
  -- this codebase; reserve_match_detail_call's own quota/backoff lock is
  -- untouched. match_detail_requests.match_id already carries a primary key,
  -- so two concurrent inserts of the SAME match can never duplicate a row
  -- even without this lock; this closes the narrower case where two
  -- concurrent callers could otherwise queue two DIFFERENT candidates.
  perform pg_advisory_xact_lock(hashtext('futbeat-match-detail-enqueue'));

  -- Never compete with a detail explicitly requested from Match Center.
  if exists(
    select 1 from futbeat_private.match_detail_requests where expires_at>now()
  ) then
    return null;
  end if;

  -- Tier 0 (unchanged): exact original selection and order. Any LIVE match
  -- whose overlay has gone stale, independent of follow/relevance.
  select e.id into v_match_id
  from futbeat_private.entities e
  join futbeat_private.provider_entities pe
    on pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=e.id
  join futbeat_private.live_match_state l
    on l.canonical_match_id=e.id
   and l.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
   and l.last_seen_at<now()-interval '15 minutes'
  left join futbeat_private.match_detail_cache c on c.match_id=e.id
  where e.kind='match'
    and nullif(e.payload->>'startTime','') is not null
    and (e.payload->>'startTime')::timestamptz
      between now()-interval '36 hours' and now()-interval '15 minutes'
    and coalesce(e.payload->>'status','') not in (
      'FINISHED_PENDING_VERIFICATION','VERIFIED','CANCELLED','SUSPENDED',
      'ABANDONED','POSTPONED'
    )
    and (c.fetched_at is null or c.fetched_at<l.last_seen_at)
  order by l.last_seen_at desc,(e.payload->>'startTime')::timestamptz desc
  limit 1;

  if v_match_id is null then
    with candidates as (
      -- Tier 1 (new): reactive refresh for matches LIVE-ish/just started by
      -- canonical status (a broader net than tier 0's live_match_state
      -- requirement) with real central demand: an explicit favorite/
      -- followed-competition/match follow, a currently unexpired temporary
      -- interest (checked directly against temporary_interests, never the
      -- stale temporary_users aggregate), or authoritative editorial
      -- relevance. Only source='editorial' with relevance_score>=800
      -- counts; derived, provider and missing metadata never do.
      select e.id match_id,1 tier,
        (coalesce(hi.explicit_followers,0)+coalesce(ai.explicit_followers,0)
          +coalesce(ci.explicit_followers,0)+coalesce(mi.explicit_followers,0)) weight,
        coalesce(l.changed_at,'epoch'::timestamptz) freshness,
        (e.payload->>'startTime')::timestamptz start_time
      from futbeat_private.entities e
      join futbeat_private.provider_entities pe
        on pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=e.id
      left join futbeat_private.live_match_state l
        on l.canonical_match_id=e.id and l.provider='goal_api'
      left join futbeat_private.match_detail_cache c on c.match_id=e.id
      left join futbeat_private.coverage_interests hi
        on hi.subject_type='team' and hi.subject_id=e.payload->>'homeTeamId'
      left join futbeat_private.coverage_interests ai
        on ai.subject_type='team' and ai.subject_id=e.payload->>'awayTeamId'
      left join futbeat_private.coverage_interests ci
        on ci.subject_type='competition'
       and ci.subject_id=futbeat_private.futbeat_resolve_entity_id(
         'competition',e.payload->>'competitionId')
      left join futbeat_private.coverage_interests mi
        on mi.subject_type='match' and mi.subject_id=e.id
      left join futbeat_private.competition_editorial_metadata meta
        on meta.competition_id=futbeat_private.futbeat_resolve_entity_id(
          'competition',e.payload->>'competitionId')
      where e.kind='match'
        and nullif(e.payload->>'startTime','') is not null
        and (e.payload->>'startTime')::timestamptz
          between now()-interval '150 minutes' and now()+interval '10 minutes'
        and coalesce(e.payload->>'status','') not in (
          'FINISHED_PENDING_VERIFICATION','VERIFIED','CANCELLED','SUSPENDED',
          'ABANDONED','POSTPONED'
        )
        and (
          coalesce(hi.explicit_followers,0)+coalesce(ai.explicit_followers,0)
          +coalesce(ci.explicit_followers,0)+coalesce(mi.explicit_followers,0)>0
          or exists(
            select 1 from futbeat_private.temporary_interests t
            where t.expires_at>now()
              and (
                (t.entity_type='team'
                  and t.entity_id in (e.payload->>'homeTeamId',e.payload->>'awayTeamId'))
                or (t.entity_type='competition'
                  and t.entity_id=futbeat_private.futbeat_resolve_entity_id(
                    'competition',e.payload->>'competitionId'))
                or (t.entity_type='match' and t.entity_id=e.id)
              )
          )
          or (meta.source='editorial' and meta.relevance_score>=800)
        )
        and (
          (
            coalesce(l.status,e.payload->>'status') in (
              'LIVE','HALFTIME','EXTRA_TIME','PENALTIES'
            )
            and coalesce(l.changed_at,'epoch'::timestamptz)<now()-interval '8 minutes'
          )
          or (
            l.canonical_match_id is null
            and (e.payload->>'startTime')::timestamptz<now()-interval '15 minutes'
          )
        )
        and (c.fetched_at is null or c.fetched_at<now()-interval '8 minutes')

      union all

      -- Tier 2 (new): pre-hydrate a match kicking off soon, only when real
      -- demand exists (same definition as tier 1) and it has never been
      -- fetched, so lineups (commonly published shortly before kickoff) are
      -- ready without waiting for someone to open Match Center after
      -- kickoff. Bounded to a tight 30-minute window so the small daily
      -- detail budget is never spent on low-value matches.
      select e.id,2,
        (coalesce(hi.explicit_followers,0)+coalesce(ai.explicit_followers,0)
          +coalesce(ci.explicit_followers,0)),
        'epoch'::timestamptz,(e.payload->>'startTime')::timestamptz
      from futbeat_private.entities e
      join futbeat_private.provider_entities pe
        on pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=e.id
      left join futbeat_private.coverage_interests hi
        on hi.subject_type='team' and hi.subject_id=e.payload->>'homeTeamId'
      left join futbeat_private.coverage_interests ai
        on ai.subject_type='team' and ai.subject_id=e.payload->>'awayTeamId'
      left join futbeat_private.coverage_interests ci
        on ci.subject_type='competition'
       and ci.subject_id=futbeat_private.futbeat_resolve_entity_id(
         'competition',e.payload->>'competitionId')
      left join futbeat_private.competition_editorial_metadata meta
        on meta.competition_id=futbeat_private.futbeat_resolve_entity_id(
          'competition',e.payload->>'competitionId')
      left join futbeat_private.match_detail_cache c on c.match_id=e.id
      where e.kind='match'
        and coalesce(e.payload->>'status','')='SCHEDULED'
        and nullif(e.payload->>'startTime','') is not null
        and (e.payload->>'startTime')::timestamptz
          between now() and now()+interval '30 minutes'
        and c.match_id is null
        and (
          coalesce(hi.explicit_followers,0)+coalesce(ai.explicit_followers,0)
          +coalesce(ci.explicit_followers,0)>0
          or exists(
            select 1 from futbeat_private.temporary_interests t
            where t.expires_at>now()
              and (
                (t.entity_type='team'
                  and t.entity_id in (e.payload->>'homeTeamId',e.payload->>'awayTeamId'))
                or (t.entity_type='competition'
                  and t.entity_id=futbeat_private.futbeat_resolve_entity_id(
                    'competition',e.payload->>'competitionId'))
                or (t.entity_type='match' and t.entity_id=e.id)
              )
          )
          or (meta.source='editorial' and meta.relevance_score>=800)
        )
    )
    select match_id into v_match_id from candidates
    order by tier,weight desc,freshness,start_time limit 1;
  end if;

  if v_match_id is null then
    return null;
  end if;

  insert into futbeat_private.match_detail_requests(
    match_id,requested_at,expires_at,request_count
  ) values(v_match_id,now(),now()+interval '10 minutes',1)
  on conflict(match_id) do update
    set requested_at=excluded.requested_at,
        expires_at=excluded.expires_at,
        request_count=futbeat_private.match_detail_requests.request_count+1;

  return v_match_id;
end
$$;

-- Pre-existing gap fixed in passing: this private helper never had an
-- explicit revoke across its three prior definitions, unlike every other
-- private function in this file's family. Postgres grants EXECUTE on new
-- functions to PUBLIC by default, so anon/authenticated could otherwise call
-- this SECURITY DEFINER function directly and queue match_detail_requests
-- rows, bypassing the intended public.futbeat_enqueue_stale_live_detail()
-- boundary. It still cannot reserve quota or call the provider.
revoke all on function futbeat_private.enqueue_stale_interested_match_detail()
from public,anon,authenticated;

notify pgrst,'reload schema';
