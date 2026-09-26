import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import { collectGoalApiPlayerIdentities, normalizeGoalApiSquad } from '../providers/goal_api_players.mjs';
import { internalPoolSQL } from '../bench/squad_candidate_pool.mjs';

const token = 'test-only-cron-token-not-a-secret-123456789';
const goalKey = 'test-only-goal-key-not-a-secret';
const candidate = { teamId: 'fb_team_control_a', externalTeamId: 'control-a', priorityTier: 1, reason: 'favorite' };
const extraCandidate = { ...candidate, teamId: 'fb_team_control_b', externalTeamId: 'control-b' };
const payload = { success: true, data: [{ id: 'control-player', name: 'Control Player', photo: 'https://media.goal-api.com/players/control.png' }] };
const unhandled = Symbol('unhandled');
const workerSource = await readFile(new URL('../../supabase/functions/futbeat-goal-live-sync/index.ts', import.meta.url), 'utf8');
const ingestSource = await readFile(new URL('../../supabase/functions/futbeat-global-ingest/index.ts', import.meta.url), 'utf8');
const paginationSource = await readFile(new URL('../../supabase/functions/_shared/results_pagination.ts', import.meta.url), 'utf8');
// The worker imports normalizeFixtureEvents from _shared/live_events.ts.
const liveEventsSource = await readFile(new URL('../../supabase/functions/_shared/live_events.ts', import.meta.url), 'utf8');
const stripImports = source => source.replace(/^import\s[\s\S]*?;\r?\n/gm, '');

// Execute the actual Edge handlers, without Deno, credentials or network.
// Only imports/runtime globals are substituted; no production routing is copied.
function edge(source, fetch, logs, globals = {}) {
  let handler;
  const context = vm.createContext({
    Request, Response, Headers, URL, AbortSignal, TextEncoder, crypto, performance, Error,
    fetch,
    console: { error: (...args) => logs.push(args), warn: (...args) => logs.push(args), log: (...args) => logs.push(args) },
    Deno: {
      env: { get: name => ({ SUPABASE_URL: 'https://supabase.test', SUPABASE_SERVICE_ROLE_KEY: 'test-service-key' })[name] },
      serve: fn => { handler = fn; },
    },
    ...globals,
  });
  vm.runInContext(stripTypeScriptTypes(stripImports(source)), context);
  return { handler, context };
}

function harness(options = {}) {
  const calls = [], logs = [], unexpected = [];
  let ingestHandler;
  const fetch = async (input, init = {}) => {
    const url = new URL(input);
    const body = init.body ? JSON.parse(init.body) : {};
    calls.push({ url: url.href, body, init });
    if (url.origin === 'https://supabase.test' && url.pathname.startsWith('/rest/v1/rpc/')) {
      const name = url.pathname.split('/').at(-1);
      if (name === 'futbeat_read_goal_live_cron_token') return Response.json(token);
      if (options.rpc) {
        const result = await options.rpc(name, body);
        if (result !== unhandled) return Response.json(result);
      }
      if (name === 'futbeat_read_goal_live_secret') return Response.json(goalKey);
      if (name === 'futbeat_team_squad_plan') return Response.json(options.plan ?? [candidate, extraCandidate]);
      if (name === 'futbeat_reserve_goal_squad_call') return Response.json(options.reservation ?? { allowed: true, reservationId: 1 });
      if (name === 'futbeat_complete_provider_call') return Response.json({ status: 'ok' });
    }
    if (url.href === 'https://api.goal-api.com/v1/teams/control-a/players') {
      assert.equal(init.headers.Authorization, `Bearer ${goalKey}`);
      return options.provider ? options.provider(init) : Response.json(payload);
    }
    if (url.href === 'https://supabase.test/functions/v1/futbeat-global-ingest') {
      assert.equal(init.headers['x-futbeat-cron-token'], token);
      if (ingestHandler) return ingestHandler(new Request(url, init));
      return options.ingest ? options.ingest(body) : Response.json({ status: 'ok', players: 1 });
    }
    unexpected.push(url.href);
    throw new Error(`Unexpected mocked request: ${url.href}`);
  };
  const pagination = (paginationSource + '\n' + liveEventsSource).replace(/^export /gm, '');
  const worker = edge(pagination + '\n' + workerSource, fetch, logs);
  if (options.realIngest) {
    ingestHandler = edge(ingestSource, fetch, logs, {
      collectGoalApiPlayerIdentities, normalizeGoalApiSquad,
      createRemoteJWKSet: () => () => { throw new Error('OIDC must not run'); },
      jwtVerify: () => { throw new Error('OIDC must not run'); },
    }).handler;
  }
  const rpcCalls = name => calls.filter(call => call.url.endsWith(`/rpc/${name}`));
  return {
    calls, logs, unexpected, rpcCalls, context: worker.context,
    providers: () => calls.filter(call => new URL(call.url).origin !== 'https://supabase.test'),
    async invoke(body = { trigger: 'squad-only' }, supplied = token, query = '', method = 'POST') {
      const response = await worker.handler(new Request(`https://worker.test/${query}`, {
        method, headers: supplied == null ? {} : { 'x-futbeat-cron-token': supplied },
        ...(method === 'POST' ? { body: JSON.stringify(body) } : {}),
      }));
      const value = response.status === 405 ? null : await response.json();
      assert.deepEqual(unexpected, [], 'No unmocked network surface may execute');
      return { status: response.status, value };
    },
  };
}

