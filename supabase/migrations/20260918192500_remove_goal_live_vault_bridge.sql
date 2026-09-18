-- Remove the abandoned Vault key bridge. GOAL_API_KEY remains in GitHub
-- Secrets and live snapshots are sent to Supabase through GitHub OIDC.

drop function if exists public.futbeat_store_goal_api_live_key(text);
drop function if exists futbeat_private.store_goal_api_live_key(text);
drop function if exists public.futbeat_read_goal_api_live_key();
drop function if exists futbeat_private.read_goal_api_live_key();

notify pgrst,'reload schema';
