import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';
import {
  ProviderHealth,
  defaultProviderHubConfig,
  providerDescriptors,
  providerHealth,
} from '../providers/core/hub.mjs';
import { apiFootballDescriptor } from '../providers/api_football.mjs';
import { sportmonksDescriptor } from '../providers/sportmonks.mjs';

// Provider Hub Phase 1A (#102): config, persistent quota, health, security
// and GOAL regressions. PGlite only; no provider network.

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}
const config = (db) => db.query(`select provider,enabled,role,development_only,priority,daily_budget,minute_budget
  from futbeat_private.provider_hub_config order by priority`).then((r) => r.rows);
const reserve = (db, provider, units = 1, kind = 'fixtures') => db.query(
  "select public.futbeat_reserve_provider_hub_call($1,$2,'test',$3) v", [provider, kind, units]).then((r) => r.rows[0].v);
const status = (db) => db.query('select public.futbeat_provider_hub_status() v').then((r) => r.rows[0].v);
const statusOf = async (db, provider) => (await status(db)).providers.find((p) => p.provider === provider);
const ledgerCount = (db, provider) => db.query('select count(*)::int n from futbeat_private.provider_call_ledger where provider=$1', [provider])
  .then((r) => r.rows[0].n);

test('registry/config: GOAL PRIMARY enabled; API-Football SECONDARY disabled; Sportmonks INTEGRATION disabled', () => withDb(async (db) => {
  assert.deepEqual(await config(db), [
    { provider: 'goal_api', enabled: true, role: 'PRIMARY', development_only: false, priority: 1, daily_budget: null, minute_budget: null },
    { provider: 'api_football', enabled: false, role: 'SECONDARY', development_only: true, priority: 2, daily_budget: 100, minute_budget: 10 },
    { provider: 'sportmonks', enabled: false, role: 'INTEGRATION', development_only: true, priority: 3, daily_budget: null, minute_budget: null },
  ]);
  // The JS mirror agrees with the seed.
  for (const row of await config(db)) {
    const js = defaultProviderHubConfig[row.provider];
    assert.deepEqual([js.enabled, js.role, js.developmentOnly, js.dailyBudget], [row.enabled, row.role, row.development_only, row.daily_budget]);
  }
  assert.equal(providerDescriptors.api_football, apiFootballDescriptor);
  assert.equal(apiFootballDescriptor.developmentOnly, true, 'API-Football stays development-only');
  assert.equal(providerDescriptors.sportmonks, sportmonksDescriptor);
  // Sportmonks can never be enabled without a configured budget (DB check).
  await assert.rejects(db.query("update futbeat_private.provider_hub_config set enabled=true where provider='sportmonks'"),
    /check/);
}));

test('quota: disabled providers never reserve; Sportmonks without budget never reserves', () => withDb(async (db) => {
  for (const provider of ['api_football', 'sportmonks']) {
    const r = await reserve(db, provider);
    assert.deepEqual([r.allowed, r.reason], [false, 'provider_disabled']);
  }
  await db.query("update futbeat_private.provider_hub_config set enabled=true,daily_budget=5 where provider='sportmonks'");
  await db.query("update futbeat_private.provider_hub_config set daily_budget=null,enabled=false where provider='sportmonks'");
  assert.equal((await reserve(db, 'sportmonks')).reason, 'provider_disabled');
  assert.equal((await reserve(db, 'goal_api')).reason, 'primary_uses_quota_manager', 'GOAL keeps its own manager');
  assert.equal((await reserve(db, 'unknown_provider')).reason, 'unknown_provider');
  for (const provider of ['api_football', 'sportmonks', 'goal_api']) assert.equal(await ledgerCount(db, provider), 0);
}));

test('quota: a (synthetic) enabled API-Football can never exceed 100 request units per day in total', () => withDb(async (db) => {
  await db.query("update futbeat_private.provider_hub_config set enabled=true,minute_budget=null where provider='api_football'");
  const kinds = ['live', 'fixtures', 'events', 'lineups', 'statistics'];
  let allowed = 0;
  for (let i = 0; i < 130; i++) {
    const r = await reserve(db, 'api_football', 1, kinds[i % kinds.length]);
    if (r.allowed) allowed++;
    else assert.equal(r.reason, 'provider_daily_budget');
  }
  assert.equal(allowed, 100, 'total across every call kind');
  // Multi-unit reservations cannot overshoot either.
  await db.query("delete from futbeat_private.provider_call_ledger where provider='api_football' and true");
  assert.equal((await reserve(db, 'api_football', 98)).allowed, true);
  assert.equal((await reserve(db, 'api_football', 3)).allowed, false);
  assert.equal((await reserve(db, 'api_football', 2)).allowed, true);
  const units = (await db.query(`select sum(futbeat_private.provider_call_units(metadata))::int n
    from futbeat_private.provider_call_ledger where provider='api_football'`)).rows[0].n;
  assert.equal(units, 100);
}));

