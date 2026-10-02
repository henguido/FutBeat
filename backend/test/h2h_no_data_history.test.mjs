import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import * as matchDetail from '../../supabase/functions/_shared/match_detail.ts';
import * as calendarCache from '../../supabase/functions/_shared/calendar_cache.ts';

// #155 review: a mapped team whose initial window was confirmed EMPTY
// (NO_DATA, no covered range) can still ask for older history, explicitly,
// deduplicated, within the floor, the team-fixtures quota and the backoff.
// NO_DATA keeps meaning "nothing in THAT window". Synthetic ids only; the
// worker is simulated through its SQL steps (plan -> reserve -> complete);
// no provider is ever called.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

let seq = 0;
async function team(db, { mapped = true } = {}) {
  const id = `fb_team_nd${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'team',$2)", [id, JSON.stringify({ id, name: `Selección ND ${seq}` })]);
  if (mapped) {
    await db.query("insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) values('goal_api','team',$1,$2)",
      [`nd-ext-${seq}`, id]);
  }
  return id;
}
async function pair(db, home, away) {
  const comp = `fb_comp_nd${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)", [comp, JSON.stringify({ id: comp, name: 'Copa ND' })]);
  const id = `fb_match_nd${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [id, JSON.stringify({
    id, competitionId: comp, homeTeamId: home, awayTeamId: away,
    startTime: new Date(Date.now() + 3 * 86400e3).toISOString(), status: 'SCHEDULED', events: [], statistics: [] })]);
  return id;
}
const fn = async (db, name, args) => {
  const entries = Object.entries(args);
  const sql = `select public.${name}(${entries.map(([k], i) => `${k}=>$${i + 1}`).join(',')}) v`;
  return (await db.query(sql, entries.map(([, v]) => v))).rows[0].v;
};
const sqlDate = async (db, offset) => (await db.query('select (current_date+$1::integer)::text d', [offset])).rows[0].d;
const read = (db, id) => fn(db, 'futbeat_read_match_h2h', { p_match_id: id, p_scope: 'all', p_cursor: null, p_limit: 20 });
const extend = (db, id) => fn(db, 'futbeat_request_match_h2h_history', { p_match_id: id });
const plan = (db) => fn(db, 'futbeat_team_fixtures_plan', { p_limit: 10 });
const state = (db, id) => db.query('select futbeat_private.team_match_coverage_state($1) v', [id]).then((r) => r.rows[0].v);
const demands = (db) => db.query('select team_id,past_target::text,reason from futbeat_private.team_match_demands order by team_id').then((r) => r.rows);
const fixtureCalls = (db) => db.query("select count(*)::int n from futbeat_private.provider_call_ledger where call_kind='team-fixtures'").then((r) => r.rows[0].n);
const extOf = (db, id) => db.query("select external_id from futbeat_private.provider_entities where canonical_id=$1", [id]).then((r) => r.rows[0].external_id);
async function quotaOk(db) {
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,completed_at,provider_remaining)
    values('goal_api','live-goal','test','SUCCEEDED',now(),900)`);
}

/** The worker, simulated: plan -> reserve page 0 -> complete with `received` fixtures. */
async function runWorker(db, teamId, { received = 0 } = {}) {
  const item = (await plan(db)).find((x) => x.teamId === teamId);
  assert.ok(item, `planned: ${teamId}`);
  const reservation = await fn(db, 'futbeat_reserve_goal_team_fixtures_call',
    { p_team_id: teamId, p_external_team_id: await extOf(db, teamId), p_page: 0, p_trigger_source: 'test' });
  assert.equal(reservation.allowed, true, JSON.stringify(reservation));
  await fn(db, 'futbeat_complete_team_fixtures', { p_team_id: teamId, p_from: item.from, p_to: item.to,
    p_complete: true, p_raw: received, p_received: received, p_new: received, p_existing: 0 });
  return item;
}
/** Initial window answered complete and EMPTY: NO_DATA, no covered range. */
async function initialNoData(db, teamId) {
  await fn(db, 'futbeat_request_team_matches', { p_team_id: teamId, p_before: null });
  const item = await runWorker(db, teamId);
  assert.equal(item.mode, 'window');
  const st = await state(db, teamId);
  assert.equal(st.state, 'NO_DATA');
  assert.equal(st.coveredFrom, undefined, 'never promoted to a covered range');
  // Old demand consumed: clear it so the test sees only new ones.
  await db.query('delete from futbeat_private.team_match_demands where team_id=$1', [teamId]);
  return st;
}
async function covered(db, teamId, daysBack) {
  await db.query(`insert into futbeat_private.team_match_coverage(team_id,status,covered_from,covered_to,window_complete,last_success_at)
    values($1,'AVAILABLE',current_date-$2::integer,current_date+120,true,now())`, [teamId, daysBack]);
}

