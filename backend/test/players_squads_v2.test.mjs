import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import { openDatabase } from '../storage/database.mjs';

test('Players v2 plans each canonical team once and reserves squad quota independently',async()=>{
 const db=await openDatabase();
 try {
  const competition='fb_comp_players_v2';
  const team='fb_team_players_v2';

  await db.query(
   "insert into futbeat_private.entities values($1,'competition',$2)",
   [competition,JSON.stringify({
    id:competition,name:'Liga Players V2',country:'Costa Rica',
   })],
  );
  await db.query(
   "insert into futbeat_private.entities values($1,'team',$2)",
   [team,JSON.stringify({
    id:team,name:'Players V2 FC',country:'Costa Rica',
    competitionId:competition,aliases:[],
   })],
  );

  await db.query(
   "insert into futbeat_private.provider_entities values('goal_api','team','goal-team-a',$1)",
   [team],
  );
  await db.query(
   "insert into futbeat_private.provider_entities values('goal_api','team','goal-team-z',$1)",
   [team],
  );

  await db.query("insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth) values('team',$1,1,'DEEP')",[team]);
  const plan=(await db.query(
   'select public.futbeat_team_squad_plan(10) value'
  )).rows[0].value;

  const rows=plan.filter(row=>row.teamId===team);
  assert.equal(rows.length,1);
  assert.equal(rows[0].externalTeamId,'goal-team-z');

  await db.query(
   "insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,provider_remaining) values('goal_api','live-goal','test',now(),now(),'SUCCEEDED',900)"
  );

  const first=(await db.query(
   "select public.futbeat_reserve_goal_squad_call($1,$2,'test') value",
   [team,'goal-team-z'],
  )).rows[0].value;
  assert.equal(first.allowed,true);
  assert.equal(first.reserve,350);
  assert.equal(first.usedToday,1);

  for(let i=0;i<15;i+=1){
   await db.query(
    "insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata) values('goal_api','team-squad','test',now(),$1)",
    [JSON.stringify({synthetic:true,n:i})],
   );
  }

  await db.query('update futbeat_private.team_detail_coverage set lease_until=null where team_id=$1',[team]);
  const blocked=(await db.query(
   "select public.futbeat_reserve_goal_squad_call($1,$2,'test-limit') value",
   [team,'goal-team-z'],
  )).rows[0].value;
  assert.equal(blocked.allowed,false);
  assert.equal(blocked.reason,'squad_daily_limit');
  assert.equal(blocked.usedToday,16);
  assert.equal(blocked.limit,16);
 } finally {
  await db.close();
 }
});

test('Supabase LIVE worker hydrates one quota-safe squad and GitHub no longer fetches squads',async()=>{
 const workflow=await readFile(
  new URL('../../.github/workflows/global-fixtures.yml',import.meta.url),
  'utf8',
 );
 const worker=await readFile(
  new URL('../../supabase/functions/futbeat-goal-live-sync/index.ts',import.meta.url),
  'utf8',
 );
 const ingest=await readFile(
  new URL('../../supabase/functions/futbeat-global-ingest/index.ts',import.meta.url),
  'utf8',
 );

 assert.doesNotMatch(workflow,/Invoke-TeamSquadHydration/);
 assert.doesNotMatch(workflow,/teams\/\$encodedTeamId\/players/);
 assert.doesNotMatch(workflow,/action = "squad-reserve"/);

 assert.match(worker,/futbeat_team_squad_plan/);
 assert.match(worker,/p_limit: 1/);
 assert.match(worker,/futbeat_reserve_goal_squad_call/);
 assert.match(
  worker,
  /teams\/\$\{encodeURIComponent\(externalTeamId\)\}\/players/,
 );
 assert.match(worker,/action: "squad-ingest"/);
 assert.match(worker,/p_trigger_source: "supabase-cron"/);

 const detail=worker.indexOf('detail = await syncOneMatchDetail()');
 const squad=worker.indexOf('squad = await syncOneSquad()');
 assert.ok(detail>=0 && squad>detail);

 assert.match(ingest,/x-futbeat-cron-token/);
 assert.match(
  ingest,
  /authorizedWorkflow === "supabase-cron"[\s\S]*input\.action !== "squad-ingest"/,
 );
 assert.match(
  ingest,
  /mode: "team-squad"[\s\S]*transport: authorizedWorkflow === "supabase-cron"/,
 );
});


test('main snapshot publishes only recently hydrated visible players',async()=>{
 const db=await openDatabase();
 try {
  const competition='fb_comp_player_catalog';
  const recentTeam='fb_team_player_catalog_recent';
  const oldTeam='fb_team_player_catalog_old';
  const recentPlayer='fb_player_catalog_recent';
  const oldPlayer='fb_player_catalog_old';

  for(const [id,kind,payload] of [
   [competition,'competition',{id:competition,name:'Liga Catalog',country:'Costa Rica'}],
   [recentTeam,'team',{id:recentTeam,name:'Recent FC',country:'Costa Rica',competitionId:competition}],
   [oldTeam,'team',{id:oldTeam,name:'Old FC',country:'Costa Rica',competitionId:competition}],
   [recentPlayer,'player',{id:recentPlayer,name:'Recent Player',country:'Costa Rica',teamId:recentTeam}],
   [oldPlayer,'player',{id:oldPlayer,name:'Old Player',country:'Costa Rica',teamId:oldTeam}],
  ]) {
   await db.query(
    'insert into futbeat_private.entities(id,kind,payload) values($1,$2,$3)',
    [id,kind,JSON.stringify(payload)],
   );
  }

  await db.query(
   "insert into futbeat_private.team_squad_members(team_id,player_id,provider,updated_at) values($1,$2,'goal_api',now()),($3,$4,'goal_api',now()-interval '20 days')",
   [recentTeam,recentPlayer,oldTeam,oldPlayer],
  );
  await db.query(
   "insert into futbeat_private.team_detail_coverage(team_id,provider,fetched_at,player_count) values($1,'goal_api',now(),1),($2,'goal_api',now()-interval '20 days',1)",
   [recentTeam,oldTeam],
  );

  const snapshot={
   schemaVersion:1,
   demo:false,
   updatedAt:new Date().toISOString(),
   coverage:{},
   teams:[
    {id:recentTeam,name:'Recent FC',country:'Costa Rica',competitionId:competition},
    {id:oldTeam,name:'Old FC',country:'Costa Rica',competitionId:competition},
   ],
   players:[],
   competitions:[{id:competition,name:'Liga Catalog',country:'Costa Rica'}],
   matches:[],
   standings:[],
   news:[],
   transfers:[],
  };

  await db.query(
   'insert into futbeat_private.imports(job_id,received_at,raw_payload,snapshot) values($1,now(),$2,$3)',
   ['player-catalog-test',JSON.stringify({}),JSON.stringify(snapshot)],
  );

  const published=(await db.query(
   'select public.futbeat_read_snapshot() value'
  )).rows[0].value;

  assert.equal(
   published.players.filter(player=>player.id===recentPlayer).length,
   1,
  );
  assert.equal(
   published.players.some(player=>player.id===oldPlayer),
   false,
  );
 } finally {
  await db.close();
 }
});
