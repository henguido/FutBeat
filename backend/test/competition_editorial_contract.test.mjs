import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
import { openDatabase } from '../storage/database.mjs';

const migrationName = '20260921215519_stabilize_competition_editorial_contract.sql';
const migrations = new URL('../../supabase/migrations/', import.meta.url);
const requiredKeys = ['relevanceScore', 'competitionClass', 'domesticTier',
  'isPrimaryDomestic', 'isGlobalRelevant', 'audienceClass', 'countryCode', 'relevanceSource'];
const cases = [
  ['UEFA Champions League', 'Europe', 970],
  ['AFC Champions League Elite', 'intl', 100],
  ['AFC Champions League Two', 'intl', 100],
  ["AFC Women's Champions League", 'intl', 100],
  ['CAF Champions League', 'intl', 100],
  ["UEFA Women's Champions League", 'intl', 100],
  ['Liga MX', 'Mexico', 800],
  ['Liga MX Femenil', 'Mexico', 100],
];

async function beforeCorrection() {
  const db = await PGlite.create();
  await db.exec('create role anon; create role authenticated; create role service_role;');
  for (const name of (await readdir(migrations)).filter(n => n.endsWith('.sql') && n < migrationName).sort()) {
    await db.exec(await readFile(new URL(name, migrations), 'utf8'));
  }
  return db;
}

async function competition(db, id, name, country, extra = {}) {
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)", [
    id, JSON.stringify({ id, name, country, ...extra }),
  ]);
}
async function metadata(db, id) {
  return (await db.query('select * from futbeat_private.competition_editorial_metadata where competition_id=$1', [id])).rows[0];
}

test('real calendar RPC always emits all eight editorial keys, including null tier/country', async () => {
  const db = await openDatabase();
  try {
    await competition(db, 'fb_comp_contract_domestic', 'Premier League', 'England');
    await competition(db, 'fb_comp_contract_international', 'Unknown international competition', 'Europe');
    await competition(db, 'fb_comp_contract_unknown', 'Unknown competition', null);
    await competition(db, 'fb_comp_contract_editorial', 'UEFA Champions League', 'Europe');
    for (const id of ['fb_team_contract_home', 'fb_team_contract_away']) {
      await db.query("insert into futbeat_private.entities values($1,'team',$2)", [id, JSON.stringify({id,name:id})]);
    }
    for (const suffix of ['domestic', 'international', 'unknown', 'editorial']) {
      const id = 'fb_match_contract_'+suffix;
      await db.query("insert into futbeat_private.entities values($1,'match',$2)", [id, JSON.stringify({
        id, competitionId:'fb_comp_contract_'+suffix,
        homeTeamId:'fb_team_contract_home', awayTeamId:'fb_team_contract_away',
        startTime:'2026-09-20T18:00:00Z', status:'SCHEDULED', events:[],
      })]);
    }
    const value = (await db.query("select public.futbeat_read_calendar_range('2026-09-20','2026-09-20','UTC') v")).rows[0].v;
    assert.equal(value.competitions.length, 4);
    for (const row of value.competitions) {
      assert.deepEqual(Object.keys(row).filter(k => requiredKeys.includes(k)).sort(), [...requiredKeys].sort());
      assert.ok(Number.isInteger(row.relevanceScore));
      assert.equal(Object.hasOwn(row,'media'), false, 'optional null media remains stripped');
    }
    const byId = Object.fromEntries(value.competitions.map(c => [c.id,c]));
    assert.equal(byId.fb_comp_contract_domestic.domesticTier, 1);
    assert.equal(byId.fb_comp_contract_domestic.countryCode, 'GB-ENG');
    assert.equal(byId.fb_comp_contract_international.domesticTier, null);
    assert.equal(byId.fb_comp_contract_international.relevanceScore, 260);
    assert.equal(byId.fb_comp_contract_international.isGlobalRelevant, false);
    assert.equal(byId.fb_comp_contract_unknown.countryCode, null);
    assert.equal(byId.fb_comp_contract_unknown.domesticTier, null);
    assert.equal(byId.fb_comp_contract_editorial.relevanceScore, 970);
    assert.equal(byId.fb_comp_contract_editorial.relevanceSource, 'editorial');
  } finally { await db.close(); }
});

