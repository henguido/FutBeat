import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

// Production 2026-10-06: the first calendar ingest after 20261005070000 timed
// out (57014, stage resolve-base) resolving 800 identities in one RPC under
// the API role's 8 s statement timeout (800, then 100). Identities go in
// chunks of 50 through runChunksWithTimeoutRetry (chunked_rpc_retry.test).
test('global ingest resolves identities in chunks of at most 50 per RPC', async () => {
  const src = await readFile(new URL('../../supabase/functions/futbeat-global-ingest/index.ts', import.meta.url), 'utf8');
  const fn = src.slice(src.indexOf('async function resolveIdentityItems('), src.indexOf('// GOAL fixtures -> canonical snapshot'));
  const size = Number(fn.match(/const chunkSize = (\d+);/)[1]);
  assert.ok(size > 0 && size <= 50, `chunk ${size}`);
  assert.match(fn, /runChunksWithTimeoutRetry\(items, chunkSize,/);
  assert.match(fn, /rows\.length !== chunk\.length/, 'every chunk is still checked complete');
});
