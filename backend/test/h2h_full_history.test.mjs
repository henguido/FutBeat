import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import * as matchDetail from '../../supabase/functions/_shared/match_detail.ts';
import * as calendarCache from '../../supabase/functions/_shared/calendar_cache.ts';

// #155: the full stored head-to-head of a pair. Synthetic ids/names only;
// DB-only reads; no provider call anywhere.

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
async function team(db, name, { mapped = true } = {}) {
  const id = `fb_team_hf${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'team',$2)", [id, JSON.stringify({ id, name })]);
  if (mapped) await db.query("insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) values('goal_api','team',$1,$2)", [`hf-ext-${seq}`, id]);
  return id;
}
async function competition(db, name) {
  const id = `fb_comp_hf${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)", [id, JSON.stringify({ id, name })]);
  return id;
}
async function match(db, { comp, home, away, at, status = 'VERIFIED', score = [1, 0], extra = {} }) {
  const id = `fb_match_hf${String(++seq).padStart(5, '0')}`;
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [id, JSON.stringify({
    id, competitionId: comp, homeTeamId: home, awayTeamId: away, startTime: iso(at), status,
    ...(score ? { score: { home: score[0], away: score[1] } } : {}), events: [], statistics: [], ...extra })]);
  return id;
}
const read = (db, id, scope = 'all', cursor = null, limit = 20) => db.query(
  'select public.futbeat_read_match_h2h($1,$2,$3,$4) v', [id, scope, cursor, limit]).then((r) => r.rows[0].v);
const preview = (db, id) => db.query('select public.futbeat_read_match_preview($1) v', [id]).then((r) => r.rows[0].v.h2h);
const allPages = async (db, id, scope, limit) => {
  const pages = [];
  let cursor = null;
  for (let i = 0; i < 50; i++) {
    const p = await read(db, id, scope, cursor, limit);
    pages.push(p);
    if (!p.hasMore) return pages;
    cursor = p.nextCursor;
  }
  throw new Error('pagination never ended');
};
const coverFrom = (db, id, daysBack) => db.query(`insert into futbeat_private.team_match_coverage(team_id,status,covered_from,covered_to,window_complete,last_success_at)
  values($1,'AVAILABLE',current_date-$2::integer,current_date+120,true,now())
  on conflict(team_id) do update set covered_from=excluded.covered_from,status='AVAILABLE',window_complete=true,last_success_at=now()`, [id, daysBack]);

// A pair with `n` alternating meetings, one every 30 days, plus a scheduled
// target in 3 days. Scores cycle home win / draw / away win.
async function history(db, n, { cupEvery = 0 } = {}) {
  const liga = await competition(db, 'Liga Histórica');
  const copa = await competition(db, 'Copa Histórica');
  const A = await team(db, 'Equipo Histórico A');
  const B = await team(db, 'Equipo Histórico B');
  const now = Date.now();
  const meetings = [];
  for (let i = 1; i <= n; i++) {
    const swap = i % 2 === 0;
    const score = [[2, 0], [1, 1], [0, 3]][i % 3];
    const comp = cupEvery && i % cupEvery === 0 ? copa : liga;
    meetings.push(await match(db, { comp, home: swap ? B : A, away: swap ? A : B, at: now - i * 30 * DAY, score }));
  }
  const target = await match(db, { comp: liga, home: A, away: B, at: now + 3 * DAY, status: 'SCHEDULED', score: null });
  return { liga, copa, A, B, now, meetings, target };
}
// Expected totals from A's (target home) perspective, by team id.
async function expectedTotals(db, ids, A) {
  const rows = (await db.query('select payload from futbeat_private.entities where id=any($1)', [ids])).rows.map((r) => r.payload);
  const t = { homeWins: 0, draws: 0, awayWins: 0, counted: rows.length };
  for (const m of rows) {
    const mine = m.homeTeamId === A ? m.score.home : m.score.away;
    const theirs = m.homeTeamId === A ? m.score.away : m.score.home;
    if (mine > theirs) t.homeWins++; else if (mine === theirs) t.draws++; else t.awayWins++;
  }
  return t;
}

// ---------------------------------------------------------------------------

