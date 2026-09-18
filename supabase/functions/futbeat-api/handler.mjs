const validDate = (value) =>
  typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value);

export function createHandler({ url, serviceKey, fetcher = fetch }) {
  const headers = {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  };
  const reply = (status, data, extra = {}) =>
    new Response(JSON.stringify(data), {
      status,
      headers: { ...headers, ...extra },
    });

  return async (request) => {
    if (request.method !== 'GET') {
      return reply(405, { error: 'Method not allowed' }, { Allow: 'GET' });
    }

    const requestUrl = new URL(request.url);
    const path = requestUrl.pathname;
    const snapshotPath =
      path === '/futbeat-api/v1/snapshot' ||
      path === '/functions/v1/futbeat-api/v1/snapshot';
    const calendarPath =
      path === '/futbeat-api/v1/calendar' ||
      path === '/functions/v1/futbeat-api/v1/calendar';

    if (!snapshotPath && !calendarPath) {
      return reply(404, { error: 'Not found' });
    }

    let rpcName = 'futbeat_read_snapshot';
    let body = {};

    if (calendarPath) {
      const date = requestUrl.searchParams.get('date');
      const timezone =
        requestUrl.searchParams.get('timezone') ?? 'America/Costa_Rica';
      if (!validDate(date) || timezone.length < 1 || timezone.length > 80) {
        return reply(400, { error: 'Fecha o zona horaria inválida' });
      }
      rpcName = 'futbeat_read_calendar_range';
      body = {
        p_from_date: date,
        p_to_date: date,
        p_timezone: timezone,
      };
    }

    try {
      const response = await fetcher(`${url}/rest/v1/rpc/${rpcName}`, {
        method: 'POST',
        headers: {
          apikey: serviceKey,
          Authorization: `Bearer ${serviceKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(8000),
      });
      if (!response.ok) {
        return reply(503, { error: 'Datos temporalmente no disponibles' });
      }
      const snapshot = await response.json();
      if (
        !snapshot ||
        snapshot.schemaVersion !== 1 ||
        snapshot.demo !== false
      ) {
        return reply(503, { error: 'Datos temporalmente no disponibles' });
      }
      return reply(200, snapshot);
    } catch {
      return reply(503, { error: 'Datos temporalmente no disponibles' });
    }
  };
}
