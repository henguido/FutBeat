import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';

// Reproduces the real "results-only" worker path end to end (real worker
// source + real local SQL RPCs via PGlite), with only the network boundary
// mocked: GOAL's /results/date response and the Supabase cron-token/GOAL-key
// lookups. This is the harness systematic-debugging asked for: find exactly
// which call in syncOneResultsDate fails, instead of guessing from reading
// the code.

const token = 'test-only-cron-token-not-a-secret-123456789';
const goalKey = 'test-only-goal-key-not-a-secret';
const unhandled = Symbol('unhandled');
const workerSource = await readFile(new URL('../../supabase/functions/futbeat-goal-live-sync/index.ts', import.meta.url), 'utf8');
const paginationSource = await readFile(new URL('../../supabase/functions/_shared/results_pagination.ts', import.meta.url), 'utf8');
const stripImports = source => source.replace(/^import\s[\s\S]*?;\r?\n/gm, '');

function edge(source, fetch, logs) {
  let handler;
  const context = vm.createContext({
    Request, Response, Headers, URL, AbortSignal, TextEncoder, crypto, performance, Error,
    fetch,
    console: { error: (...args) => logs.push(args), warn: (...args) => logs.push(args), log: (...args) => logs.push(args) },
    Deno: {
      env: { get: name => ({ SUPABASE_URL: 'https://supabase.test', SUPABASE_SERVICE_ROLE_KEY: 'test-service-key' })[name] },
      serve: fn => { handler = fn; },
    },
  });
  vm.runInContext(stripTypeScriptTypes(stripImports(source)), context);
  return { handler, context };
}

// Routes every RPC the results-only path can call through the REAL local SQL
// functions (PGlite), the same pattern squad_only_trigger.test.mjs uses.
function sqlRpc(db) {
  const allowed = new Set([
    'futbeat_reserve_goal_results_date', 'futbeat_link_goal_live_matches',
    'futbeat_record_live_batch', 'futbeat_finalize_goal_results_date',
    'futbeat_complete_results_date_attempt', 'futbeat_complete_provider_call',
  ]);
  return async (name, body) => {
    if (!allowed.has(name)) return unhandled;
    const entries = Object.entries(body);
    assert.ok(entries.every(([key]) => /^p_[a-z_]+$/.test(key)), JSON.stringify(body));
    const args = entries.map(([key], i) => `${key} => $${i + 1}`).join(',');
    const values = entries.map(([, value]) => value != null && typeof value === 'object' ? JSON.stringify(value) : value);
    return (await db.query(`select public.${name}(${args}) value`, values)).rows[0].value;
  };
}

function harness(db, options = {}) {
  const calls = [], logs = [], unexpected = [];
  const rpc = sqlRpc(db);
  const fetch = async (input, init = {}) => {
    const url = new URL(input);
    const body = init.body ? JSON.parse(init.body) : {};
    calls.push({ url: url.href, body, init });
    if (url.origin === 'https://supabase.test' && url.pathname.startsWith('/rest/v1/rpc/')) {
      const name = url.pathname.split('/').at(-1);
      if (name === 'futbeat_read_goal_live_cron_token') return Response.json(token);
      if (name === 'futbeat_read_goal_live_secret') return Response.json(goalKey);
      const result = await rpc(name, body);
      if (result !== unhandled) return Response.json(result);
      unexpected.push(url.href);
      throw new Error(`Unmocked RPC: ${name}`);
    }
    if (url.href.startsWith('https://api.goal-api.com/v1/results/date/')) {
      assert.equal(init.headers.Authorization, `Bearer ${goalKey}`);
      return options.provider ? options.provider(url, init) : Response.json({ success: true, data: [], pagination: { total: 0 } });
    }
    unexpected.push(url.href);
    throw new Error(`Unexpected mocked request: ${url.href}`);
  };
  const pagination = paginationSource.replace(/^export /gm, '');
  const worker = edge(pagination + '\n' + workerSource, fetch, logs);
  const rpcCalls = name => calls.filter(call => call.url.endsWith(`/rpc/${name}`));
  return {
    calls, logs, unexpected, rpcCalls,
    providers: () => calls.filter(call => new URL(call.url).origin !== 'https://supabase.test'),
    async invoke() {
      const response = await worker.handler(new Request('https://worker.test/', {
        method: 'POST', headers: { 'x-futbeat-cron-token': token },
        body: JSON.stringify({ trigger: 'results-only' }),
      }));
      return { status: response.status, value: await response.json() };
    },
  };
}

