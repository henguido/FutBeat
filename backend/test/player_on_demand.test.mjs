import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';

// Player discovery + profile hydration on demand, end to end and offline:
// real SQL (PGlite) + the real GOAL worker code with a simulated GOAL API.

const token = 'test-only-cron-token-not-a-secret-123456789';
const goalKey = 'test-only-goal-key-not-a-secret-XYZ';
const cdn = (name) => `https://media.goal-api.com/players/${name}.png`;
const read = (path) => readFile(new URL(`../../supabase/functions/${path}`, import.meta.url), 'utf8');
const [workerSource, paginationSource, playersSource, liveEventsSource] = await Promise.all([
  read('futbeat-goal-live-sync/index.ts'), read('_shared/results_pagination.ts'), read('_shared/goal_players.ts'),
  read('_shared/live_events.ts')]);
const stripImports = (source) => source.replace(/^import\s[\s\S]*?;\r?\n/gm, '');
const stripExports = (source) => source.replace(/^export /gm, '');

const search = (db, q) => db.query('select public.futbeat_search_catalog($1,null,50) v', [q]).then((r) => r.rows[0].v);
const names = (snapshot) => snapshot.players.map((p) => p.name);
const count = (db, sql, params = []) => db.query(sql, params).then((r) => r.rows[0].n);
const providerCalls = (db, kind) => count(db,
  "select count(*)::int n from futbeat_private.provider_call_ledger where call_kind like 'player-%' and ($1::text is null or call_kind=$1)",
  [kind ?? null]);
const metric = (db, name) => count(db, 'select coalesce(sum(value),0)::int n from futbeat_private.demand_metrics where metric=$1', [name]);

// Real worker, real SQL RPCs, simulated GOAL. Every other URL fails the test.
function worker(db, goal) {
  const calls = [], logs = [], unexpected = [];
  const fetch = async (input, init = {}) => {
    const url = new URL(input);
    calls.push(url.href);
    if (url.origin === 'https://supabase.test' && url.pathname.startsWith('/rest/v1/rpc/')) {
      const name = url.pathname.split('/').at(-1);
      if (name === 'futbeat_read_goal_live_cron_token') return Response.json(token);
      if (name === 'futbeat_read_goal_live_secret') return Response.json(goalKey);
      const body = init.body ? JSON.parse(init.body) : {};
      const keys = Object.keys(body);
      const values = keys.map((k) => (body[k] !== null && typeof body[k] === 'object' ? JSON.stringify(body[k]) : body[k]));
      try {
        const result = (await db.query(`select public.${name}(${keys.map((k, i) => `${k}=>$${i + 1}`).join(',')}) v`, values)).rows[0]?.v;
        return Response.json(result ?? null);
      } catch (error) {
        return new Response(String(error.message), { status: 400 });
      }
    }
    if (url.origin === 'https://api.goal-api.com') {
      assert.equal(init.headers.Authorization, `Bearer ${goalKey}`);
      return goal(url);
    }
    unexpected.push(url.href);
    throw new Error(`Unexpected request ${url.href}`);
  };
  let handler;
  const context = vm.createContext({
    Request, Response, Headers, URL, AbortSignal, TextEncoder, crypto, performance, Error, fetch,
    console: { error: (...a) => logs.push(a), warn: (...a) => logs.push(a), log: (...a) => logs.push(a) },
    Deno: { env: { get: (n) => ({ SUPABASE_URL: 'https://supabase.test', SUPABASE_SERVICE_ROLE_KEY: 'svc' })[n] },
      serve: (fn) => { handler = fn; } },
  });
  const source = stripExports(paginationSource) + '\n' + stripExports(playersSource) + '\n' + stripExports(liveEventsSource) + '\n' + stripImports(workerSource);
  vm.runInContext(stripTypeScriptTypes(source), context);
  return {
    calls, logs, unexpected,
    goalCalls: () => calls.filter((u) => u.startsWith('https://api.goal-api.com')),
    async run(trigger = 'demand') {
      const response = await handler(new Request('https://worker.test/', { method: 'POST',
        headers: { 'x-futbeat-cron-token': token }, body: JSON.stringify({ trigger }) }));
      const text = await response.text();
      assert.deepEqual(unexpected, []);
      // The provider key never leaks into a response or a log line.
      assert.ok(!text.includes(goalKey), 'key in response');
      assert.ok(!JSON.stringify(logs).includes(goalKey), 'key in logs');
      return JSON.parse(text);
    },
  };
}

