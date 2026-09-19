import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

import { openDatabase } from '../storage/database.mjs';

test('content push respects follows, preferences and pre-send revalidation',async()=>{
 const db=await openDatabase();
 try {
  const uid=randomUUID();
  const uidOff=randomUUID();
  const dev=randomUUID();
  const devOff=randomUUID();
  const comp='fb_comp_push_v2';
  const teamA='fb_team_push_v2_a';
  const teamB='fb_team_push_v2_b';
  const player='fb_player_push_v2';
  const newsId='newsdata:push-v2';

  for(const [id,kind,payload] of [
   [comp,'competition',{id:comp,name:'Liga Push V2',country:'Costa Rica'}],
   [teamA,'team',{id:teamA,name:'Equipo A',country:'Costa Rica',competitionId:comp}],
   [teamB,'team',{id:teamB,name:'Equipo B',country:'Costa Rica',competitionId:comp}],
   [player,'player',{id:player,name:'Jugador Push',country:'Costa Rica',teamId:teamB}],
  ]) {
   await db.query(
    'insert into futbeat_private.entities values($1,$2,$3)',
    [id,kind,JSON.stringify(payload)],
   );
  }

  await db.query(
   `insert into futbeat_private.push_devices(
      id,user_id,installation_id,platform,transport,token,enabled,registered_at
    ) values
      ($1,$2,$3,'android','test','content-push-v2',true,now()-interval '1 hour'),
      ($4,$5,$6,'android','test','content-push-v2-off',true,now()-interval '1 hour')`,
   [dev,uid,randomUUID(),devOff,uidOff,randomUUID()],
  );

  await db.query(
   `insert into futbeat_private.user_preferences(
      user_id,notify_news,notify_transfers
    ) values($1,true,true),($2,false,false)`,
   [uid,uidOff],
  );

  await db.query(
   `insert into futbeat_private.push_follows(
      user_id,entity_type,entity_id,created_at
    ) values
      ($1,'team',$3,now()-interval '1 hour'),
      ($2,'team',$3,now()-interval '1 hour')`,
   [uid,uidOff,teamB],
  );

  await db.query(
   `insert into futbeat_private.news_articles(
      id,provider,external_id,title,description,url,
      source_name,source_url,published_at,language,fetched_at
    ) values(
      $1,'newsdata','push-v2','Noticia de prueba','Descripción',
      'https://example.com/news/push-v2','Fuente','https://example.com',
      now()-interval '5 minutes','es',now()
    )`,
   [newsId],
  );

  await db.query(
   `insert into futbeat_private.news_subjects(
      article_id,subject_type,subject_id,matched_at
    ) values($1,'team',$2,now())`,
   [newsId,teamB],
  );

  let rows=(await db.query(
   "select * from futbeat_private.notification_outbox where notification_key=$1",
   ['news:'+newsId],
  )).rows;
  assert.equal(rows.length,1);
  assert.equal(rows[0].user_id,uid);
  assert.equal(rows[0].event_id,null);
  assert.equal(rows[0].message.type,'NEWS');

  const transfer=(await db.query(
   `insert into futbeat_private.transfer_events(
      player_id,from_team_id,to_team_id,detected_at,detected_period,
      provider,status,source_label
    ) values(
      $1,$2,$3,now(),date_trunc('month',now())::date,
      'goal_api','ROSTER_CHANGE','GOAL API · plantilla de equipo'
    ) returning id`,
   [player,teamA,teamB],
  )).rows[0].id;

  rows=(await db.query(
   "select * from futbeat_private.notification_outbox where notification_key=$1",
   ['transfer:'+transfer],
  )).rows;
  assert.equal(rows.length,1);
  assert.equal(rows[0].user_id,uid);
  assert.equal(rows[0].message.type,'TRANSFER');

  const claim=(await db.query(
   "select public.futbeat_claim_notifications('dry_run',20) value"
  )).rows[0].value;
  assert.equal(claim.length,2);
  assert.ok(claim.every(row=>row.transport==='test'));

  await db.query(
   `update futbeat_private.notification_outbox
      set state='pending',attempt_id=null,attempt_at=null,finished_at=null
      where notification_key=$1`,
   ['news:'+newsId],
  );
  await db.query(
   "delete from futbeat_private.push_follows where user_id=$1",
   [uid],
  );

  const afterUnfollow=(await db.query(
   "select public.futbeat_claim_notifications('dry_run',20) value"
  )).rows[0].value;
  assert.equal(afterUnfollow.length,0);

  const state=(await db.query(
   "select state from futbeat_private.notification_outbox where notification_key=$1",
   ['news:'+newsId],
  )).rows[0].state;
  assert.equal(state,'cancelled');
 } finally {
  await db.close();
 }
});
