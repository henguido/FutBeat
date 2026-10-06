import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { ChunkFailedError, isStatementTimeout, runChunksWithTimeoutRetry } from '../../supabase/functions/_shared/chunked_rpc.ts';
import { openDatabase } from '../storage/database.mjs';

// Resilient identity resolution for futbeat-global-ingest: chunks of 50, one
// retry of the SAME chunk only for Postgres 57014, never a global retry.

const timeoutError = () => new Error('RPC futbeat_resolve_global_entities failed: 500 {"code":"57014","details":null,"hint":null,"message":"canceling statement due to statement timeout"}');
const noSleep = async () => {};
const items = (n) => Array.from({ length: n }, (_, i) => i);

test('all chunks succeed: no retry, order preserved, every item once', async () => {
  const seen = [];
  const out = await runChunksWithTimeoutRetry(items(120), 50, async (chunk, i) => { seen.push([i, chunk[0], chunk.length]); return chunk.length; }, { sleep: noSleep });
  assert.deepEqual(seen, [[0, 0, 50], [1, 50, 50], [2, 100, 20]]);
  assert.deepEqual(out, [50, 50, 20]);
});

test('57014 -> one retry of the same chunk -> success; later chunks wait for it', async () => {
  const calls = [];
  let failed = false;
  const sleeps = [];
  const out = await runChunksWithTimeoutRetry(items(100), 50, async (chunk, i) => {
    calls.push(i);
    if (i === 0 && !failed) { failed = true; throw timeoutError(); }
    return chunk.length;
  }, { sleep: async (ms) => { sleeps.push(ms); }, retryDelayMs: 1500 });
  assert.deepEqual(calls, [0, 0, 1], 'chunk 0 twice, then chunk 1');
  assert.deepEqual(sleeps, [1500], 'one short, bounded delay');
  assert.deepEqual(out, [50, 50]);
});

test('57014 twice -> abort with the exact chunk; nothing after it runs', async () => {
  const calls = [];
  await assert.rejects(runChunksWithTimeoutRetry(items(150), 50, async (chunk, i) => {
    calls.push(i);
    if (i === 1) throw timeoutError();
    return chunk.length;
  }, { sleep: noSleep }), (error) => {
    assert.ok(error instanceof ChunkFailedError);
    assert.deepEqual([error.chunkIndex, error.offset, error.size, error.attempts], [1, 50, 50, 2]);
    assert.match(error.message, /57014/);
    return true;
  });
  assert.deepEqual(calls, [0, 1, 1], 'no third attempt, chunk 2 never runs');
});

test('any other error aborts at once (no retry)', async () => {
  const calls = [];
  for (const error of [new Error('RPC x failed: 500 {"code":"23505","message":"duplicate key"}'), new Error('Incomplete batch resolver response: 3/50'), new Error('RPC x failed: 503 upstream')]) {
    calls.length = 0;
    await assert.rejects(runChunksWithTimeoutRetry(items(100), 50, async (chunk, i) => { calls.push(i); throw error; }, { sleep: noSleep }),
      (e) => e instanceof ChunkFailedError && e.attempts === 1);
    assert.deepEqual(calls, [0]);
  }
});

test('57014 detection is exact (code field, not any number in the text)', () => {
  assert.equal(isStatementTimeout(timeoutError()), true);
  assert.equal(isStatementTimeout(new Error('took 57014 ms')), false);
  assert.equal(isStatementTimeout(new Error('{"code":"57P01"}')), false);
  assert.equal(isStatementTimeout(null), false);
});

test('the delay is bounded (<= 5 s) and the chunk size validated', async () => {
  const sleeps = [];
  let first = true;
  await runChunksWithTimeoutRetry(items(10), 50, async () => { if (first) { first = false; throw timeoutError(); } return 1; },
    { sleep: async (ms) => { sleeps.push(ms); }, retryDelayMs: 60000 });
  assert.deepEqual(sleeps, [5000]);
  await assert.rejects(runChunksWithTimeoutRetry(items(10), 0, async () => 1), /Invalid chunk size/);
});

test('the ingest uses chunks of 50 with this runner and never re-fetches from GOAL inside it', async () => {
  const src = await readFile(new URL('../../supabase/functions/futbeat-global-ingest/index.ts', import.meta.url), 'utf8');
  const fn = src.slice(src.indexOf('async function resolveIdentityItems('), src.indexOf('// GOAL fixtures -> canonical snapshot'));
  assert.match(fn, /const chunkSize = 50;/);
  assert.match(fn, /runChunksWithTimeoutRetry\(items, chunkSize,/);
  assert.match(fn, /futbeat_resolve_global_entities/);
  assert.doesNotMatch(fn, /goal-api\.com|fetchGoal|GOAL_API_KEY/);
  assert.match(fn, /rows\.length !== chunk\.length/);
});

test('re-resolving a chunk after a rolled-back attempt gives the same canonical ids and no duplicates', async () => {
  const db = await openDatabase();
  try {
    const chunk = [
      { kind: 'competition', external: 'retry-comp-1', name: 'Retry League', country: 'Testland' },
      ...Array.from({ length: 5 }, (_, i) => ({ kind: 'team', external: `retry-team-${i}`, name: `Retry Team ${i}` })),
    ];
    const resolve = () => db.query('select * from public.futbeat_resolve_global_entities($1,$2)', ['goal_api', JSON.stringify(chunk)]).then((r) => r.rows);
    // An attempt that times out is rolled back: simulate it.
    await db.exec('begin');
    await resolve();
    await db.exec('rollback');
    assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_entities where external_id like 'retry-%'")).rows[0].n, 0, 'clean rollback');
    const first = await resolve();
    const again = await resolve();
    assert.deepEqual(again, first, 'idempotent');
    assert.equal((await db.query("select count(*)::int n from futbeat_private.provider_entities where external_id like 'retry-%'")).rows[0].n, 6);
    assert.equal((await db.query("select count(*)::int n from futbeat_private.entities where payload->>'name' like 'Retry %'")).rows[0].n, 6, 'no duplicate entities');
  } finally { await db.close(); }
});
