// Smart-socket metadata only. No adb executable, server lifecycle or USB writes.
import net from 'node:net';
import { pathToFileURL } from 'node:url';

const services = new Set(['host:version', 'host:devices-l']);
export async function probeAdbHost({ service, port = 5037, timeoutMs = 2500 }) {
  if (!services.has(service) || !Number.isInteger(port) || port < 1 || port > 65535 ||
      !Number.isInteger(timeoutMs) || timeoutMs < 100 || timeoutMs > 8000) {
    throw new Error('Only bounded loopback ADB metadata queries are allowed');
  }
  return new Promise((resolve) => {
    const started = performance.now();
    let bytes = Buffer.alloc(0), connected = false, finished = false;
    const socket = new net.Socket();
    const finish = (status, reason, payload) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      socket.destroy();
      const elapsedMs = Math.round(performance.now() - started);
      if (status === 'OK' && elapsedMs >= timeoutMs) {
        status = 'UNKNOWN'; reason = 'response_timeout';
      }
      resolve({ service, status, reason, payload, connected,
        ackReceived: bytes.subarray(0, 4).toString('ascii') === 'OKAY',
        receivedBytes: bytes.length, elapsedMs });
    };
    const timer = setTimeout(() => finish('UNKNOWN', 'response_timeout'), timeoutMs);
    socket.on('error', (error) => finish('UNKNOWN', error.code ?? 'socket_error'));
    socket.on('end', () => finish('UNKNOWN', 'incomplete_response'));
    socket.on('data', (part) => {
      bytes = Buffer.concat([bytes, part]);
      if (performance.now() - started >= timeoutMs) return finish('UNKNOWN', 'response_timeout');
      if (bytes.length > 8200) return finish('UNKNOWN', 'oversize_response');
      if (bytes.length < 8) return;
      const ack = bytes.subarray(0, 4).toString('ascii');
      const lengthText = bytes.subarray(4, 8).toString('ascii');
      if (!['OKAY', 'FAIL'].includes(ack) || !/^[0-9a-f]{4}$/i.test(lengthText)) {
        return finish('UNKNOWN', 'invalid_frame');
      }
      const length = parseInt(lengthText, 16);
      if (length > 8192) return finish('UNKNOWN', 'oversize_response');
      if (bytes.length < length + 8) return;
      finish(ack === 'OKAY' ? 'OK' : 'ERROR', ack === 'OKAY' ? 'metadata_received' : 'server_rejected',
        bytes.subarray(8, length + 8).toString('utf8'));
    });
    socket.connect({ host: '127.0.0.1', port }, () => {
      connected = true;
      socket.write(Buffer.byteLength(service).toString(16).padStart(4, '0') + service, 'ascii');
    });
  });
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  const timeoutMs = process.argv[2] === '--timeout-ms' ? Number(process.argv[3]) : 2500;
  for (const service of services) {
    const result = await probeAdbHost({ service, timeoutMs });
    console.log(JSON.stringify(result));
    if (result.status !== 'OK') process.exitCode = 2;
  }
}