const ok = (data, remaining = 777) => new Response(JSON.stringify({ success: true, data }),
  { status: 200, headers: { 'x-ratelimit-remaining': String(remaining), 'content-type': 'application/json' } });
const notFound = () => new Response(JSON.stringify({ success: false }), { status: 404 });

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

async function seedTeam(db) {
  await db.query(`insert into futbeat_private.entities values('fb_team_od','team','{"id":"fb_team_od","name":"Inter Miami"}')`);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','team','goal-team-miami','fb_team_od')");
}

test('local player exists -> no demand, 0 provider calls', () => withDb(async (db) => {
  await db.query(`insert into futbeat_private.entities values('fb_player_od_local','player','{"id":"fb_player_od_local","name":"Lionel Messi"}')`);
  for (const q of ['messi', 'lionel messi', 'Messi']) {
    const snapshot = await search(db, q);
    assert.deepEqual(names(snapshot), ['Lionel Messi']);
    assert.equal(snapshot.coverage.pendingRemote, undefined);
  }
  assert.equal(await count(db, 'select count(*)::int n from futbeat_private.player_search_demands'), 0);
  assert.equal(await providerCalls(db), 0);
}));

test('short queries never create player demand', () => withDb(async (db) => {
  for (const q of ['ab', 'a.b', 'x y', '..']) await search(db, q);
  assert.equal(await count(db, 'select count(*)::int n from futbeat_private.player_search_demands'), 0);
}));

test('a matching team never suppresses player discovery; the team is still returned', () => withDb(async (db) => {
  await seedTeam(db);
  const snapshot = await search(db, 'inter miami');
  assert.deepEqual(snapshot.teams.map((t) => t.name), ['Inter Miami']);
  assert.equal(snapshot.coverage.pendingRemote, true);
  assert.deepEqual((await db.query('select query_key from futbeat_private.player_search_demands')).rows,
    [{ query_key: 'inter miami' }]);
}));

test('unknown player: one demand; 100 identical searches -> one row and one provider call', () => withDb(async (db) => {
  const first = await search(db, 'Julián Álvarez');
  assert.equal(first.coverage.pendingRemote, true);
  assert.deepEqual(names(first), []);
  await Promise.all(Array.from({ length: 99 }, (_, i) => search(db, i % 2 ? 'julian alvarez' : 'JULIAN  ALVAREZ!')));
  assert.deepEqual((await db.query('select query_key,request_count::int n from futbeat_private.player_search_demands')).rows,
    [{ query_key: 'julian alvarez', n: 100 }]);
  assert.equal(await metric(db, 'player_search_demands'), 1);
  assert.equal(await metric(db, 'deduped_requests'), 99);
  const reservations = await Promise.all(Array.from({ length: 100 }, () =>
    db.query("select public.futbeat_reserve_player_call('test') v").then((r) => r.rows[0].v)));
  assert.equal(reservations.filter((r) => r.allowed).length, 1);
  assert.equal(await providerCalls(db), 1);
}));

