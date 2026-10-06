import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { openDatabase } from '../storage/database.mjs';
import { collectGoalApiBaseIdentities, normalizeGoalApiFixtures } from '../providers/goal_api.mjs';
import { goalFixtureScore } from '../../supabase/functions/_shared/live_events.ts';
import { runChunksWithTimeoutRetry } from '../../supabase/functions/_shared/chunked_rpc.ts';

// 20261005110000: the GOAL hot ingest reads only the existing entities of
// its batch (futbeat_read_ingest_context, after resolve-base) instead of the
// full snapshot (3.8 MB, 5.6-7.8 s, 57014 in production run 37411216092).

const ingestSource = await readFile(new URL('../../supabase/functions/futbeat-global-ingest/index.ts', import.meta.url), 'utf8');
const stripImports = (source) => source.replace(/^import\s[\s\S]*?;\r?\n/gm, '');

const SQL_RPCS = new Set(['futbeat_reserve_provider_call', 'futbeat_read_ingest_context', 'futbeat_resolve_global_entities',
  'futbeat_store_global_fixture_window', 'futbeat_complete_provider_call']);

function harness(db, { failResolveOnce = false } = {}) {
  const calls = [];
  let handler;
  let resolveFailures = failResolveOnce ? 1 : 0;
  const fetch = async (input, init = {}) => {
    const url = new URL(input);
    const body = init.body ? JSON.parse(init.body) : {};
    calls.push({ name: url.pathname.split('/').at(-1), origin: url.origin, body });
    if (url.origin !== 'https://supabase.test') throw new Error(`Unexpected request ${url.href}`);
    const name = url.pathname.split('/').at(-1);
    if (!SQL_RPCS.has(name)) throw new Error(`Unexpected RPC ${name}`);
    if (name === 'futbeat_resolve_global_entities' && resolveFailures > 0) {
      resolveFailures -= 1;
      return new Response('{"code":"57014","details":null,"hint":null,"message":"canceling statement due to statement timeout"}', { status: 500 });
    }
    const entries = Object.entries(body);
    const args = entries.map(([k], i) => `${k} => $${i + 1}`).join(',');
    // text[] parameters stay JS arrays; everything else object-shaped is jsonb.
    const values = entries.map(([k, v]) => (k === 'p_competition_ids' || k === 'p_team_ids') ? v
      : v != null && typeof v === 'object' ? JSON.stringify(v) : v);
    if (name === 'futbeat_resolve_global_entities') {
      return Response.json((await db.query(`select * from public.${name}(${args})`, values)).rows);
    }
    return Response.json((await db.query(`select public.${name}(${args}) value`, values)).rows[0].value);
  };
  const context = vm.createContext({
    Request, Response, Headers, URL, AbortSignal, TextEncoder, crypto, performance, Error, fetch, setTimeout,
    console: { error: () => {}, warn: () => {}, log: () => {} },
    Deno: { env: { get: (n) => ({ SUPABASE_URL: 'https://supabase.test', SUPABASE_SERVICE_ROLE_KEY: 'test-service-key' })[n] }, serve: (fn) => { handler = fn; } },
    createRemoteJWKSet: () => ({}),
    jwtVerify: async () => ({ payload: { repository: 'henguido/FutBeat', ref: 'refs/heads/main', event_name: 'workflow_dispatch',
      workflow_ref: 'henguido/FutBeat/.github/workflows/global-fixtures.yml@refs/heads/main' } }),
    collectGoalApiBaseIdentities, normalizeGoalApiFixtures, goalFixtureScore, runChunksWithTimeoutRetry,
  });
  vm.runInContext(stripTypeScriptTypes(stripImports(ingestSource)), context);
  return {
    calls, context,
    names: () => calls.map((c) => c.name),
    async hot(events, dates) {
      const response = await handler(new Request('https://ingest.test/', { method: 'POST',
        headers: { authorization: 'Bearer test-only-oidc' },
        body: JSON.stringify({ source: 'GOAL API', mode: 'hot', dates, providerRemaining: 500, events }) }));
      return { status: response.status, value: await response.json() };
    },
  };
}

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const day = (offset) => { const d = new Date(); d.setUTCDate(d.getUTCDate() + offset); return d.toISOString().slice(0, 10); };
const dates = [day(-1), day(0), day(1)];
const kickoff = (hourUtc) => `${day(0)}T${String(hourUtc).padStart(2, '0')}:00:00.000Z`;
const fixture = (id, league, home, away, hour, status = 'FINISHED') => ({
  apiId: id, kickoffUtc: kickoff(hour), matchStatus: status, matchPeriod: 'FULL_TIME', matchElapsed: '90',
  homeTeamScore: 2, awayTeamScore: 1,
  league: { id: league, name: `League ${league}` }, homeTeam: { id: home, name: `Team ${home}` }, awayTeam: { id: away, name: `Team ${away}` },
});
const count = (db, sql) => db.query(sql).then((r) => r.rows[0].n);

