import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

async function seed(db, count=2, date='2020-01-02', suffix='') {
  const rows=[];
  for(let i=0;i<12;i++) rows.push({id:`fb_comp_cache_${suffix}${i}`,kind:'competition',name:`League ${i}`,country:'England'});
  for(let i=0;i<count;i++) {
    for(const side of ['home','away']) rows.push({id:`fb_team_cache_${suffix}${side}_${i}`,kind:'team',
      name:i===0?`Manchester ${side==='home'?'United':'City'}`:`Team ${side} ${i}`,
      competitionId:`fb_comp_cache_${suffix}${i%12}`,aliases:[`Alias ${side} ${i}`]});
    rows.push({id:`fb_match_cache_${suffix}${i}`,kind:'match',competitionId:`fb_comp_cache_${suffix}${i%12}`,
      homeTeamId:`fb_team_cache_${suffix}home_${i}`,awayTeamId:`fb_team_cache_${suffix}away_${i}`,
      startTime:`${date}T18:00:00Z`,status:'SCHEDULED',score:null,events:[],
      provenance:{receivedAt:`${date}T12:00:00Z`}});
  }
  await db.query(`insert into futbeat_private.entities select item->>'id',item->>'kind',item-'kind'
    from jsonb_array_elements($1::jsonb) item`,[JSON.stringify(rows)]);
  await db.exec(`update futbeat_private.competition_editorial_metadata set source='editorial',
    relevance_score=900-right(competition_id,1)::int*10
    where competition_id like 'fb_comp_cache_%'`);
}
async function calendar(db,date='2020-01-02',timezone='UTC') {
  return (await db.query('select public.futbeat_read_calendar_range($1,$1,$2) v',[date,timezone])).rows[0].v;
}
test('historic cache hit never calls builder; versions invalidate score and rescheduling',async()=>{
 const db=await openDatabase();
 try {
  await seed(db);
  const first=await calendar(db);
  const original=(await db.query("select pg_get_functiondef('futbeat_private.build_compact_calendar(date,date,text)'::regprocedure) def")).rows[0].def;
  await db.exec(`create or replace function futbeat_private.build_compact_calendar(p_from_date date,p_to_date date,p_timezone text default 'America/Costa_Rica')
    returns jsonb language plpgsql stable security definer set search_path='' as $$ begin raise exception 'heavy builder called'; end $$`);
  assert.deepEqual(await calendar(db),first);
  await db.exec(original);
  await db.query(`insert into futbeat_private.provider_observations
    (provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,payload_hash,raw_payload)
    values('goal_api','cache','fb_match_cache_0','2020-01-02T19:00Z','LIVE',1,1,$1,'{}')`,['d'.repeat(64)]);
  assert.deepEqual((await calendar(db)).matches[0].score,{home:1,away:1});
  await db.exec(`update futbeat_private.entities set payload=payload||'{"startTime":"2020-01-03T18:00:00Z"}' where id='fb_match_cache_0'`);
  assert.equal((await calendar(db)).matches.length,1);
  assert.equal((await calendar(db,'2020-01-03')).matches.length,1);
  assert.equal((await calendar(db,'2020-01-03')).matches[0].score,undefined);
 } finally {await db.close();}
});
test('cache invalidates redirects, competition metadata, events, detail and coverage across timezones',async()=>{
 const db=await openDatabase();
 try {
  await seed(db);
  await calendar(db,'2020-01-02','America/Costa_Rica');
  await db.exec(`update futbeat_private.competition_editorial_metadata set relevance_score=999 where competition_id='fb_comp_cache_0'`);
  assert.equal((await calendar(db,'2020-01-02','America/Costa_Rica')).competitions.find(c=>c.id==='fb_comp_cache_0').relevanceScore,999);
  await db.exec(`insert into futbeat_private.entities values('fb_team_canonical','team','{"id":"fb_team_canonical","name":"Canonical"}');
    insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason)
      values('fb_team_cache_home_0','fb_team_canonical','team','test')`);
  const redirected=await calendar(db,'2020-01-02','America/Costa_Rica');
  assert.equal(redirected.matches[0].homeTeamId,'fb_team_canonical');
  assert.ok(redirected.teams.some(t=>t.id==='fb_team_canonical'));
  await db.exec(`insert into futbeat_private.canonical_events values('fb_event_cache','fb_match_cache_0','goal_api','GOAL','{"minute":20}',false,now())`);
  assert.equal((await calendar(db,'2020-01-02','America/Costa_Rica')).matches[0].hasPlayedEvidence,true);
  await db.exec(`insert into futbeat_private.match_detail_cache values('fb_match_cache_0','goal_api','cache','2020-01-02T20:00Z','{"homeTeamScore":2,"awayTeamScore":1}')`);
  assert.deepEqual((await calendar(db,'2020-01-02','America/Costa_Rica')).matches[0].score,{home:2,away:1});
  await db.exec(`insert into futbeat_private.calendar_coverage(provider,provider_date,fetched_at)
    values('goal_api','2020-01-02',now()),('goal_api','2020-01-03',now())`);
  assert.equal((await calendar(db,'2020-01-02','America/Costa_Rica')).coverage.partial,false);
  const ttl=async()=>(await db.query("select extract(epoch from expires_at-built_at)::int ttl from futbeat_private.compact_calendar_cache where timezone='America/Costa_Rica'")).rows[0].ttl;
  // Past day with incomplete results: calendarHistoryIncompleteMinutes (policy).
  assert.equal(await ttl(),600);
  await db.exec('update futbeat_private.calendar_coverage set results_complete=true');
  await calendar(db,'2020-01-02','America/Costa_Rica');
  assert.equal(await ttl(),86400);
  for(const role of ['anon','authenticated']) {
    assert.equal((await db.query("select has_function_privilege($1,'public.futbeat_read_explore()','execute') ok",[role])).rows[0].ok,false);
    assert.equal((await db.query("select has_table_privilege($1,'futbeat_private.compact_calendar_cache','select') ok",[role])).rows[0].ok,false);
  }
 } finally {await db.close();}
});
test('today is served from a short-lived snapshot and LIVE changes are visible immediately (versioned)',async()=>{
 const db=await openDatabase();
 try {
  const today=(await db.query("select (now() at time zone 'UTC')::date::text d")).rows[0].d;
  await seed(db,1,today);
  await db.exec(`update futbeat_private.entities set payload=payload||jsonb_build_object('startTime',now(),
    'status','LIVE','minute',20,'score',jsonb_build_object('home',0,'away',0),'provenance',jsonb_build_object('receivedAt',now())) where id='fb_match_cache_0'`);
  assert.equal((await calendar(db,today)).matches[0].minute,20);
  // Served from the snapshot while nothing changes...
  const built=async()=>(await db.query("select built_at,extract(epoch from expires_at-built_at)::int ttl from futbeat_private.compact_calendar_cache where calendar_date=$1",[today])).rows[0];
  const first=await built();
  await calendar(db,today);
  assert.deepEqual(await built(),first);
  assert.equal(first.ttl,15,'live day: calendarLiveSeconds');
  // ...and a LIVE change bumps today's version: visible on the very next read.
  await db.exec(`update futbeat_private.entities set payload=payload||'{"minute":25,"score":{"home":1,"away":0}}' where id='fb_match_cache_0'`);
  const latest=await calendar(db,today);
  assert.deepEqual(latest.matches[0].score,{home:1,away:0});
  assert.equal(latest.matches[0].minute,25);
 } finally {await db.close();}
});