test('provider result -> canonical, searchable, stored as received; searching again costs 0 calls', () => withDb(async (db) => {
  await seedTeam(db);
  await search(db, 'julian alvarez');
  const goal = worker(db, (url) => {
    assert.equal(url.pathname, '/v1/players/search');
    assert.equal(url.searchParams.get('q'), 'julian alvarez');
    return ok([
      { id: 'goal-ja', name: 'Julián Álvarez', nationality: 'Argentina', position: { name: 'Attacker' },
        birthDate: '2000-01-31', height: '1.70 m', photo: cdn('ja'), team: { id: 'goal-team-miami' } },
      { player: { id: 'goal-ja2', firstName: 'Julian', lastName: 'Alvarez Junior' } },
      { id: '', name: 'Sin Id' },
    ]);
  });
  const result = await goal.run();
  assert.deepEqual(result.players[0], { status: 'ok', kind: 'player-search', players: 2, created: 2, fieldsGained: result.players[0].fieldsGained });
  const player = (await db.query(`select e.payload from futbeat_private.provider_entities pe join futbeat_private.entities e
    on e.id=pe.canonical_id where pe.kind='player' and pe.external_id='goal-ja'`)).rows[0].payload;
  assert.deepEqual([player.name, player.country, player.position, player.dateOfBirth, player.height, player.teamId, player.media.url],
    ['Julián Álvarez', 'Argentina', 'Attacker', '2000-01-31', 170, 'fb_team_od', cdn('ja')]);
  assert.equal(player.preferredFoot, undefined, 'never invented');
  assert.equal((await db.query("select remaining from (select futbeat_private.provider_remaining('goal_api') remaining) x")).rows[0].remaining, 777);
  const again = await search(db, 'julian alvarez');
  assert.deepEqual(names(again), ['Julián Álvarez', 'Julian Alvarez Junior']);
  assert.equal(again.coverage.pendingRemote, undefined);
  assert.equal(goal.goalCalls().length, 1);
  await goal.run();
  assert.equal(goal.goalCalls().length, 1, 'nothing left to fetch');
  assert.equal(await metric(db, 'players_discovered'), 2);
}));

test('nonexistent player -> negative cache: later searches cost 0 calls', () => withDb(async (db) => {
  await search(db, 'zzqx nadie');
  const goal = worker(db, () => ok([]));
  await goal.run();
  const demand = (await db.query('select status,next_retry_at>now()+interval \'2 days\' cached from futbeat_private.player_search_demands')).rows[0];
  assert.deepEqual(demand, { status: 'NO_DATA', cached: true });
  for (let i = 0; i < 5; i++) assert.equal((await search(db, 'zzqx nadie')).coverage.pendingRemote, undefined);
  await goal.run();
  assert.equal(goal.goalCalls().length, 1);
  assert.equal(await metric(db, 'player_search_cache_hits'), 5);
}));

test('provider failure backs off (404 negative, 500 exponential) and the lease never double-fetches', () => withDb(async (db) => {
  await search(db, 'error uno');
  let status = 500;
  const goal = worker(db, () => new Response('{}', { status }));
  await goal.run();
  let row = (await db.query('select status,failure_count,next_retry_at>now() backoff,lease_until from futbeat_private.player_search_demands')).rows[0];
  assert.deepEqual([row.status, row.failure_count, row.backoff, row.lease_until], ['FETCH_FAILED', 1, true, null]);
  assert.equal((await db.query("select status,http_status from futbeat_private.provider_call_ledger where call_kind='player-search'")).rows[0].http_status, 500);
  await goal.run();
  assert.equal(goal.goalCalls().length, 1, 'backoff respected');
  await search(db, 'error dos');
  status = 404;
  await goal.run();
  row = (await db.query("select status from futbeat_private.player_search_demands where query_key='error dos'")).rows[0];
  assert.equal(row.status, 'NO_DATA');
}));

async function mappedPlayer(db, payload) {
  const id = (await db.query("select public.futbeat_resolve_global_entity('goal_api','player','goal-pp',$1) id", [payload.name])).rows[0].id;
  await db.query("update futbeat_private.entities set payload=payload||$2 where id=$1", [id, JSON.stringify(payload)]);
  return id;
}

