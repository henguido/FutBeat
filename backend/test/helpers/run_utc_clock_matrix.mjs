import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
const times = ['23:58:00', '23:59:30', '00:00:00', '00:03:00', '00:12:00', '01:10:00', '12:00:00'];
const files = ['midday_utc_clock', 'quota_utc_day_boundary', 'utc_clock_quota_matrix',
  'live_quota_lifecycle', 'live_request_units', 'live_scheduler',
  'stuck_terminal_recovery', 'terminal_result_user_demand'];
mkdirSync('artifacts/utc246', { recursive: true });
const results = [];
for (const time of times) {
  const result = spawnSync(process.execPath, ['--import', './backend/test/helpers/utc_simulation_preload.mjs',
    '--test', ...files.map((f) => 'backend/test/' + f + '.test.mjs')],
  { env: { ...process.env, FUTBEAT_TEST_UTC_TIME: time }, encoding: 'utf8', timeout: 600000, maxBuffer: 16 * 1024 * 1024 });
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  writeFileSync('artifacts/utc246/' + time.replaceAll(':', '-') + '.log', output);
  results.push({ time, exit: result.status, error: result.error?.message,
    pass: /[ℹ#] pass (\d+)/.exec(output)?.[1], fail: /[ℹ#] fail (\d+)/.exec(output)?.[1] });
  writeFileSync('artifacts/utc246/matrix.json', JSON.stringify(results, null, 2));
  console.log(results.at(-1));
}
if (results.some((r) => r.exit !== 0)) process.exitCode = 1;
