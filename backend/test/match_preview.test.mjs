import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import * as matchDetail from '../../supabase/functions/_shared/match_detail.ts';
import * as calendarCache from '../../supabase/functions/_shared/calendar_cache.ts';

// Issue #99 phase 2: recent form + head-to-head as a separate DB-only read
// model. Synthetic ids/names only; dates relative to the target's kickoff.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

const DAY = 24 * 3600e3;
let seq = 0;
async function team(db, name) {
  const id = `fb_team_pv${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'team',$2)", [id, JSON.stringify({ id, name, color: '#112233' })]);
  return id;
}
async function competition(db, name = 'Liga Previa') {
  const id = `fb_comp_pv${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)", [id, JSON.stringify({ id, name })]);
  return id;
}
async function match(db, { comp, home, away, at, status = 'VERIFIED', score = [1, 0], events = [] }) {
  const id = `fb_match_pv${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [id, JSON.stringify({
    id, competitionId: comp, homeTeamId: home, awayTeamId: away, startTime: new Date(at).toISOString(), status,
    ...(score ? { score: { home: score[0], away: score[1] } } : {}), events, statistics: [] })]);
  return id;
}
const preview = (db, id) => db.query('select public.futbeat_read_match_preview($1) v', [id]).then((r) => r.rows[0].v);

// Target 40 days ago (a historical Match Center) between H and A.
async function scenario(db) {
  const comp = await competition(db);
  const cup = await competition(db, 'Copa Previa');
  const H = await team(db, 'Local Previa');
  const A = await team(db, 'Visita Previa');
  const O = await team(db, 'Otro Rival');
  const K = Date.now() - 40 * DAY;
  const target = await match(db, { comp, home: H, away: A, at: K, status: 'VERIFIED', score: [2, 2] });
  return { comp, cup, H, A, O, K, target };
}

test('A/B/C/D/E/F. last 5 terminal matches per side before the TARGET kickoff, team perspective, no false results', () => withDb(async (db) => {
  const s = await scenario(db);
  const { comp, H, A, O, K } = s;
  // Home: 7 terminal before K (days -1..-7), H wins/draws/loses from both orientations.
  const homeIds = [];
  homeIds.push(await match(db, { comp, home: H, away: O, at: K - 1 * DAY, score: [3, 1] })); // WIN
  homeIds.push(await match(db, { comp, home: O, away: H, at: K - 2 * DAY, score: [0, 2] })); // WIN (away)
  homeIds.push(await match(db, { comp, home: H, away: O, at: K - 3 * DAY, score: [1, 1], status: 'FINISHED_PENDING_VERIFICATION' })); // DRAW
  homeIds.push(await match(db, { comp, home: O, away: H, at: K - 4 * DAY, score: [2, 0] })); // LOSS (away)
  homeIds.push(await match(db, { comp, home: H, away: O, at: K - 5 * DAY, score: null })); // terminal, no score
  await match(db, { comp, home: H, away: O, at: K - 6 * DAY });
  await match(db, { comp, home: H, away: O, at: K - 7 * DAY });
  // Never: after the target (results that happened later), non-terminal.
  await match(db, { comp, home: H, away: O, at: K + 2 * DAY, score: [9, 0] });
  await match(db, { comp, home: H, away: O, at: K - 0.5 * DAY, status: 'SCHEDULED', score: null });
  await match(db, { comp, home: O, away: H, at: K - 0.2 * DAY, status: 'LIVE', score: [0, 0] });
  await match(db, { comp, home: H, away: O, at: K - 0.3 * DAY, status: 'POSTPONED', score: null });
  // Away: 2 terminal before K -> partial.
  const awayIds = [
    await match(db, { comp, home: A, away: O, at: K - 10 * DAY, score: [0, 1] }),
    await match(db, { comp, home: O, away: A, at: K - 20 * DAY, score: [1, 1] }),
  ];
  await match(db, { comp, home: A, away: O, at: K + 1 * DAY, score: [5, 0] });
  const p = await preview(db, s.target);
  assert.deepEqual(p.form.home.matchIds, homeIds, 'newest first, terminal, before kickoff');
  assert.deepEqual(p.form.home.results, ['WIN', 'WIN', 'DRAW', 'LOSS', null]);
  assert.equal(p.form.home.state, 'available');
  assert.deepEqual(p.form.away.matchIds, awayIds);
  assert.deepEqual(p.form.away.results, ['LOSS', 'DRAW']);
  assert.equal(p.form.away.state, 'partial');
  const all = new Set(p.matches.map((m) => m.matchId));
  for (const m of p.matches) {
    assert.ok(new Date(m.startTime).getTime() < K, 'never a match after the target kickoff');
    assert.ok(['VERIFIED', 'FINISHED_PENDING_VERIFICATION'].includes(m.status));
  }
  assert.equal(all.has(s.target), false);
  assert.equal(p.matches.find((m) => m.matchId === homeIds[4]).score, null, 'no invented score');
}));

test('A. no terminal history: state none (not pending)', () => withDb(async (db) => {
  const s = await scenario(db);
  const p = await preview(db, s.target);
  assert.deepEqual([p.form.home.state, p.form.away.state, p.h2h.state], ['none', 'none', 'none']);
  assert.deepEqual(p.h2h.matchIds, []);
  assert.equal(JSON.stringify(p).includes('pending'), false);
}));

test('G/H/I/J/K/L. H2H: both orientations, exact canonical ids, any competition, max 5, deduplicated', () => withDb(async (db) => {
  const s = await scenario(db);
  const { comp, cup, H, A, K } = s;
  const twin = await team(db, 'Local Previa'); // same display name, other canonical team
  await match(db, { comp, home: twin, away: A, at: K - 1 * DAY, score: [4, 0] });
  await match(db, { comp, home: A, away: twin, at: K - 2 * DAY, score: [0, 4] });
  const h2h = [
    await match(db, { comp, home: H, away: A, at: K - 3 * DAY, score: [2, 0] }), // home win
    await match(db, { comp: cup, home: A, away: H, at: K - 30 * DAY, score: [1, 1] }), // draw, other competition
    await match(db, { comp, home: A, away: H, at: K - 60 * DAY, score: [3, 1] }), // away (A) win
    await match(db, { comp: cup, home: H, away: A, at: K - 400 * DAY, score: [0, 1] }), // away win, >365 days still H2H
    await match(db, { comp, home: H, away: A, at: K - 500 * DAY, score: [1, 0] }),
  ];
  await match(db, { comp, home: H, away: A, at: K - 600 * DAY, score: [5, 5] }); // 6th: beyond max 5
  await match(db, { comp, home: A, away: H, at: K + 3 * DAY, score: [0, 9] }); // after the target
  const p = await preview(db, s.target);
  assert.deepEqual(p.h2h.matchIds, h2h);
  assert.equal(p.h2h.state, 'available');
  assert.deepEqual(p.h2h.summary, { homeWins: 2, draws: 1, awayWins: 2, counted: 5 });
  const h2hMatches = p.matches.filter((m) => p.h2h.matchIds.includes(m.matchId));
  assert.ok(!h2hMatches.some((m) => [m.homeTeamId, m.awayTeamId].includes(twin)), 'same-name team never counted as H2H');
  assert.ok(p.form.home.matchIds.every((id) => !p.matches.find((m) => m.matchId === id)
    || [p.matches.find((m) => m.matchId === id).homeTeamId, p.matches.find((m) => m.matchId === id).awayTeamId].includes(H)),
    'home form only has the canonical home team');
  const cupMatch = p.matches.find((m) => m.matchId === h2h[1]);
  assert.equal(cupMatch.competitionId, cup);
  assert.ok(p.competitions.some((c) => c.id === cup && c.name === 'Copa Previa'));
  // A meeting that is also recent form appears once.
  assert.ok(p.form.home.matchIds.includes(h2h[0]) && p.h2h.matchIds.includes(h2h[0]));
  const ids = p.matches.map((m) => m.matchId);
  assert.equal(new Set(ids).size, ids.length, 'each match once');
  assert.ok(p.teams.some((t) => t.id === H && t.name === 'Local Previa' && t.color === '#112233'));
}));

test('M. unknown match -> null; target without teams/kickoff -> empty states', () => withDb(async (db) => {
  assert.equal(await preview(db, 'fb_match_missing'), null);
  await db.query(`insert into futbeat_private.entities values('fb_match_pv_bare','match','{"id":"fb_match_pv_bare"}')`);
  const p = await preview(db, 'fb_match_pv_bare');
  assert.deepEqual([p.form.home.state, p.h2h.state], ['none', 'none']);
}));

test('N. payload is compact and bounded (no events/lineups/statistics)', () => withDb(async (db) => {
  const s = await scenario(db);
  const heavy = Array.from({ length: 200 }, (_, i) => ({ id: `ev${i}`, type: 'GOAL', minute: i % 90, detail: 'x'.repeat(200) }));
  for (let i = 1; i <= 8; i++) {
    await match(db, { comp: s.comp, home: s.H, away: s.O, at: s.K - i * DAY, events: heavy });
    await match(db, { comp: s.comp, home: s.A, away: s.O, at: s.K - i * DAY, events: heavy });
    await match(db, { comp: s.comp, home: i % 2 ? s.H : s.A, away: i % 2 ? s.A : s.H, at: s.K - (i + 10) * DAY, events: heavy });
  }
  const p = await preview(db, s.target);
  const size = Buffer.byteLength(JSON.stringify(p));
  assert.ok(p.matches.length <= 15);
  assert.ok(size < 16 * 1024, `payload ${size} bytes`);
  assert.equal(JSON.stringify(p).includes('"events"'), false);
  console.log('match preview payload bytes', size, 'matches', p.matches.length);
}));

test('Q/R. read-only: no ledger row, no demand, no wake-up; match context unchanged', () => withDb(async (db) => {
  const s = await scenario(db);
  const count = async (sql) => (await db.query(sql)).rows[0].n;
  const before = {
    ledger: await count('select count(*)::int n from futbeat_private.provider_call_ledger'),
    requests: await count('select count(*)::int n from futbeat_private.match_detail_requests'),
    wakeups: await count('select count(*)::int n from futbeat_private.worker_wakeups'),
    metrics: await count('select count(*)::int n from futbeat_private.demand_metrics'),
  };
  for (let i = 0; i < 5; i++) await preview(db, s.target);
  assert.deepEqual({
    ledger: await count('select count(*)::int n from futbeat_private.provider_call_ledger'),
    requests: await count('select count(*)::int n from futbeat_private.match_detail_requests'),
    wakeups: await count('select count(*)::int n from futbeat_private.worker_wakeups'),
    metrics: await count('select count(*)::int n from futbeat_private.demand_metrics'),
  }, before);
  const ctx = (await db.query('select public.futbeat_read_match_context($1) v', [s.target])).rows[0].v;
  assert.equal('form' in ctx || 'h2h' in ctx, false);
  const def = (await db.query("select pg_get_functiondef('public.futbeat_read_match_context(text)'::regprocedure) d")).rows[0].d;
  assert.doesNotMatch(def, /read_match_preview/);
  const volatility = (await db.query("select provolatile from pg_proc where oid='futbeat_private.read_match_preview(text)'::regprocedure")).rows[0].provolatile;
  assert.equal(volatility, 's', 'stable: cannot write');
}));

test('security: preview RPC is service-only; helpers private', () => withDb(async (db) => {
  const can = async (role, fn) => (await db.query("select has_function_privilege($1,$2,'EXECUTE') ok", [role, fn])).rows[0].ok;
  for (const role of ['anon', 'authenticated']) assert.equal(await can(role, 'public.futbeat_read_match_preview(text)'), false);
  assert.equal(await can('service_role', 'public.futbeat_read_match_preview(text)'), true);
  for (const role of ['anon', 'authenticated', 'service_role']) {
    assert.equal(await can(role, 'futbeat_private.read_match_preview(text)'), false);
  }
}));

// ---------------------------------------------------------------------------
// O. Indexes, plan and benchmark (before: forced sequential plan; after: the
// partial expression indexes). Generous bounds; plan asserts are the contract.
// ---------------------------------------------------------------------------
const plan = async (db, sql, params = []) => (await db.query(`explain (costs off) ${sql}`, params)).rows
  .map((r) => r['QUERY PLAN']).join('\n');
const FORM_SQL = `select e.id from futbeat_private.entities e
  where e.kind='match' and (e.payload->>'homeTeamId'=$1 or e.payload->>'awayTeamId'=$1)
    and e.payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
    and nullif(e.payload->>'startTime','')::timestamptz<$2::timestamptz`;
const H2H_SQL = `select e.id from futbeat_private.entities e
  where e.kind='match' and ((e.payload->>'homeTeamId'=$1 and e.payload->>'awayTeamId'=$2)
    or (e.payload->>'homeTeamId'=$2 and e.payload->>'awayTeamId'=$1))
    and e.payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')`;

test('O. generic partial indexes on home/away team exist and serve form and H2H (no mass scan)', () => withDb(async (db) => {
  for (const [name, key] of [['entities_match_home_team_idx', 'homeTeamId'], ['entities_match_away_team_idx', 'awayTeamId']]) {
    const def = (await db.query("select indexdef from pg_indexes where schemaname='futbeat_private' and indexname=$1", [name])).rows[0]?.indexdef ?? '';
    assert.match(def, new RegExp(`\\(\\(payload ->> '${key}'::text\\)\\)`));
    assert.match(def, /WHERE \(kind = 'match'::text\)/);
  }
  await db.exec(`insert into futbeat_private.entities(id,kind,payload)
    select 'fb_match_ix'||i,'match',jsonb_build_object('id','fb_match_ix'||i,'homeTeamId','fb_team_ix'||(i%700),
      'awayTeamId','fb_team_ix'||((i*7+3)%700),'status','VERIFIED','startTime',(now()-make_interval(hours=>i))::text)
    from generate_series(1,8000) i;
    analyze futbeat_private.entities;`);
  await db.exec('set enable_seqscan = off');
  const form = await plan(db, FORM_SQL, ['fb_team_ix1', new Date().toISOString()]);
  assert.match(form, /entities_match_home_team_idx/);
  assert.match(form, /entities_match_away_team_idx/);
  assert.doesNotMatch(form, /Seq Scan/);
  const h2h = await plan(db, H2H_SQL, ['fb_team_ix1', 'fb_team_ix10']);
  assert.match(h2h, /entities_match_(home|away)_team_idx/);
  assert.doesNotMatch(h2h, /Seq Scan/);
  await db.exec('reset enable_seqscan');
}));

test('O. benchmark: preview read with indexes vs the forced sequential plan (before)', () => withDb(async (db) => {
  // Representative shape: 25k matches of 800 teams plus the target's history.
  const s = await scenario(db);
  await db.exec(`insert into futbeat_private.entities(id,kind,payload)
    select 'fb_match_bm'||i,'match',jsonb_build_object('id','fb_match_bm'||i,'competitionId','fb_comp_bm'||(i%40),
      'homeTeamId','fb_team_bm'||(i%800),'awayTeamId','fb_team_bm'||((i*13+5)%800),
      'status',case when i%10=0 then 'SCHEDULED' else 'VERIFIED' end,
      'score',jsonb_build_object('home',i%4,'away',i%3),
      'startTime',(now()-make_interval(hours=>i%9000))::text,
      'events',jsonb_build_array(jsonb_build_object('type','GOAL','minute',i%90)))
    from generate_series(1,25000) i;`);
  for (let i = 1; i <= 6; i++) {
    await match(db, { comp: s.comp, home: s.H, away: s.O, at: s.K - i * DAY });
    await match(db, { comp: s.comp, home: s.A, away: s.O, at: s.K - i * DAY });
    await match(db, { comp: s.comp, home: s.H, away: s.A, at: s.K - (i + 7) * DAY });
  }
  await db.exec('analyze futbeat_private.entities');
  const time = async (n = 15) => {
    const samples = [];
    for (let i = 0; i < n; i++) { const t = performance.now(); await preview(db, s.target); samples.push(performance.now() - t); }
    samples.sort((a, b) => a - b);
    return +samples[Math.floor(n / 2)].toFixed(2);
  };
  await db.exec('set enable_bitmapscan = off; set enable_indexscan = off');
  const before = await time(5);
  await db.exec('reset enable_bitmapscan; reset enable_indexscan');
  const after = await time();
  console.log('match preview median ms (PGlite, 25k matches)', JSON.stringify({ beforeSeqScan: before, afterIndexes: after }));
  assert.ok(after < before, `indexed ${after} ms must beat the scan ${before} ms`);
  assert.ok(after < 250, `generous bound: ${after} ms`);
  const p = await preview(db, s.target);
  assert.deepEqual([p.form.home.matchIds.length, p.form.away.matchIds.length, p.h2h.matchIds.length], [5, 5, 5]);
}));

// ---------------------------------------------------------------------------
// P. The real futbeat-api handler (GET only), RPCs against the real SQL.
// ---------------------------------------------------------------------------
async function api(db) {
  const source = await readFile(new URL('../../supabase/functions/futbeat-api/index.ts', import.meta.url), 'utf8');
  const rpcs = [];
  const ctx = { supabaseAdmin: { rpc: async (name, args) => {
    rpcs.push(name);
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
  const code = stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''))
    .replace('export default {', 'globalThis.__api = {');
  vm.runInContext(code, context);
  const call = async (query, method = 'GET') => {
    const response = await context.__api.fetch(new Request(`https://api.test/functions/v1/futbeat-api/v1/match-preview${query}`, { method }));
    return { status: response.status, body: await response.json(), cache: response.headers.get('cache-control') };
  };
  return { call, rpcs };
}

test('P. GET /v1/match-preview: 200 read-only, 400 invalid id, 404 unknown, 405 non-GET', () => withDb(async (db) => {
  const s = await scenario(db);
  await match(db, { comp: s.comp, home: s.H, away: s.A, at: s.K - 5 * DAY, score: [1, 0] });
  const { call, rpcs } = await api(db);
  const ok = await call(`?id=${s.target}`);
  assert.equal(ok.status, 200);
  assert.equal(ok.body.schemaVersion, 1);
  assert.equal(ok.body.h2h.state, 'available');
  assert.equal((await call('?id=not-a-match')).status, 400);
  assert.equal((await call('?id=fb_match_does_not_exist')).status, 404);
  assert.equal((await call(`?id=${s.target}`, 'POST')).status, 405);
  assert.deepEqual([...new Set(rpcs)], ['futbeat_read_match_preview'], 'no demand/detail/provider RPC');
  assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 0);
}));
