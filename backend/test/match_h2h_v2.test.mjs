import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import * as matchDetail from '../../supabase/functions/_shared/match_detail.ts';
import * as calendarCache from '../../supabase/functions/_shared/calendar_cache.ts';

// #99 v2: Cara a cara. Synthetic ids/names only (no real team or
// competition is special-cased); DB-only reads; no provider call anywhere.

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
  const id = `fb_team_h2${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'team',$2)", [id, JSON.stringify({ id, name })]);
  if (mapped) await db.query("insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) values('goal_api','team',$1,$2)", [`h2-ext-${seq}`, id]);
  return id;
}
async function competition(db, name = 'Liga H2H') {
  const id = `fb_comp_h2${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'competition',$2)", [id, JSON.stringify({ id, name })]);
  return id;
}
async function match(db, { comp, home, away, at, status = 'VERIFIED', score = [1, 0], extra = {} }) {
  const id = `fb_match_h2${++seq}`;
  await db.query("insert into futbeat_private.entities values($1,'match',$2)", [id, JSON.stringify({
    id, competitionId: comp, homeTeamId: home, awayTeamId: away, startTime: iso(at), status,
    ...(score ? { score: { home: score[0], away: score[1] } } : {}), events: [], statistics: [], ...extra })]);
  return id;
}
const h2h = async (db, id) => (await db.query('select public.futbeat_read_match_preview($1) v', [id])).rows[0].v.h2h;
const requestH2h = async (db, id) => (await db.query('select public.futbeat_request_match_h2h($1) v', [id])).rows[0].v;
const coverAvailable = (db, id) => db.query(`insert into futbeat_private.team_match_coverage(team_id,status,covered_from,covered_to,window_complete,last_success_at)
  values($1,'AVAILABLE',current_date-400,current_date+200,true,now())`, [id]);

async function pair(db) {
  const comp = await competition(db);
  const cup = await competition(db, 'Copa H2H');
  const A = await team(db, 'Equipo Alfa');
  const B = await team(db, 'Equipo Beta');
  return { comp, cup, A, B, now: Date.now() };
}

// ---------------------------------------------------------------------------

test('1. pair(A,B) == pair(B,A)', () => withDb(async (db) => {
  const { comp, A, B, now } = await pair(db);
  const ab = await match(db, { comp, home: A, away: B, at: now + 5 * DAY, status: 'SCHEDULED', score: null });
  const ba = await match(db, { comp, home: B, away: A, at: now + 9 * DAY, status: 'SCHEDULED', score: null });
  const [x, y] = [await h2h(db, ab), await h2h(db, ba)];
  assert.equal(x.pairKey, y.pairKey);
  assert.equal(x.pairKey, [A, B].sort().join('|'));
}));

test('2. reversed historical home/away counts for the right team (by id)', () => withDb(async (db) => {
  const { comp, A, B, now } = await pair(db);
  // Target A (home) vs B. History: B 2-0 A at B's home, A 1-0 B, 1-1.
  const target = await match(db, { comp, home: A, away: B, at: now + 3 * DAY, status: 'SCHEDULED', score: null });
  await match(db, { comp, home: B, away: A, at: now - 30 * DAY, score: [2, 0] });
  await match(db, { comp, home: A, away: B, at: now - 60 * DAY, score: [1, 0] });
  await match(db, { comp, home: B, away: A, at: now - 90 * DAY, score: [1, 1] });
  const v = await h2h(db, target);
  assert.deepEqual(v.totals, { homeWins: 1, draws: 1, awayWins: 1, counted: 3 });
  assert.deepEqual(v.meetings.map((m) => m.result), ['LOSS', 'WIN', 'DRAW']); // from A's (target home) side
}));