test('hot ingest never reads the full snapshot; reads the targeted context after resolve-base; accepts the batch', () => withDb(async (db) => {
  const h = harness(db);
  const events = [fixture('m1', 'L1', 'A', 'B', 12), fixture('m2', 'L1', 'C', 'D', 14), fixture('m3', 'L2', 'A', 'E', 16)];
  const { status, value } = await h.hot(events, dates);
  assert.equal(status, 200, JSON.stringify(value));
  assert.equal(value.accepted, 3);
  const names = h.names();
  assert.equal(names.includes('futbeat_read_snapshot'), false, 'no full snapshot call');
  const firstResolve = names.indexOf('futbeat_resolve_global_entities');
  const ctx = names.indexOf('futbeat_read_ingest_context');
  assert.ok(ctx > firstResolve, 'context read after resolve-base');
  assert.equal(names.filter((n) => n === 'futbeat_read_ingest_context').length, 1);
  const request = h.calls.find((c) => c.name === 'futbeat_read_ingest_context').body;
  assert.equal(request.p_competition_ids.length, 2);
  assert.equal(request.p_team_ids.length, 5, 'A appears twice, requested once');
  assert.deepEqual(request.p_team_ids, [...request.p_team_ids].sort());
  assert.equal(request.p_from, kickoff(12));
  assert.equal(request.p_to, kickoff(16));
  assert.ok(h.calls.every((c) => c.origin === 'https://supabase.test'), 'no GOAL call from the ingest');
}));

test('a second run: known entities come back from the context, new ones are resolved, no duplicates, same canonical ids', () => withDb(async (db) => {
  const h1 = harness(db);
  await h1.hot([fixture('m1', 'L1', 'A', 'B', 12)], dates);
  const before = await count(db, "select count(*)::int n from futbeat_private.entities where kind='match'");
  const idA = (await db.query("select canonical_id from futbeat_private.provider_entities where provider='goal_api' and kind='team' and external_id='A'")).rows[0].canonical_id;
  const h2 = harness(db);
  const { status, value } = await h2.hot([fixture('m1', 'L1', 'A', 'B', 12), fixture('m4', 'L1', 'A', 'Z', 15)], dates);
  assert.equal(status, 200, JSON.stringify(value));
  const ctxResult = await db.query('select public.futbeat_read_ingest_context($1,$2,$3,$4) v', [
    h2.calls.find((c) => c.name === 'futbeat_read_ingest_context').body.p_competition_ids,
    h2.calls.find((c) => c.name === 'futbeat_read_ingest_context').body.p_team_ids, kickoff(12), kickoff(15)]);
  assert.ok(ctxResult.rows[0].v.teams.some((t) => t.id === idA), 'known team read from the last import');
  assert.equal(await count(db, "select count(*)::int n from futbeat_private.entities where kind='match'"), before + 1, 'only the new fixture is a new match');
  assert.equal((await db.query("select canonical_id from futbeat_private.provider_entities where provider='goal_api' and kind='team' and external_id='A'")).rows[0].canonical_id, idA);
}));

test('57014 on the first identity chunk is retried once and the ingest still succeeds', () => withDb(async (db) => {
  const h = harness(db, { failResolveOnce: true });
  const { status, value } = await h.hot([fixture('m1', 'L1', 'A', 'B', 12)], dates);
  assert.equal(status, 200, JSON.stringify(value));
  assert.equal(value.accepted, 1);
  assert.equal(h.names().filter((n) => n === 'futbeat_resolve_global_entities').length, 3, 'base chunk twice, match chunk once');
}));

