import { createHandler } from './handler.mjs';

// Platform verify_jwt remains enabled. Only public sports snapshots are returned.
// Service credentials stay in Edge Function environment, never in the APK.
Deno.serve(createHandler({
  url: Deno.env.get('SUPABASE_URL')!,
  serviceKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
}));
