-- Match summaries (contract futbeat.match-summary v1): one shared cached
-- summary per match, regenerated only on a significant change.
--
-- The summary itself is built by the deterministic generator in
-- supabase/functions/_shared/match_summary.ts (facts only: no scorer unless
-- the side's rich goal events add up to its score, assists only in a
-- VERIFIED final, no statistics). This migration adds:
--   * match_summaries: the shared cache (all users read the same row);
--   * futbeat_read_match_summary_input: the compact, read-only input
--     (read model, raw period-score fields, names) plus the cached row;
--   * futbeat_store_match_summary: writes only when the significant
--     fingerprint or the generator version changes, and never lets an older
--     generator overwrite a newer one (two deployed versions cannot flap).
-- Read-only except the cache row. No provider call, quota, cron or push.

create table if not exists futbeat_private.match_summaries (
  match_id text primary key references futbeat_private.entities(id) on delete cascade,
  contract_version smallint not null check(contract_version=1),
  generator_version text not null check(generator_version ~ '^\d+\.\d+\.\d+$'),
  significant_hash text not null check(significant_hash ~ '^[0-9a-f]{16}$'),
  phase text not null check(phase in ('PRE_MATCH','LIVE','FINAL','FINAL_PROVISIONAL','CALLED_OFF','UNKNOWN')),
  summary jsonb not null check(octet_length(summary::text)<=16384),
  generated_at timestamptz not null default now(),
  regenerations integer not null default 0
);
alter table futbeat_private.match_summaries enable row level security;
revoke all on futbeat_private.match_summaries from public,anon,authenticated;

create or replace function futbeat_private.semver_parts(p_version text)
returns integer[] language sql immutable set search_path='' as $$
  select string_to_array(p_version,'.')::integer[]
$$;

create or replace function futbeat_private.futbeat_read_match_summary_input(p_match_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  v_id text:=p_match_id;
  m jsonb; raw jsonb; detail jsonb; cached futbeat_private.match_summaries;
begin
  if nullif(p_match_id,'') is null or length(p_match_id)>130 then
    raise exception 'Invalid match summary request';
  end if;
  select payload into raw from futbeat_private.entities where id=v_id and kind='match';
  if raw is null then return null; end if;
  m:=futbeat_private.match_read_model(raw);
  select c.payload into detail from futbeat_private.match_detail_cache c where c.match_id=v_id;
  select * into cached from futbeat_private.match_summaries where match_id=v_id;
  return jsonb_build_object(
    'match',jsonb_build_object(
      'id',v_id,'status',m->>'status','startTime',m->>'startTime',
      'competitionId',m->>'competitionId','homeTeamId',m->>'homeTeamId','awayTeamId',m->>'awayTeamId',
      'score',m->'score',
      'events',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
          'id',e->>'id','type',e->>'type','minute',e->'minute','extraMinute',e->'extraMinute',
          'teamId',e->>'teamId','playerId',e->>'playerId','playerName',e->>'playerName',
          'assistPlayerId',e->>'assistPlayerId','ownGoal',e->'ownGoal','detail',e->>'detail',
          'synthetic',e->'synthetic','retracted',(e->>'retractedAt') is not null or (e->>'retracted')='true')))
        from jsonb_array_elements(coalesce(m->'events','[]'::jsonb)) e),'[]'::jsonb)),
    -- Only the raw score fields the period-score normalizer reads.
    'scoreFields',coalesce((select jsonb_object_agg(key,value) from jsonb_each(coalesce(detail,'{}'::jsonb))
        where key='matchStatus' or key ~ '^(home|away)Team(Score|FtScore|ExtraScore|HalftimeScore|PenaltyScore)$'),
      '{}'::jsonb),
    'teams',coalesce((select jsonb_object_agg(e.id,jsonb_build_object('name',e.payload->>'name'))
        from futbeat_private.entities e
        where e.kind='team' and e.id in (m->>'homeTeamId',m->>'awayTeamId')),'{}'::jsonb),
    'players',coalesce((select jsonb_object_agg(e.id,jsonb_build_object('name',e.payload->>'name'))
        from futbeat_private.entities e
        where e.kind='player' and e.id in (
          select x->>'playerId' from jsonb_array_elements(coalesce(m->'events','[]'::jsonb)) x
          union select x->>'assistPlayerId' from jsonb_array_elements(coalesce(m->'events','[]'::jsonb)) x)),
      '{}'::jsonb),
    'competition',(select jsonb_build_object('name',e.payload->>'name') from futbeat_private.entities e
        where e.kind='competition' and e.id=m->>'competitionId'),
    'cached',case when cached.match_id is null then null else jsonb_build_object(
      'generatorVersion',cached.generator_version,'significant',cached.significant_hash,
      'generatedAt',cached.generated_at,'summary',cached.summary) end);
end $$;

create or replace function futbeat_private.futbeat_store_match_summary(p_match_id text,p_summary jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_version text:=p_summary->>'generatorVersion';
  v_sig text:=p_summary#>>'{fingerprint,significant}';
  v_phase text:=p_summary->>'phase';
  cur futbeat_private.match_summaries;
begin
  if p_summary->>'contract' is distinct from 'futbeat.match-summary'
     or (p_summary->>'contractVersion') is distinct from '1'
     or p_summary->>'matchId' is distinct from p_match_id
     or coalesce(v_version,'') !~ '^\d+\.\d+\.\d+$'
     or coalesce(v_sig,'') !~ '^[0-9a-f]{16}$'
     or octet_length(p_summary::text)>16384
     or not exists(select 1 from futbeat_private.entities where id=p_match_id and kind='match') then
    raise exception 'Invalid match summary';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(hashtextextended('match-summary:'||p_match_id,0));
  select * into cur from futbeat_private.match_summaries where match_id=p_match_id;
  if found then
    if futbeat_private.semver_parts(cur.generator_version)>futbeat_private.semver_parts(v_version) then
      return jsonb_build_object('status','older_generator','kept',cur.generator_version);
    end if;
    if cur.generator_version=v_version and cur.significant_hash=v_sig then
      return jsonb_build_object('status','unchanged');
    end if;
    update futbeat_private.match_summaries set contract_version=1,generator_version=v_version,
      significant_hash=v_sig,phase=v_phase,summary=p_summary,generated_at=now(),
      regenerations=regenerations+1
    where match_id=p_match_id;
    return jsonb_build_object('status','regenerated');
  end if;
  insert into futbeat_private.match_summaries(match_id,contract_version,generator_version,significant_hash,phase,summary)
  values(p_match_id,1,v_version,v_sig,v_phase,p_summary);
  return jsonb_build_object('status','stored');
end $$;

create or replace function public.futbeat_read_match_summary_input(p_match_id text)
returns jsonb language sql stable security definer set search_path='' as $$
  select futbeat_private.futbeat_read_match_summary_input(p_match_id)
$$;
create or replace function public.futbeat_store_match_summary(p_match_id text,p_summary jsonb)
returns jsonb language sql security definer set search_path='' as $$
  select futbeat_private.futbeat_store_match_summary(p_match_id,p_summary)
$$;

revoke all on function futbeat_private.semver_parts(text),
  futbeat_private.futbeat_read_match_summary_input(text),
  futbeat_private.futbeat_store_match_summary(text,jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.futbeat_read_match_summary_input(text),
  public.futbeat_store_match_summary(text,jsonb)
  from public,anon,authenticated;
grant execute on function public.futbeat_read_match_summary_input(text),
  public.futbeat_store_match_summary(text,jsonb)
  to service_role;

notify pgrst,'reload schema';
