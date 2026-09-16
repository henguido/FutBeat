export function createHandler({ url, serviceKey, fetcher = fetch }) {
  const headers = { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' };
  const reply = (status, data, extra = {}) => new Response(JSON.stringify(data), { status, headers: { ...headers, ...extra } });
  return async (request) => {
    if (request.method !== 'GET') return reply(405, { error: 'Method not allowed' }, { Allow: 'GET' });
    const path = new URL(request.url).pathname;
    if (path !== '/futbeat-api/v1/snapshot' && path !== '/functions/v1/futbeat-api/v1/snapshot') return reply(404, { error: 'Not found' });
    try {
      const response = await fetcher(`${url}/rest/v1/rpc/futbeat_read_snapshot`, {
        method: 'POST',
        headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, 'Content-Type': 'application/json' },
        body: '{}', signal: AbortSignal.timeout(8000),
      });
      if (!response.ok) return reply(503, { error: 'Datos temporalmente no disponibles' });
      const snapshot = await response.json();
      if (!snapshot || snapshot.schemaVersion !== 1 || snapshot.demo !== false) return reply(503, { error: 'Datos temporalmente no disponibles' });
      return reply(200, snapshot);
    } catch { return reply(503, { error: 'Datos temporalmente no disponibles' }); }
  };
}
