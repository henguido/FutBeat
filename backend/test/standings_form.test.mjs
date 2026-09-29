import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import * as matchDetail from '../../supabase/functions/_shared/match_detail.ts';
import * as calendarCache from '../../supabase/functions/_shared/calendar_cache.ts';

// #158 Tabla v2 "Forma": last results per team of one competition + season,
// from stored canonical finals only. Synthetic ids/names; DB-only.

async function withDb(fn) {
  const db = await openDatabase();
  try {
    await fn(db);
    assert.equal((await db.query('select count(*)::int n from futbeat_private.provider_call_ledger')).rows[0].n, 0);
  } finally { await db.close(); }
}

const DAY = 24 * 3600e3;
const iso = (ms) => new Date(ms).toISOString();
let seq = 0;
async function entity(db, kind, prefix, payload = {}) {
  const id = `fb_${prefix}_sf${++seq}`;
  await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify({ id, name: `N${seq}`, ...payload })]);
  return id;
}
const team = (db) => entity(db, 'team', 'team');
const competition = (db) => entity(db, 'competition', 'comp', { season: '2026' });
async function match(db, { comp, home, away, at, status = 'VERIFIED', score = [1, 0], season = '2026', extra = {} }) {
  const id = `fb_match_sf${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [id, JSON.stringify({
    id, competitionId: comp, homeTeamId: home, awayTeamId: away, startTime: iso(at), status, season,
    ...(score ? { score: { home: score[0], away: score[1] } } : {}), events: [], statistics: [], ...extra })]);
  return id;
}
const redirect = (db, kind, alias, canonical) => db.query(
  'insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values($1,$2,$3,$4)',
  [alias, canonical, kind, 'test']);
const form = async (db, comp, season = '2026', limit = 5) =>
  (await db.query('select public.futbeat_read_standings_form($1,$2,$3) v', [comp, season, limit])).rows[0].v;

test('newest first, WIN/DRAW/LOSS from each side, reversed home/away by id', () => withDb(async (db) => {
  const comp = await competition(db);
  const [A, B, C] = [await team(db), await team(db), await team(db)];
  const now = Date.now();
  const m1 = await match(db, { comp, home: A, away: B, at: now - 10 * DAY, score: [2, 0] });
  const m2 = await match(db, { comp, home: B, away: A, at: now - 5 * DAY, score: [1, 1] });
  const m3 = await match(db, { comp, home: C, away: A, at: now - 2 * DAY, score: [0, 3] });
  const f = await form(db, comp);
  assert.equal(f.schemaVersion, 1);
  assert.equal(f.competitionId, comp);
  assert.equal(f.seasonKey, '2026');
  assert.equal(f.matchesConsidered, 3);
  assert.deepEqual(f.teams[A], { results: ['WIN', 'DRAW', 'WIN'], matchIds: [m3, m2, m1] });
  assert.deepEqual(f.teams[B], { results: ['DRAW', 'LOSS'], matchIds: [m2, m1] });
  assert.deepEqual(f.teams[C], { results: ['LOSS'], matchIds: [m3] });
}));

test('only that competition and season; season labels normalized', () => withDb(async (db) => {
  const comp = await competition(db);
  const other = await competition(db);
  const [A, B] = [await team(db), await team(db)];
  const now = Date.now();
  const inSeason = await match(db, { comp, home: A, away: B, at: now - 3 * DAY, season: '2025/26' });
  await match(db, { comp, home: A, away: B, at: now - 2 * DAY, season: '2024/25', score: [0, 4] });
  await match(db, { comp: other, home: A, away: B, at: now - DAY, season: '2025/26', score: [0, 4] });
  const f = await form(db, comp, '2025-2026');
  assert.equal(f.seasonKey, '2025-2026');
  assert.deepEqual(f.teams[A], { results: ['WIN'], matchIds: [inSeason] });
  assert.deepEqual(f.teams[B].results, ['LOSS']);
  assert.equal(f.matchesConsidered, 1);
  // Same answer for the raw label.
  assert.deepEqual((await form(db, comp, '2025/26')).teams, f.teams);
  assert.deepEqual((await form(db, comp, '2023')).teams, {});
}));

test('aliases: competition and team redirects converge on canonical ids; an alias id never appears', () => withDb(async (db) => {
  const comp = await competition(db);
  const compAlias = await competition(db);
  await redirect(db, 'competition', compAlias, comp);
  const [A, B] = [await team(db), await team(db)];
  const aAlias = await team(db);
  await redirect(db, 'team', aAlias, A);
  const now = Date.now();
  const m1 = await match(db, { comp: compAlias, home: B, away: aAlias, at: now - 4 * DAY, score: [0, 2] });
  const m2 = await match(db, { comp, home: A, away: B, at: now - 2 * DAY, score: [0, 0] });
  for (const requested of [comp, compAlias]) {
    const f = await form(db, requested);
    assert.equal(f.competitionId, comp);
    assert.deepEqual(f.teams[A], { results: ['DRAW', 'WIN'], matchIds: [m2, m1] });
    assert.equal(f.teams[aAlias], undefined);
    assert.deepEqual(f.teams[B].results, ['DRAW', 'LOSS']);
    assert.equal(f.matchesConsidered, 2);
  }
}));

test('scheduled, live, postponed, past-scheduled and scoreless finals are excluded', () => withDb(async (db) => {
  const comp = await competition(db);
  const [A, B] = [await team(db), await team(db)];
  const now = Date.now();
  const final = await match(db, { comp, home: A, away: B, at: now - 6 * DAY, status: 'FINISHED_PENDING_VERIFICATION', score: [3, 1] });
  await match(db, { comp, home: A, away: B, at: now + DAY, status: 'SCHEDULED', score: null });
  await match(db, { comp, home: A, away: B, at: now - 30 * 60e3, status: 'LIVE', score: [0, 1],
    extra: { provenance: { receivedAt: iso(now - 60e3) } } });
  await match(db, { comp, home: A, away: B, at: now - 3 * DAY, status: 'SCHEDULED', score: null });
  await match(db, { comp, home: A, away: B, at: now - 2 * DAY, status: 'POSTPONED', score: null });
  await match(db, { comp, home: A, away: B, at: now - DAY, status: 'VERIFIED', score: null });
  const f = await form(db, comp);
  assert.deepEqual(f.teams[A], { results: ['WIN'], matchIds: [final] });
  assert.deepEqual(f.teams[B], { results: ['LOSS'], matchIds: [final] });
  assert.equal(f.matchesConsidered, 1);
}));

test('a final known only through terminal evidence counts (effective lifecycle)', () => withDb(async (db) => {
  const comp = await competition(db);
  const [A, B] = [await team(db), await team(db)];
  const at = Date.now() - 3 * DAY;
  const id = await match(db, { comp, home: A, away: B, at, status: 'SCHEDULED', score: [1, 2] });
  await db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,first_seen_at)
    values('fb_event_sf_ft',$1,'goal_api','FULL_TIME','{}'::jsonb,$2)`, [id, iso(at + 2 * 3600e3)]);
  const f = await form(db, comp);
  assert.deepEqual(f.teams[B], { results: ['WIN'], matchIds: [id] });
}));

