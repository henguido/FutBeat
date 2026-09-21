import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import { calendarCacheControl } from '../../supabase/functions/_shared/calendar_cache.ts';

async function seed(db, count = 1) {
  const rows = [{id:'fb_comp_perf',kind:'competition',name:'Competition',country:'Costa Rica'}];
  for (let i=0;i<count;i++) {
    for (const side of ['home','away']) rows.push({id:`fb_team_${side}_${i}`,kind:'team',name:`Team ${side} ${i}`,
      country:'Costa Rica',competitionId:'fb_comp_perf',aliases:['Alias'],media:{url:`https://example.com/${side}_${i}.png`,verificationStatus:'VERIFIED'}});
    rows.push({id:`fb_match_perf_${i}`,kind:'match',competitionId:'fb_comp_perf',homeTeamId:`fb_team_home_${i}`,awayTeamId:`fb_team_away_${i}`,
      startTime:'2026-08-20T18:00:00Z',status:'SCHEDULED',score:null,events:[],statistics:[],provenance:{receivedAt:'2026-08-20T12:00:00Z'}});
  }
  await db.query(`insert into futbeat_private.entities(id,kind,payload)
    select item->>'id',item->>'kind',item-'kind' from jsonb_array_elements($1::jsonb) item`,[JSON.stringify(rows)]);
}
async function both(db) {
  const calendar=(await db.query("select public.futbeat_read_calendar_range('2026-08-20','2026-08-20','UTC') v")).rows[0].v;
  const context=(await db.query("select public.futbeat_read_match_context('fb_match_perf_0') v")).rows[0].v;
  assert.deepEqual(calendar.matches[0].score ?? null,context.matches[0].score ?? null);
  assert.equal(calendar.matches[0].status,context.matches[0].status);
  return {calendar,context,match:calendar.matches[0]};
}
test('stored score is shared by calendar and context without inventing a final result',async()=>{
  const db=await openDatabase();
  try {
    await seed(db);
    await db.query(`insert into futbeat_private.provider_observations
      (provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,payload_hash,raw_payload)
      values('goal_api','perf','fb_match_perf_0','2026-08-20T19:00:00Z','LIVE',2,1,$1,'{}')`,['a'.repeat(64)]);
    // A later scoreless observation must not erase the score field.
    await db.query(`insert into futbeat_private.provider_observations
      (provider,external_match_id,canonical_match_id,received_at,status,payload_hash,raw_payload)
      values('goal_api','perf','fb_match_perf_0','2026-08-20T20:00:00Z','SCHEDULED',$1,'{}')`,['b'.repeat(64)]);
    let result=await both(db);
    assert.deepEqual(result.match.score,{home:2,away:1});
    assert.equal(result.match.status,'SCHEDULED');
    assert.equal(result.match.hasPlayedEvidence,true);
    assert.equal(result.match.events,undefined);
    assert.deepEqual(result.calendar.players,[]);
    assert.deepEqual(result.calendar.standings,[]);
    await db.exec(`update futbeat_private.entities set payload=payload||'{"status":"VERIFIED","score":{"home":3,"away":1}}'::jsonb where id='fb_match_perf_0'`);
    result=await both(db);
    assert.deepEqual(result.match.score,{home:3,away:1});
    // Read projection has not rewritten canonical storage or lifecycle.
    assert.equal((await db.query("select count(*)::int n from futbeat_private.results_date_attempts")).rows[0].n,0);
  } finally {await db.close();}
});

test('event-only history and detail score remain available without manufacturing scores',async()=>{
  const db=await openDatabase();
  try {
    await seed(db);
    await db.exec(`insert into futbeat_private.canonical_events values('fb_event_perf','fb_match_perf_0','goal_api','GOAL','{"minute":20}',false,now())`);
    let result=await both(db);
    assert.equal(result.match.score,undefined);
    assert.equal(result.context.matches[0].score,null);
    assert.equal(result.match.hasPlayedEvidence,true);
    assert.equal(result.context.matches[0].events.length,1);
    await db.exec(`insert into futbeat_private.match_detail_cache values('fb_match_perf_0','goal_api','perf','2026-08-20T20:00:00Z','{"homeTeamScore":4,"awayTeamScore":2}')`);
    result=await both(db);
    assert.deepEqual(result.match.score,{home:4,away:2});
    assert.equal(result.match.status,'SCHEDULED');
  } finally {await db.close();}
});

