import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import { openDatabase } from '../storage/database.mjs';

test('News v1 stores source-attributed articles on the requested entity',async()=>{
 const db=await openDatabase();
 try {
  const competition='fb_comp_news_v1';
  const team='fb_team_news_v1';

  await db.query("insert into futbeat_private.entities values($1,'competition',$2)",[
   competition,JSON.stringify({id:competition,name:'Liga News V1',country:'Costa Rica'}),
  ]);
  await db.query("insert into futbeat_private.entities values($1,'team',$2)",[
   team,JSON.stringify({id:team,name:'News V1 FC',country:'Costa Rica',competitionId:competition,aliases:[]}),
  ]);

  const articles=[{
   id:'news-v1-a1',
   title:'News V1 FC prepara su próximo partido',
   description:'Resumen corto del artículo.',
   url:'https://example.com/news-v1-a1',
   sourceName:'Medio Ejemplo',
   sourceUrl:'https://example.com',
   publishedAt:'2026-09-19T02:00:00Z',
   language:'spanish',
  }];

  const stored=(await db.query(
   'select public.futbeat_store_news_batch($1,$2,$3,$4,$5) value',
   ['team',team,'2026-09-19T04:00:00Z','News V1 FC',JSON.stringify(articles)],
  )).rows[0].value;
  assert.equal(stored.articles,1);

  const detail=(await db.query(
   "select public.futbeat_read_entity_detail('team',$1) value",
   [team],
  )).rows[0].value;

  assert.equal(detail.news.length,1);
  assert.equal(detail.news[0].title,'News V1 FC prepara su próximo partido');
  assert.equal(detail.news[0].sourceName,'Medio Ejemplo');
  assert.equal(detail.news[0].url,'https://example.com/news-v1-a1');
  assert.equal(Object.hasOwn(detail.news[0],'imageUrl'),false);
 } finally {
  await db.close();
 }
});

test('squad refresh records one provider roster change when a player changes clubs',async()=>{
 const db=await openDatabase();
 try {
  const competition='fb_comp_transfer_v1';
  const from='fb_team_transfer_from';
  const to='fb_team_transfer_to';
  const player='fb_player_transfer_v1';

  await db.query("insert into futbeat_private.entities values($1,'competition',$2)",[
   competition,JSON.stringify({id:competition,name:'Liga Transfer V1',country:'Costa Rica'}),
  ]);
  for(const [id,name] of [[from,'Club Anterior'],[to,'Club Nuevo']]){
   await db.query("insert into futbeat_private.entities values($1,'team',$2)",[
    id,JSON.stringify({id,name,country:'Costa Rica',competitionId:competition,aliases:[]}),
   ]);
  }
  await db.query("insert into futbeat_private.entities values($1,'player',$2)",[
   player,JSON.stringify({
    id:player,name:'Jugador Transfer',country:'Costa Rica',teamId:from,
    aliases:[],media:null,
    provenance:{source:'GOAL API',externalId:'goal-player-transfer',receivedAt:'2026-09-01T00:00:00Z'},
   }),
  ]);

  const newPayload=[{
   id:player,name:'Jugador Transfer',country:'Costa Rica',teamId:to,
   aliases:[],media:null,position:'Defender',shirtNumber:4,
   provenance:{source:'GOAL API',externalId:'goal-player-transfer',receivedAt:'2026-09-19T04:00:00Z'},
  }];

  await db.query(
   'select public.futbeat_store_team_squad($1,$2,$3,$4)',
   [to,'goal_api','2026-09-19T04:00:00Z',JSON.stringify(newPayload)],
  );
  await db.query(
   'select public.futbeat_store_team_squad($1,$2,$3,$4)',
   [to,'goal_api','2026-09-19T04:05:00Z',JSON.stringify(newPayload)],
  );

  const rows=(await db.query(
   'select player_id,from_team_id,to_team_id,status,source_label from futbeat_private.transfer_events where player_id=$1',
   [player],
  )).rows;

  assert.equal(rows.length,1);
  assert.equal(rows[0].from_team_id,from);
  assert.equal(rows[0].to_team_id,to);
  assert.equal(rows[0].status,'ROSTER_CHANGE');
  assert.match(rows[0].source_label,/GOAL API/);

  const oldMembership=(await db.query(
   'select count(*)::int count from futbeat_private.team_squad_members where team_id=$1 and player_id=$2',
   [from,player],
  )).rows[0].count;
  const newMembership=(await db.query(
   'select count(*)::int count from futbeat_private.team_squad_members where team_id=$1 and player_id=$2',
   [to,player],
  )).rows[0].count;
  assert.equal(oldMembership,0);
  assert.equal(newMembership,1);

  const detail=(await db.query(
   "select public.futbeat_read_entity_detail('player',$1) value",
   [player],
  )).rows[0].value;
  assert.equal(detail.transfers.length,1);
  assert.equal(detail.transfers[0].fromTeamName,'Club Anterior');
  assert.equal(detail.transfers[0].toTeamName,'Club Nuevo');
 } finally {
  await db.close();
 }
});

test('NewsData planning is bounded and Supabase worker is optional without a key',async()=>{
 const db=await openDatabase();
 try {
  const competition='fb_comp_news_plan';
  const team='fb_team_news_plan';

  await db.query("insert into futbeat_private.entities values($1,'competition',$2)",[
   competition,JSON.stringify({id:competition,name:'Primera News',country:'Costa Rica'}),
  ]);
  await db.query("insert into futbeat_private.entities values($1,'team',$2)",[
   team,JSON.stringify({id:team,name:'Plan News FC',country:'Costa Rica',competitionId:competition,aliases:[]}),
  ]);

  const plan=(await db.query(
   'select public.futbeat_news_plan(5) value'
  )).rows[0].value;

  assert.ok(plan.length>=1);
  assert.ok(plan.length<=5);
  assert.equal(new Set(plan.map(row=>row.subjectType+'|'+row.subjectId)).size,plan.length);
  assert.ok(plan.every(row=>row.query.length<=100));

  const first=plan[0];
  const reservation=(await db.query(
   "select public.futbeat_reserve_newsdata_call($1,$2,$3,'test') value",
   [first.subjectType,first.subjectId,first.query],
  )).rows[0].value;
  assert.equal(reservation.allowed,true);
  assert.equal(reservation.limit,120);

  const second=(await db.query(
   "select public.futbeat_reserve_newsdata_call($1,$2,$3,'test') value",
   [first.subjectType,first.subjectId,first.query],
  )).rows[0].value;
  assert.equal(second.allowed,false);
  assert.equal(second.reason,'min_interval');

  const worker=await readFile(
   new URL('../../supabase/functions/futbeat-goal-live-sync/index.ts',import.meta.url),
   'utf8',
  );
  assert.match(worker,/news_provider_not_configured/);
  assert.match(worker,/https:\/\/newsdata\.io\/api\/1\/latest/);
  assert.match(worker,/futbeat_reserve_newsdata_call/);
  assert.match(worker,/futbeat_store_news_batch/);
  assert.match(worker,/category\", \"sports/);
  assert.doesNotMatch(worker,/image_url|imageUrl/);
 } finally {
  await db.close();
 }
});
