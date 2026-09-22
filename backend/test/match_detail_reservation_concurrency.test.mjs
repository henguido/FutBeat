import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { mkdtemp, readFile, readdir } from 'node:fs/promises';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

// Native PostgreSQL is essential here: PGlite serializes one connection and
// cannot demonstrate overlapping transactions. No remote connection is accepted.
// Provision optional tools outside package.json, e.g. in ignored .local-data:
// npm install --prefix .local-data/detail-concurrency-tools --ignore-scripts
//   @embedded-postgres/windows-x64@17.9.0-beta.17 pg@8.16.3
// Alternatively set FUTBEAT_TEST_PG_BIN and FUTBEAT_TEST_PG_MODULE to local paths.
const toolsRoot = resolve('.local-data/detail-concurrency-tools/node_modules');
const bin = process.env.FUTBEAT_TEST_PG_BIN
  ?? join(toolsRoot, '@embedded-postgres/windows-x64/native/bin');
const pgModule = process.env.FUTBEAT_TEST_PG_MODULE ?? join(toolsRoot, 'pg/lib/index.js');
const suffix = process.platform === 'win32' ? '.exe' : '';
const enabled = existsSync(join(bin, `initdb${suffix}`)) && existsSync(pgModule);
const run = promisify(execFile);
const startCluster = (command, args) => new Promise((done, reject) => {
  // pg_ctl may leave inherited pipe handles in its Windows server children.
  const child = spawn(command, args, { windowsHide: true, stdio: 'ignore' });
  child.on('error', reject);
  child.on('exit', (code) => code === 0 ? done() : reject(new Error(`pg_ctl exit ${code}`)));
});
const reserveSQL = "select public.futbeat_reserve_match_detail_call('concurrency-test') v";

test('native PostgreSQL: overlapping detail reservations are atomic', {
  skip: enabled ? false : 'Native local PostgreSQL/pg not provisioned (never simulated with PGlite)',
  timeout: 120000,
}, async (t) => {
  const { Client } = (await import(pathToFileURL(pgModule).href)).default;
  const directory = await mkdtemp(join(tmpdir(), 'futbeat-detail-concurrency-'));
  const data = join(directory, 'data');
  const socket = createServer();
  await new Promise((done) => socket.listen(0, '127.0.0.1', done));
  const port = socket.address().port;
  await new Promise((done) => socket.close(done));
  const ctl = join(bin, `pg_ctl${suffix}`);
  const clients = [];
  let started = false;
  try {
    await run(join(bin, `initdb${suffix}`), ['-D', data, '-U', 'postgres', '-A', 'trust', '--encoding=UTF8', '--locale=C'], { windowsHide: true });
    await startCluster(ctl, ['-D', data, '-l', join(directory, 'postgres.log'), '-o', `-h 127.0.0.1 -p ${port} -c max_connections=10`, '-w', 'start']);
    started = true;
    for (const name of ['observer', 'reservation_a', 'reservation_b']) {
      const client = new Client({ host: '127.0.0.1', port, user: 'postgres', database: 'postgres', application_name: name });
      await client.connect();
      clients.push(client);
      await client.query("set statement_timeout='15s'");
    }
    const [observer, a, b] = clients;
    await observer.query('create role anon; create role authenticated; create role service_role');
    const migrations = new URL('../../supabase/migrations/', import.meta.url);
    for (const name of (await readdir(migrations)).filter((n) => n.endsWith('.sql')).sort()) {
      await observer.query(await readFile(new URL(name, migrations), 'utf8'));
    }
    await observer.query(`insert into futbeat_private.entities values
      ('fb_concurrent_a','match',jsonb_build_object('id','fb_concurrent_a','status','LIVE','startTime',now()-interval '40 minutes')),
      ('fb_concurrent_b','match',jsonb_build_object('id','fb_concurrent_b','status','LIVE','startTime',now()-interval '40 minutes'));
      insert into futbeat_private.provider_entities values
      ('goal_api','match','concurrent_a','fb_concurrent_a'),('goal_api','match','concurrent_b','fb_concurrent_b')`);

    async function race({ secondMatch = false, rollback = false } = {}) {
      await observer.query('truncate futbeat_private.match_detail_requests, futbeat_private.provider_call_ledger');
      await observer.query(`insert into futbeat_private.match_detail_requests values
        ('fb_concurrent_a',now(),now()+interval '10 minutes',1)`);
      if (secondMatch) await observer.query(`insert into futbeat_private.match_detail_requests values
        ('fb_concurrent_b',now()-interval '1 minute',now()+interval '10 minutes',1)`);
      await a.query('begin');
      await b.query('begin');
      const first = (await a.query(reserveSQL)).rows[0].v;
      assert.equal(first.allowed, true);
      const secondPromise = b.query(reserveSQL).then((r) => r.rows[0].v);
      // Observe a REAL server lock wait before releasing A, not a timer-only
      // claim of concurrency or Promise.all on a single connection.
      let waiting = false;
      for (let i = 0; i < 100; i++) {
        const row = (await observer.query(`select wait_event_type from pg_stat_activity
          where application_name='reservation_b' and state='active'`)).rows[0];
        if (row?.wait_event_type === 'Lock') { waiting = true; break; }
        await delay(20);
      }
      assert.equal(waiting, true, 'B must overlap and wait for A');
      await a.query(rollback ? 'rollback' : 'commit');
      const second = await secondPromise;
      await b.query('commit');
      assert.equal(second.allowed, secondMatch || rollback);
      if (secondMatch) assert.equal(second.matchId, 'fb_concurrent_b');
      const rows = (await observer.query(`select metadata->>'matchId' id,count(*)::int n
        from futbeat_private.provider_call_ledger where status='RESERVED'
        and completed_at is null and reserved_at>now()-interval '10 minutes'
        group by metadata->>'matchId'`)).rows;
      assert.equal(rows.length, secondMatch ? 2 : 1);
      assert.ok(rows.every((r) => r.n === 1));
    }
    await t.test('same match: one commit, one rejection, one active ledger row', () => race());
    await t.test('different matches: both can reserve without duplicating either', () => race({ secondMatch: true }));
    await t.test('rollback releases lock and does not spend quota', () => race({ rollback: true }));
    await t.test('per-match guard remains atomic with distinct quota locks (UTC day boundary)', async () => {
      const original = (await observer.query(`select pg_get_functiondef(
        'futbeat_private.reserve_match_detail_call(text)'::regprocedure) source`)).rows[0].source;
      // Test-only fault injection makes the two sessions use different daily
      // quota keys, as can happen across midnight. Production SQL is restored.
      const isolated = original.replace(
        "hashtext('futbeat-provider-quota:goal_api:'||v_day_start::date::text)",
        "hashtext('test-daily-quota:'||current_setting('application_name'))",
      );
      assert.notEqual(isolated, original);
      try {
        await observer.query(isolated);
        await race();
      } finally { await observer.query(original); }
    });
  } finally {
    for (const client of clients) {
      await client.query('rollback').catch(() => {});
      await client.end();
    }
    if (started) await run(ctl, ['-D', data, '-m', 'immediate', '-w', 'stop'], { windowsHide: true });
    // Keep the isolated temp cluster/log for failure diagnosis; never touch a
    // pre-existing database or run recursive cleanup against a supplied path.
  }
});