test('quota: the minute budget is enforced persistently (10/min)', () => withDb(async (db) => {
  await db.query("update futbeat_private.provider_hub_config set enabled=true where provider='api_football'");
  const results = [];
  for (let i = 0; i < 12; i++) results.push(await reserve(db, 'api_football'));
  assert.equal(results.filter((r) => r.allowed).length, 10);
  assert.equal(results.at(-1).reason, 'provider_minute_budget');
}));

test('health (JS rules): disabled, unseen, healthy, degraded, unavailable', () => {
  const on = { enabled: true };
  assert.equal(providerHealth({ enabled: false }, { successCount: 10 }), ProviderHealth.disabled);
  assert.equal(providerHealth(on, {}), ProviderHealth.unseen);
  assert.equal(providerHealth(on, { successCount: 10, failedCount: 1 }), ProviderHealth.healthy);
  assert.equal(providerHealth(on, { successCount: 7, failedCount: 3, failureStreak: 1 }), ProviderHealth.degraded);
  assert.equal(providerHealth(on, { successCount: 10, p95LatencyMs: 12000 }), ProviderHealth.degraded);
  assert.equal(providerHealth(on, { successCount: 10, failedCount: 3, failureStreak: 3 }), ProviderHealth.unavailable);
  assert.equal(providerHealth(on, { successCount: 10, failedCount: 1, lastCompletionFailed: true, lastFailureHttpStatus: 401 }),
    ProviderHealth.unavailable);
});

