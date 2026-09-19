import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import { openDatabase } from '../storage/database.mjs';

test('post-match video plan requires verified official channel and enforces quota',async()=>{
 const db=await openDatabase();
 try {
  const comp='fb_comp_video_v1';
  const home='fb_team_video_v1_home';
  const away='fb_team_video_v1_away';
  const match='fb_match_video_v1';
  const channel='UC1234567890123456789012';
  const start=new Date(Date.now()-2*60*60*1000).toISOString();

  for(const [id,kind,payload] of [
   [comp,'competition',{id:comp,name:'Liga Video',country:'Costa Rica'}],
   [home,'team',{id:home,name:'Saprissa Video',country:'Costa Rica',competitionId:comp}],
   [away,'team',{id:away,name:'Alajuelense Video',country:'Costa Rica',competitionId:comp}],
   [match,'match',{
    id:match,competitionId:comp,homeTeamId:home,awayTeamId:away,
    startTime:start,status:'VERIFIED',score:{home:2,away:1},
    events:[],statistics:[],provenance:{source:'test',receivedAt:new Date().toISOString()},
   }],
  ]) {
   await db.query('insert into futbeat_private.entities values($1,$2,$3)',[
    id,kind,JSON.stringify(payload),
   ]);
  }

  let plan=(await db.query('select public.futbeat_video_plan(1) value')).rows[0].value;
  assert.deepEqual(plan,[],'unverified channels must never be searched');

  await db.query(
   `select public.futbeat_register_youtube_channel(
      'competition',$1,$2,'Canal oficial','https://example.com/official-proof'
    )`,
   [comp,channel],
  );

  plan=(await db.query('select public.futbeat_video_plan(1) value')).rows[0].value;
  assert.equal(plan.length,1);
  assert.equal(plan[0].matchId,match);
  assert.equal(plan[0].channelId,channel);
  assert.match(plan[0].query,/Saprissa Video/);
  assert.match(plan[0].query,/Alajuelense Video/);

  const reservation=(await db.query(
   "select public.futbeat_reserve_youtube_search_call($1,$2,'test') value",
   [match,channel],
  )).rows[0].value;
  assert.equal(reservation.allowed,true);
  assert.equal(reservation.limit,40);
  assert.equal(reservation.usedToday,1);

  const stored=(await db.query(
   'select public.futbeat_store_youtube_search_result($1,$2,$3,$4) value',
   [
    match,
    channel,
    new Date().toISOString(),
    JSON.stringify({
     videoId:'abcDEF12345',
     channelId:channel,
     title:'Saprissa Video vs Alajuelense Video | Resumen',
     publishedAt:new Date(Date.parse(start)+60*60*1000).toISOString(),
    }),
   ],
  )).rows[0].value;
  assert.equal(stored.stored,1);

  const videos=(await db.query(
   'select public.futbeat_read_match_videos($1) value',[match],
  )).rows[0].value;
  assert.equal(videos.length,1);
  assert.equal(videos[0].videoId,'abcDEF12345');
  assert.equal(videos[0].verificationStatus,'VERIFIED_CHANNEL');
  assert.equal(videos[0].url,'https://www.youtube.com/watch?v=abcDEF12345');

  assert.deepEqual(
   (await db.query('select public.futbeat_video_plan(1) value')).rows[0].value,
   [],
   'a match with a stored video is no longer due',
  );

  for(let i=0;i<39;i+=1){
   await db.query(
    `insert into futbeat_private.provider_call_ledger(
       provider,call_kind,trigger_source,reserved_at,metadata
     ) values('youtube','video-search','test',now(),$1)`,
    [JSON.stringify({synthetic:true,n:i})],
   );
  }

  const blocked=(await db.query(
   "select public.futbeat_reserve_youtube_search_call($1,$2,'test-limit') value",
   [match,channel],
  )).rows[0].value;
  assert.equal(blocked.allowed,false);
  assert.equal(blocked.reason,'youtube_daily_search_limit');
  assert.equal(blocked.usedToday,40);
 } finally {
  await db.close();
 }
});

test('YouTube worker searches only a planned verified channel with bounded filters',async()=>{
 const source=await readFile(
  new URL('../../supabase/functions/futbeat-goal-live-sync/index.ts',import.meta.url),
  'utf8',
 );

 assert.match(source,/futbeat_video_plan/);
 assert.match(source,/futbeat_reserve_youtube_search_call/);
 assert.match(source,/channelId/);
 assert.match(source,/videoEmbeddable/);
 assert.match(source,/safeSearch/);
 assert.match(source,/publishedAfter/);
 assert.match(source,/publishedBefore/);
 assert.match(source,/titleMentionsTeam\(title, homeName\)/);
 assert.match(source,/titleMentionsTeam\(title, awayName\)/);
 assert.match(source,/youtube_provider_not_configured/);
});
