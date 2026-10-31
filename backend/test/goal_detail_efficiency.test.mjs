import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { openDatabase } from '../storage/database.mjs';

// Turn 244: GOAL detail and squad efficiency (20261031240000). The rules are dormant
// until freshness.detailEfficiency244 is above 0. Real migrations on real SQL, one
// shared database; the ledger is cleared between tests. Generic fixtures only.

let db;
let seq = 0;
const FLAG = (value) => db.query(`update futbeat_private.provider_quota_policy
  set freshness=freshness||jsonb_build_object('detailEfficiency244',$1::int) where provider='goal_api'`, [value]);
const iso = (ms) => new Date(ms).toISOString();
const put = (id, kind, payload) => db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);

before(async () => { db = await openDatabase(); await FLAG(1); });
after(async () => { await db.close(); });

async function clean() {
  await db.query('delete from futbeat_private.live_terminal_recovery');
  await db.query('delete from futbeat_private.provider_call_ledger');
  await db.query('delete from futbeat_private.results_date_user_demand');
  await db.query('delete from futbeat_private.results_date_attempts');
  await db.query('delete from futbeat_private.coverage_interests');
  await db.query('delete from futbeat_private.match_detail_cache');
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,provider_remaining)
    values('goal_api','live-goal','test',now(),now(),'SUCCEEDED',900)`);
}
async function remaining(value) {
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,provider_remaining)
    values('goal_api','live-goal','test',now(),now(),'SUCCEEDED',$1)`, [value]);
}
async function match({ kickoffMinutes = -130, relevance = null, stub = false, status = 'SCHEDULED' } = {}) {
  const n = ++seq;
  const ids = { comp: `fb_comp_e${n}`, home: `fb_team_e${n}h`, away: `fb_team_e${n}a`, match: `fb_match_e${n}`, ext: `eff-${n}` };
  await put(ids.comp, 'competition', { name: `C${n}` });
  await put(ids.home, 'team', { name: `H${n}` });
  await put(ids.away, 'team', { name: `A${n}` });
  await put(ids.match, 'match', stub ? { name: '', country: '', shortName: '' } : {
    competitionId: ids.comp, homeTeamId: ids.home, awayTeamId: ids.away, status,
    startTime: iso(Date.now() + kickoffMinutes * 60e3), events: [], statistics: [],
    provenance: { receivedAt: iso(Date.now() - 3600e3) },
  });
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [ids.ext, ids.match]);
  if (relevance != null) {
    await db.query(`insert into futbeat_private.competition_editorial_metadata(competition_id,relevance_score,source,competition_class)
      values($1,$2,'editorial','other') on conflict(competition_id) do update set relevance_score=excluded.relevance_score,source='editorial'`, [ids.comp, relevance]);
  }
  return ids;
}
const row = async (m, reason = 'absent_from_live', minutes = 0, attempts = 0) => db.query(`insert into futbeat_private.live_terminal_recovery(
    provider,external_match_id,canonical_match_id,reason,state,last_live_status,detected_at,attempts,next_attempt_at)
    values('goal_api',$1,$2,$3,'PENDING','LIVE',now()-make_interval(mins=>$4),$5,now()-interval '1 second')`,
[m.ext, m.match, reason, minutes, attempts]);
const reserve = () => db.query(`select public.futbeat_reserve_terminal_recovery_call('test') v`).then((r) => r.rows[0].v);
const state = (m) => db.query('select state,resolution,attempts from futbeat_private.live_terminal_recovery where external_match_id=$1', [m.ext]).then((r) => r.rows[0]);
const due = (m, bucket) => db.query('select futbeat_private.match_detail_planner_due($1,$2) v', [m.match, bucket]).then((r) => r.rows[0].v);
const cache = (m, status, fetchedMinutes) => db.query(`insert into futbeat_private.match_detail_cache(match_id,provider,external_match_id,fetched_at,payload)
  values($1,'goal_api',$2,now()-make_interval(mins=>$3),$4) on conflict(match_id) do update set fetched_at=excluded.fetched_at,payload=excluded.payload`,
[m.match, m.ext, fetchedMinutes, JSON.stringify({ matchStatus: status })]);

test('dormant by default: the flag off keeps the old rules', async () => {
  await clean(); await FLAG(0);
  try {
    const stub = await match({ stub: true });
    await row(stub);
    const low = await match();
    await row(low);
    const first = await reserve();
    assert.equal(first.allowed, true, JSON.stringify(first));
    await db.query('select public.futbeat_complete_terminal_recovery($1,$2)', [first.externalMatchId, 'FINISHED']);
    const stubRow = await state(stub);
    assert.equal(stubRow.state, 'PENDING');
    assert.equal((await db.query("select futbeat_private.team_squad_ttl('fb_team_x')::text v")).rows[0].v, '7 days');
  } finally { await FLAG(1); }
});