test('poor profile -> hydrated with profile + season stats; partial data never erases valid fields', () => withDb(async (db) => {
  const id = await mappedPlayer(db, { name: 'Perfil Pobre', country: 'Costa Rica', shirtNumber: 9 });
  const demand = (await db.query('select public.futbeat_request_player_profile($1) v', [id])).rows[0].v;
  assert.deepEqual([demand.enrichmentPending, demand.profileDue, demand.statsDue], [true, true, true]);
  const goal = worker(db, (url) => url.pathname.endsWith('/statistics')
    ? ok([{ season: '2025', league: { name: 'Old' }, appearances: 30, goals: 9 },
      { season: '2026', league: { name: 'Liga Promerica' }, appearances: 12, lineups: 10, minutes: 900, goals: 7,
        assists: 3, cards: { yellow: 2, red: 0 }, rating: '7.4' }])
    : ok({ id: 'goal-pp', name: 'Perfil Pobre', nationality: '', height: 182, foot: 'Right', birthDate: '1999-05-14' }));
  const run = await goal.run();
  assert.deepEqual(run.players.map((r) => r.kind), ['player-profile', 'player-stats']);
  const player = (await db.query('select payload from futbeat_private.entities where id=$1', [id])).rows[0].payload;
  assert.deepEqual([player.country, player.height, player.preferredFoot, player.dateOfBirth, player.shirtNumber],
    ['Costa Rica', 182, 'right', '1999-05-14', 9]);
  const { source, receivedAt, ...season } = player.seasonStats;
  assert.equal(source, 'GOAL API');
  assert.deepEqual(season, { season: '2026', competition: 'Liga Promerica', matchesPlayed: 12, starts: 10, minutesPlayed: 900,
    goals: 7, assists: 3, yellowCards: 2, redCards: 0, rating: 7.4 });
  // Fresh profile: opening it again (many times) costs nothing.
  for (let i = 0; i < 3; i++) {
    assert.equal((await db.query('select public.futbeat_request_player_profile($1) v', [id])).rows[0].v.enrichmentPending, false);
  }
  await goal.run();
  assert.equal(goal.goalCalls().length, 2);
  assert.equal(await metric(db, 'player_profiles_hydrated'), 1);
}));

test('concurrent profile opens dedupe to one hydration; unmapped players never create demand', () => withDb(async (db) => {
  const id = await mappedPlayer(db, { name: 'Muy Abierto' });
  const opens = await Promise.all(Array.from({ length: 50 }, () =>
    db.query('select public.futbeat_request_player_profile($1) v', [id]).then((r) => r.rows[0].v)));
  assert.ok(opens.every((o) => o.enrichmentPending));
  assert.equal(await metric(db, 'player_profile_demands'), 1);
  assert.equal(await metric(db, 'deduped_requests'), 49);
  const reservations = await Promise.all(Array.from({ length: 20 }, () =>
    db.query("select public.futbeat_reserve_player_call('test') v").then((r) => r.rows[0].v)));
  assert.equal(reservations.filter((r) => r.allowed).length, 1);
  await db.query(`insert into futbeat_private.entities values('fb_player_od_unmapped','player','{"id":"fb_player_od_unmapped","name":"X"}')`);
  assert.deepEqual((await db.query("select public.futbeat_request_player_profile('fb_player_od_unmapped') v")).rows[0].v,
    { enrichmentPending: false, reason: 'unmapped' });
}));

test('empty provider profile/stats are NO_DATA and keep existing values', () => withDb(async (db) => {
  const id = await mappedPlayer(db, { name: 'Con Datos', dateOfBirth: '1990-01-01' });
  await db.query('select public.futbeat_request_player_profile($1)', [id]);
  const goal = worker(db, (url) => (url.pathname.endsWith('/statistics') ? ok([]) : ok({})));
  await goal.run();
  const row = (await db.query('select profile_status,stats_status from futbeat_private.player_profile_coverage')).rows[0];
  assert.deepEqual(row, { profile_status: 'NO_DATA', stats_status: 'NO_DATA' });
  const player = (await db.query('select payload from futbeat_private.entities where id=$1', [id])).rows[0].payload;
  assert.equal(player.dateOfBirth, '1990-01-01');
  assert.equal(player.seasonStats, undefined);
}));

