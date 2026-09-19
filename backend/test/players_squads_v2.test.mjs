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

test('global workflow hydrates a small squad batch on regular cycles and reserves before fetch',async()=>{
 const workflow=await readFile(
  new URL('../../.github/workflows/global-fixtures.yml',import.meta.url),
  'utf8',
 );

 assert.match(workflow,/action = "squad-plan"\s+limit = 3/);

 const declarations=[
  ...workflow.matchAll(/Invoke-TeamSquadHydration/g),
 ];
 assert.equal(
  declarations.length,
  2,
  'one function declaration plus one runtime invocation',
 );

 const hot=workflow.indexOf(
  'GLOBAL_INGEST_OK provider=GOAL_API',
 );
 const hydrate=workflow.indexOf(
  'Invoke-TeamSquadHydration',
  workflow.indexOf('GLOBAL_INGEST_OK provider=GOAL_API'),
 );
 const dailyExit=workflow.indexOf(
  'CALENDAR_EXPAND_SKIPPED reason=not_daily_window',
 );
 assert.ok(hot>=0 && hydrate>hot && dailyExit>hydrate);

 const reserve=workflow.indexOf('action = "squad-reserve"');
 const provider=workflow.indexOf(
  'https://api.goal-api.com/v1/teams/$encodedTeamId/players',
 );
 const ingest=workflow.indexOf('action = "squad-ingest"');
 assert.ok(reserve>=0 && provider>reserve && ingest>provider);
 assert.match(workflow,/action = "squad-ingest"[\s\S]*reservationId = \$reservationId/);
 assert.match(workflow,/action = "squad-fail"/);
});