for (const n of [1, 5, 27]) {
  test(`pair with ${n} meeting(s): every page, totals over all ${n}, no duplicates`, () => withDb(async (db) => {
    const s = await history(db, n);
    const pages = await allPages(db, s.target, 'all', 10);
    const ids = pages.flatMap((p) => p.meetings.map((m) => m.matchId));
    assert.equal(ids.length, n);
    assert.equal(new Set(ids).size, n, 'no duplicates across pages');
    assert.deepEqual(new Set(ids), new Set(s.meetings));
    const expected = await expectedTotals(db, s.meetings, s.A);
    for (const p of pages) assert.deepEqual(p.totals, expected, 'totals never depend on the page');
    assert.equal(pages.length, Math.max(1, Math.ceil(n / 10)));
    const times = ids.map((id, i) => Date.parse(pages.flatMap((p) => p.meetings)[i].startTime));
    assert.deepEqual(times, [...times].sort((a, b) => b - a), 'newest first across pages');
    // The Match Center preview reports the same totals (over all meetings).
    assert.deepEqual((await preview(db, s.target)).totals, expected);
  }));
}

test('page 1 + next cursor continue exactly after the last item; bad cursors are rejected', () => withDb(async (db) => {
  const s = await history(db, 25);
  const first = await read(db, s.target, 'all', null, 20);
  assert.equal(first.meetings.length, 20);
  assert.equal(first.hasMore, true);
  const last = first.meetings.at(-1);
  assert.equal(first.nextCursor.split('|')[1], last.matchId);
  const second = await read(db, s.target, 'all', first.nextCursor, 20);
  assert.equal(second.meetings.length, 5);
  assert.equal(second.hasMore, false);
  assert.equal(second.nextCursor, null);
  assert.ok(Date.parse(second.meetings[0].startTime) < Date.parse(last.startTime));
  await assert.rejects(read(db, s.target, 'all', 'nope'), /Invalid h2h cursor/);
  await assert.rejects(read(db, s.target, 'everything'), /Invalid h2h request/);
}));

test('Este torneo pages its own meetings with its own totals', () => withDb(async (db) => {
  const s = await history(db, 30, { cupEvery: 3 }); // 10 cup, 20 league
  const league = s.meetings.filter((_, i) => (i + 1) % 3 !== 0);
  const pages = await allPages(db, s.target, 'competition', 8);
  const ids = pages.flatMap((p) => p.meetings.map((m) => m.matchId));
  assert.equal(ids.length, 20);
  assert.deepEqual(new Set(ids), new Set(league));
  assert.ok(pages.every((p) => p.meetings.every((m) => m.competitionId === s.liga)));
  assert.deepEqual(pages[0].totals, await expectedTotals(db, league, s.A));
  assert.equal((await read(db, s.target, 'all')).totals.counted, 30);
}));

test('reversed home/away counts for the right team; current SCHEDULED/LIVE never counts; a FINAL target once', () => withDb(async (db) => {
  const liga = await competition(db, 'Liga');
  const A = await team(db, 'Alfa'); const B = await team(db, 'Beta');
  const now = Date.now();
  await match(db, { comp: liga, home: B, away: A, at: now - 40 * DAY, score: [3, 0] }); // B wins at B's home
  const scheduled = await match(db, { comp: liga, home: A, away: B, at: now + DAY, status: 'SCHEDULED', score: null });
  let p = await read(db, scheduled);
  assert.deepEqual(p.totals, { homeWins: 0, draws: 0, awayWins: 1, counted: 1 });
  assert.ok(!p.meetings.some((m) => m.matchId === scheduled));
  const live = await match(db, { comp: liga, home: A, away: B, at: now - 20 * 60e3, status: 'LIVE', score: [5, 0],
    extra: { provenance: { receivedAt: iso(now - 60e3) } } });
  p = await read(db, live);
  assert.equal(p.totals.counted, 1, 'a live score never counts');
  const final = await match(db, { comp: liga, home: A, away: B, at: now - 2 * DAY, score: [2, 1] });
  p = await read(db, final);
  assert.equal(p.meetings.filter((m) => m.matchId === final).length, 1);
  assert.deepEqual(p.totals, { homeWins: 1, draws: 0, awayWins: 1, counted: 2 });
}));

test('aliases join the canonical pair; same-named teams are never merged', () => withDb(async (db) => {
  const liga = await competition(db, 'Liga');
  const A = await team(db, 'Canónico'); const B = await team(db, 'Rival');
  const alias = await team(db, 'Canónico (antiguo)');
  await db.query("insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values($1,$2,'team','test')", [alias, A]);
  const namesake = await team(db, 'Rival');
  const now = Date.now();
  const viaAlias = await match(db, { comp: liga, home: alias, away: B, at: now - 400 * DAY, score: [1, 0] });
  await match(db, { comp: liga, home: A, away: namesake, at: now - 300 * DAY, score: [4, 0] });
  const target = await match(db, { comp: liga, home: B, away: A, at: now + DAY, status: 'SCHEDULED', score: null });
  const p = await read(db, target);
  assert.deepEqual(p.meetings.map((m) => m.matchId), [viaAlias]);
  assert.equal(p.meetings[0].homeTeamId, A);
  assert.deepEqual(p.totals, { homeWins: 0, draws: 0, awayWins: 1, counted: 1 });
  assert.equal(p.pairKey, [A, B].sort().join('|'));
}));

