import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';

// GOAL uses a purely numeric player id in lineup/match-detail rows, and a
// catalog-style string id (e.g. "cmr7...") in search/profile/statistics and
// squad ingestion. Calling /players/:id with the numeric lineup id 404s in
// production. These tests exercise the bridge end to end: real SQL (PGlite)
// + the real GOAL worker code (goal_players.ts normalizers included) with a
// simulated GOAL API -- the same harness player_on_demand.test.mjs uses.

const token = 'test-only-cron-token-not-a-secret-123456789';
const goalKey = 'test-only-goal-key-not-a-secret-XYZ';
const read = (path) => readFile(new URL(`../../supabase/functions/${path}`, import.meta.url), 'utf8');
const [workerSource, paginationSource, playersSource] = await Promise.all([
  read('futbeat-goal-live-sync/index.ts'), read('_shared/results_pagination.ts'), read('_shared/goal_players.ts')]);
const stripImports = (source) => source.replace(/^import\s[\s\S]*?;\r?\n/gm, '');
const stripExports = (source) => source.replace(/^export /gm, '');

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
  const source = stripExports(paginationSource) + '\n' + stripExports(playersSource) + '\n' + stripImports(workerSource);
  vm.runInContext(stripTypeScriptTypes(source), context);
  return {
    calls, logs, unexpected,
    goalCalls: () => calls.filter((u) => u.startsWith('https://api.goal-api.com')),
    async run(trigger = 'demand') {
      const response = await handler(new Request('https://worker.test/', { method: 'POST',
        headers: { 'x-futbeat-cron-token': token }, body: JSON.stringify({ trigger }) }));
      const text = await response.text();
      assert.deepEqual(unexpected, []);
      assert.ok(!text.includes(goalKey), 'key in response');
      assert.ok(!JSON.stringify(logs).includes(goalKey), 'key in logs');
      return JSON.parse(text);
    },
  };
}

const ok = (data) => new Response(JSON.stringify({ success: true, data }),
  { status: 200, headers: { 'x-ratelimit-remaining': '777', 'content-type': 'application/json' } });

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

let seq = 0;
async function seedTeam(db, { name = 'Nottingham Forest' } = {}) {
  const n = ++seq;
  const teamId = `fb_team_bridge_${n}`, externalId = `goal-team-bridge-${n}`;
  await db.query('insert into futbeat_private.entities values($1,$2,$3)', [teamId, 'team', JSON.stringify({ id: teamId, name })]);
  await db.query("insert into futbeat_private.provider_entities values('goal_api','team',$1,$2)", [externalId, teamId]);
  return { teamId, externalId };
}

// Mirrors what futbeat_private.harvest_lineup_players does: a canonical
// player discovered ONLY via a match-detail lineup row, identified strictly
// by GOAL's numeric provider id, with a current team but no catalog id yet.
async function seedLineupOnlyPlayer(db, { name, numericId, teamId }) {
  const pid = (await db.query(
    "select futbeat_private.futbeat_resolve_global_entity('goal_api','player',$1,$2) v", [numericId, name],
  )).rows[0].v;
  await db.query("update futbeat_private.entities set payload=payload||jsonb_build_object('teamId',$2::text) where id=$1",
    [pid, teamId]);
  return pid;
}

const lineupHydrate = (db, pids) =>
  db.query('select public.futbeat_request_lineup_hydration($1,$2) v', [pids, []]).then((r) => r.rows[0].v);
const canonicalCount = (db) =>
  db.query("select count(*)::int n from futbeat_private.entities where kind='player'").then((r) => r.rows[0].n);
const providerEntitiesFor = (db, pid) =>
  db.query("select external_id from futbeat_private.provider_entities where provider='goal_api' and kind='player' and canonical_id=$1 order by external_id",
    [pid]).then((r) => r.rows.map((row) => row.external_id));

test('numeric lineup id + a verified search profile id bridge to ONE canonical player', () => withDb(async (db) => {
  const { teamId, externalId: teamExternal } = await seedTeam(db);
  const pid = await seedLineupOnlyPlayer(db, { name: 'Matz Sels', numericId: '1343925596', teamId });
  const before = await canonicalCount(db);

  await lineupHydrate(db, [pid]); // registers name-based search demand (numeric-only id)
  const goal = worker(db, (url) => {
    // query_text preserves the entity's stored name (original case); only
    // query_key (the dedupe key) is case/whitespace-folded.
    assert.equal(url.pathname, '/v1/players/search');
    assert.equal(url.searchParams.get('q'), 'Matz Sels');
    return ok([{ id: 'cmr7matzsels', name: 'Matz Sels', team: { id: teamExternal } }]);
  });
  await goal.run();

  assert.equal(await canonicalCount(db), before, 'no new canonical player was created');
  assert.deepEqual(await providerEntitiesFor(db, pid), ['1343925596', 'cmr7matzsels'].sort());
}));

