import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { validateSnapshot } from '../providers/core/snapshot.mjs';
import { SnapshotStore, nextPollSeconds } from '../automation/sync.mjs';
import { createApi } from '../api/server.mjs';
const fixture = JSON.parse(await readFile(new URL('../../packages/contracts/demo.snapshot.json', import.meta.url), 'utf8'));
test('mobile asset matches the canonical API fixture', async () => {
  const mobile = JSON.parse(await readFile(new URL('../../apps/mobile/assets/demo.snapshot.json', import.meta.url), 'utf8'));
  assert.deepEqual(mobile, fixture);
});
test('FB-US-004/071: canonical graph and provenance validate', () => assert.equal(validateSnapshot(fixture), fixture));
test('reject dangling entity, duplicate event and negative score', () => {
  for (const mutate of [d => d.matches[0].homeTeamId = 'missing', d => d.matches[0].events.push(d.matches[0].events[0]), d => d.matches[0].score.home = -1]) {
    const data = structuredClone(fixture); mutate(data); assert.throws(() => validateSnapshot(data));
  }
});
test('FB-US-013: live polling is bounded and verified matches stop', () => {
  const match = fixture.matches[0];
  assert.equal(nextPollSeconds(match), 30);
  assert.equal(nextPollSeconds({ ...match, status: 'VERIFIED' }), null);
  assert.equal(nextPollSeconds({ ...match, status: 'FINISHED_PENDING_VERIFICATION' }), 120);
});
test('failed ingestion preserves last valid batch; repeated job is idempotent', async () => {
  const store = new SnapshotStore(fixture);
  await assert.rejects(store.sync({ getSnapshot: async () => ({}) }, 'bad'));
  assert.deepEqual(store.read(), fixture);
  const provider = { getSnapshot: async () => fixture };
  assert.equal(await store.sync(provider, 'one'), true);
  assert.equal(await store.sync(provider, 'one'), false);
});
test('API serves canonical snapshot and rejects writes/unknown routes', async t => {
  const server = createApi(new SnapshotStore(fixture));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  assert.deepEqual(await (await fetch(`${base}/v1/snapshot`)).json(), fixture);
  assert.equal((await fetch(`${base}/missing`)).status, 404);
  assert.equal((await fetch(`${base}/v1/snapshot`, { method: 'POST' })).status, 405);
});
