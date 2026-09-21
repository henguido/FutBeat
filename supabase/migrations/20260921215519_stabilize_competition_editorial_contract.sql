-- Forward-only correction after PR #76. Its deployed version is 20260921214136;
-- the historical local file is intentionally not edited or renamed here.
-- No lifecycle, event projection, worker, ranking-group or seed changes.

-- Exact aliases from the locally retained catalog. Generic "intl"/"Worldcup"
-- buckets remain unknown: do not guess a geographic region from a league name.
with extra(country_code,aliases) as (values
 ('BA','["bosnia and herzegovina","bosnia and herzegovina and herzegovina"]'::jsonb),
 ('CN','["china pr"]'::jsonb),('TW','["chinese taipei"]'::jsonb),
 ('CZ','["czech republic"]'::jsonb),('HK','["hong kong"]'::jsonb),
 ('KG','["kyrgyz republic"]'::jsonb),('MM','["myanmar"]'::jsonb),
 ('IE','["republic of ireland"]'::jsonb),('EUROPE','["eurocups"]'::jsonb)
)
update futbeat_private.country_catalog c
 set aliases=(select jsonb_agg(value order by value)
   from (select distinct value from jsonb_array_elements(c.aliases||extra.aliases)) a)
 from extra where c.country_code=extra.country_code and not c.aliases @> extra.aliases;

create or replace function futbeat_private.derived_competition_relevance(p_class text,p_audience text)
returns integer language sql immutable security invoker set search_path='' as $$
 select case when p_audience in ('women','youth','reserve','amateur') then 100
   when p_class='domestic_league' then 240
   when p_class='domestic_cup' then 180
   when p_class in ('international_club','international_national') then 260
   else 100 end
$$;

-- Compatibility helper: exact editorial identity only, never nominal tokens.
-- Callers with audience/identity data use the triggers below instead.
create or replace function futbeat_private.competition_relevance_score(p_name text,p_country text)
returns integer language sql stable security invoker set search_path='' as $$
 select coalesce((select s.relevance_score from futbeat_private.competition_editorial_seed s
   where s.country_code=futbeat_private.resolve_country_code(p_country)
     and s.normalized_identity=lower(trim(p_name))),100)
$$;

create or replace function futbeat_private.apply_competition_relevance()
returns trigger language plpgsql security invoker set search_path='' as $$
declare v_code text; v_supra boolean; v_class text; v_audience text;
  v_seed record; v_score integer; v_source text;
begin
 if new.kind<>'competition' then return new; end if;
 select relevance_score,'editorial' into v_score,v_source
 from futbeat_private.competition_editorial_metadata
 where competition_id=new.id and source='editorial';
 if not found then
   v_code:=coalesce(futbeat_private.resolve_country_code(new.payload->>'country'),
     futbeat_private.resolve_country_code(new.payload->>'countryCode'));
   select is_supranational into v_supra from futbeat_private.country_catalog where country_code=v_code;
   v_audience:=case when new.payload->>'audienceClass' in
     ('open','women','youth','reserve','amateur') then new.payload->>'audienceClass' else 'unknown' end;
 select seed.* into v_seed from futbeat_private.competition_editorial_seed seed
 where (seed.canonical_id=new.id or
   (seed.country_code=v_code and seed.normalized_identity=lower(trim(new.payload->>'name'))) or
   exists(select 1 from futbeat_private.provider_entities pe
     where pe.kind='competition' and pe.canonical_id=new.id
       and pe.provider=seed.provider and pe.external_id=seed.provider_external_id))
   and (v_audience='unknown' or v_audience=seed.audience_class)
 order by (seed.canonical_id=new.id) desc nulls last,seed.seed_id limit 1;

   v_class:=case when new.payload->>'competitionClass' in
     ('domestic_league','domestic_cup','international_club','international_national','other')
     then new.payload->>'competitionClass'
     when coalesce(v_supra,false) then 'international_club' else 'other' end;
   v_score:=coalesce(v_seed.relevance_score,
     futbeat_private.derived_competition_relevance(v_class,v_audience));
   v_source:=case when v_seed.seed_id is not null then 'editorial' else 'derived' end;
 end if;
 -- Ignore incoming score/source assertions; only owned metadata/seed is authoritative.
 new.payload:=new.payload||jsonb_build_object('relevanceScore',v_score,'relevanceSource',v_source);
 return new;
