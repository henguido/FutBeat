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
const form = async (db, comp, season = '2026', limit = 5, until = null) =>
  (await db.query('select public.futbeat_read_standings_form($1,$2,$3,$4) v', [comp, season, limit, until])).rows[0].v;
// A stored table (standings_snapshots) for comp+season; groups: [[teamId...], ...].
async function snapshot(db, comp, groups, { season = '2026', labelled = true } = {}) {
  const rows = groups.flatMap((teams, g) => teams.map((teamId, i) => ({
    teamId, position: i + 1, ...(labelled ? { group: `Grupo ${String.fromCharCode(65 + g)}` } : {}),
    played: 0, won: 0, drawn: 0, lost: 0, gf: 0, ga: 0, points: 0 })));
  await db.query(`insert into futbeat_private.standings_snapshots(competition_id,season_key,season,table_payload,fetched_at)
    values($1,$2,$2,$3,now())`, [comp, season, JSON.stringify({ competitionId: comp, season, rows })]);
}

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
  assert.equal(def.until, null);
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
  const fn = 'public.futbeat_read_standings_form(text,text,integer,timestamptz)';
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
  const def = (await db.query("select pg_get_functiondef('public.futbeat_read_standings_form(text,text,integer,timestamptz)'::regprocedure) d")).rows[0].d;
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
    if (name !== 'futbeat_read_national_teams') rpcs.push(name);
    const keys = Object.keys(args ?? {});
    try {
      const v = (await db.query(`select public.${name}(${keys.map((k, i) => `${k}=>$${i + 1}`).join(',')}) v`, keys.map((k) => args[k]))).rows[0]?.v;
      return { data: v ?? null, error: null };
    } catch (error) { return { data: null, error: { message: error.message } }; }
  } } };
  const context = vm.createContext({
    Request, Response, URL, JSON, setTimeout, clearTimeout, console: { warn: () => {}, error: () => {}, log: () => {} },
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
    '?competitionId=fb_comp_%27;drop&season=2026', '?competitionId=comp_1234&season=2026',
    `?competitionId=${comp}&season=2026&until=yesterday`, `?competitionId=${comp}&season=2026&until=2026-13-45T00:00:00Z`,
    `?competitionId=${comp}&season=2026&until=${'2026-09-01T00:00:00Z'.padEnd(41, '0')}`]) {
    const r = await call(bad);
    assert.equal(r.status, 400, bad);
  }
  assert.deepEqual(rpcs, [], 'invalid requests never reach the database');
  const ok = await call(`?competitionId=${comp}&season=2026`);
  assert.equal(ok.status, 200);
  assert.deepEqual(ok.body.teams[A].results, ['WIN']);
  assert.match(ok.cache, /max-age=30/);
  assert.deepEqual(rpcs, ['futbeat_read_standings_form']);
  const capped = await call(`?competitionId=${comp}&season=2026&until=${encodeURIComponent(new Date(Date.now() - 2 * DAY).toISOString())}`);
  assert.equal(capped.status, 200);
  assert.deepEqual(capped.body.teams, {});
  const missing = await call('?competitionId=fb_comp_nothere&season=2026');
  assert.equal(missing.status, 404);
}));

// ---------------------------------------------------------------------------
// Review follow-ups: groups, published-table cap, terminal shortcut
// ---------------------------------------------------------------------------

test('grouped table: only matches between two teams of the same group count (knockout never)', () => withDb(async (db) => {
  const comp = await competition(db);
  const [A1, A2, B1, B2] = [await team(db), await team(db), await team(db), await team(db)];
  const a1Alias = await team(db);
  await redirect(db, 'team', a1Alias, A1);
  await snapshot(db, comp, [[a1Alias, A2], [B1, B2]]);
  const now = Date.now();
  const group = await match(db, { comp, home: A1, away: A2, at: now - 9 * DAY, score: [1, 0] });
  const groupB = await match(db, { comp, home: B2, away: B1, at: now - 8 * DAY, score: [2, 2] });
  // Knockout stage of the same season: cross-group, never in the group form.
  await match(db, { comp, home: A1, away: B1, at: now - 2 * DAY, score: [0, 3] });
  const f = await form(db, comp);
  assert.equal(f.groupFilter, true);
  assert.deepEqual(f.teams[A1], { results: ['WIN'], matchIds: [group] });
  assert.deepEqual(f.teams[B1], { results: ['DRAW'], matchIds: [groupB] });
  assert.equal(f.matchesConsidered, 2);
}));