function assertIsolated(h) {
  const allowed = new Set(['futbeat_read_goal_live_cron_token', 'futbeat_team_squad_plan',
    'futbeat_reserve_goal_squad_call', 'futbeat_read_goal_live_secret', 'futbeat_complete_provider_call']);
  for (const call of h.calls.filter(call => call.url.includes('/rpc/'))) {
    assert.ok(allowed.has(call.url.split('/').at(-1)), call.url);
  }
  assert.ok(h.providers().length <= 1);
  assert.deepEqual(h.unexpected, []);
}

test('authenticated squad-only uses planner(1), one reservation, one squad and existing ingest, never other flows', async () => {
  const h = harness();
  const spies = { live: 0, detail: 0, results: 0, news: 0, video: 0 };
  h.context.spies = spies;
  vm.runInContext(`syncLive=async()=>{spies.live++;}; syncOneMatchDetail=async()=>{spies.detail++;};
    syncOneResultsDate=async()=>{spies.results++;}; syncOneNews=async()=>{spies.news++;};
    syncOnePostMatchVideo=async()=>{spies.video++;};`, h.context);
  const { value, status } = await h.invoke(undefined, token, '?teamId=evil&externalTeamId=evil&endpoint=https://evil.test');
  assert.equal(status, 200);
  assert.deepEqual(value.candidate, candidate);
  assert.equal(value.allowed, true);
  assert.equal(value.providerCalls, 1);
  assert.deepEqual(value.result, { success: true, players: 1 });
  assert.deepEqual(h.rpcCalls('futbeat_team_squad_plan').map(c => c.body), [{ p_limit: 1 }]);
  assert.deepEqual(h.rpcCalls('futbeat_reserve_goal_squad_call').map(c => c.body), [{
    p_team_id: candidate.teamId, p_external_team_id: candidate.externalTeamId, p_trigger_source: 'supabase-cron',
  }]);
  assert.equal(h.providers().length, 1);
  assert.equal(h.providers()[0].init.redirect, 'error');
  const ingest = h.calls.find(c => c.url.endsWith('/futbeat-global-ingest'));
  assert.deepEqual(ingest.body.players, payload);
  assert.equal(ingest.body.action, 'squad-ingest');
  assert.equal(ingest.body.teamId, candidate.teamId);
  assert.deepEqual(spies, { live: 0, detail: 0, results: 0, news: 0, video: 0 });
  assertIsolated(h);
});

test('squad-only empty planner is a clean no-op with no reservation or provider call', async () => {
  const h = harness({ plan: [] });
  const { value } = await h.invoke();
  assert.equal(value.status, 'skipped');
  assert.equal(value.candidate, null);
  assert.equal(value.reservation, null);
  assert.equal(value.allowed, false);
  assert.equal(value.providerCalls, 0);
  assert.equal(value.result.reason, 'no_squad_due');
  assert.equal(h.rpcCalls('futbeat_reserve_goal_squad_call').length, 0);
  assert.equal(h.providers().length, 0);
  assertIsolated(h);
});

