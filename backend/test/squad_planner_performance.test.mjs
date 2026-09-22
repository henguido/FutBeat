import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import { seedPlannerFixture,plannerSQL,explain } from '../bench/squad_planner.mjs';

async function seed(db) {
 await db.exec(`insert into futbeat_private.entities values('fb_comp_plan','competition','{"id":"fb_comp_plan"}');
  insert into futbeat_private.entities select 'fb_team_plan_'||i,'team',jsonb_build_object('id','fb_team_plan_'||i,'competitionId','fb_comp_plan') from generate_series(0,9) i;
  insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
   select 'goal_api','team','ext-'||i,'fb_team_plan_'||i from generate_series(0,8) i;`);
}
async function favorite(db,id) {
 await db.query("insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth) values('team',$1,1,'DEEP') on conflict do nothing",[id]);
}
async function plan(db) {return (await db.query('select public.futbeat_team_squad_plan(20) v')).rows[0].v;}
async function observe(db,id,urlId,stamp='now()') {
 await db.query(`insert into futbeat_private.provider_observations(provider,external_match_id,received_at,status,payload_hash,raw_payload)
  values('goal_api',$1,${stamp},'SCHEDULED',repeat('a',64),$2)`,[id,JSON.stringify({homeTeamId:urlId,awayTeam:{id:urlId}})]);
}

test('planner deduplicates three demand signals and chained team/competition redirects without writing',async()=>{
 const db=await openDatabase();
 try {
  await seed(db);
  await db.exec(`insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values
   ('fb_team_plan_0','fb_team_plan_1','team','test'),('fb_team_plan_1','fb_team_plan_2','team','test');
   insert into futbeat_private.entities values('fb_comp_alias','competition','{"id":"fb_comp_alias"}');
   insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values('fb_comp_alias','fb_comp_plan','competition','test');
   insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth) values('competition','fb_comp_alias',1,'DEEP');
   insert into futbeat_private.entities values('fb_match_plan','match',jsonb_build_object('id','fb_match_plan',
    'homeTeamId','fb_team_plan_0','awayTeamId','fb_team_plan_0','startTime',now(),'status','LIVE','competitionId','fb_comp_alias'));
   insert into futbeat_private.temporary_interests(user_id,entity_type,entity_id,expires_at)
    values('00000000-0000-0000-0000-000000000001','team','fb_team_plan_0',now()+interval '1 hour');`);
  await favorite(db,'fb_team_plan_0');
  await observe(db,'alias-observation','ext-0');
  const snapshot=async()=>(await db.query(`select
   (select coalesce(jsonb_agg(to_jsonb(x)),'[]') from futbeat_private.provider_call_ledger x) ledger,
   (select coalesce(jsonb_agg(to_jsonb(x)),'[]') from futbeat_private.team_detail_coverage x) coverage,
   (select jsonb_agg(to_jsonb(x) order by provider,kind,external_id) from futbeat_private.provider_entities x) mappings`)).rows[0];
  const before=await snapshot();
  await db.exec('begin read only');
  const result=await plan(db);
  await db.exec('commit');
  assert.equal(result.length,1); assert.equal(result[0].teamId,'fb_team_plan_2');
  assert.equal(result[0].externalTeamId,'ext-0'); assert.equal(result[0].priorityTier,0);
  assert.deepEqual(await plan(db),result); assert.deepEqual(await snapshot(),before);
  await db.exec("update futbeat_private.entities set payload=payload||'{\"status\":\"FINISHED\"}' where id='fb_match_plan'; delete from futbeat_private.coverage_interests where subject_type='team'");
  assert.equal((await plan(db))[0].priorityTier,3);
 } finally {await db.close();}
});

test('planner excludes freshness, retry, lease and missing/empty mappings',async()=>{
 const db=await openDatabase();
 try {
  await seed(db);
  for(let i=0;i<10;i++) await favorite(db,`fb_team_plan_${i}`);
  await db.exec(`insert into futbeat_private.team_detail_coverage(team_id,provider,fetched_at,player_count,next_retry_at,lease_until) values
   ('fb_team_plan_0','goal_api',now(),0,null,null),
   ('fb_team_plan_1','goal_api',now()-interval '10 days',0,now()+interval '1 hour',null),
   ('fb_team_plan_2','goal_api',null,0,null,now()+interval '10 minutes'),
   ('fb_team_plan_3','goal_api',now()-interval '10 days',0,now()-interval '1 hour',now()-interval '1 minute');
   update futbeat_private.provider_entities set external_id=' ' where canonical_id='fb_team_plan_8';`);
  assert.deepEqual((await plan(db)).map(x=>x.teamId),[4,5,6,7,3].map(i=>`fb_team_plan_${i}`));
  for(const limit of [null,0,26]) await assert.rejects(db.query('select public.futbeat_team_squad_plan($1)',[limit]),/Invalid squad plan limit/);
 } finally {await db.close();}
});

