import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import { seedRankingFixture, compareStrategies, plan, ranked, definition } from '../bench/squad_upcoming_ranking.mjs';
import { tracePools, planNodes } from '../bench/squad_candidate_pool.mjs';
import { explain } from '../bench/squad_planner.mjs';

const id = key => `fb_team_rank_${key}`;
async function fixture(run, large = false) {
  const db = await openDatabase();
  try { await seedRankingFixture(db, large); await run(db); } finally { await db.close(); }
}
const position = (rows, key) => rows.findIndex(r => (r.teamId ?? r.team_id) === id(key));

test('P2 compares A/B: editorial beats low imminent fixtures, B keeps today ahead of +6d', async () => fixture(async db => {
  const [a, b] = await compareStrategies(db);
  assert.ok(a.top.indexOf(id('near_score_6d')) < a.top.indexOf(id('premier_early')));
  assert.ok(b.top.indexOf(id('near_score_6d')) > b.top.indexOf(id('premier_early')));
  const rows = await plan(db);
  assert.deepEqual(rows.map(r => r.teamId), b.top);
  assert.ok(position(rows, 'premier_hour') < position(rows, 'low_near'));
  assert.ok(position(rows, 'premier_early') < position(rows, 'premier_late'));
  assert.ok(position(rows, 'premier_early') < position(rows, 'champions_6d'));
  assert.ok(position(rows, 'champions') < position(rows, 'low_near'));
  assert.ok(rows.every(r => r.priorityTier === 2 && r.priority === 40000 && r.reason === 'upcoming'));
}));

test('P2 followed and live temporary demand boost only their bucket; expired/repeated user interests do not inflate rank', async () => fixture(async db => {
  let rows = await ranked(db);
  assert.equal(rows[0].team_id, id('followed'));
  assert.ok(position(rows, 'demand') < position(rows, 'premier_early'));
  // Neither higher score nor followed demand may cross the explicit time bucket.
  await db.exec("insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth) values('competition','fb_rank_comp_champions_6d',5,'DEEP')");
  assert.ok(position(await ranked(db), 'champions_6d') > position(rows, 'premier_early'));
  const beforeRepeatedInterest = (await ranked(db)).map(r => r.team_id);
  await db.exec(`insert into futbeat_private.temporary_interests(user_id,entity_type,entity_id,expires_at)
    values('00000000-0000-0000-0000-000000000002','team','fb_team_rank_demand',now()+interval '1 hour')`);
  assert.deepEqual((await ranked(db)).map(r => r.team_id), beforeRepeatedInterest);
  assert.equal((await ranked(db)).filter(r => r.team_id === id('demand')).length, 1);
  await db.exec("update futbeat_private.temporary_interests set touched_at=now()-interval '2 hours',expires_at=now()-interval '1 hour'");
  rows = await ranked(db);
  assert.equal(rows.find(r => r.team_id === id('demand')).temporary_demand, false);
  assert.ok(position(rows, 'premier_early') < position(rows, 'demand'));
  // Stale aggregate temporary_users must not revive expired interest.
  await db.exec("insert into futbeat_private.coverage_interests(subject_type,subject_id,temporary_users,depth) values('team','fb_team_rank_demand',999,'TEMPORARY')");
  assert.equal((await ranked(db)).find(r => r.team_id === id('demand')).temporary_demand, false);
}));

test('P2 uses only editorial provenance, conservative missing/derived/provider fallback and no name/country exclusions', async () => fixture(async db => {
  const before = await ranked(db);
  for (const key of ['derived_high', 'provider_high', 'unknown']) {
    assert.equal(before.find(r => r.team_id === id(key)).relevance_score, 100);
    assert.ok(position(before, 'seriea') < position(before, key));
  }
  assert.ok(position(before, 'women_high') < position(before, 'premier_early'));
  assert.ok(position(before, 'u23_high') < position(before, 'premier_early'));
  await db.exec(`alter table futbeat_private.entities disable trigger user;
    update futbeat_private.entities set payload=payload||'{"name":"Women U23 arbitrary","country":"Costa Rica"}';
    alter table futbeat_private.entities enable trigger user;`);
  assert.deepEqual((await ranked(db)).map(r => r.team_id), before.map(r => r.team_id));
}));

test('P0/P1 retain absolute priority, canonical favorite is not duplicated as P2, contract is unchanged', async () => fixture(async db => {
  await db.exec(`insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth)
    values('team','fb_team_rank_low_near',1,'DEEP');
    update futbeat_private.entities set payload=jsonb_set(payload,'{status}','"LIVE"') where id='fb_rank_match_u23_near';`);
  const rows = await plan(db, 25);
  assert.equal(rows[0].teamId, id('u23_near')); assert.equal(rows[0].priorityTier, 0);
  assert.equal(rows[1].teamId, id('low_near')); assert.equal(rows[1].priorityTier, 1);
  assert.equal(rows.filter(r => r.teamId === id('low_near')).length, 1);
  assert.deepEqual(Object.keys(rows[2]).sort(), ['externalTeamId', 'lastFetchedAt', 'priority', 'priorityTier', 'reason', 'teamId']);
}));

