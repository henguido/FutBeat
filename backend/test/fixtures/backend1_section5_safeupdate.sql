-- Isolated Supabase PG17 assertion. No remote connection; fixture changes rollback.
load 'safeupdate';
begin;
do $probe$
declare rejected boolean:=false;
begin
  begin
    delete from futbeat_private.coverage_interests;
  exception when sqlstate '21000' then rejected:=true;
  end;
  if not rejected then raise exception 'safeupdate hook did not reject the unsafe control delete'; end if;
  perform futbeat_private.refresh_interest_aggregates();
  if not exists(select 1 from futbeat_private.coverage_interests where subject_type='country' and subject_id='CR') then
    raise exception 'Interest refresh lost its shared baseline';
  end if;
end $probe$;
rollback;
