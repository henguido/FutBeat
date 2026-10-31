import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { handleQaStoredRead } from '../../supabase/functions/_shared/qa_stored_reads.ts';

test('loopback HTTP stored API never falls through to a hydration route', async () => {
  const calls = [];
  const paths = [];
  const allowed = new Set(['futbeat_read_qa_stored_calendar', 'futbeat_read_match_context', 'futbeat_read_match_detail', 'futbeat_read_match_videos']);
  const server = createServer(async (incoming, outgoing) => {
    paths.push(incoming.url);
    const result = await handleQaStoredRead(new Request(`http://127.0.0.1${incoming.url}`, { method: incoming.method }), async (name) => {
      assert(allowed.has(name), `Forbidden write or demand RPC: ${name}`);
      calls.push(name);
      return { data: name === 'futbeat_read_match_videos' ? [] : { schemaVersion: 1, demo: false, matches: [] }, error: null };
    }, true);
    outgoing.writeHead(result.status, Object.fromEntries(result.headers));
    outgoing.end(await result.text());
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const origin = `http://127.0.0.1:${server.address().port}`;
  try {
    for (const path of ['calendar?date=2026-10-29', 'match-context?id=fb_match_test', 'match-detail?id=fb_match_test']) {
      const response = await fetch(`${origin}/futbeat-api/v1/qa-stored/${path}`);
      assert.equal(response.status, 200);
      assert.equal(response.headers.get('x-futbeat-qa-stored'), 'v1');
      await response.json();
    }
    const reads = calls.length;
    for (const [path, method, status] of [
      ['/futbeat-api/v1/qa-stored/calendar', 'POST', 405],
      ['/futbeat-api/v1/calendar?date=2026-10-29', 'GET', 403],
      ['/futbeat-api/v1/qa-stored/entity?id=fb_team_test', 'GET', 403],
      ['/futbeat-api/v1/qa-stored/calendar?date=2026-02-30', 'GET', 400],
    ]) {
      const response = await fetch(`${origin}${path}`, { method });
      assert.equal(response.status, status);
      await response.text();
    }
    assert.equal(calls.length, reads);
    assert.deepEqual(calls, [...allowed]);
    assert.equal(paths.length, 7);
  } finally {
    server.closeAllConnections();
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});
