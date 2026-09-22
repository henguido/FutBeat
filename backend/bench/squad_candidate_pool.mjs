// Synthetic, in-memory PGlite only. No network or production data.
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import { explain, plannerSQL, seedPlannerFixture } from './squad_planner.mjs';

export async function seedCandidatePool(db) {
 await db.exec(`
  alter table futbeat_private.entities disable trigger user;
  insert into futbeat_private.entities select 'fb_pool_comp_'||i,'competition',jsonb_build_object('id','fb_pool_comp_'||i) from generate_series(0,99) i;
  insert into futbeat_private.entities select 'fb_pool_team_'||i,'team',jsonb_build_object('id','fb_pool_team_'||i,'competitionId','fb_pool_comp_'||((i-1)/2%100)) from generate_series(1,10000) i;
  insert into futbeat_private.entities select 'fb_pool_match_'||i,'match',jsonb_build_object('id','fb_pool_match_'||i,
   'homeTeamId','fb_pool_team_'||(2*i-1),'awayTeamId','fb_pool_team_'||(2*i),'competitionId','fb_pool_comp_'||((i-1)%100),'status','SCHEDULED') from generate_series(1,5000) i;
  alter table futbeat_private.entities enable trigger user;
  insert into futbeat_private.calendar_matches select 'fb_pool_match_'||i,now()+interval '1 hour'+i*interval '1 minute','fixture',now() from generate_series(1,5000) i;
  insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) select 'goal_api','team','pool-'||i,'fb_pool_team_'||i from generate_series(1,10000) i;
  insert into futbeat_private.competition_editorial_metadata(competition_id,competition_class,relevance_score,source) values('fb_pool_comp_0','domestic_league',900,'editorial');
  insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth) values('team','fb_pool_team_9999',1,'DEEP'),('team','fb_pool_team_10000',1,'DEEP');
  analyze;
 `);
}
export function planNodes(n,out=[]) {
 out.push({node:n['Node Type'],relation:n['Relation Name'],cte:n['CTE Name'],subplan:n['Subplan Name'],index:n['Index Name'],
  rows:n['Actual Rows'],loops:n['Actual Loops'],ms:n['Actual Total Time'],removed:n['Rows Removed by Join Filter'],
  hit:n['Shared Hit Blocks'],read:n['Shared Read Blocks'],tempRead:n['Temp Read Blocks'],tempWritten:n['Temp Written Blocks'],
  sort:n['Sort Method'],sortKB:n['Sort Space Used']});
 for(const child of n.Plans??[]) planNodes(child,out);
 return out;
}
export async function installPlanner(db,file) {
 const sql=await readFile(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8');
 const start=sql.indexOf('create or replace function futbeat_private.futbeat_team_squad_plan(');
 await db.exec(sql.slice(start,sql.indexOf('end $$;',start)+7));
}
export async function measureCurrent(db) {
 const sql=await plannerSQL(db),prefix=sql.slice(0,sql.lastIndexOf(') select coalesce'))+')';
 console.log(JSON.stringify({tiers:(await db.query(prefix+` select tier,count(*)::int raw,count(distinct team_id)::int dedup from candidates group by tier order by tier`)).rows}));
 console.log(JSON.stringify({winningTiers:(await db.query(prefix+` select tier,count(*)::int teams from ranked group by tier order by tier`)).rows}));
 for(const cte of ['active_matches','active_teams','ranked','eligible','mapping_targets','provider_mapping','due']) {
  const p=await explain(db,prefix+' select count(*) from '+cte);
  console.log(JSON.stringify({cte,ms:p['Execution Time'],nodes:planNodes(p.Plan).filter(n=>n.loops>0&&(process.argv.includes('--plans')||n.subplan||n.sort||n.index))}));
 }
 for(const limit of [1,5,20]) {
  const p=await explain(db,`select futbeat_private.futbeat_team_squad_plan(${limit})`);
  console.log(JSON.stringify({label:'CURRENT',limit,ms:p['Execution Time']}));
 }
}
export async function tracePools(db,limit=20) {
 // Instrument ONLY this disposable DB with session-local counters; restore the
 // exact deployed helper body before timing or READ ONLY verification.
 const def=(await db.query("select pg_get_functiondef('futbeat_private.squad_pool_due(text[],text[],integer)'::regprocedure) v")).rows[0].v;
 const log=(expr)=>`perform set_config('futbeat.pool_trace',(current_setting('futbeat.pool_trace')::jsonb||jsonb_build_array(${expr}))::text,false);`;
 const instrumented=def.replace('begin',`begin ${log("jsonb_build_object('raw',coalesce(cardinality(p_ids),0),'limit',p_limit)")}`)
  .replace('batch_ids:=eligible_ids[pos:pos+batch_size-1];',`batch_ids:=eligible_ids[pos:pos+batch_size-1]; ${log("jsonb_build_object('mapping',cardinality(batch_ids))")}`);
 await db.exec(instrumented);
 try {
  await db.query("select set_config('futbeat.pool_trace','[]',false)");
  const result=(await db.query('select public.futbeat_team_squad_plan($1) v',[limit])).rows[0].v;
  const trace=JSON.parse((await db.query("select current_setting('futbeat.pool_trace') v")).rows[0].v);
  return {result,trace,mappings:trace.reduce((n,x)=>n+(x.mapping??0),0),raw:trace.reduce((n,x)=>n+(x.raw??0),0)};
 } finally {await db.exec(def);}
}
export async function internalPoolSQL(db) {
 // Windows checkouts preserve CRLF inside function bodies; extraction uses LF markers.
 const source=async(name)=>(await db.query('select prosrc from pg_proc where oid=$1::regprocedure',[name])).rows[0].prosrc.replace(/\r\n/g,'\n');
 const due=await source('futbeat_private.squad_pool_due(text[],text[],integer)');
 const main=await source('futbeat_private.futbeat_team_squad_plan(integer)');
 const activity=await source('futbeat_private.squad_competition_pool(text[])');
 return {
  eligible:due.slice(due.indexOf('with canonical'),due.indexOf(';\n batch_size')).replace(' into eligible_ids','').replaceAll('p_ids','$1::text[]').replaceAll('p_excluded','array[]::text[]'),
  mappings:due.slice(due.indexOf('with recursive mapping_targets'),due.indexOf(';\n  result:=')).replace(' into part','').replaceAll('batch_ids','$1::text[]').replaceAll('p_limit','$2').replaceAll('jsonb_array_length(result)','0'),
  upcoming:main.slice(main.indexOf('select c.start_time,e.payload'),main.indexOf('\n   loop',main.indexOf('select c.start_time,e.payload'))).trim(),
  competition:activity.slice(activity.indexOf('with matching'),activity.indexOf(';\n return')).replace(' into result','').replaceAll('p_competitions','$1::text[]'),
 };
}
export async function explainPools(db) {
 const queries=await internalPoolSQL(db),ids=['fb_pool_team_1','fb_pool_team_2'];
 for(const [name,sql] of Object.entries(queries)) {
  const params=name==='eligible'?[ids]:name==='mappings'?[ids,20]:name==='competition'?[['fb_pool_comp_0']]:[];
  const p=await explain(db,sql,params);
  console.log(JSON.stringify({internal:name,ms:p['Execution Time'],nodes:planNodes(p.Plan).filter(n=>n.loops>0)}));
 }
 const fetch=await explain(db,queries.upcoming+' limit 50');
 console.log(JSON.stringify({internal:'upcoming_first_50',ms:fetch['Execution Time'],nodes:planNodes(fetch.Plan).filter(n=>n.loops>0)}));
 // Evaluate the suggested compound index only inside this disposable database.
 // Rollback leaves both schema and production migration completely unchanged.
 await db.exec('begin');
 try {
  await db.exec('create index pool_mapping_experiment on futbeat_private.provider_entities(provider,kind,canonical_id,last_seen_at desc) include(external_id); analyze futbeat_private.provider_entities');
  const p=await explain(db,queries.mappings,[ids,20]);
  console.log(JSON.stringify({experimentalMappingIndex:true,ms:p['Execution Time'],nodes:planNodes(p.Plan).filter(n=>n.loops>0)}));
 } finally {await db.exec('rollback');}
}
if(process.argv[1]?.replaceAll('\\','/').endsWith('/bench/squad_candidate_pool.mjs')) {
 const db=await openDatabase();
 try {
  const currentNew=(await db.query("select pg_get_functiondef('futbeat_private.futbeat_team_squad_plan(integer)'::regprocedure) v")).rows[0].v;
  if(process.argv.includes('--legacy-fixture')) await seedPlannerFixture(db); else await seedCandidatePool(db);
  if(process.argv.includes('--legacy-fixture')) {
   await installPlanner(db,'20260922041454_player_media_squad_coverage.sql');
   console.log(JSON.stringify({label:'OLD pre-PR81',limit:20,ms:(await explain(db,'select futbeat_private.futbeat_team_squad_plan(20)'))['Execution Time']}));
  }
  await installPlanner(db,'20260922054858_optimize_squad_planner.sql'); await measureCurrent(db);
  await db.exec(currentNew);
  if(currentNew.includes('squad_pool_due')) {
   for(const limit of [1,5,20]) {
    await db.query('select futbeat_private.futbeat_team_squad_plan($1)',[limit]);
    console.log(JSON.stringify({label:'NEW',limit,ms:(await explain(db,`select futbeat_private.futbeat_team_squad_plan(${limit})`))['Execution Time']}));
   }
   console.log(JSON.stringify({pools:await tracePools(db)}));
   if(!process.argv.includes('--legacy-fixture')) await explainPools(db);
  }
 }
 finally {await db.close();}
}
