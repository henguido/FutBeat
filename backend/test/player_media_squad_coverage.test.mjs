import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import { normalizeGoalApiSquad } from '../providers/goal_api_players.mjs';

const photo='https://media.goal-api.com/players/shared.png';
async function team(db,id='fb_team_media_a',competition='fb_comp_media') {
 await db.query(`insert into futbeat_private.entities values($1,'competition',$2) on conflict do nothing`,
  [competition,JSON.stringify({id:competition,name:'Competition',country:'England'})]);
 await db.query(`insert into futbeat_private.entities values($1,'team',$2) on conflict do nothing`,
  [id,JSON.stringify({id,name:id,competitionId:competition})]);
 await db.query("insert into futbeat_private.provider_entities values('goal_api','team',$1,$2) on conflict do nothing",[id,id]);
 return id;
}
async function squad(db,tid,rows,stamp=new Date().toISOString()) {
 const players=await normalizeGoalApiSquad(rows,tid,async(kind,external,identity)=>
  (await db.query('select public.futbeat_resolve_global_entity($1,$2,$3,$4) id',
   ['goal_api',kind,external,identity.name])).rows[0].id,stamp);
 return (await db.query('select public.futbeat_store_team_squad($1,$2,$3,$4) v',
  [tid,'goal_api',stamp,JSON.stringify(players)])).rows[0].v;
}
const player=async(db,ext)=>(await db.query(`select e.id,e.payload from futbeat_private.provider_entities pe
 join futbeat_private.entities e on e.id=pe.canonical_id where pe.kind='player' and pe.external_id=$1`,[ext])).rows[0];

test('SQL GOAL media policy rejects unsafe URLs and harvest shares the policy',async()=>{
 const db=await openDatabase();
 try {
  const cases=[photo,'http://media.goal-api.com/a.png','https://media.goal-api.com.evil.test/a.png',
   'https://evil.test/a.png','https://media.goal-api.com@evil.test/a.png',
   'https://media.goal-api.com:443/a.png','https://media.goal-api.com/a b.png',
   'https://media.goal-api.com/a\\b.png','https://media.goal-api.com/%zz.png',
   'https://media.goal-api.com/',null,''];
  for(const [i,url] of cases.entries()) {
   const valid=(await db.query("select futbeat_private.futbeat_valid_goal_player_media_url($1,'GOAL API') v",[url])).rows[0].v;
   assert.equal(valid,i===0,`URL ${url}`);
   await db.query('select futbeat_private.harvest_lineup_media($1,now())',
    [JSON.stringify({lineups:[{type:'starting',playerId:`policy-${i}`,playerImage:url}]})]);
   assert.equal((await player(db,`policy-${i}`)).payload.media?.url,i===0?photo:undefined);
  }
  assert.equal((await db.query("select futbeat_private.futbeat_valid_goal_player_media_url($1,'EDITORIAL') v",[photo])).rows[0].v,false);
  for(const role of ['anon','authenticated','service_role']) {
   assert.equal((await db.query("select has_function_privilege($1,'futbeat_private.futbeat_valid_goal_player_media_url(text,text)','EXECUTE') v",[role])).rows[0].v,false);
  }
 } finally {await db.close();}
});

test('changing only the central SQL host policy propagates through harvest and canonical batch lookup',async()=>{
 const db=await openDatabase();
 try {
  const definition=(await db.query("select pg_get_functiondef('futbeat_private.futbeat_valid_goal_player_media_url(text,text)'::regprocedure) v")).rows[0].v;
  assert.ok(definition.includes('media.goal-api.com'));
  // Disposable local DB only: simulate a centrally reviewed CDN allowlist update.
  await db.exec(definition.replace('media.goal-api.com','cdn.example.test'));
  const next='https://cdn.example.test/player.png';
  await db.query('select futbeat_private.harvest_lineup_media($1,now())',
   [JSON.stringify({lineups:[{type:'starting',playerId:'new-cdn',playerImage:next},
    {type:'starting',playerId:'old-cdn',playerImage:photo}]})]);
  const result=(await db.query("select public.futbeat_read_lineup_player_media('goal_api',$1) v",[['new-cdn','old-cdn','unresolved','unresolved']])).rows[0].v;
  assert.equal(result['new-cdn'].image,next);
  assert.equal(result['old-cdn'].image,null);
  assert.deepEqual(result.unresolved,{providerId:'unresolved',canonicalId:null,image:null});
  assert.equal(Object.keys(result).length,3);
 } finally {await db.close();}
});

