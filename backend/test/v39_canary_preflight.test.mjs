import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const script = path.join(root, 'scripts', 'canary', 'v39-preflight.ps1');
const shell = process.platform === 'win32' ? 'powershell.exe' : 'pwsh';

function run(args) {
  return spawnSync(shell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, ...args], {
    cwd: root,
    encoding: 'utf8',
  });
}

test('v39 canary preflight refuses the production project ref', () => {
  const result = run(['-StagingProjectRef', 'izlmruqawgagwdcsjhte', '-Date', '2026-09-19']);
  assert.notEqual(result.status, 0);
  assert.match(`${result.stdout}\n${result.stderr}`, /REFUSED:.*production/i);
});

test('v39 canary preflight accepts a concrete non-production target locally', () => {
  const result = run([
    '-StagingProjectRef', 'abcdefghijklmnopqrst', '-Date', '2026-09-19',
    '-Provider', 'goal_api', '-MaxFixtures', '2000',
    '-StatementTimeoutSeconds', '90',
  ]);
  assert.equal(result.status, 0, result.stderr);
  const manifest = JSON.parse(result.stdout);
  assert.equal(manifest.status, 'SAFE_LOCAL_PREFLIGHT_ONLY');
  assert.equal(manifest.productionRefRejected, true);
  assert.equal(manifest.expectedProjectRef, 'abcdefghijklmnopqrst');
  assert.equal(manifest.dateUtc, '2026-09-19');
  assert.equal(manifest.provider, 'goal_api');
  assert.equal(manifest.remoteOperationExecuted, false);
});

test('v39 canary preflight rejects an impossible date and unsafe limits', () => {
  const invalidDate = run(['-StagingProjectRef', 'abcdefghijklmnopqrst', '-Date', '2026-02-31']);
  assert.notEqual(invalidDate.status, 0);
  assert.match(`${invalidDate.stdout}\n${invalidDate.stderr}`, /REFUSED:.*real UTC calendar date/i);

  const invalidLimit = run([
    '-StagingProjectRef', 'abcdefghijklmnopqrst', '-Date', '2026-09-19',
    '-MaxFixtures', '5001',
  ]);
  assert.notEqual(invalidLimit.status, 0);
});