test('equivalent 1083-match day measures compact bytes before and after',async(t)=>{
  const db=await openDatabase();
  try {
    await seed(db,1083);
    await db.exec(`update futbeat_private.entities set payload=payload||jsonb_build_object(
      'events',(select jsonb_agg(jsonb_build_object('id','event_'||i,'type','GOAL','minute',i,'teamId','fb_team_home_0')) from generate_series(1,8) i),
      'statistics',(select jsonb_agg(jsonb_build_object('label','Statistic '||i,'home',i,'away',i+1,'unit','%')) from generate_series(1,12) i),
      'venue','Stadium','season','2026') where kind='match'`);
    const after=(await db.query("select public.futbeat_read_calendar_range('2026-08-20','2026-08-20','UTC') v")).rows[0].v;
    // Execute the exact previous public RPC against the SAME database fixture.
    const previous=await readFile(new URL('../../supabase/migrations/20260921215519_stabilize_competition_editorial_contract.sql',import.meta.url),'utf8');
    await db.exec(previous.slice(previous.indexOf('create or replace function public.futbeat_read_calendar_range'),previous.indexOf('revoke all on function futbeat_private.derived_competition')));
    const before=(await db.query("select public.futbeat_read_calendar_range('2026-08-20','2026-08-20','UTC') v")).rows[0].v;
    const bytesBefore=Buffer.byteLength(JSON.stringify(before)),bytesAfter=Buffer.byteLength(JSON.stringify(after));
    t.diagnostic(JSON.stringify({matches:after.matches.length,teams:after.teams.length,bytesBefore,bytesAfter,reductionPercent:Math.round((1-bytesAfter/bytesBefore)*100)}));
    assert.equal(after.matches.length,1083);
    assert.deepEqual(after.matches.map(m=>m.id),before.matches.map(m=>m.id));
    assert.ok(bytesAfter<bytesBefore*0.65);
    for(const m of after.matches) for(const key of ['events','statistics','provenance','venue','season']) assert.equal(m[key],undefined);
  } finally {await db.close();}
});

test('HTTP caching distinguishes complete history from recovery and live days',()=>{
  const now=new Date('2026-09-21T18:00:00Z');
  assert.match(calendarCacheControl('2026-09-20','America/Costa_Rica',false,now),/max-age=300/);
  assert.match(calendarCacheControl('2026-09-20','America/Costa_Rica',true,now),/max-age=20/);
  assert.match(calendarCacheControl('2026-09-21','America/Costa_Rica',false,now),/max-age=20/);
});

test('rescheduling rejects older stored scores and helper stays private',async()=>{
  const db=await openDatabase();
  try {
    await seed(db);
    await db.query(`insert into futbeat_private.provider_observations
      (provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,payload_hash,raw_payload)
      values('goal_api','perf','fb_match_perf_0','2026-08-19T20:00:00Z','VERIFIED',9,9,$1,'{}')`,['c'.repeat(64)]);
    const result=await both(db);
    assert.equal(result.match.score,undefined);
    assert.equal(result.match.hasPlayedEvidence,false);
    assert.equal(result.match.status,'SCHEDULED');
    for(const role of ['anon','authenticated']) {
      assert.equal((await db.query("select has_function_privilege($1,'futbeat_private.match_read_model(jsonb)','EXECUTE') ok",[role])).rows[0].ok,false);
    }
  } finally {await db.close();}
});

test('compact calendar and context resolve lingering team and competition aliases',async()=>{
  const db=await openDatabase();
  try {
    await seed(db);
    for(const [id,kind] of [['fb_team_home_alias','team'],['fb_team_home_intermediate','team'],
      ['fb_team_away_alias','team'],['fb_comp_alias','competition']]) {
      await db.query('insert into futbeat_private.entities values($1,$2,$3)',[id,kind,JSON.stringify({id,name:'Legacy'})]);
    }
    // Deliberately retain old references, including a chain. Registration would
    // repair storage and hide this read-path regression.
    await db.exec(`insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values
      ('fb_team_home_alias','fb_team_home_intermediate','team','test'),
      ('fb_team_home_intermediate','fb_team_home_0','team','test'),
      ('fb_team_away_alias','fb_team_away_0','team','test'),
      ('fb_comp_alias','fb_comp_perf','competition','test');
      update futbeat_private.entities set payload=payload||'{"homeTeamId":"fb_team_home_alias",
        "awayTeamId":"fb_team_away_alias","competitionId":"fb_comp_alias"}'::jsonb where id='fb_match_perf_0';`);
    const {calendar,context}=await both(db);
    for(const snapshot of [calendar,context]) {
      const match=snapshot.matches[0];
      assert.equal(match.homeTeamId,'fb_team_home_0');
      assert.equal(match.awayTeamId,'fb_team_away_0');
      assert.equal(match.competitionId,'fb_comp_perf');
      assert.equal(snapshot.teams.find(t=>t.id===match.homeTeamId).name,'Team home 0');
      assert.equal(snapshot.teams.find(t=>t.id===match.awayTeamId).name,'Team away 0');
      assert.equal(snapshot.competitions.find(c=>c.id===match.competitionId).name,'Competition');
    }
    assert.equal(calendar.teams.length,2);
    assert.equal(calendar.competitions.length,1);
    assert.equal(calendar.entityRedirects,undefined);
    assert.equal(calendar.matches[0].events,undefined);
    // Read-only projection must not mutate the lingering aliases in storage.
    assert.equal((await db.query("select payload->>'homeTeamId' id from futbeat_private.entities where id='fb_match_perf_0'")).rows[0].id,'fb_team_home_alias');
    // This same real-RPC fixture is parsed by the Flutter Snapshot regression.
    const fixture=JSON.parse(await readFile(new URL('../../apps/mobile/test/fixtures/redirected_calendar.json',import.meta.url),'utf8'));
    assert.equal(Date.parse(calendar.updatedAt),Date.parse(fixture.updatedAt));
    assert.deepEqual({...calendar,updatedAt:fixture.updatedAt},fixture);
  } finally {await db.close();}
});
