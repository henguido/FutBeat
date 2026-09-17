-- imports.job_id predates the country bootstrap and is intentionally text.
-- The country RPC accepts UUIDs, so compare and persist the UUID as text.
create or replace function futbeat_private.futbeat_store_country_snapshot(
 p_job_id uuid,
 p_received_at timestamptz,
 p_raw jsonb,
 p_snapshot jsonb
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare item jsonb; merged jsonb;
begin
 if p_snapshot->>'demo'<>'false' or p_snapshot->>'schemaVersion'<>'1' or
  jsonb_typeof(p_snapshot->'competitions')<>'array' or jsonb_typeof(p_snapshot->'teams')<>'array' or
  jsonb_typeof(p_snapshot->'matches')<>'array' then raise exception 'Invalid country snapshot'; end if;
 if exists(select 1 from jsonb_array_elements(p_snapshot->'competitions') c where c->>'country'<>'Costa Rica')
  then raise exception 'Unexpected country'; end if;
 if exists(select 1 from futbeat_private.imports where job_id=p_job_id::text) then return '{"duplicate":true}'::jsonb; end if;
 if exists(select 1 from futbeat_private.imports where received_at>=p_received_at) then raise exception 'Out-of-order import'; end if;
 for item in select value from jsonb_array_elements(p_snapshot->'competitions') loop
  update futbeat_private.entities set payload=item where id=item->>'id' and kind='competition';
 end loop;
 for item in select value from jsonb_array_elements(p_snapshot->'teams') loop
  update futbeat_private.entities set payload=item where id=item->>'id' and kind='team';
 end loop;
 for item in select value from jsonb_array_elements(p_snapshot->'matches') loop
  update futbeat_private.entities set payload=item where id=item->>'id' and kind='match';
 end loop;
 merged:=p_snapshot||jsonb_build_object(
  'competitions',(select coalesce(jsonb_agg(payload order by id),'[]') from futbeat_private.entities where kind='competition'),
  'teams',(select coalesce(jsonb_agg(payload order by id),'[]') from futbeat_private.entities where kind='team'),
  'matches',(select coalesce(jsonb_agg(payload order by id),'[]') from futbeat_private.entities where kind='match'));
 insert into futbeat_private.imports(job_id,received_at,raw_payload,snapshot) values(p_job_id::text,p_received_at,p_raw,merged);
 update futbeat_private.coverage_interests set last_updated_at=p_received_at,next_refresh_at=p_received_at+interval '12 hours'
  where subject_type='country' and subject_id='CR';
 return jsonb_build_object('duplicate',false,'teams',jsonb_array_length(merged->'teams'),
  'matches',jsonb_array_length(merged->'matches'),'standings',jsonb_array_length(merged->'standings'));
end $$;

revoke all on function futbeat_private.futbeat_store_country_snapshot(uuid,timestamptz,jsonb,jsonb)
 from public, anon, authenticated;
grant execute on function futbeat_private.futbeat_store_country_snapshot(uuid,timestamptz,jsonb,jsonb)
 to service_role;

notify pgrst, 'reload schema';
