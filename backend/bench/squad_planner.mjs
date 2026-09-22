// Local PGlite only. No network, provider, credentials or production data.
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

export async function seedPlannerFixture(db) {
 await db.exec(`
  alter table futbeat_private.entities disable trigger user;
  insert into futbeat_private.entities select 'fb_bench_comp_'||i,'competition',jsonb_build_object('id','fb_bench_comp_'||i) from generate_series(0,99) i;
  insert into futbeat_private.entities select 'fb_bench_team_'||i,'team',jsonb_build_object('id','fb_bench_team_'||i,'competitionId','fb_bench_comp_'||(i%100)) from generate_series(1,8000) i;
  insert into futbeat_private.entities select 'fb_bench_player_'||i,'player',jsonb_build_object('id','fb_bench_player_'||i) from generate_series(1,20000) i;
  insert into futbeat_private.entities select 'fb_bench_match_'||i,'match',jsonb_build_object('id','fb_bench_match_'||i,
   'homeTeamId','fb_bench_team_'||i,'awayTeamId','fb_bench_team_'||(i+4000),'competitionId','fb_bench_comp_'||(i%100),
   'status',case when i<=20 then 'LIVE' else 'FINISHED' end) from generate_series(1,4000) i;
  alter table futbeat_private.entities enable trigger user;
  insert into futbeat_private.calendar_matches select 'fb_bench_match_'||i,now()-case when i<=20 then interval '1 hour' else interval '30 days' end,'fixture',now() from generate_series(1,4000) i;
  insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) select 'goal_api','team','external-'||i,'fb_bench_team_'||i from generate_series(1,8000) i;
  insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) select 'goal_api','player','player-'||i,'fb_bench_player_'||i from generate_series(1,20000) i;
  insert into futbeat_private.competition_editorial_metadata(competition_id,competition_class,relevance_score,source) values('fb_bench_comp_0','domestic_league',900,'editorial');
  insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth) values('competition','fb_bench_comp_1',1,'DEEP');
  insert into futbeat_private.provider_observations(provider,external_match_id,received_at,status,payload_hash,raw_payload)
   select 'goal_api','obs-'||i,now()-(i%170)*interval '1 day','SCHEDULED',repeat('a',64),
    jsonb_build_object('homeTeamId','external-'||(1+i%8000),'awayTeamId','external-'||(1+(i+4000)%8000)) from generate_series(1,30000) i;
  analyze;
 `);
}

export async function plannerSQL(db) {
 const body=(await db.query("select prosrc from pg_proc where oid='futbeat_private.futbeat_team_squad_plan(integer)'::regprocedure")).rows[0].prosrc;
 return body.slice(body.indexOf('with '),body.lastIndexOf('return result;')).trim()
  .replace(' into result from due',' from due').replace(/\bp_limit\b/g,'20').replace(/;\s*$/,'');
}

export async function explain(db,sql) {
 return (await db.query('explain (analyze,buffers,format json) '+sql)).rows[0]['QUERY PLAN'][0];
}
function nodes(plan,out=[]) {
 out.push({node:plan['Node Type'],relation:plan['Relation Name'],cte:plan['CTE Name'],subplan:plan['Subplan Name'],index:plan['Index Name'],
  rows:plan['Actual Rows'],loops:plan['Actual Loops'],ms:plan['Actual Total Time']});
 for(const child of plan.Plans??[]) nodes(child,out);
 return out;
}
export async function measure(db,label) {
 const sql=await plannerSQL(db);
 const prefix=sql.slice(0,sql.lastIndexOf(') select coalesce'))+')';
 for(const cte of ['recent_provider_teams','active_matches','candidates','ranked','provider_mapping','due']) {
  if(!new RegExp('\\b'+cte+' as').test(sql)) continue;
  const p=await explain(db,prefix+' select count(*) from '+cte);
  console.log(JSON.stringify({label,cte,ms:p['Execution Time'],...(process.argv.includes('--plans')?{nodes:nodes(p.Plan)}:{})}));
 }
 const p=await explain(db,sql);
 console.log(JSON.stringify({label,full:p['Execution Time'],nodes:nodes(p.Plan).filter(n=>n.loops>0&&(n.relation||n.index||n.subplan))}));
 const rpc=await explain(db,'select futbeat_private.futbeat_team_squad_plan(20)');
 console.log(JSON.stringify({label,rpc20:rpc['Execution Time']}));
}

if(process.argv[1]?.replaceAll('\\','/').endsWith('/bench/squad_planner.mjs')) {
 const db=await openDatabase();
 try {
  await seedPlannerFixture(db);
  if(process.argv.includes('--before')) {
   const old=await readFile(new URL('../../supabase/migrations/20260922041454_player_media_squad_coverage.sql',import.meta.url),'utf8');
   const start=old.indexOf('create or replace function futbeat_private.futbeat_team_squad_plan(');
   await db.exec(old.slice(start,old.indexOf('end $$;',start)+7));
  }
  await measure(db,process.argv.includes('--before')?'before':'after');
 } finally {await db.close();}
}
