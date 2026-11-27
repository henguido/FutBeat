-- APPLIED IN PRODUCTION 2026-11-27 01:32Z via ops ledger op 'fb06-subgroups-r4' (FB-PLAY-17). Recorded here for reproducibility;
-- source kit: fb06/kit-r3/fb06_subgroups.sql

-- FB-06: standings sub-groups inferred from the stored table itself (no fixtures, no provider call, nothing named).
-- GOAL sends only `stageName`, so a stage made of several groups arrives as ONE label with repeated positions
-- (CONMEBOL Libertadores "Regular Season": 32 rows, positions 1..4 eight times) and the store marks the table
-- groupsResolved=false: the app shows "Tabla no disponible".
-- Rule (fail-closed; reference implementation fb06/infer_ref.py, identical results on the 48 unresolved prod tables):
--   D = labels holding repeated positions. Proceed only if every label in D holds the same teams, positions exactly
--   1..n each k times (k,n >= 2), k^n <= 4096, no row played more than 2(n-1), and some label in D has played > 0.
--   Candidate group = one team per position of the first label of D such that in EVERY label of D the n teams hold
--   positions 1..n once and form a closed round robin: sum(gf)=sum(ga), sum(won)=sum(lost), sum(drawn) even.
--   Forced-choice propagation: a team in exactly one candidate forces it; candidates overlapping a forced one are
--   dropped; repeat. Accept only when exactly k forced candidates partition the teams (the unique exact cover).
--   Then every row of every label in D gets `subgroup` 1..k (ordered by the stored order of the group's position-1
--   row in the first label) and the table gets groupsResolved=true + subgroupsInferred='round_robin'.
-- The app already renders `subgroup` (standings.dart: "Subgrupo N", never merged). Provisional (live) overlays are not
-- applied to an inferred table (it is a completed/stale phase; a knockout between former group-mates must never be
-- added to it). Rollback: fb06_rollback.sql.

create or replace function futbeat_private.standings_infer_subgroups(p_table jsonb)
returns jsonb language plpgsql immutable set search_path='' as $$
declare
  v_dup text[]; v_first text; v_k int; v_n int; v_teams text[]; v_bad int;
  v_cands jsonb; v_forced jsonb := '[]'::jsonb; v_new jsonb; v_used text[]; v_rows jsonb; v_order jsonb;
