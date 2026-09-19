import test from 'node:test';
import assert from 'node:assert/strict';

import { openDatabase } from '../storage/database.mjs';

test('canonical identity redirect migrates references and normalizes snapshots',async()=>{
 const db=await openDatabase();
 try {
  const oldCompetition='fb_comp_identity_old';
  const competition='fb_comp_identity_current';
  const oldTeam='fb_team_identity_old';
  const team='fb_team_identity_current';
  const rival='fb_team_identity_rival';
  const match='fb_match_identity';

  await db.query(
   "insert into futbeat_private.entities values($1,'competition',$2)",
   [oldCompetition,JSON.stringify({
    id:oldCompetition,name:'Legacy League',country:'Costa Rica',
   })],
  );
  await db.query(
   "insert into futbeat_private.entities values($1,'competition',$2)",
   [competition,JSON.stringify({
    id:competition,name:'Current League',country:'Costa Rica',aliases:[],
   })],
  );
  await db.query(
   "insert into futbeat_private.entities values($1,'team',$2)",
   [oldTeam,JSON.stringify({
    id:oldTeam,name:'Legacy Club',country:'Costa Rica',
    competitionId:oldCompetition,aliases:[],
   })],
  );
  await db.query(
   "insert into futbeat_private.entities values($1,'team',$2)",
   [team,JSON.stringify({
    id:team,name:'Current Club',country:'',
    competitionId:competition,aliases:[],
   })],
  );
  await db.query(
   "insert into futbeat_private.entities values($1,'team',$2)",
   [rival,JSON.stringify({
    id:rival,name:'Rival',country:'Costa Rica',competitionId:competition,
   })],
  );
  await db.query(
   "insert into futbeat_private.entities values($1,'match',$2)",
   [match,JSON.stringify({
    id:match,competitionId:oldCompetition,homeTeamId:oldTeam,awayTeamId:rival,
    startTime:'2026-09-19T00:00:00Z',status:'VERIFIED',
    score:{home:1,away:0},events:[],statistics:[],
    provenance:{source:'test',receivedAt:'2026-09-19T02:00:00Z'},
   })],
  );

  await db.query(
   "insert into futbeat_private.provider_entities values('goal_api','competition','identity-league-old',$1)",
   [oldCompetition],
  );
  await db.query(
   "insert into futbeat_private.provider_entities values('goal_api','team','identity-team-old',$1)",
   [oldTeam],
  );
  await db.query(
   "insert into futbeat_private.provider_media_cache(provider,kind,external_id,canonical_id,url,received_at) values('goal_api','team','identity-team-old',$1,'https://media.goal-api.com/test.png',now())",
   [oldTeam],
  );

  await db.query(
   "select futbeat_private.futbeat_register_entity_redirect('competition',$1,$2,'verified test alias')",
   [oldCompetition,competition],
  );
  await db.query(
   "select futbeat_private.futbeat_register_entity_redirect('team',$1,$2,'verified test alias')",
   [oldTeam,team],
  );

  assert.equal(
   (await db.query(
    "select canonical_id from futbeat_private.provider_entities where provider='goal_api' and kind='competition' and external_id='identity-league-old'"
   )).rows[0].canonical_id,
   competition,
  );
  assert.equal(
   (await db.query(
    "select canonical_id from futbeat_private.provider_entities where provider='goal_api' and kind='team' and external_id='identity-team-old'"
   )).rows[0].canonical_id,
   team,
  );
  assert.equal(
   (await db.query(
    "select canonical_id from futbeat_private.provider_media_cache where provider='goal_api' and kind='team' and external_id='identity-team-old'"
   )).rows[0].canonical_id,
   team,
  );

  const storedMatch=(await db.query(
   "select payload from futbeat_private.entities where id=$1",[match]
  )).rows[0].payload;
  assert.equal(storedMatch.competitionId,competition);
  assert.equal(storedMatch.homeTeamId,team);

  const canonicalTeam=(await db.query(
   "select payload from futbeat_private.entities where id=$1",[team]
  )).rows[0].payload;
  assert.equal(canonicalTeam.country,'Costa Rica');
  assert.ok(canonicalTeam.aliases.includes('Legacy Club'));

  const snapshot={
   schemaVersion:1,
   demo:false,
   updatedAt:'2026-09-19T02:00:00Z',
   freshness:{stale:false},
   competitions:[
    {id:oldCompetition,name:'Legacy League',country:'Costa Rica'},
    {id:competition,name:'Current League',country:'Costa Rica'},
   ],
   teams:[
    {id:oldTeam,name:'Legacy Club',country:'Costa Rica',competitionId:oldCompetition},
    {id:rival,name:'Rival',country:'Costa Rica',competitionId:competition},
   ],
   players:[],
   matches:[{
    id:match,competitionId:oldCompetition,homeTeamId:oldTeam,awayTeamId:rival,
    startTime:'2026-09-19T00:00:00Z',status:'VERIFIED',
    score:{home:1,away:0},events:[],statistics:[],
   }],
   standings:[],
  };

  const normalized=(await db.query(
   'select futbeat_private.futbeat_apply_entity_redirects_snapshot($1) value',
   [JSON.stringify(snapshot)],
  )).rows[0].value;

  assert.equal(normalized.entityRedirects[oldCompetition],competition);
  assert.equal(normalized.entityRedirects[oldTeam],team);
  assert.equal(
   normalized.competitions.filter(item=>item.id===competition).length,
   1,
  );
  assert.equal(
   normalized.competitions.some(item=>item.id===oldCompetition),
   false,
  );
  assert.equal(normalized.teams.some(item=>item.id===oldTeam),false);
  assert.equal(normalized.teams.some(item=>item.id===team),true);
  assert.equal(normalized.matches[0].competitionId,competition);
  assert.equal(normalized.matches[0].homeTeamId,team);

  const detail=(await db.query(
   "select public.futbeat_read_entity_detail('team',$1) value",[oldTeam]
  )).rows[0].value;
  assert.equal(detail.teams.some(item=>item.id===oldTeam),false);
  assert.equal(detail.teams.some(item=>item.id===team),true);
  assert.equal(detail.entityRedirects[oldTeam],team);

  const resolved=(await db.query(
   "select futbeat_private.futbeat_resolve_global_entity('goal_api','team','identity-team-new','Legacy Club','Costa Rica','') value"
  )).rows[0].value;
  assert.equal(resolved,team);
 } finally {
  await db.close();
 }
});

test('canonical identity redirects reject cycles',async()=>{
 const db=await openDatabase();
 try {
  for(const [id,name] of [
   ['fb_team_cycle_a','Cycle A'],
   ['fb_team_cycle_b','Cycle B'],
  ]) {
   await db.query(
    "insert into futbeat_private.entities values($1,'team',$2)",
    [id,JSON.stringify({id,name,country:'Costa Rica',aliases:[]})],
   );
  }

  await db.query(
   "select futbeat_private.futbeat_register_entity_redirect('team','fb_team_cycle_a','fb_team_cycle_b','test')"
  );

  await assert.rejects(
   db.query(
    "select futbeat_private.futbeat_register_entity_redirect('team','fb_team_cycle_b','fb_team_cycle_a','test')"
   ),
   /cycle/i,
  );
 } finally {
  await db.close();
 }
});
