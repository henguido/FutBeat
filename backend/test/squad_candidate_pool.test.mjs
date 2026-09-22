import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';
import { seedCandidatePool,tracePools,internalPoolSQL,planNodes } from '../bench/squad_candidate_pool.mjs';
import { explain } from '../bench/squad_planner.mjs';
const plan=async(db,n=20)=>(await db.query('select public.futbeat_team_squad_plan($1) v',[n])).rows[0].v;

test('10000 upcoming teams: ranked P2, bounded mapping pool and deterministic read-only result',async(t)=>{
 const db=await openDatabase();
 try {
  await seedCandidatePool(db);
  await db.exec('begin read only');
  const first=await plan(db); assert.deepEqual(await plan(db),first);
  await db.exec('commit');
  assert.equal(first.length,20); assert.deepEqual(first.slice(0,2).map(x=>x.priorityTier),[1,1]);
  const expected=(await db.query('select team_id from futbeat_private.squad_upcoming_candidates() where not team_id=any($1) limit 18',
   [first.slice(0,2).map(x=>x.teamId)])).rows.map(x=>x.team_id);
  assert.deepEqual(first.slice(2).map(x=>x.teamId),expected);
  assert.deepEqual(Object.keys(first[0]).sort(),['externalTeamId','lastFetchedAt','priority','priorityTier','reason','teamId']);
  const traced=await tracePools(db);
  assert.equal(traced.raw,20); assert.equal(traced.mappings,20);
  assert.ok(traced.trace.every(x=>(x.mapping??0)<=25));
  const q=await internalPoolSQL(db),p=await explain(db,q.mappings,[['fb_pool_team_1','fb_pool_team_2'],20]);
  assert.equal(planNodes(p.Plan).find(n=>n.index==='provider_entities_canonical_id_idx').loops,2);
  const metrics=(await db.query(`select (select count(*)::int from futbeat_private.provider_call_ledger) ledger,
    (select count(*)::int from futbeat_private.team_detail_coverage) coverage`)).rows[0];
  assert.deepEqual(metrics,{ledger:0,coverage:0});
  t.diagnostic(JSON.stringify({rawPool:traced.raw,mappings:traced.mappings,universe:10000}));
 } finally {await db.close();}
});

test('upcoming cursor refills past missing mappings, freshness, backoff, leases and duplicate higher-tier teams',async()=>{
 const db=await openDatabase();
 try {
  await seedCandidatePool(db);
  await db.exec('update futbeat_private.competition_editorial_metadata set relevance_score=100');
  await db.exec(`delete from futbeat_private.coverage_interests;
   delete from futbeat_private.provider_entities where canonical_id in(select 'fb_pool_team_'||i from generate_series(1,200) i);
   insert into futbeat_private.team_detail_coverage(team_id,provider,fetched_at,player_count,next_retry_at,lease_until)
   select 'fb_pool_team_'||i,'goal_api',case when i<=220 then now() else null end,0,
    case when i between 221 and 240 then now()+interval '1 day' end,
    case when i between 241 and 260 then now()+interval '1 hour' end from generate_series(201,260) i;
   insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth) values('team','fb_pool_team_261',1,'DEEP');`);
  const result=await plan(db);
  assert.equal(result.length,20); assert.equal(result[0].teamId,'fb_pool_team_261'); assert.equal(result[0].priorityTier,1);
  assert.deepEqual(new Set(result.map(x=>x.teamId)),new Set(Array.from({length:20},(_,i)=>`fb_pool_team_${261+i}`)));
 } finally {await db.close();}
});

test('same-kickoff group preserves team tie order and mapping batches refill without fixed oversampling cutoff',async()=>{
 const db=await openDatabase();
 try {
  await seedCandidatePool(db);
  await db.exec('update futbeat_private.competition_editorial_metadata set relevance_score=100');
  await db.exec(`delete from futbeat_private.coverage_interests;
   update futbeat_private.calendar_matches set start_time=now()+interval '1 hour';
   delete from futbeat_private.provider_entities where canonical_id in(
    select id from futbeat_private.entities where kind='team' order by id limit 100);
   insert into futbeat_private.team_detail_coverage(team_id,provider,fetched_at,player_count)
    values('fb_pool_team_9999','goal_api',now()-interval '10 days',0);`);
  const expected=(await db.query(`select e.id from futbeat_private.entities e join futbeat_private.provider_entities p on p.canonical_id=e.id
    where e.kind='team' and e.id<>'fb_pool_team_9999' order by e.id limit 20`)).rows.map(x=>x.id);
  assert.deepEqual((await plan(db)).map(x=>x.teamId),expected);
  const traced=await tracePools(db);
  assert.equal(traced.mappings,120); // 100 unusable mappings, then 20 usable, not 10000.
  assert.equal(traced.raw,120); // Metadata sort handles the full tie; only bounded pools reach eligibility.
 } finally {await db.close();}
});

test('empty followed/recent tiers skip activity; editorial competition filter expands only its 100 teams',async()=>{
 const db=await openDatabase();
 try {
  await seedCandidatePool(db);
  const ids=(await db.query("select futbeat_private.squad_competition_pool(array['fb_pool_comp_0']) ids")).rows[0].ids;
  assert.equal(ids.length,100);
  const q=await internalPoolSQL(db),p=await explain(db,q.competition,[['fb_pool_comp_0']]);
  const matching=planNodes(p.Plan).find(n=>n.subplan==='CTE matching');
  assert.equal(matching.rows,50); // Filter before home/away expansion.
  await db.exec(`delete from futbeat_private.calendar_matches; delete from futbeat_private.coverage_interests;
   delete from futbeat_private.competition_editorial_metadata;
   create or replace function futbeat_private.squad_competition_pool(p_competitions text[])
    returns text[] language plpgsql stable set search_path='' as $$ begin raise exception 'Activity must not run'; end $$;`);
  assert.deepEqual(await plan(db),[]);
 } finally {await db.close();}
});

test('upcoming chained aliases deduplicate across kickoffs and preserve the newest alias mapping',async()=>{
 const db=await openDatabase();
 try {
  await seedCandidatePool(db);
  await db.exec('update futbeat_private.competition_editorial_metadata set relevance_score=100');
  await db.exec(`delete from futbeat_private.coverage_interests;
   insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values
    ('fb_pool_team_1','fb_pool_team_3','team','test'),('fb_pool_team_3','fb_pool_team_5','team','test');
   update futbeat_private.provider_entities set last_seen_at=now() where external_id='pool-1';`);
  const result=await plan(db,5);
  assert.deepEqual(result.map(x=>x.teamId),['fb_pool_team_2','fb_pool_team_5','fb_pool_team_4','fb_pool_team_6','fb_pool_team_7']);
  assert.equal(result[1].externalTeamId,'pool-1');
  assert.equal(new Set(result.map(x=>x.teamId)).size,5);
  // A partial match must not put NULL into the visited set and suppress all
  // later valid teams through SQL three-valued ANY semantics.
  await db.exec("update futbeat_private.entities set payload=payload-'awayTeamId' where id='fb_pool_match_1'");
  assert.deepEqual((await plan(db,5)).map(x=>x.teamId),['fb_pool_team_5','fb_pool_team_4','fb_pool_team_6','fb_pool_team_7','fb_pool_team_8']);
 } finally {await db.close();}
});