begin
  if jsonb_typeof(p_table)<>'object' or jsonb_typeof(p_table->'rows')<>'array'
     or coalesce(p_table->>'groupsResolved','')<>'false' then
    return p_table;
  end if;
  begin
    -- labels with repeated positions, in order of first appearance
    select array_agg(g order by first_ord) into v_dup from (
      select coalesce(r.v->>'group','') g, min(r.o) first_ord
      from jsonb_array_elements(p_table->'rows') with ordinality r(v,o)
      group by 1 having count(*)>count(distinct (r.v->>'position')::int)) x;
    if v_dup is null then return p_table; end if;
    v_first := v_dup[1];
    -- structure of every dup label: same team set, positions 1..n each k times, no repeated team
    select max(cnt_k), max(max_pos) into v_k, v_n from (
      select g, count(*) filter (where pos=1) cnt_k, max(pos) max_pos from (
        select coalesce(v->>'group','') g, (v->>'position')::int pos from jsonb_array_elements(p_table->'rows') v) a
      where g = any(v_dup) group by g) s;
    select array_agg(distinct v->>'teamId' order by v->>'teamId') into v_teams
      from jsonb_array_elements(p_table->'rows') v where coalesce(v->>'group','')=v_first;
    if v_k is null or v_n is null or v_k<2 or v_n<2 or power(v_k,v_n)>4096 then return p_table; end if;
    select count(*) into v_bad from (
      select g from (select coalesce(v->>'group','') g, v->>'teamId' t, (v->>'position')::int pos, (v->>'played')::int pl
                     from jsonb_array_elements(p_table->'rows') v) a
      where g = any(v_dup)
      group by g
      having count(*)<>v_k*v_n or count(distinct t)<>v_k*v_n
          or array_agg(distinct t order by t)<>v_teams
          or max(pl)>2*(v_n-1) or min(pos)<>1 or max(pos)<>v_n
          or exists(select 1 from (select p, count(*) c from unnest(array_agg(pos)) p group by p) q where q.c<>v_k)) z;
    if v_bad>0 then return p_table; end if;
    if not exists(select 1 from jsonb_array_elements(p_table->'rows') v
                  where coalesce(v->>'group','') = any(v_dup) and (v->>'played')::int>0) then
      return p_table;
    end if;
    -- candidates: one team per position of the first label, closed round robin in every dup label
    with recursive r as (
      select coalesce(v->>'group','') g, v->>'teamId' t, (v->>'position')::int pos, (v->>'won')::int w,
             (v->>'drawn')::int d, (v->>'lost')::int l, (v->>'gf')::int gf, (v->>'ga')::int ga
      from jsonb_array_elements(p_table->'rows') v where coalesce(v->>'group','') = any(v_dup)),
    tup(p, ts) as (
      select 1, array[t] from r where g=v_first and pos=1
      union all
      select tup.p+1, tup.ts||r.t from tup join r on r.g=v_first and r.pos=tup.p+1 where tup.p<v_n),
    full_t as (select ts from tup where p=v_n),
    chk as (
      select f.ts from full_t f
      where not exists(
        select 1 from unnest(v_dup) lab
        where (select array_agg(r.pos order by r.pos) from r where r.g=lab and r.t=any(f.ts))
                is distinct from (select array_agg(i) from generate_series(1,v_n) i)
           or (select sum(r.gf)-sum(r.ga) from r where r.g=lab and r.t=any(f.ts))<>0
           or (select sum(r.w)-sum(r.l) from r where r.g=lab and r.t=any(f.ts))<>0
           or (select sum(r.d) from r where r.g=lab and r.t=any(f.ts))%2<>0))
    select coalesce(jsonb_agg(to_jsonb(ts)),'[]'::jsonb) into v_cands from chk;
    -- forced-choice propagation
    loop
      if exists(select 1 from unnest(v_teams) t
                where not exists(select 1 from jsonb_array_elements(v_cands) c where c ? t)) then
        return p_table;
      end if;
      select coalesce(jsonb_agg(distinct c),'[]'::jsonb) into v_new
        from jsonb_array_elements(v_cands) c
       where not (v_forced @> jsonb_build_array(c))
         and exists(select 1 from jsonb_array_elements_text(c) t
                    where (select count(*) from jsonb_array_elements(v_cands) c2 where c2 ? t)=1);
      exit when jsonb_array_length(v_new)=0;
      v_forced := v_forced || v_new;
      select array_agg(t) into v_used from jsonb_array_elements(v_forced) c, jsonb_array_elements_text(c) t;
      select coalesce(jsonb_agg(c),'[]'::jsonb) into v_cands from jsonb_array_elements(v_cands) c
       where v_forced @> jsonb_build_array(c)
          or not exists(select 1 from jsonb_array_elements_text(c) t where t=any(v_used));
    end loop;
    if jsonb_array_length(v_cands)<>v_k or jsonb_array_length(v_forced)<>v_k
       or (select array_agg(distinct t order by t) from jsonb_array_elements(v_cands) c, jsonb_array_elements_text(c) t)
          is distinct from v_teams then
      return p_table;
    end if;
    -- number the groups by the stored order of their position-1 row in the first label
    select jsonb_object_agg(t, sub) into v_order from (
      select t, dense_rank() over (order by lead_ord) sub from (
        select c, (select min(o) from jsonb_array_elements(p_table->'rows') with ordinality r(v,o)
                    where coalesce(r.v->>'group','')=v_first and r.v->>'teamId'=c->>0) lead_ord
        from jsonb_array_elements(v_cands) c) g, jsonb_array_elements_text(g.c) t) s;
    select jsonb_agg(case when coalesce(r.v->>'group','') = any(v_dup)
                          then r.v||jsonb_build_object('subgroup',(v_order->>(r.v->>'teamId'))::int) else r.v end
                     order by r.o)
      into v_rows from jsonb_array_elements(p_table->'rows') with ordinality r(v,o);
    return p_table || jsonb_build_object('rows',v_rows,'groupsResolved',true,'subgroupsInferred','round_robin');
  exception when others then
    return p_table;  -- never block a store
  end;
end $$;

revoke all on function futbeat_private.standings_infer_subgroups(jsonb) from public, anon, authenticated;

create or replace function futbeat_private.standings_subgroups_trigger()
returns trigger language plpgsql set search_path='' as $$
begin
  new.table_payload := futbeat_private.standings_infer_subgroups(new.table_payload);
  return new;
end $$;
revoke all on function futbeat_private.standings_subgroups_trigger() from public, anon, authenticated;

-- BEFORE triggers fire in name order: standings_aa_subgroups runs before standings_current_group_hint.
drop trigger if exists standings_aa_subgroups on futbeat_private.standings_cache;
create trigger standings_aa_subgroups before insert or update of table_payload on futbeat_private.standings_cache
  for each row execute function futbeat_private.standings_subgroups_trigger();