for (const reason of ['squad_fresh_backoff_or_inflight', 'squad_daily_limit', 'live_reserve']) {
  test(`squad-only reservation denied ${reason}: zero provider calls`, async () => {
    const h = harness({ reservation: { allowed: false, reason } });
    const { value } = await h.invoke();
    assert.deepEqual(value.candidate, candidate);
    assert.equal(value.allowed, false);
    assert.equal(value.providerCalls, 0);
    assert.equal(value.result.reason, reason);
    assert.equal(h.rpcCalls('futbeat_reserve_goal_squad_call').length, 1);
    assert.equal(h.rpcCalls('futbeat_read_goal_live_secret').length, 0);
    assert.equal(h.providers().length, 0);
    assertIsolated(h);
  });
}

test('squad-only rejects absent/wrong auth, query-token bypass and non-POST before planning', async () => {
  for (const supplied of [null, 'wrong']) {
    const h = harness();
    const response = await h.invoke(undefined, supplied, `?x-futbeat-cron-token=${token}`);
    assert.equal(response.status, 403);
    assert.equal(h.rpcCalls('futbeat_team_squad_plan').length, 0);
    assert.equal(h.providers().length, 0);
  }
  const h = harness();
  assert.equal((await h.invoke(undefined, token, '', 'GET')).status, 405);
  assert.equal(h.calls.length, 0);
});

test('squad-only rejects body team/provider/quota overrides before planning', async () => {
  for (const key of ['teamId', 'externalTeamId', 'endpoint', 'providerEndpoint', 'reserve', 'limit']) {
    const h = harness();
    assert.equal((await h.invoke({ trigger: 'squad-only', [key]: 'arbitrary' })).status, 400);
    assert.equal(h.rpcCalls('futbeat_team_squad_plan').length, 0);
    assert.equal(h.providers().length, 0);
  }
});

for (const [name, provider, httpStatus] of [
  ['HTTP 500', () => Response.json({ success: false }, { status: 500 }), 500],
  ['HTTP 429', () => Response.json({ success: false }, { status: 429 }), 429],
  ['network failure', () => { throw new Error(`network failed ${goalKey}`); }, null],
  ['redirect', init => { assert.equal(init.redirect, 'error'); throw new TypeError('redirect disallowed'); }, null],
  ['invalid payload', () => Response.json({ success: true, data: null }), null],
]) {
  test(`squad-only ${name}: one attempt, FAILED completion, no team #2, sanitized response`, async () => {
    const h = harness({ provider });
    const { value } = await h.invoke();
    assert.equal(value.status, 'failed');
    assert.equal(value.result.success, false);
    assert.equal(value.providerCalls, 1);
    assert.equal(value.allowed, true);
    assert.equal(h.providers().length, 1);
    assert.equal(h.rpcCalls('futbeat_reserve_goal_squad_call').length, 1);
    const [completion] = h.rpcCalls('futbeat_complete_provider_call');
    assert.equal(completion.body.p_status, 'FAILED');
    assert.equal(completion.body.p_http_status, httpStatus);
    assert.equal(h.calls.filter(c => c.url.endsWith('/futbeat-global-ingest')).length, 0);
    assert.ok(!JSON.stringify([value, h.logs, completion.body]).includes(goalKey));
    assertIsolated(h);
  });
}

test('squad-only key lookup failure has zero attempts; completion failure never leaks RPC text', async () => {
  const h = harness({ rpc: async name => {
    if (['futbeat_read_goal_live_secret', 'futbeat_complete_provider_call'].includes(name)) throw new Error(goalKey);
    return unhandled;
  } });
  const { value } = await h.invoke();
  assert.equal(value.providerCalls, 0);
  assert.equal(value.status, 'failed');
  assert.equal(h.providers().length, 0);
  assert.ok(!JSON.stringify([value, h.logs]).includes(goalKey));
});

test('squad-only ingest failure does not retry provider or choose another team', async () => {
  const h = harness({ ingest: () => Response.json({ error: 'unavailable' }, { status: 502 }) });
  const { value } = await h.invoke();
  assert.equal(value.result.success, false);
  assert.equal(value.providerCalls, 1);
  assert.equal(h.providers().length, 1);
  assert.equal(h.rpcCalls('futbeat_complete_provider_call')[0].body.p_status, 'FAILED');
});

