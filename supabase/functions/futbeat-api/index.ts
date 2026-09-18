import { withSupabase } from 'npm:@supabase/server';

const jsonHeaders = {
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'public, max-age=30, stale-while-revalidate=60',
};

const reply = (status: number, data: unknown) =>
  new Response(JSON.stringify(data), { status, headers: jsonHeaders });

export default {
  fetch: withSupabase({ auth: 'none' }, async (request, ctx) => {
    if (request.method !== 'GET') {
      return reply(405, { error: 'Method not allowed' });
    }

    const path = new URL(request.url).pathname;
    if (!path.endsWith('/futbeat-api/v1/snapshot')) {
      return reply(404, { error: 'Not found' });
    }

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
  }),
};
