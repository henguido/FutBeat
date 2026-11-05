#!/usr/bin/env node
// Multi-client smoke/load test of the FutBeat 1.0 public API contract.
//
// Each simulated client signs in as its own Supabase ANONYMOUS user (the
// guest flow the app uses), then browses stored data through futbeat-api
// with its own access token. Reports status codes, 401/429 counts and
// latency per route.
//
// Safety:
//   * dry run unless --run is given (prints the plan, makes no request);
//   * REFUSES the production project unless --allow-production AND
//     --production-ref <ref> repeat the production ref exactly;
//   * only GET reads of stored data; with the database switch off
//     (api_access_policy.navigation_demands=false) no provider demand.
//   * keys come from the environment, never arguments, and are never
//     printed: FUTBEAT_SUPABASE_URL, FUTBEAT_PUBLISHABLE_KEY.
//
// Usage:
//   FUTBEAT_SUPABASE_URL=https://<staging>.supabase.co \
//   FUTBEAT_PUBLISHABLE_KEY=sb_publishable_... \
//   node scripts/load/public-api-multi-client.mjs --clients 5 --rounds 3 --match fb_match_x --run

const PRODUCTION_REF = 'izlmruqawgagwdcsjhte';

function args(argv) {
  const out = { clients: 3, rounds: 2, match: null, team: null, run: false, allowProduction: false, productionRef: '' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--run') out.run = true;
    else if (a === '--allow-production') out.allowProduction = true;
    else if (a === '--clients') out.clients = Number(argv[++i]);
    else if (a === '--rounds') out.rounds = Number(argv[++i]);
    else if (a === '--match') out.match = argv[++i];
    else if (a === '--team') out.team = argv[++i];
    else if (a === '--production-ref') out.productionRef = argv[++i] ?? '';
    else throw new Error(`Unknown argument ${a}`);
  }
  if (!Number.isInteger(out.clients) || out.clients < 1 || out.clients > 50) throw new Error('--clients must be 1..50');
  if (!Number.isInteger(out.rounds) || out.rounds < 1 || out.rounds > 20) throw new Error('--rounds must be 1..20');
  for (const id of [out.match, out.team]) {
    if (id !== null && !/^fb_(match|team)_[A-Za-z0-9_-]{3,120}$/.test(id)) throw new Error('Invalid entity id');
  }
  return out;
}

export function plan(options, url) {
  const ref = new URL(url).hostname.split('.')[0];
  if (ref === PRODUCTION_REF && !(options.allowProduction && options.productionRef === PRODUCTION_REF)) {
    throw new Error('REFUSED: production project. Use staging, or pass --allow-production --production-ref <ref> with written authorization.');
  }
  const today = new Date().toISOString().slice(0, 10);
  const routes = [
    `/v1/calendar?date=${today}&timezone=America/Costa_Rica`,
    '/v1/explore',
    '/v1/search?q=saprissa',
    ...(options.match ? [
      `/v1/match-context?id=${options.match}`, `/v1/match-detail?id=${options.match}&request=0`,
      `/v1/match-preview?id=${options.match}`, `/v1/match-summary?id=${options.match}`,
    ] : []),
    ...(options.team ? [`/v1/entity?type=team&id=${options.team}`, `/v1/team-matches?id=${options.team}&bucket=results`] : []),
  ];
  return { ref, routes, requests: options.clients * options.rounds * routes.length };
}

async function signInAnonymously(base, key) {
  const response = await fetch(`${base}/auth/v1/signup`, {
    method: 'POST',
    headers: { apikey: key, 'Content-Type': 'application/json' },
    body: '{}',
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || typeof body.access_token !== 'string') {
    throw new Error(`anonymous sign-in failed: HTTP ${response.status} ${body.error_code ?? body.code ?? ''}`.trim());
  }
  return body.access_token;
}

const percentile = (values, p) => {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return Math.round(sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]);
};

async function main() {
  const options = args(process.argv.slice(2));
  const base = (process.env.FUTBEAT_SUPABASE_URL ?? '').replace(/\/+$/, '');
  const key = process.env.FUTBEAT_PUBLISHABLE_KEY ?? '';
  if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(base)) throw new Error('FUTBEAT_SUPABASE_URL must be https://<ref>.supabase.co');
  if (!/^sb_publishable_[A-Za-z0-9_-]{10,}$/.test(key)) throw new Error('FUTBEAT_PUBLISHABLE_KEY must be a publishable key');
  const p = plan(options, base);
  console.log(JSON.stringify({ project: p.ref, clients: options.clients, rounds: options.rounds, routes: p.routes, requests: p.requests, run: options.run }, null, 2));
  if (!options.run) {
    console.log('Dry run: no request sent. Add --run to execute.');
    return;
  }
  const tokens = [];
  for (let i = 0; i < options.clients; i++) tokens.push(await signInAnonymously(base, key));
  const results = [];
  await Promise.all(tokens.map(async (token, client) => {
    for (let round = 0; round < options.rounds; round++) {
      for (const route of p.routes) {
        const started = performance.now();
        const response = await fetch(`${base}/functions/v1/futbeat-api${route}`, {
          headers: { apikey: key, Authorization: `Bearer ${token}` },
        });
        await response.arrayBuffer();
        results.push({ client, route: route.split('?')[0], status: response.status, ms: performance.now() - started,
          retryAfter: response.headers.get('retry-after') });
      }
    }
  }));
  const byRoute = {};
  for (const r of results) {
    const entry = byRoute[r.route] ??= { statuses: {}, ms: [] };
    entry.statuses[r.status] = (entry.statuses[r.status] ?? 0) + 1;
    entry.ms.push(r.ms);
  }
  const summary = Object.fromEntries(Object.entries(byRoute).map(([route, e]) =>
    [route, { statuses: e.statuses, p50: percentile(e.ms, 50), p95: percentile(e.ms, 95) }]));
  console.log(JSON.stringify({
    total: results.length,
    unauthorized: results.filter((r) => r.status === 401).length,
    limited: results.filter((r) => r.status === 429).length,
    serverErrors: results.filter((r) => r.status >= 500).length,
    routes: summary,
  }, null, 2));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