test('quota: player demand is class user; below its floor nothing is reserved, LIVE keeps budget', () => withDb(async (db) => {
  await search(db, 'quota prueba');
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,provider_remaining)
    values('goal_api','live-goal','test',now(),now(),'SUCCEEDED',250)`);
  const denied = (await db.query("select public.futbeat_reserve_player_call('test') v")).rows[0].v;
  assert.deepEqual([denied.allowed, denied.reason], [false, 'provider_remaining_reserve']);
  assert.equal(await providerCalls(db), 0);
  assert.equal((await db.query("select futbeat_private.quota_decision('goal_api','match-detail','live') v")).rows[0].v.allowed, true);
}));

test('metrics expose demand, cache, dedupe, calls by kind and coverage gained per call', () => withDb(async (db) => {
  await search(db, 'julian alvarez');
  await search(db, 'julian alvarez');
  await worker(db, () => ok([{ id: 'goal-m', name: 'Julian Alvarez', nationality: 'Argentina' }])).run();
  const metrics = (await db.query('select public.futbeat_demand_metrics(1) v')).rows[0].v;
  assert.equal(metrics.counters.player_search_demands, 1);
  assert.equal(metrics.counters.deduped_requests, 1);
  assert.equal(metrics.counters.player_search_provider_calls, 1);
  assert.equal(metrics.callsByKind['player-search'], 1);
  assert.equal(metrics.providerRemaining, 777);
  assert.ok(metrics.coverageGainedPerProviderCall > 0);
}));

test('security: player demand/reserve/store are service-only; helpers private; worker requires token', () => withDb(async (db) => {
  const can = async (role, fn) => (await db.query("select has_function_privilege($1,$2,'EXECUTE') ok", [role, fn])).rows[0].ok;
  const publicFns = ['public.futbeat_request_player_profile(text)', 'public.futbeat_reserve_player_call(text)',
    'public.futbeat_store_player_search_result(bigint,jsonb,integer)', 'public.futbeat_store_player_profile(bigint,jsonb,integer)',
    'public.futbeat_store_player_stats(bigint,jsonb,integer)', 'public.futbeat_fail_player_call(bigint,text,integer,text,integer)',
    'public.futbeat_demand_metrics(integer)'];
  for (const role of ['anon', 'authenticated']) for (const fn of publicFns) assert.equal(await can(role, fn), false, `${role} ${fn}`);
  for (const fn of publicFns) assert.equal(await can('service_role', fn), true, fn);
  for (const role of ['anon', 'authenticated', 'service_role']) {
    for (const fn of ['futbeat_private.note_player_search_demand(text)', 'futbeat_private.upsert_goal_player(jsonb,text,timestamp with time zone)',
      'futbeat_private.player_hydration_due(text)']) assert.equal(await can(role, fn), false, `${role} ${fn}`);
  }
  for (const table of ['player_search_demands', 'player_profile_coverage']) {
    assert.equal((await db.query("select has_table_privilege('anon',$1,'SELECT') ok", [`futbeat_private.${table}`])).rows[0].ok, false);
  }
  // A stored result can only complete its own RESERVED ledger row.
  await assert.rejects(db.query("select public.futbeat_store_player_search_result(999999,'[]')"), /Unknown or completed/);
  const goal = worker(db, () => ok([]));
  const forged = await (async () => {
    let handler;
    const context = vm.createContext({ Request, Response, Headers, URL, AbortSignal, TextEncoder, crypto, performance, Error,
      fetch: async (u) => (String(u).includes('cron_token') ? Response.json(token) : Response.json(null)),
      console: { error() {}, warn() {}, log() {} },
      Deno: { env: { get: () => 'x' }, serve: (fn) => { handler = fn; } } });
    vm.runInContext(stripTypeScriptTypes(stripExports(paginationSource) + stripExports(playersSource) + stripExports(liveEventsSource) + stripImports(workerSource)), context);
    return handler(new Request('https://worker.test/', { method: 'POST', headers: { 'x-futbeat-cron-token': 'wrong' },
      body: JSON.stringify({ trigger: 'demand' }) }));
  })();
  assert.equal(forged.status, 403);
  assert.equal(goal.goalCalls().length, 0);
}));