end $$;

create or replace function futbeat_private.sync_competition_metadata()
returns trigger language plpgsql security invoker set search_path='' as $$
declare v_code text; v_supra boolean; v_class text; v_audience text; v_seed record;
begin
 if new.kind<>'competition' then return new; end if;
 if exists(select 1 from futbeat_private.competition_editorial_metadata
   where competition_id=new.id and source='editorial') then return new; end if;
 v_code:=coalesce(futbeat_private.resolve_country_code(new.payload->>'country'),
   futbeat_private.resolve_country_code(new.payload->>'countryCode'));
 select is_supranational into v_supra from futbeat_private.country_catalog where country_code=v_code;
 v_audience:=case when new.payload->>'audienceClass' in
   ('open','women','youth','reserve','amateur') then new.payload->>'audienceClass' else 'unknown' end;
 select seed.* into v_seed from futbeat_private.competition_editorial_seed seed
 where (seed.canonical_id=new.id or
   (seed.country_code=v_code and seed.normalized_identity=lower(trim(new.payload->>'name'))) or
   exists(select 1 from futbeat_private.provider_entities pe
     where pe.kind='competition' and pe.canonical_id=new.id
       and pe.provider=seed.provider and pe.external_id=seed.provider_external_id))
   and (v_audience='unknown' or v_audience=seed.audience_class)
 order by (seed.canonical_id=new.id) desc nulls last,seed.seed_id limit 1;
 v_class:=case when new.payload->>'competitionClass' in
   ('domestic_league','domestic_cup','international_club','international_national','other')
   then new.payload->>'competitionClass'
   when coalesce(v_supra,false) then 'international_club' else 'other' end;
 -- Region determines scope only. Provider global flags are not trusted until
 -- explicitly curated; all noneditorial metadata has is_global_relevant=false.
 insert into futbeat_private.competition_editorial_metadata(
   competition_id,competition_class,domestic_tier,is_primary_domestic,audience_class,
   relevance_score,is_global_relevant,country_code,source)
 values(new.id,coalesce(v_seed.competition_class,v_class),v_seed.domestic_tier,
   coalesce(v_seed.is_primary_domestic,false),coalesce(v_seed.audience_class,v_audience),
   coalesce(v_seed.relevance_score,futbeat_private.derived_competition_relevance(v_class,v_audience)),
   coalesce(v_seed.is_global_relevant,false),coalesce(v_seed.country_code,v_code),
   case when v_seed.seed_id is not null then 'editorial'
     when new.payload->>'competitionClass'=v_class or v_audience<>'unknown' then 'provider' else 'derived' end)
 on conflict(competition_id) do update set
   competition_class=excluded.competition_class,domestic_tier=excluded.domestic_tier,
   is_primary_domestic=excluded.is_primary_domestic,audience_class=excluded.audience_class,
   relevance_score=excluded.relevance_score,is_global_relevant=excluded.is_global_relevant,
   country_code=excluded.country_code,source=excluded.source,updated_at=now()
 where futbeat_private.competition_editorial_metadata.source<>'editorial'
   and (futbeat_private.competition_editorial_metadata.competition_class,
        futbeat_private.competition_editorial_metadata.audience_class,
        futbeat_private.competition_editorial_metadata.relevance_score,
        futbeat_private.competition_editorial_metadata.country_code,
        futbeat_private.competition_editorial_metadata.source,
        futbeat_private.competition_editorial_metadata.is_global_relevant)
     is distinct from (excluded.competition_class,excluded.audience_class,
       excluded.relevance_score,excluded.country_code,excluded.source,excluded.is_global_relevant);
 return new;
end $$;

-- Refresh only derived/provider rows (or missing metadata). The sync trigger
-- refuses updates to editorial rows; their values and updated_at remain intact.
update futbeat_private.entities e set payload=e.payload
where e.kind='competition' and not exists(
 select 1 from futbeat_private.competition_editorial_metadata m
 where m.competition_id=e.id and m.source='editorial');

