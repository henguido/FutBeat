import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

// Runs the real GOAL worker (futbeat-goal-live-sync) in node against a real
// SQL database (RPCs are executed as `select public.<rpc>(...)`) and a
// simulated GOAL API. Any other network access fails the test.

const token = 'test-only-cron-token-not-a-secret-123456789';
const goalKey = 'test-only-goal-key-not-a-secret-HARNESS';
const read = (path) => readFile(new URL(`../../../supabase/functions/${path}`, import.meta.url), 'utf8');
const stripImports = (source) => source.replace(/^import\s[\s\S]*?;\r?\n/gm, '');
const stripExports = (source) => source.replace(/^export /gm, '');
const sources = await Promise.all([
  read('_shared/results_pagination.ts'), read('_shared/goal_players.ts'), read('_shared/goal_standings.ts'),
  read('futbeat-goal-live-sync/index.ts'),
]);

export const goalOk = (data, remaining = 700) => new Response(JSON.stringify({ success: true, data }),
  { status: 200, headers: { 'x-ratelimit-remaining': String(remaining), 'content-type': 'application/json' } });

export function worker(db, goal) {
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
  const [pagination, players, standings, workerSource] = sources;
  vm.runInContext(stripTypeScriptTypes([stripExports(pagination), stripExports(players), stripExports(standings),
    stripImports(workerSource)].join('\n')), context);
  return {
    calls, logs,
    goalCalls: () => calls.filter((u) => u.startsWith('https://api.goal-api.com')),
    async run(trigger = 'demand') {
      const response = await handler(new Request('https://worker.test/', { method: 'POST',
        headers: { 'x-futbeat-cron-token': token }, body: JSON.stringify({ trigger }) }));
      const text = await response.text();
      assert.deepEqual(unexpected, []);
      assert.ok(!text.includes(goalKey) && !JSON.stringify(logs).includes(goalKey), 'provider key leaked');
      return JSON.parse(text);
    },
  };
}
