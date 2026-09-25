import test from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// Match Center hot path contract: opening a match must not scan the whole
// catalog to find competitionId + season. Plan-based (not timing-based).

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const plan = async (db, sql, params = []) => (await db.query(`explain (costs off) ${sql}`, params)).rows
  .map((r) => r['QUERY PLAN']).join('\n');

test('generic partial index on match competitionId exists (no league/season specifics)', () => withDb(async (db) => {
  const def = (await db.query(`select indexdef from pg_indexes where schemaname='futbeat_private'
    and indexname='entities_match_competition_idx'`)).rows[0]?.indexdef ?? '';
  assert.match(def, /\(\(payload ->> 'competitionId'::text\)\)/);
  assert.match(def, /WHERE \(kind = 'match'::text\)/);
}));

test('hot predicates are index-served (matches by competition, mapping by canonical id)', () => withDb(async (db) => {
  // Realistic catalog shape: many mapped competitions and matches.
  await db.exec(`insert into futbeat_private.entities(id,kind,payload)
      select 'fb_comp_qv'||i,'competition',jsonb_build_object('id','fb_comp_qv'||i,'name','C'||i) from generate_series(1,3000) i;
    insert into futbeat_private.provider_entities select 'goal_api','competition','qv-'||i,'fb_comp_qv'||i from generate_series(1,3000) i;
    insert into futbeat_private.entities(id,kind,payload)
      select 'fb_match_qv'||i,'match',jsonb_build_object('id','fb_match_qv'||i,'competitionId','fb_comp_qv'||(1+i%3000))
      from generate_series(1,6000) i;
    analyze futbeat_private.entities; analyze futbeat_private.provider_entities;`);
  // With sequential scans disabled, a predicate no index can serve would
  // still show a Seq Scan.
  await db.exec('set enable_seqscan = off');
  const byCompetition = await plan(db, `select 1 from futbeat_private.entities x where x.kind='match'
    and x.payload->>'competitionId'=$1 and x.payload->>'status' in ('LIVE','HALFTIME')`, ['fb_comp_x']);
  assert.match(byCompetition, /entities_match_competition_idx/);
  assert.doesNotMatch(byCompetition, /Seq Scan/);
  const mapping = await plan(db, `select pe.external_id from futbeat_private.provider_entities pe
    where pe.canonical_id=any($1::text[]) and pe.provider='goal_api' and pe.kind='competition'`, [['fb_comp_x']]);
  assert.match(mapping, /provider_entities_canonical_id_idx/);
  assert.doesNotMatch(mapping, /Seq Scan/);
}));

test('match_standings_state never resolves every mapped competition of the catalog', () => withDb(async (db) => {
  const def = (await db.query(`select pg_get_functiondef('futbeat_private.match_standings_state(text)'::regprocedure) d`)).rows[0].d;
  assert.doesNotMatch(def, /futbeat_resolve_entity_id\('competition',\s*pe\.canonical_id\)/);
  // The indexed alias walk lives in one helper shared with the reservation (#98).
  assert.match(def, /standings_provider_league_id\(comp\)/);
  const helper = (await db.query(`select pg_get_functiondef('futbeat_private.standings_provider_league_id(text)'::regprocedure) d`)).rows[0].d;
  assert.doesNotMatch(helper, /futbeat_resolve_entity_id/);
  assert.match(helper, /canonical_id=any\(array\(select id from ids\)\)/);
}));

test('the indexed mapping still finds a provider id attached to a redirected alias', () => withDb(async (db) => {
  for (const [id, season] of [['fb_comp_qp_canon', '2026/2027'], ['fb_comp_qp_alias', '']]) {
    await db.query("insert into futbeat_private.entities values($1,'competition',$2)",
      [id, JSON.stringify({ id, name: 'Q', season })]);
  }
  await db.query("insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values('fb_comp_qp_alias','fb_comp_qp_canon','competition','test')");
  await db.query("insert into futbeat_private.provider_entities values('goal_api','competition','qp-ext','fb_comp_qp_alias')");
  for (const t of ['fb_team_qp_a', 'fb_team_qp_b']) {
    await db.query("insert into futbeat_private.entities values($1,'team',$2)", [t, JSON.stringify({ id: t, name: t })]);
  }
  await db.query("insert into futbeat_private.entities values('fb_match_qp','match',$1)", [JSON.stringify({
    id: 'fb_match_qp', competitionId: 'fb_comp_qp_canon', homeTeamId: 'fb_team_qp_a', awayTeamId: 'fb_team_qp_b',
    season: '2026/2027', status: 'SCHEDULED', startTime: new Date(Date.now() + 864e5).toISOString() })]);
  const state = (await db.query("select futbeat_private.match_standings_state('fb_match_qp') v")).rows[0].v;
  assert.deepEqual([state.externalLeagueId, state.fetchable], ['qp-ext', true]);
}));