test('service global-ingest snapshot path and squad RPC work without private table grants',async()=>{
 const db=await openDatabase();
 try {
  const tid=await team(db);
  await db.exec('set role service_role');
  await db.query('select public.futbeat_read_snapshot()');
  await squad(db,tid,[{id:'permissions',name:'Player',photo}]);
  const metrics=(await db.query('select public.futbeat_player_coverage_metrics() v')).rows[0].v;
  assert.equal(metrics.players_with_photo,1);
  await assert.rejects(db.query('select * from futbeat_private.team_squad_members'),/permission denied/);
  await db.exec('reset role');
  const f=(await db.query("select prosecdef,proconfig,pg_get_userbyid(proowner) owner from pg_proc where oid='public.futbeat_read_snapshot()'::regprocedure")).rows[0];
  assert.equal(f.prosecdef,true); assert.equal(f.owner,'postgres'); assert.deepEqual(f.proconfig,['search_path=""']);
  for(const role of ['anon','authenticated']) {
   await db.exec(`set role ${role}`);
   await assert.rejects(db.query('select * from futbeat_private.team_squad_members'),/permission denied/);
   await assert.rejects(db.query('select * from futbeat_private.player_media_coverage'),/permission denied/);
   await assert.rejects(db.query('select public.futbeat_player_coverage_metrics()'),/permission denied/);
   await assert.rejects(db.query('select public.futbeat_read_snapshot()'),/permission denied/);
   await db.exec('reset role');
  }
 } finally {await db.close();}
});

test('squad is idempotent, preserves omitted members, moves one canonical player and respects team redirects',async()=>{
 const db=await openDatabase();
 try {
  const a=await team(db),b=await team(db,'fb_team_media_b'),alias=await team(db,'fb_team_media_alias');
  await db.query("insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values($1,$2,'team','verified')",[alias,b]);
  const reserved=(await db.query("select public.futbeat_reserve_goal_squad_call($1,$2,'test') v",[b,alias])).rows[0].v;
  assert.equal(reserved.allowed,true); assert.equal(reserved.teamId,b);
  const rows=[{id:'one',name:'One',photo,number:9},{id:'two',name:'Two',photo:null}];
  await squad(db,a,rows); await squad(db,a,rows);
  assert.equal((await db.query("select count(*)::int n from futbeat_private.entities where kind='player'")).rows[0].n,2);
  const first=await player(db,'one');
  await squad(db,a,[{id:'one',name:'One'}]);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.team_squad_members where team_id=$1',[a])).rows[0].n,2);
  assert.equal((await player(db,'one')).payload.media.url,photo);
  assert.equal((await player(db,'one')).payload.shirtNumber,9);
  await squad(db,alias,[{id:'one',name:'One',photo:null}]);
  assert.equal((await player(db,'one')).id,first.id);
  assert.equal((await player(db,'one')).payload.teamId,b);
  assert.deepEqual((await db.query('select team_id from futbeat_private.team_squad_members where player_id=$1',[first.id])).rows.map(x=>x.team_id),[b]);
  assert.equal((await db.query('select player_count from futbeat_private.team_detail_coverage where team_id=$1',[a])).rows[0].player_count,1);
  // A verified second provider ID uses the same mapping, not name-based guessing.
  await db.query("insert into futbeat_private.provider_entities values('goal_api','player','one-new-id',$1)",[first.id]);
  await squad(db,b,[{id:'one-new-id',name:'One',photo:null}]);
  assert.equal((await player(db,'one-new-id')).id,first.id);
  assert.equal((await db.query("select count(*)::int n from futbeat_private.entities where kind='player'")).rows[0].n,2);
 } finally {await db.close();}
});