test('ingestContextRequest: deduplicated sorted ids, kickoff window, empty batch', () => withDb(async (db) => {
  const h = harness(db);
  const resolved = new Map([['competition:L1', 'c1'], ['team:A', 't2'], ['team:B', 't1'], ['team:A2', 't2'], ['match:m', 'x']]);
  const req = h.context.ingestContextRequest([{ kickoffUtc: kickoff(15) }, { kickoffUtc: 'bad' }, { kickoffUtc: kickoff(9) }], resolved);
  assert.deepEqual(JSON.parse(JSON.stringify(req)), { p_competition_ids: ['c1'], p_team_ids: ['t1', 't2'], p_from: kickoff(9), p_to: kickoff(15) });
  const empty = h.context.ingestContextRequest([], new Map());
  assert.deepEqual(JSON.parse(JSON.stringify(empty)), { p_competition_ids: [], p_team_ids: [], p_from: null, p_to: null });
}));

test('SQL: targeted context equals the full snapshot items for the same ids; missing ids are simply absent', () => withDb(async (db) => {
  const comp = (id) => ({ id, name: `Comp ${id}`, country: 'X', season: '2026' });
  const team = (id) => ({ id, name: `Team ${id}`, shortName: '', country: '', competitionId: 'fb_competition_k1', aliases: [] });
  const match = (id, h, a, start) => ({ id, competitionId: 'fb_competition_k1', homeTeamId: h, awayTeamId: a, startTime: start, status: 'SCHEDULED', events: [], statistics: [] });
  const snapshot = { schemaVersion: 1, demo: false, updatedAt: new Date().toISOString(),
    competitions: [comp('fb_competition_k1'), comp('fb_competition_k2')],
    teams: [team('fb_team_k1'), team('fb_team_k2'), team('fb_team_k3')],
    players: [],
    matches: [match('fb_match_k1', 'fb_team_k1', 'fb_team_k2', kickoff(12)), match('fb_match_k2', 'fb_team_k1', 'fb_team_k3', kickoff(20)),
      match('fb_match_k3', 'fb_team_k2', 'fb_team_k3', kickoff(13))] };
  await db.query("insert into futbeat_private.imports(job_id,received_at,raw_payload,snapshot) values('test-import-ctx',now()+interval '1 minute','{}'::jsonb,$1)", [JSON.stringify(snapshot)]);
  const ctx = (await db.query('select public.futbeat_read_ingest_context($1,$2,$3,$4) v',
    [['fb_competition_k1', 'fb_competition_missing'], ['fb_team_k1', 'fb_team_k2', 'fb_team_missing'], kickoff(11), kickoff(14)])).rows[0].v;
  const full = (await db.query('select public.futbeat_read_snapshot() v')).rows[0].v;
  assert.deepEqual(ctx.competitions, full.competitions.filter((c) => c.id === 'fb_competition_k1'));
  assert.deepEqual(ctx.teams, full.teams.filter((t) => ['fb_team_k1', 'fb_team_k2'].includes(t.id)));
  assert.deepEqual(ctx.matches.map((m) => m.id), ['fb_match_k1'], 'both teams requested and kickoff inside the window');
  assert.deepEqual(ctx.matches[0], full.matches.find((m) => m.id === 'fb_match_k1'));
  const none = (await db.query("select public.futbeat_read_ingest_context('{}'::text[],'{}'::text[],null,null) v")).rows[0].v;
  assert.deepEqual(none, { competitions: [], teams: [], matches: [] });
}));

test('SQL: read-only, service_role only', () => withDb(async (db) => {
  const v = (await db.query("select provolatile v from pg_proc where proname='futbeat_read_ingest_context'")).rows[0].v;
  assert.equal(v, 's');
  for (const role of ['anon', 'authenticated']) {
    assert.equal((await db.query("select has_function_privilege($1,'public.futbeat_read_ingest_context(text[],text[],timestamptz,timestamptz)','execute') ok", [role])).rows[0].ok, false);
  }
}));