// ---------------------------------------------------------------------------

test('1. mapped team, initial NO_DATA, no coveredFrom: H2H asks for the first older window', () => withDb(async (db) => {
  await quotaOk(db);
  const A = await team(db); const B = await team(db);
  await covered(db, B, 180);
  const target = await pair(db, A, B);
  const st = await initialNoData(db, A);
  assert.equal(st.emptyFrom, await sqlDate(db, -180));
  const w = (await read(db, target)).window;
  assert.equal(w.canExtend, true);
  assert.equal(w.verifiedFrom, await sqlDate(db, -180), 'confirmed-empty start counts as verified');
  const r = await extend(db, target);
  assert.equal(r.home.demandRecorded, true);
  assert.equal(r.home.backfill, true);
  const d = (await demands(db)).find((x) => x.team_id === A);
  assert.equal(d.past_target, await sqlDate(db, -360));
  assert.equal(d.reason, 'history');
  // The 14-day negative cache of the initial window does not block the OLDER one.
  const item = (await plan(db)).find((x) => x.teamId === A);
  assert.deepEqual([item.mode, item.from, item.to], ['history', await sqlDate(db, -360), await sqlDate(db, -180)]);
  // Still NO_DATA: nothing was converted to AVAILABLE.
  assert.equal((await state(db, A)).state, 'NO_DATA');
}));

test('2. two NO_DATA teams: at most one valid demand per team', () => withDb(async (db) => {
  await quotaOk(db);
  const A = await team(db); const B = await team(db);
  const target = await pair(db, A, B);
  await initialNoData(db, A); await initialNoData(db, B);
  assert.equal((await read(db, target)).window.canExtend, true);
  await extend(db, target);
  const rows = await demands(db);
  assert.deepEqual(rows.map((x) => x.team_id).sort(), [A, B].sort());
  assert.ok(rows.every((x) => x.reason === 'history' && x.past_target !== null));
  const planned = await plan(db);
  assert.deepEqual(planned.filter((x) => [A, B].includes(x.teamId)).map((x) => x.mode), ['history', 'history']);
}));

test('3. repeated extend never duplicates nor skips steps', () => withDb(async (db) => {
  await quotaOk(db);
  const A = await team(db); const B = await team(db);
  const target = await pair(db, A, B);
  await initialNoData(db, A); await initialNoData(db, B);
  await extend(db, target);
  const first = await demands(db);
  for (let i = 0; i < 20; i++) {
    const r = await extend(db, target);
    assert.equal(r.requested, false, 'a step already in flight');
  }
  await db.query("update futbeat_private.team_match_demands set requested_at=requested_at-interval '5 minutes'");
  for (let i = 0; i < 5; i++) await extend(db, target);
  assert.deepEqual((await demands(db)).map((x) => [x.team_id, x.past_target]), first.map((x) => [x.team_id, x.past_target]));
  assert.equal((await read(db, target)).window.extending, true);
}));

test('4. NO_DATA without a provider mapping can never extend', () => withDb(async (db) => {
  const X = await team(db, { mapped: false }); const Y = await team(db, { mapped: false });
  // Even with a stored confirmed-empty range, no source = UNAVAILABLE.
  for (const t of [X, Y]) {
    await db.query(`insert into futbeat_private.team_match_coverage(team_id,status,empty_from,empty_to,next_retry_at,last_attempt_at)
      values($1,'NO_DATA',current_date-180,current_date+120,now()+interval '14 days',now()-interval '1 hour')`, [t]);
  }
  const target = await pair(db, X, Y);
  assert.equal((await state(db, X)).state, 'UNAVAILABLE');
  assert.equal((await read(db, target)).window.canExtend, false);
  assert.equal((await extend(db, target)).requested, false);
  assert.deepEqual(await demands(db), []);
  assert.deepEqual(await plan(db), []);
}));

