import { withSupabase } from 'npm:@supabase/server';
import { handleStoredRead } from './handler.ts';

export default {
  fetch: withSupabase({ auth: 'none' }, (request, ctx) =>
    handleStoredRead(
      request,
      (fn, args) => ctx.supabaseAdmin.rpc(fn, args),
      Deno.env.get('FUTBEAT_QA_STORED_READS_ENABLED') === 'true',
    )),
};