test('limit: at most p_limit per team (default 5, clamped to 1..10)', () => withDb(async (db) => {
  const comp = await competition(db);
  const [A, B] = [await team(db), await team(db)];
  const now = Date.now();
  const ids = [];
  for (let i = 0; i < 12; i++) ids.push(await match(db, { comp, home: A, away: B, at: now - (i + 1) * DAY, score: [i % 3, 1] }));
  assert.equal((await form(db, comp)).teams[A].results.length, 5);
  assert.deepEqual((await form(db, comp)).teams[A].matchIds, ids.slice(0, 5));
  assert.equal((await form(db, comp, '2026', 3)).teams[A].results.length, 3);
  assert.equal((await form(db, comp, '2026', 50)).limit, 10);
  assert.equal((await form(db, comp, '2026', 0)).teams[A].results.length, 1);
  const def = (await db.query("select public.futbeat_read_standings_form($1,'2026') v", [comp])).rows[0].v;
  assert.equal(def.limit, 5);
  assert.equal(def.matchesConsidered, 12);
}));

test('unknown competition or blank season: null', () => withDb(async (db) => {
  const comp = await competition(db);
  assert.equal(await form(db, 'fb_comp_missing_sf'), null);
  assert.equal(await form(db, comp, '   '), null);
  assert.deepEqual((await form(db, comp)).teams, {});
}));

