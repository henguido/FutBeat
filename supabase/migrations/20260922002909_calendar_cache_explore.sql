-- Compact, dependency-versioned cache. No provider jobs or lifecycle writes.
-- The previous public builder remains available for local before/after benchmarks.
alter function public.futbeat_read_calendar_range(date,date,text)
  rename to futbeat_read_calendar_range_before_cache;
alter function public.futbeat_read_calendar_range_before_cache(date,date,text)
  set schema futbeat_private;
revoke all on function futbeat_private.futbeat_read_calendar_range_before_cache(date,date,text)
  from public,anon,authenticated,service_role;

create table futbeat_private.calendar_cache_versions (
  utc_date date primary key, revision bigint not null default 1
);
create table futbeat_private.catalog_cache_version (
  singleton boolean primary key default true check(singleton),
  revision bigint not null default 1
);
insert into futbeat_private.catalog_cache_version values(true,1);
create table futbeat_private.compact_calendar_cache (
  calendar_date date not null, timezone text not null,
  version text not null, payload jsonb not null,
  built_at timestamptz not null, expires_at timestamptz not null,
  primary key(calendar_date,timezone)
);
alter table futbeat_private.calendar_cache_versions enable row level security;
alter table futbeat_private.catalog_cache_version enable row level security;
alter table futbeat_private.compact_calendar_cache enable row level security;
revoke all on futbeat_private.calendar_cache_versions,
  futbeat_private.catalog_cache_version,futbeat_private.compact_calendar_cache
  from public,anon,authenticated;

create or replace function futbeat_private.bump_calendar_date(p_date date)
returns void language sql volatile set search_path='' as $$
  -- UTC dependencies, not session/local dates. Readers bypass EVERY civil date
  -- intersecting UTC today; skipping only this bucket cannot stale a cached day.
  insert into futbeat_private.calendar_cache_versions
  select p_date,1 where p_date<>(now() at time zone 'UTC')::date
  on conflict(utc_date) do update set revision=futbeat_private.calendar_cache_versions.revision+1
$$;
create or replace function futbeat_private.invalidate_calendar_cache()
returns trigger language plpgsql security definer set search_path='' as $$
declare o jsonb; n jsonb; d date; v_match_id text;
begin
  if TG_OP<>'INSERT' then o:=to_jsonb(old); end if;
  if TG_OP<>'DELETE' then n:=to_jsonb(new); end if;
  if o is not distinct from n then return null; end if;
  if TG_TABLE_NAME='entities' then
    if coalesce(n->>'kind',o->>'kind')='match' then
      select (start_time at time zone 'UTC')::date into d
        from futbeat_private.calendar_matches where match_id=coalesce(n->>'id',o->>'id');
      if d is not null then perform futbeat_private.bump_calendar_date(d); end if;
      -- Activity changes affect suggestions; score/minute changes do not.
      if ((o->'payload')-array['score','status','minute','events','statistics','provenance'])
        is distinct from ((n->'payload')-array['score','status','minute','events','statistics','provenance']) then
        update futbeat_private.catalog_cache_version set revision=revision+1;
      end if;
    elsif coalesce(n->>'kind',o->>'kind') in ('team','competition') then
      update futbeat_private.catalog_cache_version set revision=revision+1;
    end if;
  elsif TG_TABLE_NAME='competition_editorial_metadata' then
    -- Ingestion may touch updated_at without changing the editorial contract.
    if (o-'updated_at') is distinct from (n-'updated_at') then
      update futbeat_private.catalog_cache_version set revision=revision+1;
    end if;
  elsif TG_TABLE_NAME='entity_redirects' then
    update futbeat_private.catalog_cache_version set revision=revision+1;
  elsif TG_TABLE_NAME='calendar_coverage' then
    for d in select distinct v::date from unnest(array[o->>'provider_date',n->>'provider_date']) v
      where v is not null order by 1 loop
      perform futbeat_private.bump_calendar_date(d);
    end loop;
  elsif TG_TABLE_NAME='calendar_matches' then
    for d in select distinct (v::timestamptz at time zone 'UTC')::date
      from unnest(array[o->>'start_time',n->>'start_time']) v
      where v is not null order by 1 loop
      perform futbeat_private.bump_calendar_date(d);
    end loop;
  else
    for v_match_id in select distinct v from unnest(array[
      o->>'canonical_match_id',n->>'canonical_match_id',o->>'match_id',n->>'match_id']) v
      where v is not null order by 1 loop
      select (start_time at time zone 'UTC')::date into d
        from futbeat_private.calendar_matches c where c.match_id=v_match_id;
      if d is not null then perform futbeat_private.bump_calendar_date(d); end if;
    end loop;
  end if;
  return null;