test('5. the history floor is never passed', () => withDb(async (db) => {
  await quotaOk(db);
  const A = await team(db); const B = await team(db);
  const target = await pair(db, A, B);
  await initialNoData(db, A); await initialNoData(db, B);
  // Confirmed empty down to 1000 days: one last step, clamped at the floor.
  await db.query("update futbeat_private.team_match_coverage set empty_from=current_date-1000 where team_id=$1", [A]);
  await db.query("update futbeat_private.team_match_coverage set empty_from=current_date-1095 where team_id=$1", [B]);
  const r = await extend(db, target);
  assert.equal(r.away.demandRecorded, false, 'B is at the floor');
  const d = await demands(db);
  assert.deepEqual(d.map((x) => [x.team_id, x.past_target]), [[A, await sqlDate(db, -1095)]]);
  // Once A is also at the floor, nothing more can be asked.
  await runWorker(db, A);
  assert.equal((await state(db, A)).emptyFrom, await sqlDate(db, -1095));
  assert.equal((await read(db, target)).window.canExtend, false);
  assert.equal((await extend(db, target)).requested, false);
}));

test('6. an empty historical backfill advances the window and another step can follow', () => withDb(async (db) => {
  await quotaOk(db);
  const A = await team(db); const C = await team(db);
  await covered(db, C, 180);
  const target = await pair(db, A, C);
  await initialNoData(db, A);
  await extend(db, target);
  // A: the older window is empty too -> still NO_DATA, confirmed empty since -360.
  const itemA = await runWorker(db, A);
  assert.equal(itemA.mode, 'history');
  let st = await state(db, A);
  assert.equal(st.state, 'NO_DATA');
  assert.equal(st.emptyFrom, await sqlDate(db, -360));
  // C (AVAILABLE): its older window was empty -> covered range extended.
  await runWorker(db, C);
  assert.equal((await state(db, C)).coveredFrom, await sqlDate(db, -360));
  let w = (await read(db, target)).window;
  assert.equal(w.extending, false);
  assert.equal(w.canExtend, true);
  assert.equal(w.verifiedFrom, await sqlDate(db, -360));
  // Next step: both teams, past the 14-day negative cache of the empty answers.
  await db.query("update futbeat_private.team_match_demands set requested_at=requested_at-interval '5 minutes'");
  await extend(db, target);
  const planned = await plan(db);
  assert.deepEqual(planned.map((x) => [x.teamId, x.mode, x.from, x.to]).sort(), [
    [A, 'history', await sqlDate(db, -540), await sqlDate(db, -360)],
    [C, 'history', await sqlDate(db, -540), await sqlDate(db, -360)],
  ].sort());
  // A's older window finally has fixtures: AVAILABLE with the whole verified
  // range (history + the confirmed-empty windows).
  await runWorker(db, A, { received: 2 });
  st = await state(db, A);
  assert.equal(st.coveredFrom, await sqlDate(db, -540));
  assert.equal(st.coveredTo, await sqlDate(db, 120));
  assert.equal(st.emptyFrom, undefined);
}));