test('ingestion uses explicit editorial scores or conservative structure, never name tokens or asserted scores', async () => {
  const db = await openDatabase();
  try {
    for (const [i,[name,country,expected]] of cases.entries()) {
      const id = 'fb_comp_contract_case_'+i;
      await competition(db,id,name,country,{relevanceScore:999,relevanceSource:'editorial'});
      const meta = await metadata(db,id);
      const payload = (await db.query('select payload from futbeat_private.entities where id=$1',[id])).rows[0].payload;
      assert.equal(meta.relevance_score, expected, name);
      assert.equal(payload.relevanceScore, expected, name);
      if (expected===100) assert.equal(meta.is_global_relevant,false,name);
    }
    for (const [i,[cls,audience,score]] of [
      ['other','unknown',100], ['domestic_league','open',240], ['domestic_cup','open',180],
      ['international_club','unknown',260], ['international_national','open',260],
      ['international_club','women',100], ['domestic_league','youth',100],
      ['domestic_league','reserve',100], ['domestic_league','amateur',100],
    ].entries()) {
      const id='fb_comp_contract_structure_'+i;
      await competition(db,id,'Champions League Liga MX Unseeded','Mexico',{
        competitionClass:cls,audienceClass:audience,relevanceScore:970,
      });
      const meta=await metadata(db,id);
      assert.equal(meta.relevance_score,score);
      assert.equal(meta.is_global_relevant,false);
      assert.equal(meta.is_primary_domestic,false);
    }
    const id='fb_comp_contract_explicit_women';
    await db.query("insert into futbeat_private.competition_editorial_seed(country_code,normalized_identity,competition_class,audience_class,relevance_score) values('EUROPE','explicit women test','international_club','women',600)");
    await competition(db,id,'Explicit Women Test','Europe',{audienceClass:'women'});
    assert.equal((await metadata(db,id)).relevance_score,600);
  } finally { await db.close(); }
});

test('forward migration repairs old derived rows and preserves editorial metadata, seeds and lifecycle functions', async () => {
  const db = await beforeCorrection();
  try {
    for (const [i,[name,country]] of cases.entries()) await competition(db,'fb_comp_upgrade_'+i,name,country);
    assert.equal((await metadata(db,'fb_comp_upgrade_1')).relevance_score,970);
    assert.equal((await metadata(db,'fb_comp_upgrade_7')).relevance_score,800);
    const allSeeds=async()=> (await db.query('select * from futbeat_private.competition_editorial_seed order by seed_id')).rows;
    const functions=async()=> (await db.query("select oid::regprocedure::text signature,prosrc from pg_proc where pronamespace='futbeat_private'::regnamespace and (proname like '%results%' or proname like '%event%') order by oid")).rows;
    const seedsBefore=await allSeeds(), functionsBefore=await functions();
    const editorialBefore=await metadata(db,'fb_comp_upgrade_0');
    const sql=await readFile(new URL(migrationName,migrations),'utf8');
    await db.exec(sql);
    for(const [i,[name,,expected]] of cases.entries()) assert.equal((await metadata(db,'fb_comp_upgrade_'+i)).relevance_score,expected,name);
    assert.deepEqual(await metadata(db,'fb_comp_upgrade_0'),editorialBefore);
    assert.deepEqual(await allSeeds(),seedsBefore);
    assert.deepEqual(await functions(),functionsBefore);
    await db.query("update futbeat_private.entities set payload=payload||$2::jsonb where id=$1",[
      'fb_comp_upgrade_0',JSON.stringify({name:'Provider renamed entry',relevanceScore:1,relevanceSource:'provider'}),
    ]);
    assert.deepEqual(await metadata(db,'fb_comp_upgrade_0'),editorialBefore);
    const derivedBefore=await metadata(db,'fb_comp_upgrade_1');
    await db.exec(sql);
    assert.deepEqual(await metadata(db,'fb_comp_upgrade_1'),derivedBefore,'recompute is idempotent');
    assert.deepEqual(await metadata(db,'fb_comp_upgrade_0'),editorialBefore);
    assert.deepEqual(await functions(),functionsBefore);
    for (const role of ['anon','authenticated']) {
      assert.equal((await db.query("select has_function_privilege($1,'futbeat_private.derived_competition_relevance(text,text)','EXECUTE') ok",[role])).rows[0].ok,false);
      assert.equal((await db.query("select has_function_privilege($1,'public.futbeat_read_calendar_range(date,date,text)','EXECUTE') ok",[role])).rows[0].ok,false);
    }
  } finally { await db.close(); }
});

test('local catalog audit repairs known country aliases and leaves ambiguous buckets explicitly unknown', async () => {
  const db = await beforeCorrection();
  try {
    const audit=JSON.parse(await readFile(new URL('./fixtures/competition_country_audit.json',import.meta.url),'utf8'));
    for(const c of audit.competitions) {
      await competition(db,c.id,c.name,c.country);
      assert.equal((await metadata(db,c.id)).country_code,null,c.country);
    }
    await db.exec(await readFile(new URL(migrationName,migrations),'utf8'));
    const mapping={
      'Bosnia and Herzegovina':'BA','Bosnia and Herzegovina and Herzegovina':'BA',
      'China PR':'CN','Chinese Taipei':'TW','Czech Republic':'CZ','eurocups':'EUROPE',
      'Hong Kong':'HK','Kyrgyz Republic':'KG','Myanmar':'MM','Republic of Ireland':'IE',
      intl:null,Worldcup:null,
    };
    let repaired=0,unknown=0;
    for(const c of audit.competitions) {
      const code=(await metadata(db,c.id)).country_code;
      assert.equal(code,mapping[c.country],c.name);
      if(code===null)unknown++; else repaired++;
    }
    assert.equal(repaired,24);
    assert.equal(unknown,28);
    assert.equal((await db.query('select count(*)::int n from futbeat_private.country_catalog')).rows[0].n,262);
  } finally { await db.close(); }
});