let seq = 0;
async function seedResultsDueMatch(db, { daysAgo = 3 } = {}) {
  const n = ++seq;
  const comp = `fb_comp_ro_${n}`, home = `fb_team_ro_h${n}`, away = `fb_team_ro_a${n}`, match = `fb_match_ro_${n}`;
  const date = new Date(); date.setUTCDate(date.getUTCDate() - daysAgo);
  const dateStr = date.toISOString().slice(0, 10);
  const start = `${dateStr}T18:00:00.000Z`;
  for (const [id, kind, payload] of [
    [comp, 'competition', { id: comp, name: `Liga ${n}` }],
    [home, 'team', { id: home, name: `Home ${n}` }],
    [away, 'team', { id: away, name: `Away ${n}` }],
    [match, 'match', { id: match, competitionId: comp, homeTeamId: home, awayTeamId: away,
      startTime: start, status: 'SCHEDULED', events: [], statistics: [] }],
  ]) await db.query('insert into futbeat_private.entities values($1,$2,$3)', [id, kind, JSON.stringify(payload)]);
  const external = `goal-result-${n}`;
  await db.query("insert into futbeat_private.provider_entities values('goal_api','match',$1,$2)", [external, match]);
  return { match, external, dateStr };
}

function resultFixture(external, { status = 'FINISHED', home = 2, away = 1 } = {}) {
  return {
    apiId: external,
    matchStatus: status,
    matchPeriod: 'FULL_TIME',
    matchElapsed: '90',
    homeTeamScore: home,
    awayTeamScore: away,
    events: [],
    cards: [],
    substitutions: [],
  };
}

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

test('results-only: reservation allowed, provider success, full pipeline reaches SUCCEEDED', () => withDb(async (db) => {
  const { external, dateStr } = await seedResultsDueMatch(db);
  const h = harness(db, {
    provider: (url) => {
      assert.equal(url.href, `https://api.goal-api.com/v1/results/date/${dateStr}?limit=500&offset=0`);
      return Response.json({ success: true, data: [resultFixture(external)], pagination: { total: 1 } });
    },
  });
  const { status, value } = await h.invoke();
  assert.equal(status, 200, JSON.stringify({ value, logs: h.logs }));
  assert.equal(value.status, 'ok', JSON.stringify({ value, logs: h.logs, calls: h.calls.map(c => ({ url: c.url, body: c.body })) }));
  assert.equal(value.results.status, 'ok', JSON.stringify({ value, logs: h.logs }));
  const completion = h.rpcCalls('futbeat_complete_provider_call')[0];
  assert.equal(completion.body.p_status, 'SUCCEEDED');
}));

test('results-only: no date due -> skipped, zero provider calls', () => withDb(async (db) => {
  const h = harness(db);
  const { value } = await h.invoke();
  assert.equal(value.status, 'ok');
  assert.equal(value.results.status, 'skipped');
  assert.equal(h.providers().length, 0);
}));

test('results-only: local repair resolves it before any provider call is needed', () => withDb(async (db) => {
  const { match, dateStr } = await seedResultsDueMatch(db);
  // Terminal evidence already stored locally (mirrors a FINISHED observation
  // landing via another path) -- reserve()'s own local-repair step should
  // resolve the date before syncOneResultsDate ever calls fetchGoal.
  await db.query(`insert into futbeat_private.provider_observations(
      provider,external_match_id,canonical_match_id,received_at,status,home_score,away_score,minute,raw_payload,payload_hash)
    values('goal_api','ext-local-repair',$1,now(),'VERIFIED',2,1,90,'{}',md5(random()::text)||md5(clock_timestamp()::text))`,
    [match]);
  const h = harness(db);
  const { value } = await h.invoke();
  assert.equal(value.results.status, 'skipped');
  assert.equal(value.results.reason, 'reconciled_locally');
  assert.equal(h.providers().length, 0, 'local repair means 0 GOAL calls');
}));

test('results-only: provider HTTP failure is recorded as FAILED with a sanitized reason, no secrets leaked', () => withDb(async (db) => {
  await seedResultsDueMatch(db);
  const h = harness(db, { provider: () => Response.json({ success: false }, { status: 500 }) });
  const { value } = await h.invoke();
  assert.equal(value.status, 'ok');
  assert.equal(value.results.status, 'failed');
  const completion = h.rpcCalls('futbeat_complete_provider_call')[0];
  assert.equal(completion.body.p_status, 'FAILED');
  assert.ok(!JSON.stringify([value, h.logs]).includes(goalKey));
}));

