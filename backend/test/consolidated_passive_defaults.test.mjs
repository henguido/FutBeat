import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

test('consolidated production defaults: navigation stays passive for all enrichment routes', async t => {
  const db=await openDatabase();t.after(()=>db.close());
  assert.equal((await db.query('select futbeat_private.navigation_demands_enabled() enabled')).rows[0].enabled,false);
  assert.equal(Number((await db.query("select futbeat_private.quota_setting('goal_api','openTriggersFetch',1) v")).rows[0].v),0);
  const requests=[
    ["select public.futbeat_request_calendar_date(current_date,'UTC') v",[]],
    ['select public.futbeat_request_player_profile($1) v',['fb_player_missing']],
    ['select public.futbeat_request_team_squad($1) v',['fb_team_missing']],
    ['select public.futbeat_request_team_matches($1,null) v',['fb_team_missing']],
    ['select public.futbeat_request_match_standings($1) v',['fb_match_missing']],
    ['select public.futbeat_request_match_h2h($1) v',['fb_match_missing']],
    ['select public.futbeat_request_match_h2h_history($1) v',['fb_match_missing']],
    ['select public.futbeat_request_terminal_result($1) v',['fb_match_missing']],
    ['select public.futbeat_request_lineup_hydration($1,$2) v',[['fb_player_missing'],[]]],
  ];
  for(const [sql,args] of requests) assert.deepEqual((await db.query(sql,args)).rows[0].v,{passive:true,requested:false},sql);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n,0);
  assert.equal((await db.query('select coalesce(sum(wake_count),0)::int n from futbeat_private.worker_wakeups')).rows[0].n,0);
});

test('D1v2 default: a repeated LIVE open records one expiring P0 interest without acquisition or direct wake', async t=>{
  const db=await openDatabase();t.after(()=>db.close());
  const match='fb_match_default_d1';
  await db.query(`insert into futbeat_private.entities(id,kind,payload) values($1,'match',jsonb_build_object(
    'id',$1::text,'competitionId','fb_comp_default_d1','homeTeamId','fb_team_default_h','awayTeamId','fb_team_default_a',
    'status','LIVE','minute',10,'startTime',now()-interval '10 minutes','score',jsonb_build_object('home',0,'away',0),
    'events','[]'::jsonb,'statistics','[]'::jsonb))`,[match]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match','default-d1',$1)",[match]);
  for(let i=0;i<5;i++){
    const response=(await db.query('select public.futbeat_request_match_detail($1) v',[match])).rows[0].v;
    assert.ok(response,'stored response opens immediately');
  }
  const rows=(await db.query('select source,request_count::int n,expires_at>now() valid from futbeat_private.match_detail_requests where match_id=$1',[match])).rows;
  assert.deepEqual(rows,[{source:'user',n:1,valid:true}]);
  assert.equal((await db.query('select futbeat_private.live_demand_tier($1) v',[match])).rows[0].v,0);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n,0);
  assert.equal((await db.query('select coalesce(sum(wake_count),0)::int n from futbeat_private.worker_wakeups')).rows[0].n,0);
});
