import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

const call = async (db, source = 'cron') => (await db.query(
  'select public.futbeat_reserve_live_call($1) value',[source],
)).rows[0].value;

async function seedBetaMatch(db,{offsetMinutes,status='SCHEDULED'}={}) {
 const competition='fb_competition_beta',home='fb_team_beta_home',away='fb_team_beta_away',match='fb_match_beta';
 const start=new Date(Date.now()+offsetMinutes*60000).toISOString();
 await db.query("insert into futbeat_private.entities values($1,'competition',$2)",[competition,JSON.stringify({id:competition,name:'La Liga',country:'Spain'})]);
 await db.query("insert into futbeat_private.provider_entities values('api_football','competition','140',$1)",[competition]);
 for(const [id,name] of [[home,'Home'],[away,'Away']]) await db.query("insert into futbeat_private.entities values($1,'team',$2)",[id,JSON.stringify({id,name,competitionId:competition})]);
 await db.query("insert into futbeat_private.entities values($1,'match',$2)",[match,JSON.stringify({
  id:match,competitionId:competition,homeTeamId:home,awayTeamId:away,startTime:start,status,
  score:null,events:[],statistics:[],provenance:{source:'API-Football',externalId:'700',receivedAt:new Date().toISOString()},
 })]);
 for(const [kind,external,id] of [['match','700',match],['team','10',home],['team','20',away]])
  await db.query('insert into futbeat_private.provider_entities values($1,$2,$3,$4)',['api_football',kind,external,id]);
 return {competition,home,away,match,start};
}

test('dynamic LIVE guard spends nothing outside window and allows upcoming kickoff once',async()=>{
 const db=await openDatabase();
 try {
  await seedBetaMatch(db,{offsetMinutes:60});
  assert.equal((await call(db)).reason,'outside_beta_window');
  assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_call_ledger where provider='api_football'")).rows[0].n,0);
  await db.query("update futbeat_private.entities set payload=jsonb_set(payload,'{startTime}',to_jsonb($1::text)) where id='fb_match_beta'",[new Date(Date.now()+4*60000).toISOString()]);
  assert.equal((await call(db)).allowed,true);
  assert.equal((await call(db)).reason,'min_interval');
 } finally {await db.close();}
});

test('LIVE guard accepts active state, stops finished match and preserves seven-call reserve',async()=>{
 const db=await openDatabase();
 try {
  const ids=await seedBetaMatch(db,{offsetMinutes:-30,status:'LIVE'});
  assert.equal((await call(db)).allowed,true);
  await db.query("update futbeat_private.entities set payload=jsonb_set(payload,'{status}','\"FINISHED_PENDING_VERIFICATION\"') where id=$1",[ids.match]);
  assert.equal((await call(db)).reason,'outside_beta_window');
  await db.query("update futbeat_private.entities set payload=jsonb_set(payload,'{status}','\"LIVE\"') where id=$1",[ids.match]);
  await db.query("delete from futbeat_private.provider_call_ledger");
  for(let i=0;i<75;i++) await db.query("insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,status) values('api_football','live','test',now()-interval '6 minutes','SUCCEEDED')");
  const before=(await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n;
  assert.equal((await call(db)).reason,'live_daily_limit');
  assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n,before);
  for(let i=0;i<20;i++) await db.query("insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,status) values('api_football','fixtures-date-today','test',now(),'SUCCEEDED')");
  assert.equal((await call(db)).reason,'global_daily_limit');
 } finally {await db.close();}
});

test('existing canonical fixture transitions SCHEDULED to LIVE to FT without duplication',async()=>{
 const db=await openDatabase();
 try {
  const ids=await seedBetaMatch(db,{offsetMinutes:-10});
  const record=async(status,homeScore,minute)=>{
   const observation={externalMatchId:'700',competitionId:ids.competition,competitionExternalId:'140',
    status,minute,score:{home:homeScore,away:0},events:[],startTime:ids.start,
    homeTeam:{externalId:'10',name:'Home'},awayTeam:{externalId:'20',name:'Away'}};
   observation.payloadHash=createHash('sha256').update(JSON.stringify(observation)).digest('hex');
   await db.query('select public.futbeat_record_live_batch($1,$2,$3)',['api_football',new Date().toISOString(),JSON.stringify([observation])]);
  };
  await record('LIVE',1,20);
  await record('FINISHED_PENDING_VERIFICATION',2,90);
  const update=(await db.query('select * from public.live_match_updates where match_id=$1',[ids.match])).rows[0];
  assert.equal(update.status,'FINISHED_PENDING_VERIFICATION');
  assert.equal(update.home_score,2);
  assert.equal((await db.query("select count(*)::int n from futbeat_private.entities where kind='match'")).rows[0].n,1);
  assert.equal((await db.query("select canonical_id from futbeat_private.provider_entities where provider='api_football' and kind='match' and external_id='700'")).rows[0].canonical_id,ids.match);
 } finally {await db.close();}
});


