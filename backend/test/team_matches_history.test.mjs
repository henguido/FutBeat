import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import * as matchDetail from '../../supabase/functions/_shared/match_detail.ts';
import * as calendarCache from '../../supabase/functions/_shared/calendar_cache.ts';

// #164 x #163: the end of an UNFILTERED Resultados list asks centrally for
// the older window, also for a team whose recent window was confirmed EMPTY
// (NO_DATA + emptyFrom, no stored result). Only a demand is recorded; the
// worker is simulated through its SQL steps; no provider is ever called.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

let seq = 0;
async function team(db, { mapped = true } = {}) {
  const id = `fb_team_tmh${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'team',$2)", [id, JSON.stringify({ id, name: `Selección TMH ${seq}` })]);
  if (mapped) {
    await db.query("insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) values('goal_api','team',$1,$2)",
      [`tmh-ext-${seq}`, id]);
  }
  return id;
}
async function competition(db) {
  const id = `fb_comp_tmh${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)", [id, JSON.stringify({ id, name: `Copa TMH ${seq}`, season: '2026' })]);
  return id;
}
async function match(db, { comp, home, away, daysAgo, season = '2026' }) {
  const id = `fb_match_tmh${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [id, JSON.stringify({
    id, competitionId: comp, homeTeamId: home, awayTeamId: away, season,
    startTime: new Date(Date.now() - daysAgo * 86400e3).toISOString(), status: 'VERIFIED',
    score: { home: 1, away: 0 }, events: [], statistics: [] })]);
  return id;
}
const fn = async (db, name, args) => {
  const entries = Object.entries(args);
  const sql = `select public.${name}(${entries.map(([k], i) => `${k}=>$${i + 1}`).join(',')}) v`;
  return (await db.query(sql, entries.map(([, v]) => v))).rows[0].v;
};
const sqlDate = async (db, offset) => (await db.query('select (current_date+$1::integer)::text d', [offset])).rows[0].d;
const demands = (db) => db.query('select team_id,past_target::text,reason from futbeat_private.team_match_demands order by team_id').then((r) => r.rows);
const fixtureCalls = (db) => db.query("select count(*)::int n from futbeat_private.provider_call_ledger where call_kind='team-fixtures'").then((r) => r.rows[0].n);
const extOf = (db, id) => db.query('select external_id from futbeat_private.provider_entities where canonical_id=$1', [id]).then((r) => r.rows[0].external_id);
async function quotaOk(db) {
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,completed_at,provider_remaining)
    values('goal_api','live-goal','test','SUCCEEDED',now(),900)`);
}
/** Initial window answered complete and EMPTY (worker simulated): NO_DATA. */
async function initialNoData(db, teamId) {
  await fn(db, 'futbeat_request_team_matches', { p_team_id: teamId, p_before: null });
  const item = (await fn(db, 'futbeat_team_fixtures_plan', { p_limit: 10 })).find((x) => x.teamId === teamId);
  const reservation = await fn(db, 'futbeat_reserve_goal_team_fixtures_call',
    { p_team_id: teamId, p_external_team_id: await extOf(db, teamId), p_page: 0, p_trigger_source: 'test' });
  assert.equal(reservation.allowed, true);
  await fn(db, 'futbeat_complete_team_fixtures', { p_team_id: teamId, p_from: item.from, p_to: item.to,
    p_complete: true, p_raw: 0, p_received: 0, p_new: 0, p_existing: 0 });
  await db.query('delete from futbeat_private.team_match_demands where team_id=$1', [teamId]);
}

async function api(db) {
  const source = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  const rpcs = [];
  const ctx = { supabaseAdmin: { rpc: async (name, args) => {
    if (name !== 'futbeat_read_national_teams') rpcs.push({ name, args });
    const keys = Object.keys(args ?? {});
    try {
      const v = (await db.query(`select public.${name}(${keys.map((k, i) => `${k}=>$${i + 1}`).join(',')}) v`, keys.map((k) => args[k]))).rows[0]?.v;
      return { data: v ?? null, error: null };
    } catch (error) { return { data: null, error: { message: error.message } }; }
  } } };
  const context = vm.createContext({
    Request, Response, URL, JSON, console: { warn: () => {}, error: () => {}, log: () => {} },
    withSupabase: (_opts, handler) => (request) => handler(request, ctx),
    ...matchDetail, ...calendarCache,
  });
  vm.runInContext(stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''))
    .replace('export default {', 'globalThis.__api = {'), context);
  const call = async (query) => {
    const response = await context.__api.fetch(new Request(`https://api.test/functions/v1/futbeat-api/v1/team-matches${query}`));
    return { status: response.status, body: await response.json(), cache: response.headers.get('cache-control') };
  };
  const history = () => rpcs.filter((r) => r.name === 'futbeat_request_team_matches');
  return { call, rpcs, history };
}

