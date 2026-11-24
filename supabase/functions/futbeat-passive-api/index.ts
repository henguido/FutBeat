import { withSupabase } from 'npm:@supabase/server@1.8.0';
import { handleStoredRead } from './handler.ts';

// Every RPC goes out as GET: PostgREST then runs it in a READ ONLY transaction.
// The switch is the policy row (created disabled, read every 30 s). The secret is only an
// emergency stop: FUTBEAT_PASSIVE_API_ENABLED=false turns it off without the database.
export default {
  fetch: withSupabase({ auth: 'none' }, (request, ctx) =>
    handleStoredRead(
      request,
      (fn, args) => ctx.supabaseAdmin.rpc(fn, args, { get: true }),
      Deno.env.get('FUTBEAT_PASSIVE_API_ENABLED') !== 'false',
    )),
};