test('GOAL LIVE pagination is not capped to the first 100 fixtures',async()=>{
 const workflow=await readFile(new URL('../../.github/workflows/live-fixtures.yml',import.meta.url),'utf8');
 assert.match(workflow,/fixtures\/live\?limit=100&offset=\$offset/);
 assert.match(workflow,/pagination\.hasMore/);
 assert.match(workflow,/providerRequests/);
});

test('GOAL LIVE links an existing scheduled match by teams and kickoff without a preexisting external id',async()=>{
 const db=await openDatabase();
 try {
  const competition='fb_comp_goal_live',home='fb_team_brentford',away='fb_team_chelsea',match='fb_match_goal_live';
  const start=new Date().toISOString();

  await db.query("insert into futbeat_private.entities values($1,'competition',$2)",[
   competition,JSON.stringify({id:competition,name:'Premier League',country:'England'})
  ]);
  await db.query("insert into futbeat_private.entities values($1,'team',$2)",[
   home,JSON.stringify({id:home,name:'Brentford',country:'England',competitionId:competition})
  ]);
  await db.query("insert into futbeat_private.entities values($1,'team',$2)",[
   away,JSON.stringify({id:away,name:'Chelsea',country:'England',competitionId:competition})
  ]);
  await db.query("insert into futbeat_private.entities values($1,'match',$2)",[
   match,JSON.stringify({
    id:match,competitionId:competition,homeTeamId:home,awayTeamId:away,startTime:start,
    status:'SCHEDULED',score:null,events:[],statistics:[],
    provenance:{source:'FutBeat Global',receivedAt:new Date().toISOString()}
   })
  ]);

  const fixture={
   apiId:'812690',
   kickoffUtc:start,
   matchStatus:'LIVE',
   matchElapsed:18,
   homeTeamScore:'1',
   awayTeamScore:'0',
   homeTeam:{id:'goal-home',name:'Brentford'},
   awayTeam:{id:'goal-away',name:'Chelsea'},
  };

  const linked=(await db.query(
   'select public.futbeat_link_goal_live_matches($1) result',
   [JSON.stringify([fixture])],
  )).rows[0].result;

  assert.equal(linked.linked,1);
  assert.equal(linked.unmappedCount,0);
  assert.equal((await db.query(
   "select canonical_id from futbeat_private.provider_entities where provider='goal_api' and kind='match' and external_id='812690'"
  )).rows[0].canonical_id,match);

  const observation={
   externalMatchId:'812690',
   status:'LIVE',
   minute:18,
   score:{home:1,away:0},
   events:[],
   rawPayload:fixture,
  };
  observation.payloadHash=createHash('sha256').update(JSON.stringify([
   observation.externalMatchId,observation.status,observation.minute,1,0
  ])).digest('hex');

  await db.query('select public.futbeat_record_live_batch($1,$2,$3)',[
   'goal_api',new Date().toISOString(),JSON.stringify([observation])
  ]);

  const update=(await db.query(
   'select * from public.live_match_updates where match_id=$1',[match]
  )).rows[0];
  assert.equal(update.status,'LIVE');
  assert.equal(update.minute,18);
  assert.equal(update.home_score,1);

  const unrelated={...fixture,apiId:'812691',kickoffUtc:new Date(Date.now()+8*3600000).toISOString()};
  const rejected=(await db.query(
   'select public.futbeat_link_goal_live_matches($1) result',
   [JSON.stringify([unrelated])],
  )).rows[0].result;
  assert.equal(rejected.linked,0);
  assert.equal(rejected.unmappedCount,1);
 } finally {await db.close();}
});


