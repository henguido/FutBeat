import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { openDatabase } from '../storage/database.mjs';
import { createTransport } from '../notifications/transports.mjs';
import { dispatchNotifications } from '../notifications/dispatch.mjs';

test('durable canonical events, first observation, duplicates, cards, two devices and outbox delivery',async()=>{
 const db=await openDatabase();
 try {
  const fixture=JSON.parse(await readFile(new URL('../../packages/contracts/demo.snapshot.json',import.meta.url)));
  for(const [kind,items] of [['competition',fixture.competitions],['team',fixture.teams],['match',fixture.matches]]) {
   for(const item of items) await db.query('insert into futbeat_private.entities values($1,$2,$3)',[item.id,kind,JSON.stringify(item)]);
  }
  for(const [kind,external,id] of [['match','test-fixture','fb_match_clasico'],['team','1','fb_team_sap'],['team','2','fb_team_lda']])
   await db.query('insert into futbeat_private.provider_entities values($1,$2,$3,$4)',['api_football',kind,external,id]);
  const uid=randomUUID();
  for(let i=0;i<2;i++) await db.query("insert into futbeat_private.push_devices(user_id,installation_id,platform,transport,token) values($1,$2,'android','test',$3)",[uid,randomUUID(),'test-token-'+i]);
  await db.query("insert into futbeat_private.push_follows(user_id,entity_type,entity_id) values($1,'team','fb_team_lda')",[uid]);
  let sequence=0;
  const record=async(events,status='LIVE',external='test-fixture')=>{
   const obs={externalMatchId:external,status,minute:80,score:{home:0,away:events.filter(e=>e.type==='GOAL').length},events};
   obs.payloadHash=createHash('sha256').update(JSON.stringify(obs)).digest('hex');
   const at=new Date(Date.now()+sequence++).toISOString();
   return (await db.query('select public.futbeat_record_live_batch($1,$2,$3) as result',['api_football',at,JSON.stringify([obs])])).rows[0].result;
  };
  const event=(key,type,minute)=>({eventKey:key,type,minute,teamExternalId:'2',playerExternalId:'88',payload:{time:{elapsed:minute}}});
  const first=event('old','GOAL',20);
  let result=await record([first]);
  assert.equal(result.changes[0].notifyCandidate,false);
  assert.equal((await db.query('select * from futbeat_private.notification_outbox')).rows.length,0);
  const goal=event('new','GOAL',63);
  result=await record([first,goal]);
  assert.equal(result.changes[0].notifyCandidate,true);
  assert.equal((await db.query('select * from futbeat_private.notification_outbox')).rows.length,2);
  result=await record([first,goal]);
  assert.equal(result.duplicates,1);
  await record([first,{...goal,eventKey:'provider-comment-changed'}]);
  assert.equal((await db.query('select * from futbeat_private.notification_outbox')).rows.length,2);
  const second=event('second','GOAL',66),card=event('card','YELLOW_CARD',71);
  await record([first,goal,second,card]);
  assert.equal((await db.query('select * from futbeat_private.notification_outbox')).rows.length,6);
  await record([event('unknown','GOAL',5)],'LIVE','unmapped-fixture');
  assert.equal((await db.query('select * from public.live_match_updates')).rows.length,1);
  let timeline=(await db.query('select latest_events from public.live_match_updates')).rows[0].latest_events;
  assert.equal(timeline.filter(e=>e.type==='GOAL').length,3);
  assert.ok(timeline.every(e=>e.id.startsWith('fb_event_') && e.matchId==='fb_match_clasico' && !e.payload && !e.teamExternalId));
  assert.equal(timeline.find(e=>e.type==='YELLOW_CARD').teamId,'fb_team_lda');
  await record([first,goal,second,card],'FINISHED_PENDING_VERIFICATION');
  const messages=(await db.query('select message from futbeat_private.notification_outbox')).rows;
  assert.ok(messages.some(r=>r.message.title.startsWith('🏁 Final')));
  const rpc=async(name,args)=>{
   const keys=Object.keys(args);
   return (await db.query('select public.'+name+'('+keys.map((_,i)=>'$'+(i+1)).join(',')+') as value',Object.values(args))).rows[0].value;
  };
  const deliveries=await dispatchNotifications({rpc,transport:createTransport(),mode:'dry_run'});
  assert.equal(deliveries.length,8);
  assert.ok(deliveries.every(x=>x.state==='simulated'));
  assert.equal((await dispatchNotifications({rpc,transport:createTransport()})).length,0);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.notification_outbox')).rows[0].n,8);
  await db.exec("create role outsider; set role outsider");
  await assert.rejects(db.query('select * from futbeat_private.push_devices'));
  await assert.rejects(db.query("select public.futbeat_claim_notifications()"));
  await db.exec('reset role');
 } finally {await db.close();}
});

test('dry run never contacts FCM/APNs and refuses a real device',async()=>{
 const transport=createTransport({fetcher:()=>{throw new Error('must not call network');}});
 assert.equal((await transport.send({id:'safe',transport:'test'})).state,'simulated');
 await assert.rejects(transport.send({id:'unsafe',transport:'fcm'}));
 assert.equal((await createTransport({mode:'live'}).send({transport:'fcm'})).receipt,'FCM_NOT_CONFIGURED');
});

import { normalizeObservation } from '../providers/live_observation.mjs';
test('LIVE event normalization supports all event types without unstable order/comments in IDs',async()=>{
 const types=[['Goal','Normal Goal','GOAL'],['Card','Yellow Card','YELLOW_CARD'],['Card','Red Card','RED_CARD'],
 ['subst','Substitution','SUBSTITUTION'],['Var','Goal confirmed','VAR'],['Goal','Missed Penalty','MISSED_PENALTY']];
 const fixture={fixture:{id:123,date:'2026-09-16T12:00:00Z',status:{short:'1H',elapsed:20}},
 league:{country:'Costa Rica'},teams:{home:{id:1,name:'Home'},away:{id:2,name:'Away'}},goals:{home:0,away:0},
 events:types.map(([type,detail],i)=>({type,detail,time:{elapsed:20+i,extra:1},team:{id:2},player:{id:80+i},assist:{id:90+i}}))};
 const first=await normalizeObservation(fixture);
 assert.deepEqual(first.events.map(e=>e.type),types.map(x=>x[2]));
 const repeat=await normalizeObservation({...fixture,events:[...fixture.events].reverse().map(e=>({...e,comments:'updated text'}))});
 assert.deepEqual(first.events.map(e=>e.eventKey).sort(),repeat.events.map(e=>e.eventKey).sort());
 assert.equal(first.events[3].assistExternalId,'93');
});
test('push registration requires authenticated ownership and raw tables stay private',async()=>{
 const db=await openDatabase();
 try {
  await db.exec("create schema auth; create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;");
  await assert.rejects(db.query("select public.futbeat_register_push($1,'android','fcm','test-token',true)",[randomUUID()]),/Authentication required/);
  const uid=randomUUID(),other=randomUUID(),installation=randomUUID();
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[uid]);
  const did=(await db.query("select public.futbeat_register_push($1,'android','fcm','owner-token',true) as id",[installation])).rows[0].id;
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[other]);
  await assert.rejects(db.query("select public.futbeat_register_push($1,'android','fcm','owner-token',true)",[randomUUID()]));
  assert.equal((await db.query('select user_id from futbeat_private.push_devices where id=$1',[did])).rows[0].user_id,uid);
 } finally {await db.close();}
});