test('a provider final ends the row, also on a stub, with no second attempt', async () => {
  await clean();
  const m = await match({ relevance: 900 });
  await row(m);
  assert.equal((await reserve()).matchId, m.match);
  const done = (await db.query('select public.futbeat_complete_terminal_recovery($1,$2) v', [m.ext, 'AFTER_PEN'])).rows[0].v;
  assert.equal(done.state, 'RESOLVED');
  assert.equal((await reserve()).reason, 'no_recovery_due');
});

test('a stub match spends no recovery call', async () => {
  await clean();
  const m = await match({ stub: true });
  await row(m);
  assert.equal((await reserve()).reason, 'no_recovery_due');
  assert.deepEqual(await state(m), { state: 'EXHAUSTED', resolution: 'no_read_model', attempts: 0 });
});

test('low priority waits for the results batch; priority does not', async () => {
  await clean();
  const low = await match({ relevance: 100 });
  const top = await match({ relevance: 900 });
  await row(low);
  await row(top);
  assert.equal((await reserve()).matchId, top.match);
  assert.equal((await reserve()).reason, 'no_recovery_due');
  // Still open past the delay: one detail call as the fallback, never a second.
  await db.query(`update futbeat_private.live_terminal_recovery set detected_at=now()-interval '46 minutes' where external_match_id=$1`, [low.ext]);
  assert.equal((await reserve()).matchId, low.match);
  await db.query(`update futbeat_private.live_terminal_recovery set next_attempt_at=now()-interval '1 second' where external_match_id=$1`, [low.ext]);
  assert.equal((await reserve()).reason, 'no_recovery_due');
});

test('a followed team makes a low relevance match priority, also through an alias', async () => {
  await clean();
  const m = await match({ relevance: 100 });
  await db.query("insert into futbeat_private.entities values('fb_team_alias_target','team','{\"id\":\"fb_team_alias_target\"}')");
  await db.query("insert into futbeat_private.entity_redirects(kind,alias_id,canonical_id,reason) values('team',$1,'fb_team_alias_target','test')", [m.home]);
  assert.equal((await db.query('select futbeat_private.match_detail_is_priority($1) v', [m.match])).rows[0].v, false);
  await db.query("insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth) values('team','fb_team_alias_target',1,'DEEP')");
  assert.equal((await db.query('select futbeat_private.match_detail_is_priority($1) v', [m.match])).rows[0].v, true);
});

test('overdue rows stop at three calls and keep the absence path open', async () => {
  await clean();
  const m = await match({ relevance: 900 });
  await row(m, 'overdue_live', 0, 2);
  const third = await reserve();
  assert.equal(third.allowed, true);
  const next = (await db.query('select extract(epoch from next_attempt_at-now())/60 v from futbeat_private.live_terminal_recovery where external_match_id=$1', [m.ext])).rows[0].v;
  assert.ok(next > 29 && next <= 30, `${next}`);
  await db.query(`select futbeat_private.settle_terminal_recovery()`);
  assert.equal((await state(m)).state, 'EXHAUSTED');
});

test('three waiting finals lift the date backoff for one results call', async () => {
  await clean();
  const rows = [await match(), await match(), await match()];
  for (const m of rows) await row(m, 'absent_from_live', 12);
  const date = (await db.query('select futbeat_private.match_provider_date($1) d', [rows[0].match])).rows[0].d;
  await db.query(`insert into futbeat_private.results_date_attempts(provider,provider_date,last_attempt_at,attempt_count,last_outcome,next_retry_at,updated_at)
    values('goal_api',$1,now()-interval '40 minutes',1,'SUCCEEDED',now()+interval '80 minutes',now()-interval '40 minutes')`, [date]);
  await db.query(`insert into futbeat_private.results_date_user_demand(provider,provider_date,requested_at,request_count)
    values('goal_api',$1,now()-interval '31 minutes',1)`, [date]);
  await db.query('select futbeat_private.settle_terminal_recovery()');
  const a = (await db.query("select next_retry_at<=now() due from futbeat_private.results_date_attempts where provider='goal_api' and provider_date=$1", [date])).rows[0];
  assert.equal(a.due, true);
  const d = (await db.query("select requested_at>now()-interval '1 minute' fresh from futbeat_private.results_date_user_demand where provider='goal_api' and provider_date=$1", [date])).rows[0];
  assert.equal(d.fresh, true);
});