test('GOAL score increase creates a provisional canonical goal event without detail quota',async()=>{
 const db=await openDatabase();
 try {
  const competition='fb_comp_goal_event',home='fb_team_goal_home',away='fb_team_goal_away',match='fb_match_goal_event';
  const start=new Date().toISOString();
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)",[
   competition,JSON.stringify({id:competition,name:'Liga Test',country:'Costa Rica'}),
  ]);
  for(const [id,name] of [[home,'Home'],[away,'Away']]) {
   await db.query("insert into futbeat_private.entities values($1,'team',$2)",[
    id,JSON.stringify({id,name,competitionId:competition}),
   ]);
  }
  await db.query("insert into futbeat_private.entities values($1,'match',$2)",[
   match,JSON.stringify({
    id:match,competitionId:competition,homeTeamId:home,awayTeamId:away,startTime:start,
    status:'SCHEDULED',score:null,events:[],statistics:[],
    provenance:{source:'GOAL API',receivedAt:start},
   }),
  ]);
  await db.query(
   "insert into futbeat_private.provider_entities values('goal_api','match','goal-event-1',$1)",
   [match],
  );

  const record=async(homeScore,awayScore,minute,stamp)=>{
   const observation={
    externalMatchId:'goal-event-1',
    payloadHash:createHash('sha256').update(JSON.stringify([homeScore,awayScore,minute,stamp])).digest('hex'),
    status:'LIVE',
    minute,
    score:{home:homeScore,away:awayScore},
    events:[],
    rawPayload:{apiId:'goal-event-1'},
   };
   await db.query(
    'select public.futbeat_record_live_batch($1,$2,$3)',
    ['goal_api',stamp,JSON.stringify([observation])],
   );
  };

  await record(0,0,5,new Date(Date.now()-1000).toISOString());
  await record(1,0,12,new Date().toISOString());

  const events=(await db.query(
   "select payload from futbeat_private.canonical_events where match_id=$1 and event_type='GOAL'",
   [match],
  )).rows;
  assert.equal(events.length,1);
  assert.equal(events[0].payload.synthetic,true);
  assert.equal(events[0].payload.teamId,home);
  assert.equal(events[0].payload.score.home,1);

  const published=(await db.query(
   'select latest_events from public.live_match_updates where match_id=$1',
   [match],
  )).rows[0].latest_events;
  assert.equal(published.some(event=>event.type==='GOAL'),true);
 } finally {await db.close();}
});

test('Match Center detail is queued once, cached, and not refetched while fresh',async()=>{
 const db=await openDatabase();
 try {
  const ids=await seedBetaMatch(db,{offsetMinutes:-15,status:'LIVE'});
  await db.query(
   "insert into futbeat_private.provider_entities values('goal_api','match','goal-detail-1',$1)",
   [ids.match],
  );

  const initial=(await db.query(
   'select public.futbeat_request_match_detail($1) value',[ids.match],
  )).rows[0].value;
  assert.equal(initial.available,false);
  assert.equal(initial.detailLevel,'none');

  const plan=(await db.query(
   "select public.futbeat_reserve_match_detail_call('test') value",
  )).rows[0].value;
  assert.equal(plan.allowed,true);
  assert.equal(plan.matchId,ids.match);
  assert.equal(plan.externalMatchId,'goal-detail-1');

  const payload={
   matchReferee:'Ref Test',
   matchStadium:'Estadio Test',
   matchRound:'9',
   homeTeamSystem:'4-3-3',
   awayTeamSystem:'4-2-3-1',
   lineups:{
    hasLineups:true,
    homeFormation:'4-3-3',
    awayFormation:'4-2-3-1',
    home:{startingLineups:[{lineupPlayer:'Home One',lineupNumber:'9',playerPosition:'Forward'}],substitutes:[]},
    away:{startingLineups:[{lineupPlayer:'Away One',lineupNumber:'1',playerPosition:'Goalkeeper'}],substitutes:[]},
   },
   statistics:{match:{fullTime:[{type:'Ball Possession',home:'55%',away:'45%'}]}},
   cards:[],
   substitutions:[],
  };
  const stored=(await db.query(
   'select public.futbeat_store_match_detail($1,$2,$3,$4) value',
   [ids.match,'goal-detail-1',new Date().toISOString(),JSON.stringify(payload)],
  )).rows[0].value;
  assert.equal(stored.available,true);
  assert.equal(stored.detailLevel,'full');
  assert.equal(stored.payload.matchReferee,'Ref Test');

  const second=(await db.query(
   "select public.futbeat_reserve_match_detail_call('test') value",
  )).rows[0].value;
  assert.equal(second.allowed,false);
  assert.equal(second.reason,'no_detail_due');
 } finally {await db.close();}
});