// ---------------------------------------------------------------------------
// Verified window and on-demand extension (central coverage)
// ---------------------------------------------------------------------------

test('window: verified range only where both teams have one; extension asks both teams one step back', () => withDb(async (db) => {
  const s = await history(db, 2);
  // Cache miss: no coverage -> nothing claimed.
  let p = await read(db, s.target);
  assert.equal(p.window.verifiedFrom, undefined);
  assert.equal(p.window.canExtend, false);
  await coverFrom(db, s.A, 180); await coverFrom(db, s.B, 150);
  p = await read(db, s.target);
  const d150 = (await db.query('select (current_date-150)::text d')).rows[0].d;
  assert.equal(p.window.verifiedFrom, d150, 'the later of the two covered starts');
  assert.equal(p.window.canExtend, true);
  const r = (await db.query('select public.futbeat_request_match_h2h_history($1) v', [s.target])).rows[0].v;
  assert.equal(r.home.demandRecorded, true);
  assert.equal(r.away.demandRecorded, true);
  assert.equal(r.window.extending, true);
  const demands = (await db.query('select team_id,past_target::text t,reason from futbeat_private.team_match_demands order by team_id')).rows;
  const expectedTarget = async (days) => (await db.query('select (current_date-$1::integer)::text d', [days])).rows[0].d;
  assert.deepEqual(new Map(demands.map((d) => [d.team_id, d.t])), new Map([
    [s.A, await expectedTarget(360)], [s.B, await expectedTarget(330)]]));
  assert.ok(demands.every((d) => d.reason === 'history'));
  // Repeated taps: still one demand per team.
  for (let i = 0; i < 20; i++) await db.query('select public.futbeat_request_match_h2h_history($1)', [s.target]);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.team_match_demands')).rows[0].n, 2);
  // The plan asks exactly for the older missing window.
  const plan = (await db.query('select public.futbeat_team_fixtures_plan(10) v')).rows[0].v;
  assert.ok(plan.every((x) => x.mode === 'history'));
}));

test('window: at the 3-year floor there is nothing more to ask; unmapped teams never extend', () => withDb(async (db) => {
  const s = await history(db, 1);
  await coverFrom(db, s.A, 1095); await coverFrom(db, s.B, 1095);
  const p = await read(db, s.target);
  assert.equal(p.window.canExtend, false);
  const r = (await db.query('select public.futbeat_request_match_h2h_history($1) v', [s.target])).rows[0].v;
  assert.equal(r.requested, false, 'nothing older to ask for');
  assert.equal((await db.query('select count(*)::int n from futbeat_private.team_match_demands')).rows[0].n, 0);
  const X = await team(db, 'Sin fuente', { mapped: false }); const Y = await team(db, 'Sin fuente 2', { mapped: false });
  const orphan = await match(db, { comp: s.liga, home: X, away: Y, at: Date.now() + DAY, status: 'SCHEDULED', score: null });
  assert.equal((await read(db, orphan)).window.canExtend, false);
  assert.equal((await db.query('select public.futbeat_request_match_h2h_history($1) v', [orphan])).rows[0].v.requested, false);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.team_match_demands')).rows[0].n, 0);
}));

test('window: extending is per team (a stale profile demand of one side never hides or fakes the other)', () => withDb(async (db) => {
  const s = await history(db, 1);
  await coverFrom(db, s.A, 180); await coverFrom(db, s.B, 180);
  // A profile demand without an older target on A: nothing is extending.
  await db.query("insert into futbeat_private.team_match_demands(team_id,reason) values($1,'profile')", [s.A]);
  assert.equal((await read(db, s.target)).window.extending, false);
  // B asks for an older range: extending, although A's row has no target.
  await db.query("insert into futbeat_private.team_match_demands(team_id,reason,past_target) values($1,'history',current_date-360)", [s.B]);
  assert.equal((await read(db, s.target)).window.extending, true);
  // While a step is in flight, another extend adds nothing.
  const r = (await db.query('select public.futbeat_request_match_h2h_history($1) v', [s.target])).rows[0].v;
  assert.equal(r.requested, false);
  const rows = (await db.query('select team_id,past_target from futbeat_private.team_match_demands order by team_id')).rows;
  assert.equal(rows.find((x) => x.team_id === s.A).past_target, null);
}));

