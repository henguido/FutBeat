alter function public.futbeat_resolve_country_entity(text,text,text) set schema futbeat_private;
alter function futbeat_private.futbeat_resolve_country_entity(text,text,text) security definer;
alter function public.futbeat_store_country_snapshot(uuid,timestamptz,jsonb,jsonb) set schema futbeat_private;
alter function futbeat_private.futbeat_store_country_snapshot(uuid,timestamptz,jsonb,jsonb) security definer;

create function public.futbeat_resolve_country_entity(p_provider text,p_kind text,p_external text) returns text
language sql security invoker set search_path='' as $$
 select futbeat_private.futbeat_resolve_country_entity(p_provider,p_kind,p_external)
$$;
create function public.futbeat_store_country_snapshot(p_job_id uuid,p_received_at timestamptz,p_raw jsonb,p_snapshot jsonb)
returns jsonb language sql security invoker set search_path='' as $$
 select futbeat_private.futbeat_store_country_snapshot(p_job_id,p_received_at,p_raw,p_snapshot)
$$;
revoke all on function futbeat_private.futbeat_resolve_country_entity(text,text,text),
 futbeat_private.futbeat_store_country_snapshot(uuid,timestamptz,jsonb,jsonb),
 public.futbeat_resolve_country_entity(text,text,text),
 public.futbeat_store_country_snapshot(uuid,timestamptz,jsonb,jsonb) from public;
do $$ begin
 if exists(select 1 from pg_roles where rolname='service_role') then
  grant execute on function futbeat_private.futbeat_resolve_country_entity(text,text,text),
   futbeat_private.futbeat_store_country_snapshot(uuid,timestamptz,jsonb,jsonb),
   public.futbeat_resolve_country_entity(text,text,text),
   public.futbeat_store_country_snapshot(uuid,timestamptz,jsonb,jsonb) to service_role;
 end if;
end $$;