test('detail harvest populates canonical media without extra fetches and omission/older data cannot erase it',async()=>{
 const db=await openDatabase();
 try {
  await db.exec(`insert into futbeat_private.entities values('fb_match_media','match','{"id":"fb_match_media"}');
   insert into futbeat_private.provider_entities values('goal_api','match','detail-media','fb_match_media')`);
  const detail=async(rows,stamp)=>(await db.query(`select public.futbeat_store_match_detail('fb_match_media','detail-media',$1,$2)`,
   [stamp,JSON.stringify({lineups:rows})]));
  const stamp=new Date().toISOString();
  await detail([{type:'starting_lineups',playerKey:'lineup-one',lineupPlayer:'One',playerImage:photo}],stamp);
  const first=await player(db,'lineup-one');
  assert.equal(first.payload.media.url,photo);
  assert.equal(first.payload.media.discoveredVia,'lineup');
  assert.equal(first.payload.media.rightsStatus,'REVIEW_REQUIRED');
  await detail([{type:'starting_lineups',playerKey:'lineup-one',lineupPlayer:'One'}],new Date(Date.now()+1000).toISOString());
  assert.equal((await player(db,'lineup-one')).payload.media.url,photo);
  await detail([{type:'starting_lineups',playerKey:'lineup-one',lineupPlayer:'One',playerImage:'https://media.goal-api.com/older.png'}],'2020-01-01T00:00:00Z');
  assert.equal((await player(db,'lineup-one')).payload.media.url,photo);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n,0);
 } finally {await db.close();}
});

test('media TTLs distinguish confirmed absence, rejected URL and partial lineup discovery',async()=>{
 const db=await openDatabase();
 try {
  const tid=await team(db);
  await squad(db,tid,[{id:'valid',name:'Valid',photo},{id:'missing',name:'Missing'},
   {id:'invalid',name:'Invalid',photo:'http://media.goal-api.com/bad.png'}]);
  const rows=(await db.query(`select external_id,status,extract(epoch from retry_after-last_checked_at)/86400 ttl
   from futbeat_private.player_media_coverage order by external_id`)).rows;
  assert.deepEqual(rows.map(r=>[r.external_id,r.status,Number(r.ttl)]),[
   ['invalid','TEMPORARY_ERROR',1/24],['missing','NOT_AVAILABLE',30],['valid','AVAILABLE',90]]);
  const valid=await player(db,'valid'),missing=await player(db,'missing');
  const due=async(id,demand)=>(await db.query('select futbeat_private.player_media_refresh_due($1,$2) v',[id,demand])).rows[0].v;
  assert.equal(await due(valid.id,true),false); assert.equal(await due(missing.id,true),false);
  await db.query("update futbeat_private.player_media_coverage set retry_after=now()-interval '1 second' where player_id=$1",[valid.id]);
  assert.equal(await due(valid.id,false),false); assert.equal(await due(valid.id,true),true);
  assert.equal((await player(db,'valid')).payload.media.url,photo);
  await db.query("select public.futbeat_resolve_global_entity('goal_api','player','identity-only','Identity Only')");
  assert.equal((await db.query("select count(*)::int n from futbeat_private.player_media_coverage where external_id='identity-only'")).rows[0].n,0);
  await assert.rejects(normalizeGoalApiSquad({error:'failure'},tid,()=>null,new Date().toISOString()),/Failed squad/);
 } finally {await db.close();}
});

