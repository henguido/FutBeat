import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import * as matchDetail from '../../supabase/functions/_shared/match_detail.ts';
import * as calendarCache from '../../supabase/functions/_shared/calendar_cache.ts';

// Team profile first paint: /v1/entity answers in the time of its slowest RPC
// (demands and the stored read run concurrently) and the stored read never
// scans the whole catalog. Synthetic data only; no provider is ever called.

const stored = (extra = {}) => ({
  schemaVersion: 1, demo: false, updatedAt: new Date().toISOString(),
  coverage: { source: 'FutBeat' }, competitions: [], teams: [], players: [],
  matches: [], standings: [], ...extra,
});

/**
 * The API with a fake Supabase client. Every RPC waits until [expected] RPCs
 * have STARTED: a handler that awaited them one after another would never
 * get there (and the request would time out).
 */
async function concurrentApi(expected, answers) {
  const source = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  const started = [];
  let release;
  const allStarted = new Promise((resolve) => { release = resolve; });
  const ctx = { supabaseAdmin: { rpc: (name, args) => {
    // The shared national-team map is not one of the request's own reads.
    if (name === 'futbeat_read_national_teams') return Promise.resolve({ data: null, error: null });
    started.push({ name, args });
    if (started.length === expected) release();
    return allStarted.then(() => answers[name]?.() ?? { data: null, error: null });
  } } };
  const context = vm.createContext({
    Request, Response, URL, JSON, setTimeout, clearTimeout, Promise, console: { warn: () => {}, error: () => {}, log: () => {} },
    withSupabase: (_opts, handler) => (request) => handler(request, ctx),
    ...matchDetail, ...calendarCache,
  });
  vm.runInContext(stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''))
    .replace('export default {', 'globalThis.__api = {'), context);
  const call = async (query) => {
    const pending = context.__api.fetch(new Request(`https://api.test/functions/v1/futbeat-api/v1/entity${query}`));
    let timer;
    const timeout = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(
        `RPCs ran one after another: only ${started.map((s) => s.name).join(', ')} started`)), 2000);
    });
    try {
      const response = await Promise.race([pending, timeout]);
      return { status: response.status, body: await response.json(), cache: response.headers.get('cache-control') };
    } finally { clearTimeout(timer); }
  };
  return { call, started };
}

test('team open: both demands and the stored read run concurrently', async () => {
  const { call, started } = await concurrentApi(3, {
    futbeat_read_entity_detail: () => ({ data: stored({ teams: [{ id: 'fb_team_fp1', name: 'Equipo' }] }), error: null }),
    futbeat_request_team_squad: () => ({ data: { state: 'PENDING' }, error: null }),
    futbeat_request_team_matches: () => ({ data: { state: 'PENDING' }, error: null }),
  });
  const r = await call('?type=team&id=fb_team_fp1');
  assert.equal(r.status, 200);
  assert.equal(r.body.teams[0].id, 'fb_team_fp1');
  assert.deepEqual(new Set(started.map((s) => s.name)), new Set([
    'futbeat_request_team_squad', 'futbeat_request_team_matches', 'futbeat_read_entity_detail',
  ]));
  // The team endpoint never claims player enrichment.
  assert.equal(r.body.coverage.enrichmentPending, undefined);
});

test('team open: a failing demand never blocks the stored profile', async () => {
  const { call } = await concurrentApi(3, {
    futbeat_read_entity_detail: () => ({ data: stored(), error: null }),
    futbeat_request_team_squad: () => { throw new Error('demand rpc down'); },
    futbeat_request_team_matches: () => ({ data: null, error: { message: 'boom' } }),
  });
  const r = await call('?type=team&id=fb_team_fp2');
  assert.equal(r.status, 200);
});

test('player open: demand and read concurrent, enrichmentPending still reported', async () => {
  const { call, started } = await concurrentApi(2, {
    futbeat_read_entity_detail: () => ({ data: stored({ players: [{ id: 'fb_player_fp3', name: 'J' }] }), error: null }),
    futbeat_request_player_profile: () => ({ data: { enrichmentPending: true }, error: null }),
  });
  const r = await call('?type=player&id=fb_player_fp3');
  assert.equal(r.status, 200);
  assert.equal(r.body.coverage.enrichmentPending, true);
  assert.equal(r.cache, 'no-store');
  assert.equal(started.length, 2);
});

test('player open: a failed demand still serves the cached profile (no enrichment flag)', async () => {
  const { call } = await concurrentApi(2, {
    futbeat_read_entity_detail: () => ({ data: stored(), error: null }),
    futbeat_request_player_profile: () => { throw new Error('demand rpc down'); },
  });
  const r = await call('?type=player&id=fb_player_fp4');
  assert.equal(r.status, 200);
  assert.equal(r.body.coverage.enrichmentPending, undefined);
  assert.notEqual(r.cache, 'no-store');
});

