import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { openDatabase } from '../storage/database.mjs';

// Legacy API-Football schedulers stay disabled in the migration history
// (Provider Hub hardening before #102 Phase 1B). Synthetic cron schema only.

const NAME = '20260925071000_disable_legacy_api_football_crons.sql';
const migrationsDir = new URL('../../supabase/migrations/', import.meta.url);
const sql = await readFile(new URL(NAME, migrationsDir), 'utf8');
const migrations = (await readdir(migrationsDir)).filter((f) => f.endsWith('.sql')).sort();

const legacyNames = ['futbeat-live-sync-free-tier', 'futbeat-fixtures-today', 'futbeat-fixtures-tomorrow', 'futbeat-fixtures-yesterday'];
const goalNames = ['futbeat-goal-live-cron', 'futbeat-goal-detail-cron', 'futbeat-goal-results-cron', 'futbeat-prune-stale-live'];
const post = (fn) => `select net.http_post(url:='https://example.invalid/functions/v1/${fn}',body:='{}'::jsonb)`;

async function withDb(fn) {
  const db = await openDatabase();
  try { await fn(db); } finally { await db.close(); }
}

// Minimal stand-in for pg_cron: cron.job + cron.unschedule(bigint).
async function fakeCron(db) {
  await db.exec(`create schema if not exists cron;
    create table if not exists cron.job(jobid bigserial primary key,jobname text,schedule text,command text,active boolean default true);
    create or replace function cron.unschedule(job_id bigint) returns boolean language plpgsql as $f$
    begin delete from cron.job where jobid=job_id; return found; end $f$;`);
}
const addJob = (db, jobname, command) => db.query("insert into cron.job(jobname,schedule,command) values($1,'* * * * *',$2)", [jobname, command]);
const jobs = (db) => db.query('select jobname from cron.job order by jobname').then((r) => r.rows.map((j) => j.jobname));

test('A-D. migration after 20260925070000, names + command targets covered, no GOAL job named', () => {
  assert.ok(migrations.indexOf(NAME) > migrations.indexOf('20260925070000_provider_hub_phase1a.sql'));
  for (const name of [...legacyNames, 'futbeat-fixtures-three-day-window']) assert.ok(sql.includes(`'${name}'`), name);
  assert.match(sql, /\/functions\/v1\/futbeat-\(live\|fixtures\)-sync/);
  // GOAL jobs may only appear in comments, never in the executable SQL.
  const body = sql.split('\n').filter((line) => !line.trimStart().startsWith('--')).join('\n');
  for (const name of goalNames) assert.ok(!body.includes(name), `${name} not targeted`);
  assert.doesNotMatch(body, /jobid\s*=\s*\d/, 'no hardcoded jobid');
});

test('E/F. portable without a cron schema; applying twice never fails', () => withDb(async (db) => {
  assert.equal((await db.query("select to_regnamespace('cron') is null v")).rows[0].v, true);
  await db.exec(sql);
  await db.exec(sql);
}));

test('G/H. synthetic legacy jobs are unscheduled (by name or target); GOAL jobs remain; idempotent', () => withDb(async (db) => {
  await fakeCron(db);
  for (const name of legacyNames) await addJob(db, name, post(name.startsWith('futbeat-live') ? 'futbeat-live-sync' : 'futbeat-fixtures-sync'));
  await addJob(db, 'futbeat-fixtures-three-day-window', post('futbeat-fixtures-sync'));
  // Unknown names, recognized only by their command target.
  await addJob(db, 'renamed-legacy-live', post('futbeat-live-sync'));
  await addJob(db, 'renamed-legacy-fixtures', `${post('futbeat-fixtures-sync')}; -- window`);
  // GOAL and other jobs that must survive.
  await addJob(db, 'futbeat-goal-live-cron', post('futbeat-goal-live-sync'));
  await addJob(db, 'futbeat-goal-detail-cron', post('futbeat-goal-live-sync'));
  await addJob(db, 'futbeat-goal-results-cron', post('futbeat-goal-live-sync'));
  await addJob(db, 'futbeat-prune-stale-live', 'select public.futbeat_prune_stale_live_updates()');
  await addJob(db, 'lookalike-function', post('futbeat-live-sync-v2'));
  await db.exec(sql);
  assert.deepEqual(await jobs(db), ['futbeat-goal-detail-cron', 'futbeat-goal-live-cron', 'futbeat-goal-results-cron',
    'futbeat-prune-stale-live', 'lookalike-function']);
  await db.exec(sql);
  assert.equal((await jobs(db)).length, 5, 'second run: nothing else removed, no error');
}));

test('I. no later migration schedules the legacy Edge Functions again', async () => {
  for (const name of migrations.slice(migrations.indexOf(NAME) + 1)) {
    const text = await readFile(new URL(name, migrationsDir), 'utf8');
    assert.doesNotMatch(text, /functions\/v1\/futbeat-(live|fixtures)-sync|cron\.schedule\(\s*'futbeat-(live-sync|fixtures)/, name);
  }
});

test('self-review: secondaries stay disabled after the migration', () => withDb(async (db) => {
  const rows = (await db.query('select provider,enabled from futbeat_private.provider_hub_config order by provider')).rows;
  assert.deepEqual(rows, [
    { provider: 'api_football', enabled: false },
    { provider: 'goal_api', enabled: true },
    { provider: 'sportmonks', enabled: false },
  ]);
}));