test('3/4/5/18. scheduled or live target is `current` and not counted; a final target counts once', () => withDb(async (db) => {
  const { comp, A, B, now } = await pair(db);
  await match(db, { comp, home: A, away: B, at: now - 100 * DAY, score: [3, 0] });
  const scheduled = await match(db, { comp, home: A, away: B, at: now + 2 * DAY, status: 'SCHEDULED', score: null });
  let v = await h2h(db, scheduled);
  assert.equal(v.current.matchId, scheduled);
  assert.equal(v.current.status, 'SCHEDULED');
  assert.equal(v.totals.counted, 1);
  assert.ok(!v.meetings.some((m) => m.matchId === scheduled));

  const live = await match(db, { comp, home: B, away: A, at: now - 30 * 60e3, status: 'LIVE', score: [2, 0],
    extra: { provenance: { receivedAt: iso(now - 60e3) } } });
  v = await h2h(db, live);
  assert.equal(v.current.status, 'LIVE');
  assert.deepEqual(v.current.score, { home: 2, away: 0 });
  assert.equal(v.totals.counted, 1, 'a live score never counts');

  const final = await match(db, { comp, home: A, away: B, at: now - 2 * DAY, status: 'VERIFIED', score: [0, 1] });
  v = await h2h(db, final);
  assert.equal(v.current, undefined);
  assert.equal(v.totals.counted, 2);
  assert.equal(v.meetings.filter((m) => m.matchId === final).length, 1, 'never duplicated');
  assert.equal(v.meetings[0].matchId, final);
  // Legacy contract untouched: meetings strictly before the target.
  assert.ok(!v.matchIds.includes(final));
}));

test('6/7/8. several competitions, "Este torneo" totals, newest first', () => withDb(async (db) => {
  const { comp, cup, A, B, now } = await pair(db);
  const target = await match(db, { comp, home: A, away: B, at: now + DAY, status: 'SCHEDULED', score: null });
  await match(db, { comp, home: A, away: B, at: now - 10 * DAY, score: [2, 1] });
  await match(db, { comp: cup, home: B, away: A, at: now - 20 * DAY, score: [3, 0] });
  await match(db, { comp: cup, home: A, away: B, at: now - 40 * DAY, score: [0, 0] });
  await match(db, { comp, home: B, away: A, at: now - 80 * DAY, score: [1, 2] });
  const v = await h2h(db, target);
  assert.deepEqual(v.totals, { homeWins: 2, draws: 1, awayWins: 1, counted: 4 });
  assert.deepEqual(v.competitionTotals, { competitionId: comp, homeWins: 2, draws: 0, awayWins: 0, counted: 2 });
  const times = v.meetings.map((m) => Date.parse(m.startTime));
  assert.deepEqual(times, [...times].sort((a, b) => b - a));
  assert.equal(new Set(v.meetings.map((m) => m.competitionId)).size, 2);
}));

test('9/15. aliases converge on the canonical pair; same-named teams are never merged', () => withDb(async (db) => {
  const { comp, A, B, now } = await pair(db);
  const aliasA = await team(db, 'Equipo Alfa (antiguo)');
  await db.query("insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason) values($1,$2,'team','test')", [aliasA, A]);
  const namesake = await team(db, 'Equipo Beta'); // same name as B, different identity
  const target = await match(db, { comp, home: A, away: B, at: now + DAY, status: 'SCHEDULED', score: null });
  const viaAlias = await match(db, { comp, home: B, away: aliasA, at: now - 15 * DAY, score: [0, 2] });
  await match(db, { comp, home: A, away: namesake, at: now - 25 * DAY, score: [5, 0] });
  const v = await h2h(db, target);
  assert.deepEqual(v.meetings.map((m) => m.matchId), [viaAlias]);
  assert.equal(v.meetings[0].awayTeamId, A, 'ids resolved to the canonical team');
  assert.equal(v.meetings[0].result, 'WIN');
}));