for (const trigger of ['results-only', 'detail-only', 'cron']) {
  test(`${trigger} routing regression: isolated modes exclude squad, default retains all five flows`, async () => {
    const h = harness();
    const ran = [];
    h.context.ran = ran;
    vm.runInContext(`syncLive=async()=>{ran.push('live');return {status:'ok'};};
      syncOneMatchDetail=async()=>{ran.push('detail');return {status:'ok'};};
      syncOneResultsDate=async()=>{ran.push('results');return {status:'ok'};};
      syncOneNews=async()=>{ran.push('news');return {status:'ok'};};
      syncOnePostMatchVideo=async()=>{ran.push('video');return {status:'ok'};};
      syncPlayerDemand=async()=>{ran.push('player');return [];};
      syncStandingsDemand=async()=>{ran.push('standings');return {status:'ok'};};
      syncCalendarWarm=async()=>{ran.push('calendar');return {built:[]};};`, h.context);
    const { value } = await h.invoke({ trigger });
    if (trigger === 'cron') {
      assert.deepEqual(ran, ['live', 'detail', 'news', 'video']);
      assert.deepEqual(Object.keys(value), ['status', 'live', 'detail', 'squad', 'news', 'video']);
      assert.equal(value.squad.status, 'ok');
      assert.equal(h.providers().length, 1);
      assert.equal(h.providers()[0].init.redirect, 'follow');
    } else {
      // detail-only is also the user-demand lane: up to three details, players, standings.
      assert.deepEqual(ran, trigger === 'detail-only' ? ['detail', 'detail', 'detail', 'player', 'standings', 'calendar'] : [trigger.split('-')[0]]);
      assert.equal(h.rpcCalls('futbeat_team_squad_plan').length, 0);
      assert.equal(h.providers().length, 0);
    }
  });
}

async function seededDatabase() {
  const db = await openDatabase();
  for (const c of [candidate, extraCandidate]) {
    await db.query("insert into futbeat_private.entities values($1,'team',$2)", [c.teamId, JSON.stringify({ id: c.teamId, name: c.teamId })]);
    await db.query("insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id) values('goal_api','team',$1,$2)", [c.externalTeamId, c.teamId]);
    await db.query("insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,depth) values('team',$1,1,'DEEP')", [c.teamId]);
  }
  await db.exec("insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,status,completed_at,provider_remaining) values('goal_api','live-goal','test','SUCCEEDED',now(),900)");
  return db;
}

test('local benchmark SQL extraction is identical with LF and Windows CRLF function bodies', async () => {
  const db = await openDatabase();
  try {
    const sourceWith = newline => ({ query: async (...args) => {
      const response = await db.query(...args);
      return { rows: [{ prosrc: response.rows[0].prosrc.replace(/\r?\n/g, newline) }] };
    } });
    const lf = await internalPoolSQL(sourceWith('\n'));
    const crlf = await internalPoolSQL(sourceWith('\r\n'));
    assert.deepEqual(crlf, lf);
    for (const sql of Object.values(crlf)) {
      assert.ok(sql.length > 0);
      assert.doesNotMatch(sql, /\r|result:=|return coalesce/);
    }
  } finally { await db.close(); }
});

function sqlRpc(db) {
  const allowed = new Set(['futbeat_team_squad_plan', 'futbeat_reserve_goal_squad_call',
    'futbeat_complete_provider_call', 'futbeat_resolve_global_entities', 'futbeat_store_team_squad']);
  return async (name, body) => {
    if (!allowed.has(name)) return unhandled;
    const entries = Object.entries(body);
    assert.ok(entries.every(([key]) => /^p_[a-z_]+$/.test(key)));
    const args = entries.map(([key], i) => `${key} => $${i + 1}`).join(',');
    const values = entries.map(([, value]) => value != null && typeof value === 'object' ? JSON.stringify(value) : value);
    if (name === 'futbeat_resolve_global_entities') {
      return (await db.query(`select * from public.${name}(${args})`, values)).rows;
    }
    return (await db.query(`select public.${name}(${args}) value`, values)).rows[0].value;
  };
}