// ---------------------------------------------------------------------------
// API, mobile, query plan
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
    const response = await context.__api.fetch(new Request(`https://api.test/functions/v1/futbeat-api/v1/match-h2h${query}`));
    return { status: response.status, body: await response.json(), cache: response.headers.get('cache-control') };
  };
  return { call, rpcs };
}

test('API: GET /v1/match-h2h pages, validates, and extend=1 records demand without caching', () => withDb(async (db) => {
  const s = await history(db, 12);
  await coverFrom(db, s.A, 180); await coverFrom(db, s.B, 180);
  const { call, rpcs } = await api(db);
  const first = await call(`?id=${s.target}&limit=5`);
  assert.equal(first.status, 200);
  assert.equal(first.body.meetings.length, 5);
  assert.match(first.cache, /max-age/);
  const next = await call(`?id=${s.target}&limit=5&cursor=${encodeURIComponent(first.body.nextCursor)}`);
  assert.equal(next.body.meetings.length, 5);
  assert.equal((await call('?id=nope')).status, 400);
  assert.equal((await call(`?id=${s.target}&scope=all&cursor=x`)).status, 400);
  assert.equal((await call(`?id=${s.target}&scope=other`)).status, 400);
  assert.equal((await call('?id=fb_match_does_not_exist')).status, 404);
  assert.deepEqual([...new Set(rpcs)], ['futbeat_read_match_h2h']);
  const extended = await call(`?id=${s.target}&extend=1`);
  assert.equal(extended.cache, 'no-store');
  assert.equal(extended.body.window.extending, true);
  assert.ok(rpcs.includes('futbeat_request_match_h2h_history'));
}));

test('mobile contains no provider URL or call', async () => {
  const offenders = [];
  const walk = async (dir) => {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const path = new URL(entry.name + (entry.isDirectory() ? '/' : ''), dir);
      if (entry.isDirectory()) await walk(path);
      else if (entry.name.endsWith('.dart')) {
        const source = (await readFile(path, 'utf8')).toLowerCase();
        for (const host of ['api.goal-api.com', 'goal-api.com/v1', 'api-sports.io', 'api-football', 'thesportsdb']) {
          if (source.includes(host)) offenders.push(`${entry.name}:${host}`);
        }
      }
    }
  };
  await walk(new URL('../../apps/mobile/lib/', import.meta.url));
  assert.deepEqual(offenders, []);
});

test('the pair lookup uses the home/away team indexes (no global scan)', () => withDb(async (db) => {
  await db.exec(`insert into futbeat_private.entities(id,kind,payload)
    select 'fb_match_hfx'||i,'match',jsonb_build_object('id','fb_match_hfx'||i,'homeTeamId','fb_team_hfx'||(i%700),
      'awayTeamId','fb_team_hfx'||((i*7+3)%700),'status','VERIFIED','startTime',(now()-make_interval(hours=>i))::text)
    from generate_series(1,8000) i;
    analyze futbeat_private.entities;`);
  await db.exec('set enable_seqscan = off');
  const sql = `explain select e.id from futbeat_private.entities e
    where e.kind='match' and e.payload->>'homeTeamId'=any($1::text[]) and e.payload->>'awayTeamId'=any($1::text[])
      and ((e.payload->>'homeTeamId'=any($2::text[]) and e.payload->>'awayTeamId'=any($3::text[]))
        or (e.payload->>'homeTeamId'=any($3::text[]) and e.payload->>'awayTeamId'=any($2::text[])))`;
  const plan = (await db.query(sql, [['fb_team_hfx1', 'fb_team_hfx10'], ['fb_team_hfx1'], ['fb_team_hfx10']])).rows
    .map((r) => r['QUERY PLAN']).join('\n');
  await db.exec('reset enable_seqscan');
  assert.match(plan, /entities_match_(home|away)_team_idx/);
  assert.doesNotMatch(plan, /Seq Scan/);
  const migration = await readFile(new URL('../../supabase/migrations/20260929130000_h2h_full_history.sql', import.meta.url), 'utf8');
  assert.match(migration, /e\.payload->>'homeTeamId'=any\(home_alias\|\|away_alias\)/);
  assert.match(migration, /e\.payload->>'awayTeamId'=any\(home_alias\|\|away_alias\)/);
}));