test('P2 ignores fetched_at as an extra ranking signal; shared eligibility still excludes fresh/backoff/lease and refills missing mappings', async () => fixture(async db => {
  await db.exec(`insert into futbeat_private.team_detail_coverage(team_id,provider,fetched_at,player_count,next_retry_at,lease_until) values
    ('fb_team_rank_followed','goal_api',now(),1,null,null),
    ('fb_team_rank_champions','goal_api',null,0,now()+interval '1 day',null),
    ('fb_team_rank_women_high','goal_api',null,0,null,now()+interval '10 minutes'),
    ('fb_team_rank_premier_early','goal_api',now()-interval '10 days',1,null,null);
    delete from futbeat_private.provider_entities where canonical_id='fb_team_rank_libertadores';`);
  const rows = await plan(db, 5);
  assert.equal(rows.length, 5);
  for (const key of ['followed', 'champions', 'women_high', 'libertadores']) assert.equal(position(rows, key), -1);
  assert.ok(position(rows, 'premier_early') < position(rows, 'premier_hour'));
  assert.deepEqual(rows.map(r => r.teamId), ['u23_high', 'demand', 'premier_early', 'premier_hour', 'premier_late'].map(id));
  const traced = await tracePools(db, 5);
  assert.ok(traced.raw > 5);
  assert.equal(traced.mappings, 6); // One missing mapping plus the five selected teams.
}));

test('P2 chained team/competition aliases use best match representation and one canonical membership across buckets', async () => fixture(async db => {
  await db.exec(`insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values
    ('fb_team_rank_champions','fb_team_rank_u23_near','team','test'),
    ('fb_team_rank_u23_near','fb_team_rank_low_near','team','test'),
    ('fb_rank_comp_women_near','fb_rank_comp_champions','competition','test');
    insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth)
      values('competition','fb_rank_comp_women_near',1,'DEEP');
    insert into futbeat_private.temporary_interests(user_id,entity_type,entity_id,expires_at)
      values('00000000-0000-0000-0000-000000000003','team','fb_team_rank_champions',now()+interval '1 hour');
    update futbeat_private.provider_entities set last_seen_at=now() where external_id='champions';
    update futbeat_private.entities set payload=jsonb_set(payload,'{homeTeamId}','"fb_team_rank_low_near"') where id='fb_rank_match_champions_6d';`);
  const candidates = await ranked(db);
  const chosen = candidates.find(r => r.team_id === id('low_near'));
  assert.equal(chosen.relevance_score, 970);
  assert.equal(chosen.competition_id, 'fb_rank_comp_champions');
  assert.equal(chosen.time_bucket, 0);
  assert.equal(chosen.followed_competition, true);
  assert.equal(chosen.temporary_demand, true);
  assert.equal(candidates.filter(r => r.team_id === id('low_near')).length, 1);
  assert.equal(candidates.find(r => r.team_id === id('women_near')).relevance_score, 970);
  const rows = await plan(db, 25);
  assert.equal(rows.filter(r => r.teamId === id('low_near')).length, 1);
  assert.equal(rows.find(r => r.teamId === id('low_near')).externalTeamId, 'champions');
  assert.ok(!rows.some(r => [id('champions'), id('u23_near')].includes(r.teamId)));
}));

test('P2 bucket boundaries and existing future/7-day window are unchanged; later buckets progressively fill', async () => fixture(async db => {
  await db.exec('begin');
  try {
    await db.exec(`update futbeat_private.calendar_matches set start_time=now()+interval '24 hours' where match_id='fb_rank_match_champions';
      update futbeat_private.calendar_matches set start_time=now()+interval '24 hours 1 second' where match_id='fb_rank_match_libertadores';
      update futbeat_private.calendar_matches set start_time=now()+interval '72 hours' where match_id='fb_rank_match_laliga';
      update futbeat_private.calendar_matches set start_time=now()+interval '72 hours 1 second' where match_id='fb_rank_match_seriea';
      update futbeat_private.calendar_matches set start_time=now()-interval '1 minute' where match_id='fb_rank_match_low_near';
      update futbeat_private.calendar_matches set start_time=now()+interval '7 days 1 second' where match_id='fb_rank_match_unknown';
      update futbeat_private.calendar_matches set start_time=now()+interval '7 days' where match_id='fb_rank_match_u23_near';`);
    const rows = await ranked(db);
    for (const [key, bucket] of [['champions', 0], ['libertadores', 1], ['laliga', 1], ['seriea', 2], ['u23_near', 2]]) {
      assert.equal(rows.find(r => r.team_id === id(key)).time_bucket, bucket);
    }
    assert.equal(position(rows, 'low_near'), -1); assert.equal(position(rows, 'unknown'), -1);
    const selected = await plan(db, 25);
    assert.deepEqual(selected.filter(r => r.priorityTier === 2).map(r => r.teamId), rows.map(r => r.team_id));
  } finally { await db.exec('rollback'); }
}));