test('real handlers + local SQL ingest canonical players/media/memberships and prevent an immediate repeat for A', async () => {
  const db = await seededDatabase();
  try {
    await db.query('delete from futbeat_private.coverage_interests where subject_id=$1', [extraCandidate.teamId]);
    const h = harness({ rpc: sqlRpc(db), realIngest: true });
    const first = (await h.invoke()).value;
    assert.equal(first.result.success, true, JSON.stringify({ first, logs: h.logs, calls: h.calls.map(c => ({ url: c.url, body: c.body })) }));
    assert.equal(first.result.players, 1);
    const second = (await h.invoke()).value;
    assert.equal(second.status, 'skipped');
    assert.equal(second.result.reason, 'no_squad_due');
    assert.equal(second.providerCalls, 0);
    assert.equal(h.providers().length, 1);
    assert.equal(h.rpcCalls('futbeat_reserve_goal_squad_call').length, 1);
    assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_call_ledger where call_kind='team-squad' and status='SUCCEEDED'")).rows[0].n, 1);
    assert.equal((await db.query('select count(*)::int n from futbeat_private.team_squad_members')).rows[0].n, 1);
    const player = (await db.query("select e.payload from futbeat_private.entities e join futbeat_private.provider_entities p on p.canonical_id=e.id where p.kind='player' and p.external_id='control-player'")).rows[0];
    assert.equal(player.payload.media.url, payload.data[0].photo);
    const coverage = (await db.query('select * from futbeat_private.team_detail_coverage where team_id=$1', [candidate.teamId])).rows[0];
    assert.equal(coverage.status, 'AVAILABLE');
    assert.equal(coverage.player_count, 1);
    assert.equal(coverage.lease_until, null);
    assert.ok(new Date(coverage.next_retry_at) > new Date());
  } finally { await db.close(); }
});

for (const [status, seconds] of [[500, 900], [429, 86400]]) {
  test(`squad-only HTTP ${status} records FAILED and existing SQL backoff ${seconds}s without trying B`, async () => {
    const db = await seededDatabase();
    try {
      const h = harness({ rpc: sqlRpc(db), provider: () => Response.json({ success: false }, { status }) });
      const { value } = await h.invoke();
      assert.equal(value.status, 'failed');
      assert.equal(value.providerCalls, 1);
      assert.equal(h.providers().length, 1);
      const rows = (await db.query("select status,http_status from futbeat_private.provider_call_ledger where call_kind='team-squad'")).rows;
      assert.deepEqual(rows, [{ status: 'FAILED', http_status: status }]);
      const coverage = (await db.query('select status,failure_count,lease_until,extract(epoch from next_retry_at-last_attempt_at)::int seconds from futbeat_private.team_detail_coverage where team_id=$1', [candidate.teamId])).rows[0];
      assert.deepEqual(coverage, { status: 'FETCH_FAILED', failure_count: 1, lease_until: null, seconds });
      const next = (await db.query('select public.futbeat_team_squad_plan(1) value')).rows[0].value;
      assert.equal(next[0].teamId, extraCandidate.teamId); // B is eligible, but was never attempted.
    } finally { await db.close(); }
  });
}

for (const state of ['fresh', 'lease']) {
  test(`real reservation rejects ${state} introduced after planning, with zero GOAL calls`, async () => {
    const db = await seededDatabase();
    try {
      const rpc = sqlRpc(db);
      const h = harness({ rpc: async (name, body) => {
        if (name === 'futbeat_reserve_goal_squad_call') {
          await db.query(`insert into futbeat_private.team_detail_coverage(team_id,provider,fetched_at,player_count,lease_until)
            values($1,'goal_api',${state === 'fresh' ? 'now()' : 'null'},0,${state === 'lease' ? "now()+interval '10 minutes'" : 'null'})`, [candidate.teamId]);
        }
        return rpc(name, body);
      } });
      const { value } = await h.invoke();
      assert.equal(value.allowed, false);
      assert.equal(value.result.reason, 'squad_fresh_backoff_or_inflight');
      assert.equal(h.providers().length, 0);
      assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_call_ledger where call_kind='team-squad'")).rows[0].n, 0);
    } finally { await db.close(); }
  });
}