end $$;

do $$ declare t text; begin
  foreach t in array array['entities','calendar_matches','calendar_coverage',
    'provider_observations','live_match_state','match_detail_cache','canonical_events',
    'entity_redirects','competition_editorial_metadata'] loop
    execute format('create trigger invalidate_compact_calendar after insert or update or delete on futbeat_private.%I for each row execute function futbeat_private.invalidate_calendar_cache()',t);
  end loop;
end $$;

create or replace function futbeat_private.calendar_cache_version(p_date date,p_timezone text)
returns text language sql stable set search_path='' as $$
  select c.revision::text||':'||coalesce(string_agg(v.utc_date::text||'='||v.revision,',' order by v.utc_date),'')
  from futbeat_private.catalog_cache_version c
  left join futbeat_private.calendar_cache_versions v on v.utc_date between
    (p_date::timestamp at time zone p_timezone at time zone 'UTC')::date and
    (((p_date+1)::timestamp at time zone p_timezone-interval '1 microsecond') at time zone 'UTC')::date
  group by c.revision
$$;

create or replace function futbeat_private.build_compact_calendar(
  p_from_date date,p_to_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb language sql stable security definer set search_path='' as $$
  with bounds as (
    select p_from_date::timestamp at time zone p_timezone lo,
      (p_to_date+1)::timestamp at time zone p_timezone hi
  ), read_models as materialized (
    select futbeat_private.match_read_model(e.payload) item,c.updated_at
    from bounds b join futbeat_private.calendar_matches c
      on c.start_time>=b.lo and c.start_time<b.hi
    join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
  ), reconciled as materialized (
    -- Explicit payload boundary: never join collections through physical aliases.
    -- Resolve all references even if the read-model implementation changes.
    select item||jsonb_build_object(
      'homeTeamId',futbeat_private.futbeat_resolve_entity_id('team',item->>'homeTeamId'),
      'awayTeamId',futbeat_private.futbeat_resolve_entity_id('team',item->>'awayTeamId'),
      'competitionId',futbeat_private.futbeat_resolve_entity_id('competition',item->>'competitionId')
    ) item,updated_at from read_models
  ), source as (
    select jsonb_build_object(
      'updatedAt',coalesce((select max(greatest(
        nullif(item#>>'{provenance,receivedAt}','')::timestamptz,
        nullif(item->>'liveChangedAt','')::timestamptz,updated_at)) from reconciled),now()),
      'freshness',jsonb_build_object('stale',false),
      'coverage',jsonb_build_object('source','FutBeat','partial',not complete,
        'live',false,'developmentOnly',false,'sources',jsonb_build_array('GOAL API'),
        'calendar',jsonb_build_object('from',p_from_date,'to',p_to_date,
          'timezone',p_timezone,'complete',complete))) value
    from (
      select count(*)=(select ((hi-interval '1 microsecond') at time zone 'UTC')::date
        -(lo at time zone 'UTC')::date+1 from bounds) complete
      from futbeat_private.calendar_coverage,bounds
      where provider='goal_api' and provider_date between (lo at time zone 'UTC')::date
        and ((hi-interval '1 microsecond') at time zone 'UTC')::date
    ) coverage
  ), team_items as (
    -- Match references and entity collections must share the same final IDs,
    -- including chained redirects; no redirect catalog is sent to the phone.
    select e.payload item from futbeat_private.entities e where e.kind='team'
      and e.id in (select item->>'homeTeamId' from reconciled
                   union select item->>'awayTeamId' from reconciled)
  ), competition_items as (
    select e.payload item from futbeat_private.entities e where e.kind='competition'
      and e.id in (select item->>'competitionId' from reconciled)
  ), compact_teams as (
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','name',item->'name','shortName',item->'shortName',
      'media',case when item->'media' is null then null else jsonb_strip_nulls(
        jsonb_build_object('url',item#>'{media,url}','verificationStatus',
          item#>'{media,verificationStatus}')) end
    )) order by item->>'name',item->>'id'),'[]'::jsonb) value
    from team_items
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
    from competition_items
    left join futbeat_private.competition_editorial_metadata meta
      on meta.competition_id=item->>'id'
  ), compact_matches as (
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','competitionId',item->'competitionId',
      'homeTeamId',item->'homeTeamId','awayTeamId',item->'awayTeamId',
      'startTime',item->'startTime','status',item->'status',
      'score',item->'score','minute',item->'minute',
      'hasPlayedEvidence',item->'hasPlayedEvidence',
      'latestEvent',case when item->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
        then (select event from jsonb_array_elements(item->'events') event
          order by (event->>'minute')::integer desc nulls last,
            (event->>'extraMinute')::integer desc nulls last,event->>'id' desc limit 1) end
    )) order by item->>'startTime',item->>'id'),'[]'::jsonb) value
    from reconciled
  )
  select jsonb_build_object(
    'schemaVersion',1,'demo',false,'updatedAt',source.value->'updatedAt',
    'coverage',source.value->'coverage','freshness',source.value->'freshness',
    'teams',compact_teams.value,'competitions',compact_competitions.value,
    'matches',compact_matches.value,'players','[]'::jsonb,'standings','[]'::jsonb)
  from source,compact_teams,compact_competitions,compact_matches
