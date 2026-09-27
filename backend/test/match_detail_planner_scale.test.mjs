import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const migration = new URL('../../supabase/migrations/20260927152657_bound_match_detail_planner.sql', import.meta.url);
const benchmark = new URL('../bench/match_detail_planner_scale.mjs', import.meta.url);

test('#131 planner profiles the indexed time window once before ranking candidates', async () => {
  const sql = await readFile(migration, 'utf8');
  assert.match(sql, /window_matches as materialized/i);
  assert.match(sql, /profiled as materialized/i);
  assert.match(sql, /calendar_matches cm[\s\S]*cm\.start_time between now\(\)-history and now\(\)\+upcoming/i);
  assert.match(sql, /left join public\.live_match_updates l on l\.match_id=cm\.match_id/i);
  const candidate = sql.slice(sql.indexOf('with window_matches'), sql.indexOf('loop\n'));
  assert.doesNotMatch(candidate, /match_detail_status\(/i, 'candidate ranking must not call a SQL function per match');
});

test('#131 mixed 5k planner workload completes under the 8s RPC statement timeout', async () => {
  const { stdout } = await execFileAsync(process.execPath, [fileURLToPath(benchmark), '5000', '3'], {
    cwd: new URL('../..', import.meta.url),
    maxBuffer: 4 * 1024 * 1024,
    windowsHide: true,
  });
  const result = JSON.parse(stdout.trim().split(/\r?\n/).at(-1));
  assert.equal(result.statementTimeoutMs, 8000);
  assert.equal(result.counts.matches, 5000);
  assert.ok(result.counts.requests > 300);
  assert.ok(result.counts.coverage > 4000);
  assert.ok(result.counts.recovery > 200);
  assert.ok(result.counts.interests > 100);
  for (const route of ['planner', 'enqueue', 'rpc']) {
    assert.ok(result.measurements[route].p95ApproxMs < result.statementTimeoutMs,
      `${route} p95 ${result.measurements[route].p95ApproxMs}ms must stay below 8s`);
  }
});
