-- Tighten profile RPC grants: Supabase may grant EXECUTE directly to anon
-- through default privileges even after revoking from PUBLIC.

revoke all on function
  futbeat_private.sync_user_profile(text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean),
  futbeat_private.read_user_profile(),
  public.futbeat_sync_user_profile(text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean),
  public.futbeat_read_user_profile()
from public, anon, authenticated;

grant execute on function
  futbeat_private.sync_user_profile(text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean),
  futbeat_private.read_user_profile(),
  public.futbeat_sync_user_profile(text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean),
  public.futbeat_read_user_profile()
to authenticated;