// ---------------------------------------------------------------------------

test('A. NO_DATA + emptyFrom + no stored result: one history demand with p_before=emptyFrom', () => withDb(async (db) => {
  await quotaOk(db);
  const T = await team(db);
  await initialNoData(db, T);
  const { call, history } = await api(db);
  const r = await call(`?id=${T}&bucket=results`);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.matches, []);
  assert.equal(r.body.coverage.teamMatches.state, 'NO_DATA');
  assert.deepEqual(history().map((x) => x.args.p_before), [await sqlDate(db, -180)]);
  const d = await demands(db);
  assert.deepEqual(d.map((x) => [x.team_id, x.past_target, x.reason]), [[T, await sqlDate(db, -360), 'history']]);
  // The app is told the list may still grow; never a cached "no results".
  assert.equal(r.body.coverage.teamMatches.history, 'requested');
  assert.equal(r.cache, 'no-store');
}));

test('B. repeated reads never duplicate the demand nor skip windows', () => withDb(async (db) => {
  await quotaOk(db);
  const T = await team(db);
  await initialNoData(db, T);
  const { call } = await api(db);
  for (let i = 0; i < 10; i++) await call(`?id=${T}&bucket=results`);
  await db.query("update futbeat_private.team_match_demands set requested_at=requested_at-interval '5 minutes'");
  for (let i = 0; i < 5; i++) await call(`?id=${T}&bucket=results`);
  const d = await demands(db);
  assert.equal(d.length, 1);
  assert.equal(d[0].past_target, await sqlDate(db, -360), 'one step back only (never -540 without an answer)');
}));

test('C. NO_DATA without a provider mapping never progresses', () => withDb(async (db) => {
  const T = await team(db, { mapped: false });
  await db.query(`insert into futbeat_private.team_match_coverage(team_id,status,empty_from,empty_to,next_retry_at,last_attempt_at)
    values($1,'NO_DATA',current_date-180,current_date+120,now()+interval '14 days',now()-interval '1 hour')`, [T]);
  const { call, history } = await api(db);
  const r = await call(`?id=${T}&bucket=results`);
  assert.equal(r.body.coverage.teamMatches.state, 'UNAVAILABLE');
  assert.deepEqual(history(), []);
  assert.deepEqual(await demands(db), []);
  assert.equal(r.body.coverage.teamMatches.history, undefined);
}));

test('D. an empty FILTERED list (competition/season) never asks for global history', () => withDb(async (db) => {
  await quotaOk(db);
  const T = await team(db);
  await initialNoData(db, T);
  const comp = await competition(db);
  const { call, history } = await api(db);
  const r = await call(`?id=${T}&bucket=results&competitionId=${comp}&season=2026`);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.matches, []);
  assert.deepEqual(history(), []);
  assert.deepEqual(await demands(db), []);
}));

test('E. with stored results: the oldest result date, as before', () => withDb(async (db) => {
  const T = await team(db); const R = await team(db);
  const comp = await competition(db);
  await match(db, { comp, home: T, away: R, daysAgo: 10 });
  const oldest = await match(db, { comp, home: R, away: T, daysAgo: 40 });
  await db.query(`insert into futbeat_private.team_match_coverage(team_id,status,covered_from,covered_to,window_complete,last_success_at)
    values($1,'AVAILABLE',current_date-50,current_date+120,true,now())`, [T]);
  const { call, history } = await api(db);
  const r = await call(`?id=${T}&bucket=results`);
  assert.equal(r.body.matches.at(-1).id, oldest);
  assert.deepEqual(history().map((x) => x.args.p_before), [r.body.matches.at(-1).startTime.slice(0, 10)]);
}));

test('F. the history floor is never passed', () => withDb(async (db) => {
  await quotaOk(db);
  const T = await team(db);
  await initialNoData(db, T);
  await db.query('update futbeat_private.team_match_coverage set empty_from=current_date-1095 where team_id=$1', [T]);
  const { call, history } = await api(db);
  const r = await call(`?id=${T}&bucket=results`);
  assert.equal(history().length, 1, 'asked through the central request');
  assert.deepEqual(await demands(db), [], 'at the floor: nothing recorded');
  assert.equal(r.body.coverage.teamMatches.history, undefined, 'final: no "loading" claim');
  assert.match(r.cache, /max-age/);
}));

test('G. API reads make zero provider reservations', () => withDb(async (db) => {
  await quotaOk(db);
  const T = await team(db);
  await initialNoData(db, T);
  const before = await fixtureCalls(db);
  const { call } = await api(db);
  for (const bucket of ['live', 'upcoming', 'results']) await call(`?id=${T}&bucket=${bucket}`);
  assert.equal(await fixtureCalls(db), before);
}));