test('same name on two different teams: an unresolved team never merges unsafely', () => withDb(async (db) => {
  const teamA = await seedTeam(db, { name: 'Club A' });
  const teamB = await seedTeam(db, { name: 'Club B' });
  const other = await seedTeam(db, { name: 'Club C (search result team)' });
  const playerA = await seedLineupOnlyPlayer(db, { name: 'Juan Perez', numericId: '111', teamId: teamA.teamId });
  const playerB = await seedLineupOnlyPlayer(db, { name: 'Juan Perez', numericId: '222', teamId: teamB.teamId });
  const before = await canonicalCount(db);

  await lineupHydrate(db, [playerA, playerB]);
  const goal = worker(db, () => ok([{ id: 'cmr7juanperez', name: 'Juan Perez', team: { id: other.externalId } }]));
  await goal.run();

  // The search result's team matches neither existing candidate: a new,
  // separate canonical player is created rather than guessing which one.
  assert.equal(await canonicalCount(db), before + 1);
  assert.deepEqual(await providerEntitiesFor(db, playerA), ['111']);
  assert.deepEqual(await providerEntitiesFor(db, playerB), ['222']);
}));

test('exact name but mismatched team: no merge even with a single lineup-only candidate', () => withDb(async (db) => {
  const team = await seedTeam(db);
  const otherTeam = await seedTeam(db, { name: 'A Different Club' });
  const pid = await seedLineupOnlyPlayer(db, { name: 'Ola Aina', numericId: '999', teamId: team.teamId });
  const before = await canonicalCount(db);

  await lineupHydrate(db, [pid]);
  const goal = worker(db, () => ok([{ id: 'cmr7olaaina', name: 'Ola Aina', team: { id: otherTeam.externalId } }]));
  await goal.run();

  assert.equal(await canonicalCount(db), before + 1, 'team context did not verify: treated as a different person');
  assert.deepEqual(await providerEntitiesFor(db, pid), ['999']);
}));

test('an existing bridge is reused, not re-created, on a later search for the same player', () => withDb(async (db) => {
  const { teamId, externalId: teamExternal } = await seedTeam(db);
  const pid = await seedLineupOnlyPlayer(db, { name: 'Matz Sels', numericId: '1343925596', teamId });
  await lineupHydrate(db, [pid]);
  const first = worker(db, () => ok([{ id: 'cmr7matzsels', name: 'Matz Sels', team: { id: teamExternal } }]));
  await first.run();
  const afterFirstBridge = await providerEntitiesFor(db, pid);

  // A second, unrelated search cycle for the same name must not touch the
  // already-bridged identity again.
  await db.query("select public.futbeat_request_player_profile($1)", [pid]);
  const second = worker(db, (url) => {
    if (url.pathname === '/v1/players/search') return ok([{ id: 'cmr7matzsels', name: 'Matz Sels', team: { id: teamExternal } }]);
    return ok({ id: 'cmr7matzsels', name: 'Matz Sels' });
  });
  await second.run();

  assert.deepEqual(await providerEntitiesFor(db, pid), afterFirstBridge);
}));

test('hydration uses the profile-compatible external id, never the numeric lineup one', () => withDb(async (db) => {
  const { teamId, externalId: teamExternal } = await seedTeam(db);
  const pid = await seedLineupOnlyPlayer(db, { name: 'Matz Sels', numericId: '1343925596', teamId });
  await lineupHydrate(db, [pid]); // no catalog id yet: registers discovery demand, not profile coverage
  const search = worker(db, () => ok([{ id: 'cmr7matzsels', name: 'Matz Sels', team: { id: teamExternal } }]));
  await search.run();
  await lineupHydrate(db, [pid]); // now bridged: queues the real profile demand

  const plan = (await db.query("select public.futbeat_reserve_player_call('test') v")).rows[0].v;
  assert.equal(plan.allowed, true);
  assert.equal(plan.playerId, pid);
  assert.equal(plan.externalPlayerId, 'cmr7matzsels', 'must never send the numeric lineup id to GOAL');
}));

test('a numeric-only identity is never reserved for profile/stats (no 404 by construction)', () => withDb(async (db) => {
  const { teamId } = await seedTeam(db);
  const pid = await seedLineupOnlyPlayer(db, { name: 'Sin Bridge', numericId: '424242', teamId });
  const result = await lineupHydrate(db, [pid]);
  assert.equal(result.enrichmentPending, true, 'discovery is in progress');
  // No player_profile_coverage row was queued for this still-numeric-only id.
  assert.equal((await db.query('select count(*)::int n from futbeat_private.player_profile_coverage where player_id=$1', [pid])).rows[0].n, 0);
  // A search demand was registered instead, by name.
  assert.deepEqual((await db.query('select query_text from futbeat_private.player_search_demands')).rows, [{ query_text: 'Sin Bridge' }]);
  const plan = (await db.query("select public.futbeat_reserve_player_call('test') v")).rows[0].v;
  assert.notEqual(plan.playerId, pid);
}));