test('16/17. reschedule never duplicates; effective lifecycle decides what counts', () => withDb(async (db) => {
  const { comp, A, B, now } = await pair(db);
  const target = await match(db, { comp, home: A, away: B, at: now + DAY, status: 'SCHEDULED', score: null });
  const moved = await match(db, { comp, home: A, away: B, at: now - 50 * DAY, score: [1, 0] });
  await db.query("update futbeat_private.entities set payload=jsonb_set(payload,'{startTime}',to_jsonb($2::text)) where id=$1",
    [moved, iso(now - 45 * DAY)]);
  // Raw SCHEDULED in the past, but a final whistle was recorded: counts.
  const evidenced = await match(db, { comp, home: B, away: A, at: now - 5 * DAY, status: 'SCHEDULED', score: [2, 2] });
  await db.query(`insert into futbeat_private.canonical_events(id,match_id,provider,event_type,payload,first_seen_at)
    values('fb_event_h2_ft',$1,'goal_api','FULL_TIME','{}',now()-interval '4 days')`, [evidenced]);
  // Never counted: postponed, cancelled, a stale raw LIVE, a raw SCHEDULED with no evidence.
  await match(db, { comp, home: A, away: B, at: now - 7 * DAY, status: 'POSTPONED', score: null });
  await match(db, { comp, home: A, away: B, at: now - 8 * DAY, status: 'CANCELLED', score: null });
  await match(db, { comp, home: A, away: B, at: now - 9 * DAY, status: 'LIVE', score: [4, 0],
    extra: { provenance: { receivedAt: iso(now - 9 * DAY) } } });
  await match(db, { comp, home: A, away: B, at: now - 11 * DAY, status: 'SCHEDULED', score: null });
  const v = await h2h(db, target);
  assert.deepEqual(v.meetings.map((m) => m.matchId), [evidenced, moved]);
  assert.equal(v.meetings[0].status, 'FINISHED_PENDING_VERIFICATION');
  assert.deepEqual(v.totals, { homeWins: 1, draws: 1, awayWins: 0, counted: 2 });
}));

// ---------------------------------------------------------------------------
// Availability and central coverage demand
// ---------------------------------------------------------------------------

test('10. cache hit (both teams covered) creates no demand and reads AVAILABLE', () => withDb(async (db) => {
  const { comp, A, B, now } = await pair(db);
  await coverAvailable(db, A); await coverAvailable(db, B);
  const target = await match(db, { comp, home: A, away: B, at: now + DAY, status: 'SCHEDULED', score: null });
  await match(db, { comp, home: B, away: A, at: now - 30 * DAY });
  const r = await requestH2h(db, target);
  assert.equal(r.home.demandRecorded, false);
  assert.equal(r.away.demandRecorded, false);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.team_match_demands')).rows[0].n, 0);
  assert.equal((await h2h(db, target)).availability, 'AVAILABLE');
}));

test('11/12/13. no local history + incomplete coverage is PENDING and one central demand per team', () => withDb(async (db) => {
  const { comp, A, B, now } = await pair(db);
  const target = await match(db, { comp, home: A, away: B, at: now + DAY, status: 'SCHEDULED', score: null });
  const v = await h2h(db, target);
  assert.equal(v.availability, 'PENDING', 'a cache miss is never "no previous meetings"');
  assert.notEqual(v.availability, 'CONFIRMED_EMPTY');
  for (let i = 0; i < 50; i++) await requestH2h(db, target);
  const rows = (await db.query('select team_id,request_count from futbeat_private.team_match_demands order by team_id')).rows;
  assert.deepEqual(rows.map((r) => r.team_id), [A, B].sort());
  assert.ok(rows.every((r) => r.request_count === 1));
  // Data but one side still incomplete: shown, marked STALE.
  await match(db, { comp, home: A, away: B, at: now - 10 * DAY });
  await coverAvailable(db, A);
  assert.equal((await h2h(db, target)).availability, 'STALE');
}));

test('14. CONFIRMED_EMPTY only when both teams were verified; no source is UNAVAILABLE', () => withDb(async (db) => {
  const { comp, A, B, now } = await pair(db);
  await coverAvailable(db, A); await coverAvailable(db, B);
  const target = await match(db, { comp, home: A, away: B, at: now + DAY, status: 'SCHEDULED', score: null });
  const v = await h2h(db, target);
  assert.equal(v.availability, 'CONFIRMED_EMPTY');
  const expectedFrom = (await db.query("select (current_date-400)::text d")).rows[0].d;
  assert.equal(v.coverage.verifiedFrom, expectedFrom);
  // Provider NO_DATA on one side also verifies it.
  await db.query("update futbeat_private.team_match_coverage set status='NO_DATA',covered_from=null,covered_to=null,window_complete=false,next_retry_at=now()+interval '5 days' where team_id=$1", [B]);
  assert.equal((await h2h(db, target)).availability, 'CONFIRMED_EMPTY');
  const X = await team(db, 'Sin Fuente', { mapped: false });
  const Y = await team(db, 'Sin Fuente Dos', { mapped: false });
  const orphan = await match(db, { comp, home: X, away: Y, at: now + DAY, status: 'SCHEDULED', score: null });
  assert.equal((await h2h(db, orphan)).availability, 'UNAVAILABLE');
  assert.equal((await requestH2h(db, orphan)).home.demandRecorded, false);
}));