test('a lone waiting final keeps the date backoff', async () => {
  await clean();
  const m = await match();
  await row(m, 'absent_from_live', 12);
  const date = (await db.query('select futbeat_private.match_provider_date($1) d', [m.match])).rows[0].d;
  await db.query(`insert into futbeat_private.results_date_attempts(provider,provider_date,last_attempt_at,attempt_count,last_outcome,next_retry_at,updated_at)
    values('goal_api',$1,now()-interval '40 minutes',1,'SUCCEEDED',now()+interval '80 minutes',now()-interval '40 minutes')`, [date]);
  await db.query('select futbeat_private.settle_terminal_recovery()');
  const a = (await db.query("select next_retry_at>now() held from futbeat_private.results_date_attempts where provider='goal_api' and provider_date=$1", [date])).rows[0];
  assert.equal(a.held, true);
});

test('planner: low priority gets one fetch, only on abundant quota', async () => {
  await clean();
  const m = await match({ relevance: 100, kickoffMinutes: -130 });
  assert.equal(await due(m, 'results'), true);
  await remaining(500);
  assert.equal(await due(m, 'results'), false);
  await remaining(900);
  await cache(m, 'FINISHED', 60);
  assert.equal(await due(m, 'recent_hot'), false);
  for (const bucket of ['upcoming', 'prematch']) {
    const n = await match({ relevance: 100, kickoffMinutes: 60 });
    assert.equal(await due(n, bucket), false);
  }
});

test('planner: a cached final only leaves the final capture', async () => {
  await clean();
  const m = await match({ relevance: 900, kickoffMinutes: -100 });
  await cache(m, 'FINISHED', 40);
  assert.equal(await due(m, 'results'), false, 'before the capture time');
  const n = await match({ relevance: 900, kickoffMinutes: -130 });
  await cache(n, 'FINISHED', 40);
  assert.equal(await due(n, 'results'), true, 'taken before kickoff + 120');
  const fresh = await match({ relevance: 900, kickoffMinutes: -130 });
  await cache(fresh, 'FINISHED', 5);
  assert.equal(await due(fresh, 'results'), false, 'already the capture');
  const live = await match({ relevance: 900, kickoffMinutes: -130 });
  await cache(live, 'LIVE', 40);
  assert.equal(await due(live, 'results'), true, 'a cache that is not final still refreshes');
});

test('squads: 21 days for unfollowed teams, 7 for followed; pace leaves followed teams', async () => {
  await clean();
  const m = await match();
  const ttl = (id) => db.query('select futbeat_private.team_squad_ttl($1)::text v', [id]).then((r) => r.rows[0].v);
  assert.equal(await ttl(m.home), '21 days');
  await db.query("insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth) values('team',$1,1,'DEEP')", [m.home]);
  assert.equal(await ttl(m.home), '7 days');
  await db.query(`insert into futbeat_private.team_detail_coverage(team_id,provider,fetched_at,player_count)
    values($1,'goal_api',now()-interval '10 days',20) on conflict(team_id) do update set fetched_at=excluded.fetched_at`, [m.away]);
  const pool = (id) => db.query("select jsonb_array_length(futbeat_private.squad_pool_due(array[$1],array[]::text[],1)) n", [id]).then((r) => r.rows[0].n);
  assert.equal(await pool(m.away), 0, 'ten days old, not due yet');
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status)
    select 'goal_api','team-squad','test',now(),now(),'SUCCEEDED' from generate_series(1,25)`);
  const body = (await db.query("select pg_get_functiondef('futbeat_private.futbeat_team_squad_plan(integer)'::regprocedure) d")).rows[0].d;
  assert.match(body, /continue when v_paced and tier not in \(1,6\)/);
});

test('a user open is never gated: the reservation body is untouched', async () => {
  const sql = await import('node:fs/promises').then((fs) => fs.readFile(
    new URL('../../supabase/migrations/20261031240000_goal_detail_efficiency.sql', import.meta.url), 'utf8'));
  assert.doesNotMatch(sql, /function futbeat_private\.reserve_match_detail_call/i);
  assert.doesNotMatch(sql, /function futbeat_private\.match_detail_needs_fetch/i);
  assert.doesNotMatch(sql, /update futbeat_private\.provider_quota_policy/);
  assert.doesNotMatch(sql, /cron\.schedule/);
});