test('a photo hydrated via the bridged catalog id shows up for the original lineup numeric id', () => withDb(async (db) => {
  const { teamId, externalId: teamExternal } = await seedTeam(db);
  const pid = await seedLineupOnlyPlayer(db, { name: 'Matz Sels', numericId: '1343925596', teamId });
  const before = (await db.query(
    "select futbeat_private.futbeat_read_lineup_player_media('goal_api',array['1343925596']) v",
  )).rows[0].v['1343925596'];
  assert.equal(before.image, null);

  await lineupHydrate(db, [pid]);
  const search = worker(db, () => ok([{ id: 'cmr7matzsels', name: 'Matz Sels', team: { id: teamExternal } }]));
  await search.run();

  await lineupHydrate(db, [pid]); // now profileIdReady: queues the real profile fetch
  const profile = worker(db, (url) => {
    assert.equal(url.pathname, '/v1/players/cmr7matzsels');
    return ok({ id: 'cmr7matzsels', name: 'Matz Sels', photo: 'https://media.goal-api.com/players/sels.png' });
  });
  await profile.run();

  const after = (await db.query(
    "select futbeat_private.futbeat_read_lineup_player_media('goal_api',array['1343925596']) v",
  )).rows[0].v['1343925596'];
  assert.equal(after.canonicalId, pid);
  assert.equal(after.image, 'https://media.goal-api.com/players/sels.png');
}));

test('bridge_player_identity guard: non-Latin (or blank) names never count as a match, even with team context', () => withDb(async (db) => {
  // Tested directly against bridge_player_identity, not through the
  // search-discovery pipeline: player_search_key/search_fold separately
  // reject a name with zero [a-z0-9] characters as "too_short" before any
  // search ever fires, which would make an end-to-end test pass trivially
  // (nothing runs) without actually exercising the guard in
  // bridge_player_identity itself -- normalize_live_name folding two
  // different non-Latin names to the SAME blank string.
  const { teamId, externalId: teamExternal } = await seedTeam(db);
  await seedLineupOnlyPlayer(db, { name: '기성용', numericId: '555001', teamId });

  const bridge = (await db.query(
    "select futbeat_private.bridge_player_identity('cmr7different','손흥민',$1) v", [teamExternal],
  )).rows[0].v;
  assert.equal(bridge, null, 'two blank-folding names must never be treated as the same person');
}));

test('numeric-only player_profile_coverage rows doomed by a prior 404 are repaired by the migration logic', () => withDb(async (db) => {
  const { teamId } = await seedTeam(db);
  const pid = await seedLineupOnlyPlayer(db, { name: 'Old 404 Player', numericId: '777777', teamId });
  const other = await seedLineupOnlyPlayer(db, { name: 'Already Bridged Player', numericId: '888', teamId });
  // Simulate the pre-fix state: a profile call was attempted against the
  // numeric id, GOAL 404'd, and futbeat_fail_player_call backed it off ~30 days.
  await db.query(`insert into futbeat_private.player_profile_coverage(
      player_id,external_id,requested_at,request_count,profile_status,profile_next_retry_at,failure_count,last_error)
    values($1,'777777',now()-interval '1 day',1,'FETCH_FAILED',now()+interval '29 days',1,'HTTP 404')`, [pid]);
  // A catalog-id row (already working correctly) must be left untouched.
  await db.query(`insert into futbeat_private.player_profile_coverage(
      player_id,external_id,requested_at,request_count,profile_status,profile_next_retry_at)
    values($1,'cmr7ok',now(),1,'AVAILABLE',now()+interval '25 days')`, [other]);

  // Re-run the migration's own repair statement (it only ran once, at
  // migration-apply time, against whatever data existed then) to prove its
  // logic correctly targets numeric-external-id rows.
  await db.query(`update futbeat_private.player_profile_coverage c
    set profile_status='NEVER',profile_fetched_at=null,profile_next_retry_at=null,
      stats_status='NEVER',stats_fetched_at=null,stats_next_retry_at=null,
      failure_count=0,lease_until=null,last_error=null
    where futbeat_private.player_external_id_is_numeric(c.external_id)
      and (c.profile_status<>'NEVER' or c.stats_status<>'NEVER' or c.failure_count>0)`);

  const repaired = (await db.query(
    "select profile_status,profile_next_retry_at,failure_count from futbeat_private.player_profile_coverage where player_id=$1",
    [pid],
  )).rows[0];
  assert.deepEqual(repaired, { profile_status: 'NEVER', profile_next_retry_at: null, failure_count: 0 });
  const untouched = (await db.query(
    "select profile_status from futbeat_private.player_profile_coverage where player_id=$1", [other],
  )).rows[0];
  assert.equal(untouched.profile_status, 'AVAILABLE');
}));