test('historical Match Center detail queues recent finished matches once and keeps verified cache',async()=>{
 const db=await openDatabase();
 try {
  const ids=await seedBetaMatch(db,{offsetMinutes:-(30*24*60),status:'VERIFIED'});
  await db.query(
   "insert into futbeat_private.provider_entities values('goal_api','match','goal-history-1',$1)",
   [ids.match],
  );

  const first=(await db.query(
   'select public.futbeat_request_match_detail($1) value',[ids.match],
  )).rows[0].value;
  assert.equal(first.available,false);

  const plan=(await db.query(
   "select public.futbeat_reserve_match_detail_call('test') value",
  )).rows[0].value;
  assert.equal(plan.allowed,true);
  assert.equal(plan.matchId,ids.match);

  await db.query(
   'select public.futbeat_store_match_detail($1,$2,$3,$4)',
   [
    ids.match,
    'goal-history-1',
    new Date().toISOString(),
    JSON.stringify({
     events:[{type:'Goal',time:'45+2',homeScorer:'Historic Goal'}],
     cards:[{card:'Yellow Card',time:'51',homeFault:'Historic Card'}],
     substitutions:[],
    }),
   ],
  );

  await db.query('select public.futbeat_request_match_detail($1)',[ids.match]);
  const again=(await db.query(
   "select public.futbeat_reserve_match_detail_call('test') value",
  )).rows[0].value;
  assert.equal(again.allowed,false);
  assert.equal(again.reason,'no_detail_due');
 } finally {await db.close();}
});

test('GOAL quota priority preserves LIVE while allowing bounded Match Center detail',async()=>{
 const db=await openDatabase();
 try {
  const ids=await seedBetaMatch(db,{offsetMinutes:-15,status:'LIVE'});
  await db.query(
   "insert into futbeat_private.provider_entities values('goal_api','match','goal-quota-match',$1)",
   [ids.match],
  );
  await db.query('select public.futbeat_request_match_detail($1)',[ids.match]);
  await db.query(
   "insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,provider_remaining) values('goal_api','global-ingest','test',now()-interval '10 minutes',now()-interval '10 minutes','SUCCEEDED',200)"
  );

  const catalog=(await db.query(
   'select public.futbeat_goal_low_priority_plan(350) value'
  )).rows[0].value;
  assert.equal(catalog.allowed,false);
  assert.equal(catalog.reason,'provider_remaining_reserve');
  assert.equal(catalog.reserve,350);

  const detail=(await db.query(
   "select public.futbeat_reserve_match_detail_call('test') value"
  )).rows[0].value;
  assert.equal(detail.allowed,true);
  assert.equal(detail.reserve,80);

  await db.query(
   "insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,provider_remaining) values('goal_api','global-ingest','test',now(),now(),'SUCCEEDED',70)"
  );
  const protectedDetail=(await db.query(
   "select public.futbeat_reserve_match_detail_call('test') value"
  )).rows[0].value;
  assert.equal(protectedDetail.allowed,false);
  assert.equal(protectedDetail.reason,'provider_remaining_reserve');
  assert.equal(protectedDetail.reserve,80);

  const live=(await db.query(
   "select public.futbeat_reserve_goal_live_call('test') value"
  )).rows[0].value;
  assert.equal(live.allowed,true);
  assert.equal(live.reserve,20);
 } finally {await db.close();}
});

test('global catalog workflow uses only its three-hour schedule and low-priority guard',async()=>{
 const workflow=await readFile(new URL('../../.github/workflows/global-fixtures.yml',import.meta.url),'utf8');
 assert.match(workflow,/cron: '17 \*\/3 \* \* \*'/);
 assert.doesNotMatch(workflow,/cron: '\*\/5 \* \* \*'/);
 assert.match(workflow,/action = "global-quota-plan"/);
 assert.match(workflow,/\$quotaReserve = 350/);
 assert.match(workflow,/\$squadReserve = 350/);
 assert.match(workflow,/\$calendarRequestBudget = 180/);
});


test('LIVE workflow avoids peak minute zero while keeping a five-minute cadence',async()=>{
 const workflow=await readFile(new URL('../../.github/workflows/live-fixtures.yml',import.meta.url),'utf8');
 assert.match(workflow,/cron: '2-57\/5 \* \* \* \*'/);
 assert.doesNotMatch(workflow,/cron: '\*\/5 \* \* \* \*'/);
});