test('single-group table: a team outside the table never brings its matches in', () => withDb(async (db) => {
  const comp = await competition(db);
  const [A, B, X] = [await team(db), await team(db), await team(db)];
  await snapshot(db, comp, [[A, B]], { labelled: false });
  const now = Date.now();
  const league = await match(db, { comp, home: A, away: B, at: now - 5 * DAY });
  await match(db, { comp, home: X, away: A, at: now - DAY, score: [5, 0] });
  const f = await form(db, comp);
  assert.deepEqual(f.teams[A].matchIds, [league]);
  assert.equal(f.teams[X], undefined);
}));

test('p_until: a published table never gets results newer than itself (3 h margin)', () => withDb(async (db) => {
  const comp = await competition(db);
  const [A, B] = [await team(db), await team(db)];
  const now = Date.now();
  const older = await match(db, { comp, home: A, away: B, at: now - 5 * DAY, score: [1, 0] });
  await match(db, { comp, home: A, away: B, at: now - 2 * DAY, score: [0, 1] });
  // Kicked off 1 h before the table was fetched: possibly not in J/Pts.
  await match(db, { comp, home: A, away: B, at: now - 4 * DAY - 3600e3, score: [0, 2] });
  const f = await form(db, comp, '2026', 5, iso(now - 4 * DAY));
  assert.deepEqual(f.teams[A], { results: ['WIN'], matchIds: [older] });
  assert.equal(f.until !== null, true);
  assert.equal((await form(db, comp)).teams[A].results.length, 3);
}));

test('shootouts: the stored draw counts as DRAW', () => withDb(async (db) => {
  const comp = await competition(db);
  const [A, B] = [await team(db), await team(db)];
  await match(db, { comp, home: A, away: B, at: Date.now() - DAY, score: [1, 1], extra: { penalties: { home: 4, away: 3 } } });
  const f = await form(db, comp);
  assert.deepEqual([f.teams[A].results, f.teams[B].results], [['DRAW'], ['DRAW']]);
}));

test('terminal shortcut is equivalent: match_read_model_core keeps a terminal payload status and score', () => withDb(async (db) => {
  const comp = await competition(db);
  const [A, B] = [await team(db), await team(db)];
  const at = Date.now() - DAY;
  for (const status of ['VERIFIED', 'FINISHED_PENDING_VERIFICATION']) {
    const id = await match(db, { comp, home: A, away: B, at, status, score: [2, 1],
      extra: { provenance: { receivedAt: iso(at + 3 * 3600e3) } } });
    // Later contradicting evidence: a LIVE observation with another score.
    await db.query(`insert into futbeat_private.provider_observations(provider,external_match_id,canonical_match_id,
        received_at,provider_observed_at,status,minute,home_score,away_score,events,payload_hash,raw_payload)
      values('goal_api',$1,$2,$3,$3,'LIVE',80,0,0,'[]'::jsonb,$4,'{}'::jsonb)`,
    [`sf-obs-${id}`, id, iso(at + 4 * 3600e3), (status[0] === 'V' ? 'a' : 'b').repeat(64)]);
    const payload = (await db.query('select payload from futbeat_private.entities where id=$1', [id])).rows[0].payload;
    const model = (await db.query('select futbeat_private.match_read_model_core($1,false) m', [payload])).rows[0].m;
    assert.equal(model.status, status);
    assert.deepEqual(model.score, { home: 2, away: 1 });
  }
  const f = await form(db, comp);
  assert.deepEqual(f.teams[A].results, ['WIN', 'WIN']);
  // A non-integer stored score is never taken as final (same as the model).
  await match(db, { comp, home: A, away: B, at: at + 3600e3, status: 'VERIFIED', score: [1.5, 0] });
  assert.equal((await form(db, comp)).matchesConsidered, 2);
  // String scores never count (nor inflate matchesConsidered).
  await match(db, { comp, home: A, away: B, at: at + 2 * 3600e3, status: 'VERIFIED', score: ['3', '0'] });
  const f2 = await form(db, comp);
  assert.equal(f2.matchesConsidered, 2);
  assert.deepEqual(f2.teams[A].results, ['WIN', 'WIN']);
}));