test('results-only: finalization stage failure is distinguishable from a provider fetch failure', () => withDb(async (db) => {
  const { external, dateStr } = await seedResultsDueMatch(db);
  // A fixture with no apiId/id cannot be linked or normalized -> exercises
  // the post-fetch pipeline (link/record/finalize) rather than the fetch itself.
  const h = harness(db, {
    provider: () => Response.json({ success: true, data: [{ matchStatus: 'FINISHED' }], pagination: { total: 1 } }),
  });
  const { value } = await h.invoke();
  // A fixture with no external id is silently skipped by both
  // futbeat_link_goal_live_matches and the worker's own fixture loop, so the
  // batch still completes -- 0 results linked, not a hard failure.
  assert.equal(value.results.status, 'ok', JSON.stringify({ value, logs: h.logs }));
  assert.equal(value.results.results, 0);
}));

test('results-only wake actually invokes syncOneResultsDate (not a routing no-op)', async () => {
  const source = workerSource;
  const handlerBlock = source.slice(source.indexOf('if (trigger === "results-only")'), source.indexOf('if (trigger === "detail-only"'));
  assert.match(handlerBlock, /syncOneResultsDate\(\)/);
});

test('results-only run does not touch demand/live provider_call_ledger rows or wake other lanes', () => withDb(async (db) => {
  const { external, dateStr } = await seedResultsDueMatch(db);
  const h = harness(db, {
    provider: () => Response.json({ success: true, data: [resultFixture(external)], pagination: { total: 1 } }),
  });
  await h.invoke();
  const kinds = (await db.query("select distinct call_kind from futbeat_private.provider_call_ledger")).rows.map(r => r.call_kind);
  assert.deepEqual(kinds, ['results-date']);
  const wakeRow = await db.query("select count(*)::int n from futbeat_private.worker_wakeups where trigger='demand'");
  assert.equal(wakeRow.rows[0].n, 0);
}));

test('pagination: a duplicated page 2 (same rows as page 1) still reaches SUCCEEDED via the total match, not the safety cap', () => withDb(async (db) => {
  const { external } = await seedResultsDueMatch(db);
  let call = 0;
  const h = harness(db, {
    provider: () => {
      call++;
      // Page 1: 500 rows all identical to the one real fixture we care about
      // (simulates GOAL repeating rows to fill a page). pagination.total
      // claims more exist than are actually unique.
      if (call === 1) {
        const data = Array.from({ length: 500 }, () => resultFixture(external));
        return Response.json({ success: true, data, pagination: { total: 600 } });
      }
      const data = Array.from({ length: 100 }, () => resultFixture(external));
      return Response.json({ success: true, data, pagination: { total: 600 } });
    },
  });
  const { value } = await h.invoke();
  assert.equal(value.results.status, 'ok', JSON.stringify(value));
  assert.equal(value.results.results, 1, 'the 600 rows collapse to the one unique fixture id');
  assert.equal(value.results.providerRequests, 2);
}));

test('a large realistic multi-fixture results-date batch (300 worldwide matches, 1 tracked) succeeds', () => withDb(async (db) => {
  const { external, dateStr } = await seedResultsDueMatch(db);
  const h = harness(db, {
    provider: () => {
      const data = [];
      for (let i = 0; i < 299; i++) {
        data.push({
          apiId: `untracked-${i}`,
          homeTeam: { id: `untracked-home-${i}`, name: `Untracked Home ${i}` },
          awayTeam: { id: `untracked-away-${i}`, name: `Untracked Away ${i}` },
          kickoffUtc: `${dateStr}T15:00:00Z`,
          matchStatus: 'FINISHED', matchPeriod: 'FULL_TIME', matchElapsed: '90',
          homeTeamScore: 1, awayTeamScore: 0, events: [], cards: [], substitutions: [],
        });
      }
      data.push(resultFixture(external));
      return Response.json({ success: true, data, pagination: { total: 300 } });
    },
  });
  const { value } = await h.invoke();
  assert.equal(value.results.status, 'ok', JSON.stringify(value));
  assert.equal(value.results.results, 300);
  const completion = h.rpcCalls('futbeat_complete_provider_call')[0];
  assert.equal(completion.body.p_status, 'SUCCEEDED');
  assert.equal(completion.body.p_metadata.unmappedMatches, 299, '299 untracked fixtures are recorded as unmapped, not an error');
}));

test('a stage-tagged failure names the failing stage and never leaks the GOAL key or a raw provider payload', () => withDb(async (db) => {
  await seedResultsDueMatch(db);
  const h = harness(db, { provider: () => Response.json({ success: false, secretLeakCanary: goalKey }, { status: 500 }) });
  const { value } = await h.invoke();
  assert.equal(value.results.status, 'failed');
  assert.equal(value.results.stage, 'provider_fetch');
  assert.ok(value.results.detail.length <= 200);
  assert.ok(!JSON.stringify([value, h.logs]).includes(goalKey), 'the GOAL key must never appear in the response or logs');
  const completion = h.rpcCalls('futbeat_complete_provider_call')[0];
  assert.equal(completion.body.p_metadata.stage, 'provider_fetch');
}));