test('grants: service_role only; security definer with empty search_path', () => withDb(async (db) => {
  const fn = 'public.futbeat_read_standings_form(text,text,integer)';
  for (const role of ['anon', 'authenticated', 'public']) {
    const ok = role === 'public'
      ? (await db.query(`select exists(select 1 from pg_proc p, aclexplode(p.proacl) a
          where p.oid=$1::regprocedure and a.grantee=0 and a.privilege_type='EXECUTE') ok`, [fn])).rows[0].ok
      : (await db.query("select has_function_privilege($1,$2,'EXECUTE') ok", [role, fn])).rows[0].ok;
    assert.equal(ok, false, role);
  }
  assert.equal((await db.query("select has_function_privilege('service_role',$1,'EXECUTE') ok", [fn])).rows[0].ok, true);
  const meta = (await db.query('select prosecdef,proconfig from pg_proc where oid=$1::regprocedure', [fn])).rows[0];
  assert.equal(meta.prosecdef, true);
  assert.ok(meta.proconfig.some((c) => /^search_path=("")?$/.test(c)), String(meta.proconfig));
}));

test('candidates come from the competitionId index (no global scan of matches)', () => withDb(async (db) => {
  await db.exec(`insert into futbeat_private.entities(id,kind,payload)
      select 'fb_match_sfx'||i,'match',jsonb_build_object('id','fb_match_sfx'||i,'competitionId','fb_comp_sfx'||(i%400),
        'homeTeamId','fb_team_sfx'||(i%900),'awayTeamId','fb_team_sfx'||((i*7+3)%900),'status','VERIFIED',
        'season','2026','score',jsonb_build_object('home',1,'away',0),'startTime',(now()-make_interval(hours=>i))::text)
      from generate_series(1,8000) i;
    analyze futbeat_private.entities;`);
  await db.exec('set enable_seqscan = off');
  const plan = (await db.query(`explain select e.id from futbeat_private.entities e
    where e.kind='match' and e.payload->>'competitionId'=any($1::text[])
      and futbeat_private.normalize_season(e.payload->>'season')=$2
      and nullif(e.payload->>'startTime','') is not null
      and (e.payload->>'startTime')::timestamptz<=now()`, [['fb_comp_sfx1', 'fb_comp_sfx2'], '2026'])).rows
    .map((r) => r['QUERY PLAN']).join('\n');
  await db.exec('reset enable_seqscan');
  assert.match(plan, /entities_match_competition_idx/);
  assert.doesNotMatch(plan, /Seq Scan on entities/);
  // The function uses that same predicate shape.
  const def = (await db.query("select pg_get_functiondef('public.futbeat_read_standings_form(text,text,integer)'::regprocedure) d")).rows[0].d;
  assert.match(def, /e\.payload->>'competitionId'=any\(comp_ids\)/);
  // Real data through the function still works with the synthetic catalog.
  await db.query("insert into futbeat_private.entities values('fb_comp_sfx1','competition','{\"id\":\"fb_comp_sfx1\",\"name\":\"X\"}')");
  const f = await form(db, 'fb_comp_sfx1');
  assert.equal(f.matchesConsidered, 20);
}));

// ---------------------------------------------------------------------------
// API route
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
  const call = async (query) => {
    const response = await context.__api.fetch(new Request(`https://api.test/functions/v1/futbeat-api/v1/standings-form${query}`));
    return { status: response.status, body: await response.json(), cache: response.headers.get('cache-control') };
  };
  return { call, rpcs };
}

test('API: validates ids and season; normal cache policy; one DB-only read', () => withDb(async (db) => {
  const comp = await competition(db);
  const [A, B] = [await team(db), await team(db)];
  await match(db, { comp, home: A, away: B, at: Date.now() - DAY });
  const { call, rpcs } = await api(db);
  for (const bad of ['', `?competitionId=${comp}`, '?competitionId=fb_team_abcdef&season=2026',
    `?competitionId=${comp}&season=`, `?competitionId=${comp}&season=${'x'.repeat(21)}`,
    '?competitionId=fb_comp_%27;drop&season=2026', '?competitionId=comp_1234&season=2026']) {
    const r = await call(bad);
    assert.equal(r.status, 400, bad);
  }
  assert.deepEqual(rpcs, [], 'invalid requests never reach the database');
  const ok = await call(`?competitionId=${comp}&season=2026`);
  assert.equal(ok.status, 200);
  assert.deepEqual(ok.body.teams[A].results, ['WIN']);
  assert.match(ok.cache, /max-age=30/);
  assert.deepEqual(rpcs, ['futbeat_read_standings_form']);
  const missing = await call('?competitionId=fb_comp_nothere&season=2026');
  assert.equal(missing.status, 404);
}));