test('P2 10000 candidates keep exactly 20 mapping evaluations and lazy buckets skip later expensive pools', async t => fixture(async db => {
  const all = await ranked(db);
  assert.equal(all.length, 10000);
  const traced = await tracePools(db, 20);
  assert.equal(traced.raw, 20); assert.equal(traced.mappings, 20);
  assert.deepEqual(traced.result.map(r => r.teamId), all.slice(0, 20).map(r => r.team_id));
  assert.ok(traced.trace.every(x => (x.mapping ?? 0) <= 25));
  // Same production source, instrumented ONLY in this disposable database.
  const def = await definition(db, 'futbeat_private.squad_upcoming_candidates(integer)');
  const body = (await db.query("select prosrc from pg_proc where oid='futbeat_private.squad_upcoming_candidates(integer)'::regprocedure")).rows[0].prosrc;
  await db.exec(`create or replace function futbeat_private.squad_upcoming_candidates(p_bucket integer default null)
    returns table(team_id text,competition_id text,followed_competition boolean,relevance_score integer,
    temporary_demand boolean,kickoff timestamptz,time_bucket integer) language plpgsql stable set search_path='' as $$
    #variable_conflict use_column
    begin if p_bucket<>0 then raise exception 'Later bucket must not run'; end if;
    return query select s.* from (${body.trim().replace(/;$/, '')}) s; end $$;`);
  assert.equal((await plan(db)).length, 20);
  await db.exec(def);
  const p = await explain(db, body.trim().replace(/;$/, '').replaceAll('p_bucket', '0'));
  const nodes = planNodes(p.Plan);
  assert.equal(nodes.find(n => n.subplan === 'CTE matches').rows, 1380);
  assert.ok(!nodes.some(n => ['provider_entities', 'provider_observations'].includes(n.relation)));
  assert.ok(nodes.some(n => n.index === 'entities_pkey'));
  assert.ok(!nodes.some(n => n.tempRead > 0 || n.tempWritten > 0));
  t.diagnostic(JSON.stringify({ universe: 10000, matchesRanked: 1380, appearancesRanked: 2760, candidateRowsInspected: traced.raw, mappingEvaluations: traced.mappings }));
}, true));

test('P2 all first-bucket mappings missing still fills from a later bucket without a fixed oversampling cutoff', async () => fixture(async db => {
  await db.exec(`delete from futbeat_private.provider_entities where kind='team' and canonical_id in
    (select team_id from futbeat_private.squad_upcoming_candidates(0));`);
  const rows = await plan(db, 20);
  assert.equal(rows.length, 20);
  const diagnostic = await ranked(db);
  assert.ok(rows.every(row => diagnostic.find(r => r.team_id === row.teamId).time_bucket === 1));
  assert.equal(new Set(rows.map(r => r.teamId)).size, 20);
}, true));

test('P2 helpers remain private and planner is deterministic/read-only with unchanged non-P2 code and limit checks', async () => fixture(async db => {
  const before = (await db.query(`select (select count(*) from futbeat_private.provider_call_ledger) ledger,
    (select count(*) from futbeat_private.team_detail_coverage) coverage,(select count(*) from futbeat_private.provider_entities) mappings`)).rows;
  await db.exec('begin read only');
  const first = await plan(db);
  assert.deepEqual(await plan(db), first);
  await db.exec('commit');
  const after = (await db.query(`select (select count(*) from futbeat_private.provider_call_ledger) ledger,
    (select count(*) from futbeat_private.team_detail_coverage) coverage,(select count(*) from futbeat_private.provider_entities) mappings`)).rows;
  assert.deepEqual(after, before);
  for (const role of ['anon', 'authenticated', 'service_role']) {
    for (const signature of ['futbeat_private.squad_upcoming_candidates(integer)', 'futbeat_private.squad_upcoming_due(text[],integer)']) {
      assert.equal((await db.query('select has_function_privilege($1,$2,\'EXECUTE\') value', [role, signature])).rows[0].value, false);
    }
  }
  await db.exec('set role service_role'); assert.equal((await plan(db, 1)).length, 1); await db.exec('reset role');
  for (const n of [0, 26, null]) await assert.rejects(plan(db, n), /Invalid squad plan limit/);
  const old = (await readFile(new URL('../../supabase/migrations/20260922141448_optimize_squad_candidate_pool.sql', import.meta.url), 'utf8')).replace(/\r\n/g, '\n');
  const current = (await definition(db, 'futbeat_private.futbeat_team_squad_plan(integer)')).replace(/\r\n/g, '\n');
  assert.equal(current.slice(current.indexOf('  if tier=0 then'), current.indexOf('  elsif tier=2 then')),
    old.slice(old.indexOf('  if tier=0 then'), old.indexOf('  elsif tier=2 then')));
  assert.equal(current.slice(current.indexOf('  elsif tier in (3,4) then'), current.indexOf(' return result;')),
    old.slice(old.indexOf('  elsif tier in (3,4) then'), old.indexOf(' return result;', old.indexOf('  elsif tier in (3,4) then'))));
}));