async function ledger(db, provider, rows) {
  for (const [minutesAgo, st, http, latencySeconds = 1] of rows) {
    await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,completed_at,status,http_status)
      values($1,'fixtures','test',now()-make_interval(mins=>$2),now()-make_interval(mins=>$2)+make_interval(secs=>$4),$3,$5)`,
    [provider, minutesAgo, st, latencySeconds, http]);
  }
}

test('health (SQL status): derived from the ledger with the same rules', () => withDb(async (db) => {
  assert.equal((await statusOf(db, 'api_football')).health, 'DISABLED');
  assert.equal((await statusOf(db, 'goal_api')).health, 'UNSEEN');
  await ledger(db, 'goal_api', [[30, 'SUCCEEDED', 200], [20, 'SUCCEEDED', 200], [10, 'SUCCEEDED', 200, 2]]);
  const goal = await statusOf(db, 'goal_api');
  assert.deepEqual([goal.health, goal.successToday >= 0, goal.averageLatencyMs > 0], ['HEALTHY', true, true]);
  await db.query("update futbeat_private.provider_hub_config set enabled=true where provider='api_football'");
  await ledger(db, 'api_football', [[50, 'SUCCEEDED', 200], [40, 'SUCCEEDED', 200], [30, 'SUCCEEDED', 200], [20, 'FAILED', 500]]);
  assert.equal((await statusOf(db, 'api_football')).health, 'DEGRADED', '1/4 failed');
  await ledger(db, 'api_football', [[15, 'FAILED', 500], [5, 'FAILED', 500]]);
  assert.equal((await statusOf(db, 'api_football')).health, 'UNAVAILABLE', '3 consecutive failures');
  await ledger(db, 'api_football', [[2, 'SUCCEEDED', 200], [1, 'FAILED', 401]]);
  assert.equal((await statusOf(db, 'api_football')).health, 'UNAVAILABLE', 'auth failure');
  await db.query("update futbeat_private.provider_hub_config set enabled=false where provider='api_football'");
  assert.equal((await statusOf(db, 'api_football')).health, 'DISABLED');
}));

test('status: all three providers, budgets and no secrets', () => withDb(async (db) => {
  await db.query(`insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,metadata)
    values('api_football','fixtures','test','{"apiKey":"synthetic-secret-123","Authorization":"Bearer synthetic-secret-123"}')`);
  const s = await status(db);
  assert.deepEqual(s.providers.map((p) => p.provider), ['goal_api', 'api_football', 'sportmonks']);
  const text = JSON.stringify(s);
  assert.ok(!/synthetic-secret-123|apiKey|Authorization|token/i.test(text), 'no secrets or headers');
  const af = s.providers.find((p) => p.provider === 'api_football');
  assert.deepEqual([af.enabled, af.role, af.developmentOnly, af.dailyBudget, af.callsToday], [false, 'SECONDARY', true, 100, 1]);
}));

test('security: hub RPCs are service-only; helpers private; tables not exposed', () => withDb(async (db) => {
  const can = async (role, fn) => (await db.query("select has_function_privilege($1,$2,'EXECUTE') ok", [role, fn])).rows[0].ok;
  const rpcs = ['public.futbeat_reserve_provider_hub_call(text,text,text,integer,jsonb)', 'public.futbeat_provider_hub_status()',
    'public.futbeat_bind_provider_entity(text,text,text,text,jsonb)',
    'public.futbeat_match_provider_fixture(text,text,text,text,text,timestamptz,text,text,boolean)'];
  for (const fn of rpcs) {
    for (const role of ['anon', 'authenticated']) assert.equal(await can(role, fn), false, `${role} ${fn}`);
    assert.equal(await can('service_role', fn), true, fn);
  }
  for (const fn of ['futbeat_private.provider_hub_decision(text,integer)', 'futbeat_private.resolve_provider_entity_strict(text,text,text)']) {
    for (const role of ['anon', 'authenticated', 'service_role']) assert.equal(await can(role, fn), false, `${role} ${fn}`);
  }
  for (const table of ['futbeat_private.provider_hub_config', 'futbeat_private.provider_fixture_diagnostics']) {
    for (const role of ['anon', 'authenticated']) {
      assert.equal((await db.query("select has_table_privilege($1,$2,'SELECT') ok", [role, table])).rows[0].ok, false);
    }
  }
}));

test('GOAL regression: policy, LIVE floor 20, live-goal cap and decisions are unchanged by the hub', () => withDb(async (db) => {
  const policy = (await db.query("select class_floors,kind_daily_caps from futbeat_private.provider_quota_policy where provider='goal_api'")).rows[0];
  assert.equal(policy.class_floors.live, 20);
  assert.equal(policy.kind_daily_caps['live-goal'], 400);
  assert.equal(policy.kind_daily_caps['match-detail'], 900);
  const decide = async (kind, cls) => (await db.query('select futbeat_private.quota_decision($1,$2,$3) v', ['goal_api', kind, cls])).rows[0].v;
  const before = { live: await decide('live-goal', 'live'), detail: await decide('match-detail', 'user') };
  // Secondary activity (even a synthetic enabled API-Football) never touches GOAL.
  await db.query("update futbeat_private.provider_hub_config set enabled=true,minute_budget=null where provider='api_football'");
  for (let i = 0; i < 20; i++) await reserve(db, 'api_football');
  assert.deepEqual({ live: await decide('live-goal', 'live'), detail: await decide('match-detail', 'user') }, before);
  assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_quota_policy where provider<>'goal_api'")).rows[0].n, 0,
    'no second quota policy/governor');
}));

test('no activation anywhere: no workflow, worker or ingest references the new providers or hub reservation', async () => {
  const roots = ['.github/workflows', 'supabase/functions'];
  const offenders = [];
  for (const root of roots) {
    const dir = new URL(`../../${root}/`, import.meta.url);
    const walk = async (url) => {
      for (const entry of await readdir(url, { withFileTypes: true })) {
        const child = new URL(entry.name + (entry.isDirectory() ? '/' : ''), url);
        if (entry.isDirectory()) await walk(child);
        else if (/\.(ya?ml|ts|mjs|js)$/.test(entry.name)) {
          const text = await readFile(child, 'utf8');
          if (/sportmonks|futbeat_reserve_provider_hub_call|SPORTMONKS_TOKEN/i.test(text)) offenders.push(child.pathname);
        }
      }
    };
    await walk(dir);
  }
  assert.deepEqual(offenders, []);
  // The legacy API-Football edge functions (futbeat-live-sync /
  // futbeat-fixtures-sync) stay unscheduled: 20260918194000 removed the live
  // job, 20260925071000 removes every legacy job for good, and no later
  // migration schedules them again (mentioning them to unschedule is fine).
  const migrations = (await readdir(new URL('../../supabase/migrations/', import.meta.url))).sort();
  const unscheduledAt = migrations.indexOf('20260918194000_rebalance_goal_live_quota.sql');
  assert.ok(unscheduledAt >= 0);
  const unschedule = await readFile(new URL(`../../supabase/migrations/${migrations[unscheduledAt]}`, import.meta.url), 'utf8');
  assert.match(unschedule, /jobname='futbeat-live-sync-free-tier'[\s\S]*cron\.unschedule/);
  for (const name of migrations.slice(unscheduledAt + 1)) {
    const text = await readFile(new URL(`../../supabase/migrations/${name}`, import.meta.url), 'utf8');
    assert.doesNotMatch(text, /http_post\(\s*url\s*:=\s*'[^']*\/functions\/v1\/futbeat-(live|fixtures)-sync'/, name);
    assert.doesNotMatch(text, /cron\.(schedule|alter_job)\([^;]{0,200}futbeat-(live-sync|fixtures-(today|tomorrow|yesterday|three-day-window))/, name);
  }
});