// ---------------------------------------------------------------------------
// API, mobile and query plan
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
    const response = await context.__api.fetch(new Request(`https://api.test/functions/v1/futbeat-api/v1/match-preview${query}`));
    return { status: response.status, body: await response.json(), cache: response.headers.get('cache-control') };
  };
  return { call, rpcs };
}

test('API: opening Cara a cara records coverage demand; PENDING is never cached', () => withDb(async (db) => {
  const { comp, A, B, now } = await pair(db);
  const target = await match(db, { comp, home: A, away: B, at: now + DAY, status: 'SCHEDULED', score: null });
  const { call, rpcs } = await api(db);
  const first = await call(`?id=${target}`);
  assert.equal(first.status, 200);
  assert.equal(first.body.h2h.availability, 'PENDING');
  assert.equal(first.cache, 'no-store');
  assert.deepEqual([...new Set(rpcs)], ['futbeat_request_match_h2h', 'futbeat_read_match_preview']);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.team_match_demands')).rows[0].n, 2);
  await coverAvailable(db, A); await coverAvailable(db, B);
  const covered = await call(`?id=${target}`);
  assert.equal(covered.body.h2h.availability, 'CONFIRMED_EMPTY');
  assert.match(covered.cache, /max-age/);
}));

test('19. mobile contains no provider URL or call', async () => {
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

test('20. the pair lookup uses the home/away team indexes (no global scan)', () => withDb(async (db) => {
  await db.exec(`insert into futbeat_private.entities(id,kind,payload)
    select 'fb_match_hx'||i,'match',jsonb_build_object('id','fb_match_hx'||i,'homeTeamId','fb_team_hx'||(i%700),
      'awayTeamId','fb_team_hx'||((i*7+3)%700),'status','VERIFIED','startTime',(now()-make_interval(hours=>i))::text)
    from generate_series(1,8000) i;
    analyze futbeat_private.entities;`);
  await db.exec('set enable_seqscan = off');
  const sql = `explain select e.id from futbeat_private.entities e
    where e.kind='match' and e.payload->>'homeTeamId'=any($1::text[]) and e.payload->>'awayTeamId'=any($1::text[])
      and ((e.payload->>'homeTeamId'=any($2::text[]) and e.payload->>'awayTeamId'=any($3::text[]))
        or (e.payload->>'homeTeamId'=any($3::text[]) and e.payload->>'awayTeamId'=any($2::text[])))`;
  const plan = (await db.query(sql, [['fb_team_hx1', 'fb_team_hx10'], ['fb_team_hx1'], ['fb_team_hx10']])).rows
    .map((r) => r['QUERY PLAN']).join('\n');
  await db.exec('reset enable_seqscan');
  assert.match(plan, /entities_match_(home|away)_team_idx/);
  assert.doesNotMatch(plan, /Seq Scan/);
  // The migration uses that same predicate shape.
  const migration = await readFile(new URL('../../supabase/migrations/20260929120000_match_h2h_v2.sql', import.meta.url), 'utf8');
  assert.match(migration, /e\.payload->>'homeTeamId'=any\(home_alias\|\|away_alias\)/);
  assert.match(migration, /e\.payload->>'awayTeamId'=any\(home_alias\|\|away_alias\)/);
}));

// ---------------------------------------------------------------------------
// #99 v2 follow-up: cache policy, on-demand wake, verified window
// ---------------------------------------------------------------------------

// Local stand-ins for pg_net / Vault so the real wake path runs (no network:
// the stub only records the POST it would send).
async function stubWake(db) {
  await db.exec(`
    create schema if not exists net;
    create table if not exists net.http_calls(id serial primary key,url text,headers jsonb,body jsonb);
    create or replace function net.http_post(url text,headers jsonb default '{}',body jsonb default '{}',
      timeout_milliseconds integer default 1000) returns bigint language sql as
      'insert into net.http_calls(url,headers,body) values(url,headers,body) returning id';
    create schema if not exists vault;
    create table if not exists vault.decrypted_secrets(name text,decrypted_secret text,updated_at timestamptz,created_at timestamptz);
    insert into vault.decrypted_secrets values('futbeat_goal_live_cron_token','test-only-token',now(),now());`);
}
const wakes = (db) => db.query("select count(*)::int n from net.http_calls where body->>'trigger'='team-fixtures-only'").then((r) => r.rows[0].n);
const wakeRow = (db) => db.query("select * from futbeat_private.worker_wakeups where trigger='team-fixtures-only'").then((r) => r.rows[0]);
const finishRun = (db, release = false) => db.query('select public.futbeat_finish_team_fixtures_run($1) v', [release]).then((r) => r.rows[0].v);
const requestTeam = (db, id) => db.query('select public.futbeat_request_team_matches($1) v', [id]).then((r) => r.rows[0].v);

test('cache: PENDING and STALE are no-store; AVAILABLE and CONFIRMED_EMPTY use the normal policy', () => withDb(async (db) => {
  const { comp, A, B, now } = await pair(db);
  const target = await match(db, { comp, home: A, away: B, at: now + DAY, status: 'SCHEDULED', score: null });
  const { call } = await api(db);
  let r = await call(`?id=${target}`);
  assert.deepEqual([r.body.h2h.availability, r.cache], ['PENDING', 'no-store']);
  await match(db, { comp, home: B, away: A, at: now - 20 * DAY });
  await coverAvailable(db, A);
  r = await call(`?id=${target}`);
  assert.deepEqual([r.body.h2h.availability, r.cache], ['STALE', 'no-store']);
  await coverAvailable(db, B);
  r = await call(`?id=${target}`);
  assert.equal(r.body.h2h.availability, 'AVAILABLE');
  assert.match(r.cache, /max-age/);
  const C = await team(db, 'Equipo Gamma'); const D = await team(db, 'Equipo Delta');
  await coverAvailable(db, C); await coverAvailable(db, D);
  const empty = await match(db, { comp, home: C, away: D, at: now + DAY, status: 'SCHEDULED', score: null });
  r = await call(`?id=${empty}`);
  assert.equal(r.body.h2h.availability, 'CONFIRMED_EMPTY');
  assert.match(r.cache, /max-age/);
}));

test('wake: a new demand wakes once; 100 opens are one wake; covered, unmapped or NO_DATA teams never wake', () => withDb(async (db) => {
  await stubWake(db);
  const { A, B } = await pair(db);
  assert.equal((await requestTeam(db, A)).wake, 'queued');
  for (let i = 0; i < 99; i++) await requestTeam(db, A);
  assert.equal(await wakes(db), 1, 'one POST, not one per open');
  const payload = (await db.query('select headers,body from net.http_calls')).rows[0];
  assert.deepEqual(payload.body, { trigger: 'team-fixtures-only' });
  assert.equal(payload.headers['x-futbeat-cron-token'], 'test-only-token');
  // While the run lease is held, another team's demand only marks pending.
  assert.equal((await requestTeam(db, B)).wake, 'pending');
  assert.equal(await wakes(db), 1);
  assert.equal((await wakeRow(db)).pending, true);
  await finishRun(db, true);
  // No wake without a demand write: covered, no source, provider NO_DATA.
  const covered = await team(db, 'Cubierto'); await coverAvailable(db, covered);
  const unmapped = await team(db, 'Sin fuente', { mapped: false });
  const empty = await team(db, 'Sin partidos');
  await db.query(`insert into futbeat_private.team_match_coverage(team_id,status,next_retry_at)
    values($1,'NO_DATA',now()+interval '5 days')`, [empty]);
  for (const id of [covered, unmapped, empty]) {
    const r = await requestTeam(db, id);
    assert.equal(r.demandRecorded, false, id);
    assert.equal(r.wake, undefined, id);
  }
  assert.equal(await wakes(db), 1);
}));

test('wake: home + away of one Cara a cara are two demands and neither is dropped by the debounce', () => withDb(async (db) => {
  await stubWake(db);
  const { comp, A, B, now } = await pair(db);
  const target = await match(db, { comp, home: A, away: B, at: now + DAY, status: 'SCHEDULED', score: null });
  const r = await requestH2h(db, target);
  assert.deepEqual([r.home.wake, r.away.wake], ['queued', 'pending']);
  assert.equal((await db.query('select count(*)::int n from futbeat_private.team_match_demands')).rows[0].n, 2);
  assert.equal(await wakes(db), 1);
  // Both are due for the (single) run.
  const due = (await db.query('select public.futbeat_team_fixtures_plan(10) v')).rows[0].v.map((x) => x.teamId).sort();
  assert.deepEqual(due, [A, B].sort());
  // The run sees `pending` (and the queued demands) -> one more round.
  const next = await finishRun(db);
  assert.equal(next.again, true);
  assert.equal(next.pending, true);
  assert.ok(new Date((await wakeRow(db)).running_until) > new Date());
  // While both are still due, another round is kept even without pending.
  const still = await finishRun(db);
  assert.deepEqual([still.again, still.pending, still.due], [true, false, true]);
  // Once processed (attempted), the run releases the lease.
  await db.query('insert into futbeat_private.team_match_coverage(team_id,last_attempt_at) values($1,now()),($2,now())', [A, B]);
  assert.deepEqual(await finishRun(db), { again: false, pending: false, due: false });
  assert.equal((await wakeRow(db)).running_until, null);
  // After the release the next demand wakes a new run at once.
  const C = await team(db, 'Equipo Tardío');
  assert.equal((await requestTeam(db, C)).wake, 'queued');
  assert.equal(await wakes(db), 2);
}));

test('wake: a crashed run never blocks forever (lease expiry); no worker URL keeps no lease', () => withDb(async (db) => {
  await stubWake(db);
  const { A, B } = await pair(db);
  await requestTeam(db, A);
  await db.query("update futbeat_private.worker_wakeups set running_until=now()-interval '1 second' where trigger='team-fixtures-only'");
  assert.equal((await requestTeam(db, B)).wake, 'queued');
  await db.query("delete from futbeat_private.runtime_settings where key='goal_worker_url'");
  await db.query("update futbeat_private.worker_wakeups set running_until=null where trigger='team-fixtures-only'");
  const C = await team(db, 'Equipo Sin Worker');
  assert.equal((await requestTeam(db, C)).wake, 'unavailable');
  assert.equal((await wakeRow(db)).running_until, null);
}));

test('verifiedFrom is null unless both teams have an explicit covered window', () => withDb(async (db) => {
  const { comp, A, B, now } = await pair(db);
  await coverAvailable(db, A);
  await db.query(`insert into futbeat_private.team_match_coverage(team_id,status,next_retry_at)
    values($1,'NO_DATA',now()+interval '5 days')`, [B]);
  const target = await match(db, { comp, home: A, away: B, at: now + DAY, status: 'SCHEDULED', score: null });
  const v = await h2h(db, target);
  assert.equal(v.availability, 'CONFIRMED_EMPTY');
  assert.equal(v.coverage.verifiedFrom, undefined, 'no date claimed for an unbounded NO_DATA side');
}));

test('no new cron; quota policy untouched by the wake path', async () => {
  const migration = await readFile(new URL('../../supabase/migrations/20260929120000_match_h2h_v2.sql', import.meta.url), 'utf8');
  const code = migration.replace(/--[^\n]*/g, '');
  assert.doesNotMatch(code, /cron\.|schedule\s*\(/i);
  assert.doesNotMatch(code, /provider_quota_policy|class_floors|kind_daily_caps/);
  const worker = await readFile(new URL('../../supabase/functions/futbeat-goal-live-sync/index.ts', import.meta.url), 'utf8');
  // The drain runs only for the explicit trigger (manual or on-demand wake).
  assert.equal(worker.match(/syncTeamFixturesOnly\(\)/g).length, 2);
  assert.match(worker, /trigger === "team-fixtures-only"/);
});