test('history/future revisions invalidate cached days and offset civil days around UTC today are cached too',async()=>{
 const db=await openDatabase();
 try {
  const {today,past,future}=(await db.query(`select (now() at time zone 'UTC')::date::text today,
    ((now() at time zone 'UTC')::date-3)::text past,
    ((now() at time zone 'UTC')::date+3)::text future`)).rows[0];
  for(const [date,suffix] of [[past,'past_'],[future,'future_']]) {
    await seed(db,1,date,suffix);
    await calendar(db,date);
    const revision=async()=>(await db.query('select revision::int n from futbeat_private.calendar_cache_versions where utc_date=$1',[date])).rows[0].n;
    const before=await revision();
    await db.query(`update futbeat_private.entities set payload=payload||'{"status":"CANCELLED"}' where id=$1`,[`fb_match_cache_${suffix}0`]);
    assert.ok(await revision()>before);
    assert.equal((await calendar(db,date)).matches[0].status,'CANCELLED');
  }
  // A future day is re-evaluated once it starts (then "today" rules apply).
  assert.equal((await db.query(`select expires_at<=calendar_date::timestamp at time zone 'UTC' ok
    from futbeat_private.compact_calendar_cache c where c.calendar_date=$1 and c.timezone='UTC'`,[future])).rows[0].ok,true);
  // UTC bucket boundaries, including non-local-today dates in both directions.
  for(const timezone of ['America/Costa_Rica','Pacific/Kiritimati']) {
    const days=(await db.query(`select distinct (instant at time zone $2)::date::text d
      from (values($1::date::timestamp at time zone 'UTC'),
        (($1::date+1)::timestamp at time zone 'UTC'-interval '1 microsecond')) v(instant)`,[today,timezone])).rows;
    for(const {d} of days) {
      await calendar(db,d,timezone);
      assert.equal((await db.query(`select count(*)::int n from futbeat_private.compact_calendar_cache
        where calendar_date=$1 and timezone=$2`,[d,timezone])).rows[0].n,1);
    }
  }
  await db.exec(`set timezone='Pacific/Kiritimati'`);
  // UTC today is versioned now: a bump is recorded regardless of the session zone.
  await db.query('select futbeat_private.bump_calendar_date($1)',[today]);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.calendar_cache_versions where utc_date=$1',[today])).rows[0].n,1);
 } finally {await db.close();}
});