test('squad planner ranks demand P0 through P5, deduplicates mappings and has no country bonus',async()=>{
 const db=await openDatabase();
 try {
  const ids=[];
  for(let i=0;i<7;i++) ids.push(await team(db,`fb_team_priority_${i}`,`fb_comp_priority_${i}`));
  await db.exec(`insert into futbeat_private.entities
   select 'fb_match_priority_'||i,'match',jsonb_build_object('id','fb_match_priority_'||i,
    'homeTeamId','fb_team_priority_'||i,'awayTeamId','fb_team_priority_'||i,
    'startTime',now()+case when i=0 then interval '-10 minutes' else interval '1 day' end,
    'status',case when i=0 then 'LIVE' else 'SCHEDULED' end) from (values(0),(2)) x(i);
   insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth) values
    ('team','fb_team_priority_1',1,'DEEP'),('competition','fb_comp_priority_3',1,'DEEP');
   update futbeat_private.competition_editorial_metadata set relevance_score=900,source='editorial' where competition_id='fb_comp_priority_4';
   insert into futbeat_private.temporary_interests(user_id,entity_type,entity_id,expires_at)
    values('00000000-0000-0000-0000-000000000001','team','fb_team_priority_5',now()+interval '1 hour');
   update futbeat_private.entities set payload=payload||'{"country":"Costa Rica"}' where id='fb_comp_priority_6';
   insert into futbeat_private.provider_entities values('goal_api','team','zz-duplicate','fb_team_priority_1')`);
  const plan=(await db.query('select public.futbeat_team_squad_plan(25) v')).rows[0].v;
  assert.deepEqual(plan.map(x=>x.teamId),ids.slice(0,6));
  assert.deepEqual(plan.map(x=>x.priorityTier),[0,1,2,3,4,5]);
  await db.query(`insert into futbeat_private.provider_observations
   (provider,external_match_id,canonical_match_id,received_at,status,payload_hash,raw_payload)
   values('goal_api','priority-observation','fb_match_priority_0',now(),'SCHEDULED',$1,$2)`,
   ['b'.repeat(64),JSON.stringify({homeTeam:{id:ids[1]}})]);
  assert.equal((await db.query('select public.futbeat_team_squad_plan(25) v')).rows[0].v.find(x=>x.teamId===ids[1]).externalTeamId,ids[1]);
  await squad(db,ids[0],[{id:'fresh',name:'Fresh'}]);
  assert.ok(!(await db.query('select public.futbeat_team_squad_plan(25) v')).rows[0].v.some(x=>x.teamId===ids[0]));
 } finally {await db.close();}
});

test('central reservation single-flight and failure backoff protect shared quota',async()=>{
 const db=await openDatabase();
 try {
  const tid=await team(db);
  const reserve=async()=>(await db.query("select public.futbeat_reserve_goal_squad_call($1,$1,'test') v",[tid])).rows[0].v;
  const fail=async(id,http)=>db.query(`select public.futbeat_complete_provider_call($1,'FAILED',null,$2,'TEST_FAILURE','{}')`,[id,http]);
  const first=await reserve(); assert.equal(first.allowed,true);
  assert.equal((await reserve()).allowed,false);
  await fail(first.reservationId,500);
  const coverage=async()=>(await db.query(`select status,failure_count,last_error,
   extract(epoch from next_retry_at-last_attempt_at)::int seconds from futbeat_private.team_detail_coverage where team_id=$1`,[tid])).rows[0];
  assert.equal((await coverage()).seconds,900);
  assert.equal((await coverage()).status,'FETCH_FAILED');
  assert.equal((await reserve()).allowed,false);
  await db.query("update futbeat_private.team_detail_coverage set next_retry_at=now()-interval '1 second' where team_id=$1",[tid]);
  const second=await reserve(); await fail(second.reservationId,500);
  assert.equal((await coverage()).seconds,1800);
  await db.query("update futbeat_private.team_detail_coverage set next_retry_at=now()-interval '1 second' where team_id=$1",[tid]);
  const third=await reserve(); await fail(third.reservationId,404);
  assert.equal((await coverage()).status,'NO_DATA'); assert.equal((await coverage()).seconds,30*86400);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.player_media_coverage')).rows[0].n,0);
  await db.query("update futbeat_private.team_detail_coverage set next_retry_at=now()-interval '1 second' where team_id=$1",[tid]);
  await db.exec("insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,provider_remaining) values('goal_api','live-goal','test',300)");
  assert.equal((await reserve()).reason,'provider_remaining_reserve');
 } finally {await db.close();}
});

