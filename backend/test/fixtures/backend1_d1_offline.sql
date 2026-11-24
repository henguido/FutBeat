-- Local reconstruction fixture only. No provider network, real identity or event dispatch.
begin;
do $test$
declare calls_before bigint; wakes_before bigint; response jsonb; p jsonb;
begin
 select count(*) into calls_before from futbeat_private.provider_call_ledger;
 select coalesce(sum(wake_count),0) into wakes_before from futbeat_private.worker_wakeups;
 p:=jsonb_build_object('id','fb_match_rebuild_d1','competitionId','fb_comp_rebuild',
  'homeTeamId','fb_team_rebuild_h','awayTeamId','fb_team_rebuild_a',
  'startTime',now()-interval '10 minutes','status','LIVE','minute',10,
  'score',jsonb_build_object('home',0,'away',0),'events','[]'::jsonb,'statistics','[]'::jsonb);
 insert into futbeat_private.entities(id,kind,payload) values('fb_match_rebuild_d1','match',p);
 insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
 values('goal_api','match','rebuild-d1','fb_match_rebuild_d1');
 response:=public.futbeat_request_match_detail('fb_match_rebuild_d1');
 if response is null then raise exception 'D1 returned no stored response'; end if;
 if not exists(select 1 from futbeat_private.match_detail_requests
   where match_id='fb_match_rebuild_d1' and source='user' and expires_at>now())
 then raise exception 'D1 failed to record expiring P0 interest'; end if;
 if futbeat_private.live_demand_tier('fb_match_rebuild_d1')<>0 then raise exception 'D1 interest is not P0'; end if;
 perform public.futbeat_request_match_detail('fb_match_rebuild_d1');
 if calls_before<>(select count(*) from futbeat_private.provider_call_ledger)
 then raise exception 'Opening D1 directly reserved a provider call'; end if;
 if wakes_before<>(select coalesce(sum(wake_count),0) from futbeat_private.worker_wakeups)
 then raise exception 'Opening D1 directly woke a worker'; end if;
end $test$;
rollback;