test('read failure or a missing entity keep their status codes', async () => {
  const failing = await concurrentApi(3, {
    futbeat_read_entity_detail: () => ({ data: null, error: { message: 'down' } }),
  });
  assert.equal((await failing.call('?type=team&id=fb_team_fp5')).status, 503);
  const missing = await concurrentApi(1, {});
  assert.equal((await missing.call('?type=competition&id=fb_comp_fp6')).status, 404);
});

// ---------------------------------------------------------------------------
// Stored read: no catalog scan.
// ---------------------------------------------------------------------------

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const insert = (db, id, kind, payload) => db.query(
  'insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, ...payload })]);
const detail = (db, type, id) => db.query('select public.futbeat_read_entity_detail($1,$2) v', [type, id]).then((r) => r.rows[0].v);

test('entity detail keeps its teams: the team, its rivals, and a competition\'s teams', () => withDb(async (db) => {
  await insert(db, 'fb_comp_fp', 'competition', { name: 'Torneo FP', country: 'Nowhere' });
  await insert(db, 'fb_comp_fp_other', 'competition', { name: 'Otro FP', country: 'Nowhere' });
  for (const t of ['a', 'b', 'c']) await insert(db, `fb_team_fp_${t}`, 'team', { name: `Equipo ${t}`, competitionId: 'fb_comp_fp' });
  await insert(db, 'fb_team_fp_x', 'team', { name: 'Equipo x', competitionId: 'fb_comp_fp_other' });
  const id = 'fb_match_fp1';
  await insert(db, id, 'match', { competitionId: 'fb_comp_fp', homeTeamId: 'fb_team_fp_a', awayTeamId: 'fb_team_fp_b',
    status: 'SCHEDULED', startTime: new Date(Date.now() + 864e5).toISOString(), events: [], statistics: [] });
  await db.query(`insert into futbeat_private.calendar_matches(match_id,start_time,source,updated_at)
    values($1,now()+interval '1 day','test',now()) on conflict(match_id) do nothing`, [id]);
  // Run often enough for plpgsql to settle on its cached generic plan.
  for (let i = 0; i < 7; i++) {
    const team = await detail(db, 'team', 'fb_team_fp_a');
    assert.deepEqual(team.teams.map((t) => t.id).sort(), ['fb_team_fp_a', 'fb_team_fp_b']);
    const lonely = await detail(db, 'team', 'fb_team_fp_c');
    assert.deepEqual(lonely.teams.map((t) => t.id), ['fb_team_fp_c']);
    const competition = await detail(db, 'competition', 'fb_comp_fp');
    // Every team of the competition, also one without a listed match; never another competition's.
    assert.deepEqual(competition.teams.map((t) => t.id).sort(), ['fb_team_fp_a', 'fb_team_fp_b', 'fb_team_fp_c']);
  }
}));

test('entity detail teams query is index-served (no OR across id and competitionId)', () => withDb(async (db) => {
  const def = (await db.query(`select pg_get_functiondef('futbeat_private.futbeat_read_entity_detail(text,text)'::regprocedure) d`)).rows[0].d;
  assert.doesNotMatch(def, /e\.id in \(select id from ids where id is not null\)\s*or/);
  const index = (await db.query(`select indexdef from pg_indexes where schemaname='futbeat_private'
    and indexname='entities_team_competition_idx'`)).rows[0]?.indexdef ?? '';
  assert.match(index, /\(\(payload ->> 'competitionId'::text\)\)/);
  assert.match(index, /WHERE \(kind = 'team'::text\)/);
  await db.exec(`insert into futbeat_private.entities(id,kind,payload)
    select 'fb_team_fpq'||i,'team',jsonb_build_object('id','fb_team_fpq'||i,'name','T'||i,'competitionId','fb_comp_fpq'||(i%300))
    from generate_series(1,6000) i;
    analyze futbeat_private.entities;`);
  await db.exec('set enable_seqscan = off');
  const plan = async (sql, params) => (await db.query(`explain (costs off) ${sql}`, params)).rows
    .map((r) => r['QUERY PLAN']).join('\n');
  const byCompetition = await plan(`select e.id from futbeat_private.entities e
    where e.kind='team' and e.payload->>'competitionId'=$1`, ['fb_comp_fpq1']);
  assert.match(byCompetition, /entities_team_competition_idx/);
  assert.doesNotMatch(byCompetition, /Seq Scan/);
}));