test('bridge_player_identity is symmetric: a catalog-id-only player bridges to a NEW numeric lineup id too', () => withDb(async (db) => {
  const { teamId, externalId: teamExternal } = await seedTeam(db);
  const pid = (await db.query(
    "select futbeat_private.futbeat_resolve_global_entity('goal_api','player','cmr7early','Early Bird') v",
  )).rows[0].v;
  await db.query("update futbeat_private.entities set payload=payload||jsonb_build_object('teamId',$2::text) where id=$1",
    [pid, teamId]);

  const bridge = (await db.query(
    "select futbeat_private.bridge_player_identity('888888','Early Bird',$1) v", [teamExternal],
  )).rows[0].v;
  assert.equal(bridge, pid);
}));

test('harvest_lineup_players end to end: a lineup numeric id bridges to an already squad/search-known catalog player', () => withDb(async (db) => {
  const { teamId: homeTeamId, externalId: homeTeamExternal } = await seedTeam(db, { name: 'Home Club' });
  const { teamId: awayTeamId } = await seedTeam(db, { name: 'Away Club' });
  const matchId = 'fb_match_harvest_bridge';
  await db.query('insert into futbeat_private.entities values($1,$2,$3)', [matchId, 'match', JSON.stringify({
    id: matchId, homeTeamId, awayTeamId, startTime: new Date().toISOString(), status: 'SCHEDULED', events: [], statistics: [],
  })]);
  // Already known via search/squad, catalog id only, no numeric id yet.
  const pid = (await db.query(
    "select futbeat_private.futbeat_resolve_global_entity('goal_api','player','cmr7harvest','Harvest Target') v",
  )).rows[0].v;
  await db.query("update futbeat_private.entities set payload=payload||jsonb_build_object('teamId',$2::text) where id=$1",
    [pid, homeTeamId]);
  const before = await canonicalCount(db);

  await db.query('select futbeat_private.harvest_lineup_players($1,$2,now())', [matchId, JSON.stringify({
    lineups: { home: { startingLineups: [{ playerId: '999111', lineupPlayer: 'Harvest Target' }] } },
  })]);

  assert.equal(await canonicalCount(db), before, 'no new canonical player was minted for the lineup row');
  assert.deepEqual(await providerEntitiesFor(db, pid), ['999111', 'cmr7harvest'].sort());
}));

test('discovery demand from lineup hydration is bounded per call, not one search per undiscovered player', () => withDb(async (db) => {
  const { teamId } = await seedTeam(db);
  const pids = [];
  for (let i = 0; i < 8; i++) {
    pids.push(await seedLineupOnlyPlayer(db, { name: `Discover Me ${i}`, numericId: `600000${i}`, teamId }));
  }
  await lineupHydrate(db, pids);
  const demands = (await db.query('select count(*)::int n from futbeat_private.player_search_demands')).rows[0].n;
  assert.ok(demands <= 5, `expected at most 5 discovery demands per call, got ${demands}`);
}));

test('futbeat_request_player_profile never claims pending when neither profile nor stats is due', () => withDb(async (db) => {
  const player = (await db.query(
    "select futbeat_private.futbeat_resolve_global_entity('goal_api','player','cmr7fully','Fully Hydrated') v",
  )).rows[0].v;
  await db.query(`update futbeat_private.entities set payload=payload||jsonb_build_object(
      'dateOfBirth','2000-01-01','country','Test','position','Forward','height','180',
      'media',jsonb_build_object('url','https://media.goal-api.com/players/x.png','verificationStatus','VERIFIED')
    ) where id=$1`, [player]);
  // profileDue is now false (all profile facts present); make statsDue false
  // too via an existing, not-yet-due coverage row (the simplest way to reach
  // that state without needing the separate fresh-squad exemption path).
  await db.query(`insert into futbeat_private.player_profile_coverage(
      player_id,external_id,requested_at,request_count,profile_status,profile_next_retry_at,
      stats_status,stats_next_retry_at)
    values($1,'cmr7fully',now(),1,'AVAILABLE',now()+interval '25 days','AVAILABLE',now()+interval '10 hours')`,
    [player]);
  const result = (await db.query('select public.futbeat_request_player_profile($1) v', [player])).rows[0].v;
  assert.equal(result.enrichmentPending, false);
}));