$$;

revoke all on function futbeat_private.build_compact_calendar(date,date,text) from public,anon,authenticated,service_role;

create or replace function public.futbeat_read_calendar_range(
 p_from_date date,p_to_date date,p_timezone text default 'America/Costa_Rica')
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare v_version text; v_payload jsonb; v_expiry timestamptz; v_today date;
 v_utc_today date; v_first_utc date; v_last_utc date;
begin
 if p_from_date is null or p_to_date is null or p_from_date>p_to_date
   or p_to_date-p_from_date>31 or not exists(select 1 from pg_catalog.pg_timezone_names where name=p_timezone) then
   raise exception 'Invalid calendar range';
 end if;
 v_today:=(now() at time zone p_timezone)::date;
 v_utc_today:=(now() at time zone 'UTC')::date;
 v_first_utc:=(p_from_date::timestamp at time zone p_timezone at time zone 'UTC')::date;
 v_last_utc:=(((p_to_date+1)::timestamp at time zone p_timezone-interval '1 microsecond') at time zone 'UTC')::date;
 -- UTC today is deliberately unversioned. Bypass any overlapping civil day,
 -- including yesterday/tomorrow in offset timezones, as well as local today.
 if p_from_date<>p_to_date or p_from_date=v_today
   or v_utc_today between v_first_utc and v_last_utc then
   return futbeat_private.build_compact_calendar(p_from_date,p_to_date,p_timezone);
 end if;
 v_version:=futbeat_private.calendar_cache_version(p_from_date,p_timezone);
 select payload into v_payload from futbeat_private.compact_calendar_cache
   where calendar_date=p_from_date and timezone=p_timezone and version=v_version and expires_at>now();
 if found then return v_payload; end if;
 -- One rebuild per date/timezone; version is read AFTER the lock, before building.
 -- Concurrent domain writes change the version, so cannot be lost by an upsert.
 perform pg_catalog.pg_advisory_xact_lock(hashtextextended('calendar:'||p_from_date||':'||p_timezone,0));
 v_version:=futbeat_private.calendar_cache_version(p_from_date,p_timezone);
 select payload into v_payload from futbeat_private.compact_calendar_cache
   where calendar_date=p_from_date and timezone=p_timezone and version=v_version and expires_at>now();
 if found then return v_payload; end if;
 v_payload:=futbeat_private.build_compact_calendar(p_from_date,p_to_date,p_timezone);
 v_expiry:=now()+case when p_from_date<v_today and not (v_payload#>>'{coverage,partial}')::boolean
   and not exists(select 1 from futbeat_private.calendar_coverage c where c.provider='goal_api'
     and c.provider_date between (p_from_date::timestamp at time zone p_timezone at time zone 'UTC')::date
       and (((p_to_date+1)::timestamp at time zone p_timezone-interval '1 microsecond') at time zone 'UTC')::date
     and not c.results_complete)
   then interval '1 day' else interval '30 seconds' end;
 -- Clock-driven transitions (LIVE expiry, kickoff/evidence grace) cannot outlive a short cache.
 if exists(select 1 from jsonb_array_elements(v_payload->'matches') m
   where m->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
     or (m->>'startTime')::timestamptz>now()-interval '30 minutes') then
   v_expiry:=least(v_expiry,now()+interval '10 seconds');
 end if;
 -- Expire BEFORE the first dependency enters the unversioned UTC-today window.
 -- Thus a pre-today entry cannot survive that window and be reused as history.
 if p_from_date>v_today then
   v_expiry:=least(v_expiry,(v_today+1)::timestamp at time zone p_timezone,
     v_first_utc::timestamp at time zone 'UTC');
 end if;
 insert into futbeat_private.compact_calendar_cache values(p_from_date,p_timezone,v_version,v_payload,now(),v_expiry)
 on conflict(calendar_date,timezone) do update set version=excluded.version,payload=excluded.payload,
   built_at=excluded.built_at,expires_at=excluded.expires_at;
 -- Opportunistic bounded retention; no cron/provider work.
 delete from futbeat_private.compact_calendar_cache where built_at<now()-interval '30 days';
 return v_payload;
end $$;
revoke all on function public.futbeat_read_calendar_range(date,date,text) from public,anon,authenticated;
grant execute on function public.futbeat_read_calendar_range(date,date,text) to service_role;
revoke all on function futbeat_private.bump_calendar_date(date),
 futbeat_private.invalidate_calendar_cache(),futbeat_private.calendar_cache_version(date,text)
 from public,anon,authenticated,service_role;

-- Search terms are normalized on write, not expanded from JSON on every read.
create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;
create table futbeat_private.entity_search_index (
  entity_id text not null references futbeat_private.entities(id) on delete cascade,
  kind text not null, term text not null,
  primary key(entity_id,term)
);
create index entity_search_term_trgm on futbeat_private.entity_search_index
  using gin(term extensions.gin_trgm_ops);
create index entity_search_term_prefix on futbeat_private.entity_search_index(term text_pattern_ops);
alter table futbeat_private.entity_search_index enable row level security;
revoke all on futbeat_private.entity_search_index from public,anon,authenticated;

create function futbeat_private.index_entity_search() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if TG_OP='UPDATE' and new.kind=old.kind
   and new.payload->'name' is not distinct from old.payload->'name'
   and new.payload->'shortName' is not distinct from old.payload->'shortName'
   and new.payload->'aliases' is not distinct from old.payload->'aliases' then return new; end if;
 delete from futbeat_private.entity_search_index where entity_id=new.id;
 if new.kind in ('competition','team','player') then
   insert into futbeat_private.entity_search_index
   select new.id,new.kind,lower(btrim(term)) from (
     select new.payload->>'name' term union select new.payload->>'shortName'
     union select jsonb_array_elements_text(case when jsonb_typeof(new.payload->'aliases')='array'
       then new.payload->'aliases' else '[]'::jsonb end)
   ) terms where nullif(btrim(term),'') is not null on conflict do nothing;
 end if;
 return new;
end $$;
create trigger index_entity_search after insert or update of kind,payload on futbeat_private.entities
 for each row execute function futbeat_private.index_entity_search();
insert into futbeat_private.entity_search_index
select e.id,e.kind,lower(btrim(term)) from futbeat_private.entities e cross join lateral (
 select e.payload->>'name' term union select e.payload->>'shortName'
 union select jsonb_array_elements_text(case when jsonb_typeof(e.payload->'aliases')='array'
   then e.payload->'aliases' else '[]'::jsonb end)
) terms where e.kind in ('competition','team','player') and nullif(btrim(term),'') is not null
on conflict do nothing;

-- Snapshot envelope deliberately contains no global fixtures or player suggestions.
create function futbeat_private.catalog_snapshot(p_competitions jsonb,p_teams jsonb,p_players jsonb default '[]')
returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('schemaVersion',1,'demo',false,'updatedAt',now(),
   'coverage',jsonb_build_object('partial',false),'freshness',jsonb_build_object('stale',false),
   'competitions',p_competitions,'teams',p_teams,'players',p_players,
   'matches','[]'::jsonb,'standings','[]'::jsonb,'news','[]'::jsonb,'transfers','[]'::jsonb)
$$;
create function futbeat_private.catalog_entity(p_payload jsonb,p_score integer)
returns jsonb language sql immutable set search_path='' as $$
 select jsonb_strip_nulls(jsonb_build_object('id',p_payload->'id','name',p_payload->'name',
   'shortName',p_payload->'shortName','country',p_payload->'country','media',p_payload->'media',
   'competitionId',p_payload->'competitionId','teamId',p_payload->'teamId',
   'relevanceScore',p_score))
$$;
create table futbeat_private.explore_cache (
 singleton boolean primary key default true check(singleton),
 version bigint not null,payload jsonb not null,expires_at timestamptz not null
);
alter table futbeat_private.explore_cache enable row level security;
revoke all on futbeat_private.explore_cache from public,anon,authenticated;

create function public.futbeat_read_explore() returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare v_version bigint; v_payload jsonb;
begin
 select revision into v_version from futbeat_private.catalog_cache_version;
 select payload into v_payload from futbeat_private.explore_cache
   where singleton and version=v_version and expires_at>now();
 if found then return v_payload; end if;
 perform pg_catalog.pg_advisory_xact_lock(hashtextextended('futbeat:explore',0));
 select revision into v_version from futbeat_private.catalog_cache_version;
 select payload into v_payload from futbeat_private.explore_cache
   where singleton and version=v_version and expires_at>now();
 if found then return v_payload; end if;
 with competitions as materialized (
   select e.id,e.payload,m.relevance_score,m.is_global_relevant
   from futbeat_private.competition_editorial_metadata m
   join futbeat_private.entities e on e.id=m.competition_id and e.kind='competition'
   where not exists(select 1 from futbeat_private.entity_redirects r where r.alias_id=e.id and r.kind='competition')
   -- Relevance leads: domestic major leagues are not crowded out by global flags.
   order by m.relevance_score desc,m.is_global_relevant desc,e.payload->>'name',e.id limit 12
 ), activity as (
   select futbeat_private.futbeat_resolve_entity_id('team',team.id) team_id,
     max(coalesce(m.relevance_score,100)) score,
     min(abs(extract(epoch from c.start_time-now()))) distance
   from futbeat_private.calendar_matches c
   join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
   cross join lateral (values(e.payload->>'homeTeamId'),(e.payload->>'awayTeamId')) team(id)
   left join futbeat_private.competition_editorial_metadata m on m.competition_id=
     futbeat_private.futbeat_resolve_entity_id('competition',e.payload->>'competitionId')
   where c.start_time between now()-interval '7 days' and now()+interval '7 days'
   group by 1
 ), teams as (
   select e.payload,a.score,a.distance from activity a
   join futbeat_private.entities e on e.id=a.team_id and e.kind='team'
   order by a.score desc,a.distance,e.payload->>'name',e.id limit 16
 )
 select futbeat_private.catalog_snapshot(
   (select coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance_score)
      order by relevance_score desc,is_global_relevant desc,payload->>'name',id),'[]') from competitions),
   (select coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,score)
      order by score desc,distance,payload->>'name',payload->>'id'),'[]') from teams)
 ) into v_payload;
 insert into futbeat_private.explore_cache values(true,v_version,v_payload,now()+interval '5 minutes')
 on conflict(singleton) do update set version=excluded.version,payload=excluded.payload,expires_at=excluded.expires_at;
 return v_payload;