test('future cache expires when the day starts, today changes are versioned, and it never reappears stale as history',async()=>{
 const db=await openDatabase();
 try {
  // Freeze only the cache functions in this disposable DB; no production clock hook.
  const definitions=await Promise.all(['futbeat_private.bump_calendar_date(date)',
    'public.futbeat_read_calendar_range(date,date,text)'].map(async(name)=>
      (await db.query('select pg_get_functiondef($1::regprocedure) def',[name])).rows[0].def));
  const at=async(instant)=>{
    for(const definition of definitions) await db.exec(definition.replaceAll('now()',`'${instant}'::timestamptz`));
  };
  await at('2030-01-01T23:59:59Z');
  await seed(db,1,'2030-01-02');
  await calendar(db,'2030-01-02');
  assert.equal((await db.query(`select expires_at='2030-01-02T00:00Z'::timestamptz ok
    from futbeat_private.compact_calendar_cache`)).rows[0].ok,true);
  const revision=async()=>(await db.query("select revision::int n from futbeat_private.calendar_cache_versions where utc_date='2030-01-02'")).rows[0].n;
  const before=await revision();
  await at('2030-01-02T12:00:00Z');
  await db.exec(`update futbeat_private.entities set payload=payload||'{"status":"CANCELLED"}' where id='fb_match_cache_0'`);
  // UTC today is versioned: the change bumps the day's revision.
  assert.ok(await revision()>before);
  assert.equal((await calendar(db,'2030-01-02')).matches[0].status,'CANCELLED');
  await at('2030-01-03T00:00:01Z');
  assert.equal((await calendar(db,'2030-01-02')).matches[0].status,'CANCELLED');
  assert.equal((await db.query(`select built_at='2030-01-03T00:00:01Z'::timestamptz ok
    from futbeat_private.compact_calendar_cache`)).rows[0].ok,true);
 } finally {await db.close();}
});

