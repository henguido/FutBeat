import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { once } from 'node:events';
import { probeAdbHost } from './adb-host-readonly.mjs';

async function withServer(reply, run) {
  const sockets = new Set();
  const server = net.createServer((socket) => {
    sockets.add(socket); socket.on('close', () => sockets.delete(socket));
    socket.once('data', (request) => reply(socket, request));
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  try { await run(server.address().port); }
  finally { for (const socket of sockets) socket.destroy(); await new Promise((r) => server.close(r)); }
}

test('fragmented reply preserves exact read-only framing', () => withServer((socket, request) => {
  assert.equal(request.toString(), '000chost:version');
  socket.write('OK'); setTimeout(() => socket.end('AY00040029'), 10);
}, async (port) => {
  const result = await probeAdbHost({ port, service: 'host:version' });
  assert.equal(result.status, 'OK'); assert.equal(result.payload, '0029');
}));
test('ACK alone is not a verified response', () => withServer((socket) => socket.write('OKAY'), async (port) => {
  const result = await probeAdbHost({ port, service: 'host:version', timeoutMs: 100 });
  assert.equal(result.status, 'UNKNOWN'); assert.equal(result.ackReceived, true);
  assert.equal(result.reason, 'response_timeout'); assert(result.elapsedMs < 1500);
}));
test('silent listener closes only the owned socket at deadline', () => withServer(() => {}, async (port) => {
  const result = await probeAdbHost({ port, service: 'host:devices-l', timeoutMs: 100 });
  assert.equal(result.status, 'UNKNOWN'); assert.equal(result.connected, true);
  assert.equal(result.ackReceived, false); assert(result.elapsedMs < 1500);
}));
test('late complete metadata is never promoted after deadline', () => withServer((socket) => {
  socket.write('OKAY');
  setTimeout(() => { if (!socket.destroyed) socket.end('00040029'); }, 250).unref();
}, async (port) => {
  const result = await probeAdbHost({ port, service: 'host:version', timeoutMs: 100 });
  assert.equal(result.status, 'UNKNOWN'); assert.equal(result.ackReceived, true);
  assert.equal(result.reason, 'response_timeout');
}));
test('FAIL is not successful metadata', () => withServer((s) => s.end('FAIL000bunsupported'), async (port) => {
  assert.equal((await probeAdbHost({ port, service: 'host:devices-l' })).status, 'ERROR');
}));
test('malformed or oversized replies fail closed', async () => {
  for (const frame of ['OKAYzzzz', 'OKAYffff']) await withServer((s) => s.end(frame), async (port) => {
    assert.equal((await probeAdbHost({ port, service: 'host:version' })).status, 'UNKNOWN');
  });
});
test('kill, shell, transport and unbounded inputs are rejected before connection', async () => {
  for (const service of ['host:kill', 'shell:am force-stop', 'host:transport-any', '']) {
    await assert.rejects(probeAdbHost({ service }));
  }
  for (const timeoutMs of [0, 9000, NaN]) await assert.rejects(probeAdbHost({ service: 'host:version', timeoutMs }));
});
