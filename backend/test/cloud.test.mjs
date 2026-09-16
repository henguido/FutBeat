import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler } from '../../supabase/functions/futbeat-api/handler.mjs';

test('cloud BFF only reads sports snapshot and keeps server failures private', async () => {
  let calls = 0;
  const handler = createHandler({ url: 'https://example.supabase.co', serviceKey: 'server-only', fetcher: async (url, options) => {
    calls++;
    assert.equal(url, 'https://example.supabase.co/rest/v1/rpc/futbeat_read_snapshot');
    assert.equal(options.headers.Authorization, 'Bearer server-only');
    return Response.json({ schemaVersion: 1, demo: false, matches: [] });
  } });
  const path = 'https://example.supabase.co/functions/v1/futbeat-api/v1/snapshot';
  assert.equal((await handler(new Request(path, { method: 'POST' }))).status, 405);
  assert.equal((await handler(new Request(path + '/unknown'))).status, 404);
  assert.equal(calls, 0);
  const response = await handler(new Request(path));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  const failed = createHandler({ fetcher: async () => { throw new Error('secret connection details'); } });
  const error = await failed(new Request(path));
  assert.equal(error.status, 503);
  assert.doesNotMatch(await error.text(), /secret/);
});
