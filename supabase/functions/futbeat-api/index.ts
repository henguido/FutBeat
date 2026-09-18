import { withSupabase } from 'npm:@supabase/server';

const jsonHeaders = {
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'public, max-age=30, stale-while-revalidate=60',
};

const reply = (status: number, data: unknown) =>
  new Response(JSON.stringify(data), { status, headers: jsonHeaders });

const validDate = (value: string | null) =>
  value !== null && /^\d{4}-\d{2}-\d{2}$/.test(value);

export default {
  fetch: withSupabase({ auth: 'none' }, async (request, ctx) => {
    if (request.method !== 'GET') {
      return reply(405, { error: 'Method not allowed' });
    }

    const requestUrl = new URL(request.url);
    const path = requestUrl.pathname;

    if (path.endsWith('/futbeat-api/v1/snapshot')) {
      const { data: snapshot, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_read_snapshot',
      );
      if (
        error ||
        !snapshot ||
        snapshot.schemaVersion !== 1 ||
        snapshot.demo !== false
      ) {
        return reply(503, { error: 'Datos temporalmente no disponibles' });
      }

      return reply(200, snapshot);
    }

    if (path.endsWith('/futbeat-api/v1/calendar')) {
      const date = requestUrl.searchParams.get('date');
      const timezone =
        requestUrl.searchParams.get('timezone') ?? 'America/Costa_Rica';

      if (!validDate(date) || timezone.length < 1 || timezone.length > 80) {
        return reply(400, { error: 'Fecha o zona horaria inválida' });
      }

      const { data: snapshot, error } = await ctx.supabaseAdmin.rpc(
        'futbeat_read_calendar_range',
        {
          p_from_date: date,
          p_to_date: date,
          p_timezone: timezone,
        },
      );

      if (
        error ||
        !snapshot ||
        snapshot.schemaVersion !== 1 ||
        snapshot.demo !== false
      ) {
        return reply(503, { error: 'Datos temporalmente no disponibles' });
      }

      return reply(200, snapshot);
    }

    return reply(404, { error: 'Not found' });
  }),
};