test('compact builder resolves home, chained away and competition aliases without physical alias rows',async()=>{
 const db=await openDatabase();
 try {
  await seed(db);
  const before=await calendar(db);
  await db.exec(`insert into futbeat_private.entities values
    ('fb_team_final_home','team','{"id":"fb_team_final_home","name":"Home"}'),
    ('fb_team_middle_away','team','{"id":"fb_team_middle_away","name":"Middle"}'),
    ('fb_team_final_away','team','{"id":"fb_team_final_away","name":"Away"}'),
    ('fb_comp_final','competition','{"id":"fb_comp_final","name":"Final League"}');
    insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values
    ('fb_team_cache_home_0','fb_team_final_home','team','test'),
    ('fb_team_cache_home_1','fb_team_final_home','team','test'),
    ('fb_team_cache_away_0','fb_team_middle_away','team','test'),
    ('fb_team_middle_away','fb_team_final_away','team','test'),
    ('fb_comp_cache_0','fb_comp_final','competition','test');`);
  // Production FKs deliberately retain aliases. Relax ONLY this disposable
  // fixture to prove the builder needs redirect mappings, not alias entity rows.
  await db.exec(`alter table futbeat_private.entity_redirects drop constraint entity_redirects_alias_id_fkey;
    alter table futbeat_private.entity_redirects drop constraint entity_redirects_canonical_id_fkey;
    delete from futbeat_private.entities where id in ('fb_team_cache_home_0','fb_team_cache_home_1',
      'fb_team_cache_away_0','fb_team_middle_away','fb_comp_cache_0');`);
  const verify=(result)=>{
    assert.equal(result.matches.length,before.matches.length);
    const match=result.matches.find(m=>m.id==='fb_match_cache_0');
    assert.equal(match.homeTeamId,'fb_team_final_home');
    assert.equal(match.awayTeamId,'fb_team_final_away');
    assert.equal(match.competitionId,'fb_comp_final');
    for(const field of ['teams','competitions','matches']) {
      assert.equal(new Set(result[field].map(e=>e.id)).size,result[field].length);
    }
    assert.ok(result.teams.some(t=>t.id===match.homeTeamId));
    assert.ok(result.teams.some(t=>t.id===match.awayTeamId));
    assert.ok(result.competitions.some(c=>c.id===match.competitionId));
    assert.equal(result.teams.length,3); // Shared canonical home appears once.
  };
  verify(await calendar(db));
  // The explicit boundary must work even if reconciliation returns raw refs.
  const model=(await db.query("select pg_get_functiondef('futbeat_private.match_read_model(jsonb)'::regprocedure) def")).rows[0].def;
  await db.exec(`create or replace function futbeat_private.match_read_model(p_match jsonb)
    returns jsonb language sql stable set search_path='' as $$ select p_match $$`);
  verify((await db.query("select futbeat_private.build_compact_calendar('2020-01-02','2020-01-02','UTC') v")).rows[0].v);
  await db.exec(model);
 } finally {await db.close();}
});
test('Explore is bounded, editorial, activity-based and cached; search ignores country and tracks aliases',async()=>{
 const db=await openDatabase();
 try {
  const today=(await db.query("select (now() at time zone 'UTC')::date::text d")).rows[0].d;
  await seed(db,20,today);
  const explore=(await db.query('select public.futbeat_read_explore() v')).rows[0].v;
  assert.equal(explore.competitions.length,12);
  assert.equal(explore.teams.length,16);
  assert.equal(explore.players.length,0);
  assert.equal(explore.matches.length,0);
  assert.equal(explore.competitions[0].relevanceScore,900);
  assert.ok(explore.teams.every(t=>t.id.startsWith('fb_team_cache_')));
  assert.deepEqual((await db.query('select public.futbeat_read_explore() v')).rows[0].v,explore);
  const cr=(await db.query("select public.futbeat_search_catalog('manchester','CR',50) v")).rows[0].v;
  const es=(await db.query("select public.futbeat_search_catalog('manchester','ES',50) v")).rows[0].v;
  assert.deepEqual(cr.teams,es.teams);
  assert.equal(cr.teams.length,2);
  await db.exec(`update futbeat_private.entities set payload=payload||'{"aliases":["The Red Devils"]}' where id='fb_team_cache_home_0'`);
  const alias=(await db.query("select public.futbeat_search_catalog('red devils',null,50) v")).rows[0].v;
  assert.equal(alias.teams[0].id,'fb_team_cache_home_0');
  assert.deepEqual((await db.query("select public.futbeat_search_catalog('m',null,50) v")).rows[0].v.teams,[]);
  assert.equal((await db.query("select public.futbeat_search_catalog('',null,50) v")).rows[0].v.matches.length,0);
  const src=await readFile(new URL('../../supabase/functions/futbeat-api/index.ts',import.meta.url),'utf8');
  assert.match(src,/\/futbeat-api\/v1\/explore/);
  assert.match(src,/futbeat_read_explore/);
 } finally {await db.close();}
});
test('EXPLAIN benchmark on reproducible September fixtures (not a production after measurement)',async(t)=>{
 const db=await openDatabase();
 try {
  await seed(db,1084,'2026-09-20','large_');
  await seed(db,171,'2026-09-23','small_');
  // A substantial catalog makes the index comparison meaningful.
  await db.exec(`insert into futbeat_private.entities
    select 'fb_team_extra_'||i,'team',jsonb_build_object('id','fb_team_extra_'||i,
      'name','Catalog Team '||i,'aliases',jsonb_build_array('Alias extra '||i))
    from generate_series(1,10000) i;
    analyze futbeat_private.entity_search_index; analyze futbeat_private.entities;`);
  const explain=async(sql)=>{
    const plan=(await db.query('explain (analyze,buffers,format json) '+sql)).rows[0]['QUERY PLAN'][0];
    return {ms:plan['Execution Time'],plan:plan.Plan['Node Type']};
  };
  for(const date of ['2026-09-20','2026-09-23']) {
    const args=`('${date}','${date}','America/Costa_Rica')`;
    const before=await explain('select futbeat_private.futbeat_read_calendar_range_before_cache'+args);
    const cold=await explain('select public.futbeat_read_calendar_range'+args);
    const hit=await explain('select public.futbeat_read_calendar_range'+args);
    const current=await calendar(db,date,'America/Costa_Rica');
    t.diagnostic(JSON.stringify({fixture:'synthetic',date,matches:current.matches.length,bytes:Buffer.byteLength(JSON.stringify(current)),before,cold,hit}));
    assert.equal(current.matches.length,date.endsWith('20')?1084:171);
  }
  const newSearch=(await db.query("select pg_get_functiondef('public.futbeat_search_catalog(text,text,integer)'::regprocedure) def")).rows[0].def;
  const old=await readFile(new URL('../../supabase/migrations/20260919153000_lightweight_tabs.sql',import.meta.url),'utf8');
  await db.exec(old.slice(old.indexOf('create or replace function public.futbeat_search_catalog'),old.indexOf('create or replace function public.futbeat_read_favorites')));
  const emptyBefore=await explain("select public.futbeat_search_catalog('',null,50)");
  const manchesterBefore=await explain("select public.futbeat_search_catalog('manchester',null,50)");
  await db.exec(newSearch);
  const emptyCold=await explain('select public.futbeat_read_explore()');
  const emptyHit=await explain('select public.futbeat_read_explore()');
  const manchesterAfter=await explain("select public.futbeat_search_catalog('manchester',null,50)");
  const termPlan=(await db.query("explain (analyze,buffers,format json) select entity_id from futbeat_private.entity_search_index where term like '%manchester%'")).rows[0]['QUERY PLAN'][0];
  assert.match(JSON.stringify(termPlan),/entity_search_term_trgm/);
  const entities=(await db.query('select count(*)::int n from futbeat_private.entities')).rows[0].n;
  t.diagnostic(JSON.stringify({fixture:'synthetic',entities,emptyBefore,emptyCold,emptyHit,manchesterBefore,manchesterAfter,index:termPlan.Plan}));
 } finally {await db.close();}
});
