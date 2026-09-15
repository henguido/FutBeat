import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { SnapshotStore } from '../automation/sync.mjs';

export function createApi(store) {
  return createServer((request, response) => {
    response.setHeader('Content-Type', 'application/json; charset=utf-8');
    response.setHeader('Cache-Control', 'no-store');
    if (request.method !== 'GET') {
      response.writeHead(405, { Allow: 'GET' });
      return response.end(JSON.stringify({ error: 'Method not allowed' }));
    }
    const path = new URL(request.url, 'http://localhost').pathname;
    if (path === '/health') return response.end(JSON.stringify({ status: 'ok', mode: 'demo' }));
    if (path === '/v1/snapshot') return response.end(JSON.stringify(store.read()));
    response.writeHead(404);
    response.end(JSON.stringify({ error: 'Not found' }));
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const fixture = JSON.parse(await readFile(new URL('../../packages/contracts/demo.snapshot.json', import.meta.url), 'utf8'));
  const server = createApi(new SnapshotStore(fixture));
  server.listen(Number(process.env.PORT || 8787), '127.0.0.1', () => console.log('FutBeat demo API: http://127.0.0.1:8787/v1/snapshot'));
}