test('20 lineup identities use one batch query; coverage metrics match canonical photos',async()=>{
 const db=await openDatabase();
 try {
  const tid=await team(db);
  const rows=Array.from({length:20},(_,i)=>({id:`batch-${i}`,name:`Player ${i}`,photo:i<10?photo:null}));
  await squad(db,tid,rows);
  const result=(await db.query("select public.futbeat_read_lineup_player_media('goal_api',$1) v",[rows.map(r=>r.id)])).rows[0].v;
  assert.equal(Object.keys(result).length,20);
  for(let i=0;i<20;i++) {assert.equal(result[`batch-${i}`].image,i<10?photo:null); assert.ok(result[`batch-${i}`].canonicalId.startsWith('fb_player_'));}
  const metrics=(await db.query('select public.futbeat_player_coverage_metrics() v')).rows[0].v;
  assert.equal(metrics.canonical_players,20); assert.equal(metrics.players_with_photo,10);
  assert.equal(metrics.players_without_photo_known,10); assert.equal(metrics.squad_mapping_pct,100);
  assert.equal(metrics.squad_photo_pct,50); assert.equal(metrics.teams_fresh_pct,100);
  const source=await readFile(new URL('../../supabase/functions/futbeat-api/index.ts',import.meta.url),'utf8');
  assert.match(source,/safeImage\(canonical.image\) \?\?/);
 } finally {await db.close();}
});

test('empty successful squad retains members; 429 and network failure never imply NO_PHOTO',async()=>{
 const db=await openDatabase();
 try {
  const tid=await team(db);
  await squad(db,tid,[{id:'keep',name:'Keep',photo}]);
  await squad(db,tid,[]);
  const cov=(await db.query('select status,player_count,media_count from futbeat_private.team_detail_coverage where team_id=$1',[tid])).rows[0];
  assert.deepEqual(cov,{status:'NO_DATA',player_count:1,media_count:1});
  await db.query("update futbeat_private.team_detail_coverage set next_retry_at=now()-interval '1 second' where team_id=$1",[tid]);
  const reservation=(await db.query("select public.futbeat_reserve_goal_squad_call($1,$1,'test') v",[tid])).rows[0].v;
  await db.query("select public.futbeat_complete_provider_call($1,'FAILED',0,429,'QUOTA','{}')",[reservation.reservationId]);
  assert.equal((await db.query('select extract(epoch from next_retry_at-last_attempt_at)::int n from futbeat_private.team_detail_coverage where team_id=$1',[tid])).rows[0].n,86400);
  assert.equal((await player(db,'keep')).payload.media.url,photo);
  await assert.rejects(normalizeGoalApiSquad({success:false,data:[]},tid,()=>null,new Date().toISOString()),/Failed squad/);
 } finally {await db.close();}
});

test('lower trust, null, invalid and older media cannot replace a good canonical photo',async()=>{
 const db=await openDatabase();
 try {
  const tid=await team(db);
  await squad(db,tid,[{id:'quality',name:'Quality',photo}]);
  const initial=await player(db,'quality');
  const checked=(await db.query('select last_checked_at from futbeat_private.player_media_coverage where player_id=$1',[initial.id])).rows[0].last_checked_at;
  for(const media of [null,{url:'',verificationStatus:'VERIFIED'},{url:'http://invalid/photo',verificationStatus:'VERIFIED'},
   {url:'https://media.goal-api.com/unverified.png',verificationStatus:'PROVISIONAL'}]) {
   await db.query("update futbeat_private.entities set payload=jsonb_set(payload,'{media}',$2::jsonb,true) where id=$1",[initial.id,JSON.stringify(media)]);
   assert.equal((await player(db,'quality')).payload.media.url,photo);
  }
  assert.deepEqual((await db.query('select last_checked_at from futbeat_private.player_media_coverage where player_id=$1',[initial.id])).rows[0].last_checked_at,checked);
  await db.query(`update futbeat_private.entities set payload=jsonb_set(payload,'{media}',
    '{"url":"https://trusted.example/photo.png","source":"EDITORIAL","verificationStatus":"VERIFIED","receivedAt":"2030-01-01T00:00:00Z","rightsStatus":"LICENSED"}') where id=$1`,[initial.id]);
  await squad(db,tid,[{id:'quality',name:'Quality',photo:'https://media.goal-api.com/new.png'}]);
  assert.equal((await player(db,'quality')).payload.media.url,'https://trusted.example/photo.png');
  assert.equal((await player(db,'quality')).payload.media.rightsStatus,'LICENSED');
 } finally {await db.close();}
});