create or replace function public.futbeat_read_calendar_range(
  p_from_date date,p_to_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb language sql stable security definer set search_path='' as $$
  with source as materialized (
    select futbeat_private.futbeat_apply_entity_redirects_snapshot(
      futbeat_private.futbeat_read_calendar_range(p_from_date,p_to_date,p_timezone)
    ) value
  ), team_countries as materialized (
    select country,futbeat_private.resolve_country_code(country) as code
    from (select distinct item->>'country' country from source
      cross join lateral jsonb_array_elements(coalesce(source.value->'teams','[]'::jsonb)) item) names
  ), compact_teams as (
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','name',item->'name','shortName',item->'shortName',
      'country',item->'country','countryCode',to_jsonb(coalesce(
        item->>'countryCode',countries.code)),
      'competitionId',item->'competitionId',
      'media',case when item->'media' is null then null else jsonb_strip_nulls(
        jsonb_build_object('url',item#>'{media,url}','verificationStatus',
          item#>'{media,verificationStatus}')) end
    )) order by item->>'name',item->>'id'),'[]'::jsonb) value
    from source cross join lateral jsonb_array_elements(
      coalesce(source.value->'teams','[]'::jsonb)) item
    left join team_countries countries on countries.country=item->>'country'
  ), compact_competitions as (
    -- Sanitize optional fields, then append the required nullable contract.
    select coalesce(jsonb_agg((jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','name',item->'name','country',item->'country',
      'media',case when item->'media' is null then null else jsonb_strip_nulls(
        jsonb_build_object('url',item#>'{media,url}','verificationStatus',
          item#>'{media,verificationStatus}')) end
    ))||jsonb_build_object(
      'countryCode',meta.country_code,
      'relevanceScore',coalesce(meta.relevance_score,
        futbeat_private.derived_competition_relevance(item->>'competitionClass',item->>'audienceClass')),
      'competitionClass',coalesce(meta.competition_class,'other'),
      'domesticTier',meta.domestic_tier,
      'isPrimaryDomestic',coalesce(meta.is_primary_domestic,false),
      'isGlobalRelevant',coalesce(meta.is_global_relevant,false),
      'audienceClass',coalesce(meta.audience_class,'unknown'),
      'relevanceSource',coalesce(meta.source,'derived')
    )) order by item->>'country',item->>'name',item->>'id'),'[]'::jsonb) value
    from source cross join lateral jsonb_array_elements(
      coalesce(source.value->'competitions','[]'::jsonb)) item
    left join futbeat_private.competition_editorial_metadata meta
      on meta.competition_id=item->>'id'
  ), compact_matches as (
    select coalesce(jsonb_agg((jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','competitionId',item->'competitionId',
      'homeTeamId',item->'homeTeamId','awayTeamId',item->'awayTeamId',
      'startTime',item->'startTime','status',item->'status','score',item->'score',
      'minute',item->'minute',
      'statistics',coalesce(item->'statistics','[]'::jsonb),
      'venue',item->'venue','season',item->'season',
      'provenance',case when item->'provenance' is null then null
        else jsonb_strip_nulls(jsonb_build_object(
          'source',item#>'{provenance,source}',
          'receivedAt',item#>'{provenance,receivedAt}')) end
    ))||jsonb_build_object('events',futbeat_private.normalize_event_array(item->'events')))
      order by item->>'startTime',item->>'id'),'[]'::jsonb) value
    from source cross join lateral jsonb_array_elements(
      coalesce(source.value->'matches','[]'::jsonb)) item
  )
  select (source.value-'teams'-'competitions'-'matches')||jsonb_build_object(
    'teams',compact_teams.value,'competitions',compact_competitions.value,
    'matches',compact_matches.value)
  from source,compact_teams,compact_competitions,compact_matches
$$;
revoke all on function public.futbeat_read_calendar_range(date,date,text)
  from public,anon,authenticated;
grant execute on function public.futbeat_read_calendar_range(date,date,text) to service_role;

revoke all on function futbeat_private.derived_competition_relevance(text,text),
 futbeat_private.competition_relevance_score(text,text),
 futbeat_private.apply_competition_relevance(),futbeat_private.sync_competition_metadata()
from public,anon,authenticated;

notify pgrst,'reload schema';