test('7. quota/planner: central team-fixtures lane only; reads and extend make zero provider reservations; failures keep their backoff', () => withDb(async (db) => {
  const A = await team(db); const B = await team(db);
  const target = await pair(db, A, B);
  await quotaOk(db);
  await initialNoData(db, A); await initialNoData(db, B);
  const reserved = await fixtureCalls(db);
  // Read + extend + API: no reservation, no provider call.
  await read(db, target); await extend(db, target);
  const source = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  const ctx = { supabaseAdmin: { rpc: async (name, args) => {
    const keys = Object.keys(args ?? {});
    try {
      return { data: (await db.query(`select public.${name}(${keys.map((k, i) => `${k}=>$${i + 1}`).join(',')}) v`, keys.map((k) => args[k]))).rows[0]?.v ?? null, error: null };
    } catch (error) { return { data: null, error: { message: error.message } }; }
  } } };
  const context = vm.createContext({ Request, Response, URL, JSON, setTimeout, clearTimeout, console: { warn() {}, error() {}, log() {} },
    withSupabase: (_o, h) => (req) => h(req, ctx), ...matchDetail, ...calendarCache });
  vm.runInContext(stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, '')).replace('export default {', 'globalThis.__api = {'), context);
  const res = await context.__api.fetch(new Request(`https://api.test/functions/v1/futbeat-api/v1/match-h2h?id=${target}&extend=1`));
  assert.equal(res.status, 200);
  assert.equal(await fixtureCalls(db), reserved, 'read/API never reserve provider quota');
  // The worker reservation goes through the central team-fixtures quota.
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at)
    select 'goal_api','team-fixtures','test',now() from generate_series(1,80)`);
  const denied = await fn(db, 'futbeat_reserve_goal_team_fixtures_call',
    { p_team_id: A, p_external_team_id: await extOf(db, A), p_page: 0, p_trigger_source: 'test' });
  assert.equal(denied.allowed, false, 'the daily team-fixtures cap still applies');
  // A FAILED history step (real failure path) keeps its backoff: a history
  // demand never passes it, and the confirmed-empty range stays NO_DATA.
  // Drop only the 80 synthetic cap-fillers (no teamId) to free the quota.
  await db.query("delete from futbeat_private.provider_call_ledger where call_kind='team-fixtures' and not (coalesce(metadata,'{}'::jsonb) ? 'teamId')");
  const reservedB = await fn(db, 'futbeat_reserve_goal_team_fixtures_call',
    { p_team_id: B, p_external_team_id: await extOf(db, B), p_page: 0, p_trigger_source: 'test' });
  assert.equal(reservedB.allowed, true);
  await fn(db, 'futbeat_fail_team_fixtures', { p_team_id: B, p_reason: 'HTTP_500', p_http_statuses: [500] });
  // Unknown outcome: never reported as NO_DATA; no offer during the backoff.
  const stB = await state(db, B);
  assert.equal(stB.state, 'PENDING');
  assert.equal(stB.reason, 'retrying');
  assert.equal((await read(db, target)).window.canExtend, true, 'A (still NO_DATA) can extend');
  const rowB = (await db.query('select empty_from::text e from futbeat_private.team_match_coverage where team_id=$1', [B])).rows[0];
  assert.equal(rowB.e, await sqlDate(db, -180), 'the confirmed range is kept in the row');
  await db.query("update futbeat_private.team_match_demands set requested_at=now() where team_id=$1", [B]);
  assert.ok(!(await plan(db)).some((x) => x.teamId === B), 'failure backoff respected');
  // Once the window is confirmed empty again, the stored range comes back.
  await db.query("update futbeat_private.team_match_coverage set next_retry_at=now()-interval '1 minute' where team_id=$1", [B]);
  await runWorker(db, B);
  assert.equal((await state(db, B)).state, 'NO_DATA');
  // The refresh also covered the pending older target (window from -360).
  assert.equal((await state(db, B)).emptyFrom, await sqlDate(db, -360));
}));

test('8. while a NO_DATA step is being fetched the pair is extending; a partial step keeps NO_DATA; the demand wakes the worker', () => withDb(async (db) => {
  await quotaOk(db);
  const A = await team(db); const B = await team(db);
  const target = await pair(db, A, B);
  await initialNoData(db, A); await initialNoData(db, B);
  const r = await extend(db, target);
  assert.ok(r.home.wake, 'a NO_DATA history demand wakes the team-fixtures lane');
  const item = (await plan(db)).find((x) => x.teamId === A);
  const reservation = await fn(db, 'futbeat_reserve_goal_team_fixtures_call',
    { p_team_id: A, p_external_team_id: await extOf(db, A), p_page: 0, p_trigger_source: 'test' });
  assert.equal(reservation.allowed, true);
  assert.equal((await read(db, target)).window.extending, true, 'leased step = still extending');
  // Partial answer (not every identity answered): unknown -> retrying, never
  // NO_DATA; the older window is NOT confirmed; no offer meanwhile.
  await fn(db, 'futbeat_complete_team_fixtures', { p_team_id: A, p_from: item.from, p_to: item.to,
    p_complete: false, p_raw: 0, p_received: 0, p_new: 0, p_existing: 0 });
  const st = await state(db, A);
  assert.equal(st.state, 'PENDING');
  const rowA = (await db.query('select empty_from::text e from futbeat_private.team_match_coverage where team_id=$1', [A])).rows[0];
  assert.equal(rowA.e, await sqlDate(db, -180), 'the older window was NOT confirmed');
}));
