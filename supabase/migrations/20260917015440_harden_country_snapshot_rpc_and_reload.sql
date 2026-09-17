revoke all on function futbeat_private.futbeat_resolve_country_entity(text,text,text) from public, anon, authenticated;
revoke all on function futbeat_private.futbeat_store_country_snapshot(uuid,timestamptz,jsonb,jsonb) from public, anon, authenticated;
revoke all on function public.futbeat_resolve_country_entity(text,text,text) from public, anon, authenticated;
revoke all on function public.futbeat_store_country_snapshot(uuid,timestamptz,jsonb,jsonb) from public, anon, authenticated;

grant execute on function futbeat_private.futbeat_resolve_country_entity(text,text,text) to service_role;
grant execute on function futbeat_private.futbeat_store_country_snapshot(uuid,timestamptz,jsonb,jsonb) to service_role;
grant execute on function public.futbeat_resolve_country_entity(text,text,text) to service_role;
grant execute on function public.futbeat_store_country_snapshot(uuid,timestamptz,jsonb,jsonb) to service_role;

notify pgrst, 'reload schema';