end $$;

-- Preserve the public signature for older clients, but deliberately ignore p_country.
create or replace function public.futbeat_search_catalog(
 p_query text default '',p_country text default null,p_limit integer default 50)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare q text:=lower(btrim(coalesce(p_query,''))); pattern text; v_result jsonb;
begin
 if length(q)>80 then raise exception 'Invalid search query'; end if;
 if q='' then return public.futbeat_read_explore(); end if;
 if length(q)<2 then return futbeat_private.catalog_snapshot('[]','[]'); end if;
 pattern:=replace(replace(replace(q,E'\\',E'\\\\'),'%',E'\\%'),'_',E'\\_');
 with matches as materialized (
   select s.kind,futbeat_private.futbeat_resolve_entity_id(s.kind,s.entity_id) id,
     max(case when s.term=q then 3 when s.term like pattern||'%' then 2
       when s.term like '%'||pattern||'%' then 1 else 0 end) quality,
     max(extensions.similarity(s.term,q)) similarity
   from futbeat_private.entity_search_index s
   where (length(q)=2 and s.term like pattern||'%')
      or (length(q)>=3 and (s.term like '%'||pattern||'%' or s.term operator(extensions.%) q))
   group by s.kind,2
 ), scored as (
   select e.id,e.kind,e.payload,h.quality,h.similarity,coalesce(meta.relevance_score,100) relevance
   from matches h join futbeat_private.entities e on e.id=h.id and e.kind=h.kind
   left join futbeat_private.entities team on e.kind='player' and team.id=e.payload->>'teamId'
   left join futbeat_private.competition_editorial_metadata meta on meta.competition_id=
     case when e.kind='competition' then e.id else futbeat_private.futbeat_resolve_entity_id(
       'competition',coalesce(e.payload->>'competitionId',team.payload->>'competitionId')) end
 ), ranked as (
   select *,row_number() over(partition by kind order by quality desc,similarity desc,relevance desc,
     lower(payload->>'name'),id) rn from scored
 ), bounded as (
   select * from ranked where rn<=greatest(1,least(coalesce(p_limit,50),75))
 )
 select futbeat_private.catalog_snapshot(
   coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance) order by rn) filter(where kind='competition'),'[]'),
   coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance) order by rn) filter(where kind='team'),'[]'),
   coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance) order by rn) filter(where kind='player'),'[]')
 ) into v_result from bounded;
 return v_result;
end $$;
revoke all on function futbeat_private.index_entity_search(),
 futbeat_private.catalog_snapshot(jsonb,jsonb,jsonb),futbeat_private.catalog_entity(jsonb,integer)
 from public,anon,authenticated,service_role;
revoke all on function public.futbeat_read_explore(),public.futbeat_search_catalog(text,text,integer)
 from public,anon,authenticated;
grant execute on function public.futbeat_read_explore(),public.futbeat_search_catalog(text,text,integer) to service_role;
analyze futbeat_private.entity_search_index;
notify pgrst,'reload schema';
