import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
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