test('mapping last-seen is monotonic, idempotent, provider-scoped and keeps deterministic 180-day preference',async()=>{
 const db=await openDatabase();
 try {
  await seed(db); await favorite(db,'fb_team_plan_0');
  await db.exec("insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) values('goal_api','team','zz-old','fb_team_plan_0'),('other','team','ext-0','fb_team_plan_0')");
  await observe(db,'new','ext-0');
  const row=async()=>(await db.query("select last_seen_at,xmin::text version from futbeat_private.provider_entities where provider='goal_api' and external_id='ext-0'")).rows[0];
  const first=await row();
  await observe(db,'older','ext-0',"now()-interval '1 day'");
  assert.deepEqual(await row(),first);
  await db.exec("update futbeat_private.provider_observations set received_at=received_at where external_match_id='new'");
  assert.deepEqual(await row(),first);
  assert.equal((await plan(db))[0].externalTeamId,'ext-0');
  assert.equal((await db.query("select last_seen_at from futbeat_private.provider_entities where provider='other'")).rows[0].last_seen_at,null);
  await db.exec("update futbeat_private.provider_entities set last_seen_at=now()-interval '181 days' where provider='goal_api' and external_id='ext-0'");
  assert.equal((await plan(db))[0].externalTeamId,'zz-old');
  await db.exec("update futbeat_private.provider_observations set received_at=now()+interval '1 second' where external_match_id='new'");
  assert.equal((await plan(db))[0].externalTeamId,'ext-0');
  for(const role of ['anon','authenticated','service_role']) assert.equal((await db.query("select has_function_privilege($1,'futbeat_private.track_squad_mapping_seen()','EXECUTE') v",[role])).rows[0].v,false);
 } finally {await db.close();}
});

test('P3/P4 require bounded activity; country and inactive league catalog do not create demand',async()=>{
 const db=await openDatabase();
 try {
  await seed(db);
  await db.exec(`update futbeat_private.competition_editorial_metadata set relevance_score=900,source='editorial' where competition_id='fb_comp_plan';
   insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth) values('competition','fb_comp_plan',1,'DEEP');`);
  assert.deepEqual(await plan(db),[]);
  await db.exec(`insert into futbeat_private.entities select 'fb_match_window_'||i,'match',jsonb_build_object('id','fb_match_window_'||i,
   'homeTeamId','fb_team_plan_'||i,'awayTeamId','fb_team_plan_'||i,'competitionId','fb_comp_plan','status','FINISHED',
   'startTime',now()+case i when 0 then interval '-1 hour' when 1 then interval '-7 hours' else interval '8 days' end) from generate_series(0,2) i;`);
  assert.deepEqual((await plan(db)).map(x=>[x.teamId,x.priorityTier]),[['fb_team_plan_0',3]]);
  await db.exec("delete from futbeat_private.coverage_interests; update futbeat_private.entities set payload=payload||'{\"country\":\"Costa Rica\"}' where kind='team'");
  assert.equal((await plan(db))[0].priorityTier,4);
 } finally {await db.close();}
});

test('incremental migration backfills existing mapping last-seen once',async()=>{
 const db=await openDatabase();
 try {
  await seed(db);
  await db.exec(`drop trigger futbeat_squad_mapping_seen_insert on futbeat_private.provider_observations;
   drop trigger futbeat_squad_mapping_seen_update on futbeat_private.provider_observations;
   drop function futbeat_private.track_squad_mapping_seen();
   alter table futbeat_private.provider_entities drop column last_seen_at;`);
  await observe(db,'existing','ext-0');
  await observe(db,'expired','ext-1',"now()-interval '181 days'");
  await db.exec(await readFile(new URL('../../supabase/migrations/20260922054858_optimize_squad_planner.sql',import.meta.url),'utf8'));
  const rows=(await db.query("select external_id,last_seen_at from futbeat_private.provider_entities where external_id in ('ext-0','ext-1') order by external_id")).rows;
  assert.ok(rows[0].last_seen_at); assert.equal(rows[1].last_seen_at,null);
 } finally {await db.close();}
});

test('large planner fixture uses indexed bounded lookups and never scans observations or player catalog',async(t)=>{
 const db=await openDatabase();
 try {
  await seedPlannerFixture(db);
  const sql=await plannerSQL(db),p=await explain(db,sql);
  const nodes=[]; const walk=n=>{nodes.push(n); for(const c of n.Plans??[]) walk(c);}; walk(p.Plan);
  assert.ok(!nodes.some(n=>n['Relation Name']==='provider_observations'));
  assert.ok(!nodes.some(n=>n['Relation Name']==='entities' && n['Node Type']==='Seq Scan'));
  assert.ok(nodes.some(n=>n['Index Name']==='provider_entities_canonical_id_idx'));
  assert.ok(nodes.some(n=>n['Index Name']==='calendar_matches_start_time_idx'));
  assert.equal((await plan(db)).length,20);
  // All 8,000 catalog teams now belong to followed/high-editorial competitions.
  // Only the 40 teams with real window activity may become candidates.
  await db.exec(`insert into futbeat_private.competition_editorial_metadata(competition_id,competition_class,relevance_score,source)
   select 'fb_bench_comp_'||i,'domestic_league',900,'editorial' from generate_series(0,99) i on conflict(competition_id) do update set relevance_score=900,source='editorial';
   insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth)
   select 'competition','fb_bench_comp_'||i,1,'DEEP' from generate_series(0,99) i on conflict do nothing;`);
  const prefix=sql.slice(0,sql.lastIndexOf(') select coalesce'))+')';
  assert.equal((await db.query(prefix+' select count(*)::int n from ranked')).rows[0].n,40);
  assert.ok(p['Execution Time']<1000,`Local planner took ${p['Execution Time']} ms`);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n,0);
  t.diagnostic(JSON.stringify({fixture:'synthetic PGlite',teams:8000,players:20000,matches:4000,mappings:28000,observations:30000,sqlMs:p['Execution Time']}));
 } finally {await db.close();}
});
