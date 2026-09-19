-- Canonical identity v2.
-- Verified aliases are redirected to one canonical entity without deleting the
-- historical entity row. Old deep links remain resolvable while all new reads,
-- follows, interests and provider mappings converge on the canonical id.

create table if not exists futbeat_private.entity_redirects (
  alias_id text primary key references futbeat_private.entities(id) on delete cascade,
  canonical_id text not null references futbeat_private.entities(id),
  kind text not null check(kind in ('competition','team')),
  reason text not null,
  created_at timestamptz not null default now(),
  check(alias_id<>canonical_id)
);

create index if not exists entity_redirects_canonical_idx
  on futbeat_private.entity_redirects(kind,canonical_id);

alter table futbeat_private.entity_redirects enable row level security;
revoke all on futbeat_private.entity_redirects from public,anon,authenticated;
grant select on futbeat_private.entity_redirects to service_role;

create or replace function futbeat_private.futbeat_resolve_entity_id(
  p_kind text,
  p_id text
) returns text
language sql
stable
security definer
set search_path=''
as $fn$
  with recursive chain(id,depth,path) as (
    select p_id,0,array[p_id]::text[]
    union all
    select r.canonical_id,c.depth+1,c.path||r.canonical_id
    from chain c
    join futbeat_private.entity_redirects r
      on r.alias_id=c.id
     and r.kind=p_kind
    where c.depth<8
      and not r.canonical_id=any(c.path)
  )
  select id
  from chain
  order by depth desc
  limit 1
$fn$;

create or replace function futbeat_private.futbeat_register_entity_redirect(
  p_kind text,
  p_alias_id text,
  p_canonical_id text,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $fn$
declare
  v_target text;
  v_alias_name text;
  v_alias_country text;
  v_alias_short text;
  v_alias_media jsonb;
begin
  if p_kind not in ('competition','team')
     or nullif(p_alias_id,'') is null
     or nullif(p_canonical_id,'') is null
     or p_alias_id=p_canonical_id
     or nullif(btrim(p_reason),'') is null
  then
    raise exception 'Invalid entity redirect';
  end if;

  if not exists(
    select 1 from futbeat_private.entities
    where id=p_alias_id and kind=p_kind
  ) or not exists(
    select 1 from futbeat_private.entities
    where id=p_canonical_id and kind=p_kind
  ) then
    raise exception 'Redirect entities must exist and share kind';
  end if;

  v_target:=futbeat_private.futbeat_resolve_entity_id(p_kind,p_canonical_id);
  if v_target=p_alias_id
     or futbeat_private.futbeat_resolve_entity_id(p_kind,v_target)=p_alias_id
  then
    raise exception 'Entity redirect cycle';
  end if;

  select
    nullif(payload->>'name',''),
    nullif(payload->>'country',''),
    nullif(payload->>'shortName',''),
    payload->'media'
  into v_alias_name,v_alias_country,v_alias_short,v_alias_media
  from futbeat_private.entities
  where id=p_alias_id and kind=p_kind;

  insert into futbeat_private.entity_redirects(
    alias_id,canonical_id,kind,reason,created_at
  )
  values(p_alias_id,v_target,p_kind,left(btrim(p_reason),500),now())
  on conflict(alias_id) do update
    set canonical_id=excluded.canonical_id,
        kind=excluded.kind,
        reason=excluded.reason;

  -- Preserve useful alias metadata on the canonical row.
  update futbeat_private.entities e
  set payload=
    jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(
            e.payload,
            '{country}',
            to_jsonb(coalesce(nullif(e.payload->>'country',''),v_alias_country,'')),
            true
          ),
          '{shortName}',
          to_jsonb(coalesce(nullif(e.payload->>'shortName',''),v_alias_short,'')),
          true
        ),
        '{media}',
        case
          when e.payload->'media' is null or e.payload->'media'='null'::jsonb
            then coalesce(v_alias_media,'null'::jsonb)
          else e.payload->'media'
        end,
        true
      ),
      '{aliases}',
      case
        when v_alias_name is null
          or lower(v_alias_name)=lower(coalesce(e.payload->>'name',''))
          or exists(
            select 1
            from jsonb_array_elements_text(
              coalesce(e.payload->'aliases','[]'::jsonb)
            ) a(value)
            where lower(a.value)=lower(v_alias_name)
          )
          then coalesce(e.payload->'aliases','[]'::jsonb)
        else coalesce(e.payload->'aliases','[]'::jsonb)
          || jsonb_build_array(v_alias_name)
      end,
      true
    )
  where e.id=v_target and e.kind=p_kind;

  update futbeat_private.provider_entities
  set canonical_id=v_target
  where kind=p_kind and canonical_id=p_alias_id;

  update futbeat_private.provider_media_cache
  set canonical_id=v_target
  where kind=p_kind and canonical_id=p_alias_id;

  -- Merge follows without creating duplicate primary-key rows.
  insert into futbeat_private.push_follows(
    user_id,entity_type,entity_id,created_at
  )
  select user_id,p_kind,v_target,created_at
  from futbeat_private.push_follows
  where entity_type=p_kind and entity_id=p_alias_id
  on conflict(user_id,entity_type,entity_id) do nothing;

  delete from futbeat_private.push_follows
  where entity_type=p_kind and entity_id=p_alias_id;

  insert into futbeat_private.temporary_interests(
    user_id,entity_type,entity_id,touched_at,expires_at
  )
  select user_id,p_kind,v_target,touched_at,expires_at
  from futbeat_private.temporary_interests
  where entity_type=p_kind and entity_id=p_alias_id
  on conflict(user_id,entity_type,entity_id) do update
    set touched_at=greatest(
          futbeat_private.temporary_interests.touched_at,
          excluded.touched_at
        ),
        expires_at=greatest(
          futbeat_private.temporary_interests.expires_at,
          excluded.expires_at
        );

  delete from futbeat_private.temporary_interests
  where entity_type=p_kind and entity_id=p_alias_id;

  insert into futbeat_private.coverage_interests(
    subject_type,subject_id,country_code,
    explicit_followers,temporary_users,selected_country_users,
    detected_country_users,priority_score,depth,last_updated_at,
    next_refresh_at,calculated_at
  )
  select
    p_kind,v_target,country_code,
    explicit_followers,temporary_users,selected_country_users,
    detected_country_users,priority_score,depth,last_updated_at,
    next_refresh_at,calculated_at
  from futbeat_private.coverage_interests
  where subject_type=p_kind and subject_id=p_alias_id
  on conflict(subject_type,subject_id) do update
  set country_code=case
        when futbeat_private.coverage_interests.country_code=''
          then excluded.country_code
        else futbeat_private.coverage_interests.country_code
      end,
      explicit_followers=greatest(
        futbeat_private.coverage_interests.explicit_followers,
        excluded.explicit_followers
      ),
      temporary_users=greatest(
        futbeat_private.coverage_interests.temporary_users,
        excluded.temporary_users
      ),
      selected_country_users=greatest(
        futbeat_private.coverage_interests.selected_country_users,
        excluded.selected_country_users
      ),
      detected_country_users=greatest(
        futbeat_private.coverage_interests.detected_country_users,
        excluded.detected_country_users
      ),
      priority_score=greatest(
        futbeat_private.coverage_interests.priority_score,
        excluded.priority_score
      ),
      depth=case
        when 'DEEP' in (
          futbeat_private.coverage_interests.depth,excluded.depth
        ) then 'DEEP'
        when 'TEMPORARY' in (
          futbeat_private.coverage_interests.depth,excluded.depth
        ) then 'TEMPORARY'
        else 'BASE'
      end,
      last_updated_at=case
        when futbeat_private.coverage_interests.last_updated_at is null
          then excluded.last_updated_at
        when excluded.last_updated_at is null
          then futbeat_private.coverage_interests.last_updated_at
        else greatest(
          futbeat_private.coverage_interests.last_updated_at,
          excluded.last_updated_at
        )
      end,
      next_refresh_at=least(
        futbeat_private.coverage_interests.next_refresh_at,
        excluded.next_refresh_at
      ),
      calculated_at=greatest(
        futbeat_private.coverage_interests.calculated_at,
        excluded.calculated_at
      );

  delete from futbeat_private.coverage_interests
  where subject_type=p_kind and subject_id=p_alias_id;

  if p_kind='competition' then
    update futbeat_private.entities
    set payload=jsonb_set(payload,'{competitionId}',to_jsonb(v_target),true)
    where kind in ('team','match')
      and payload->>'competitionId'=p_alias_id;

    insert into futbeat_private.standings_cache(
      competition_id,provider,external_league_id,season,table_payload,fetched_at
    )
    select
      v_target,provider,external_league_id,season,
      jsonb_set(table_payload,'{competitionId}',to_jsonb(v_target),true),
      fetched_at
    from futbeat_private.standings_cache
    where competition_id=p_alias_id
    on conflict(competition_id) do update
      set provider=excluded.provider,
          external_league_id=excluded.external_league_id,
          season=excluded.season,
          table_payload=excluded.table_payload,
          fetched_at=excluded.fetched_at
      where excluded.fetched_at>
        futbeat_private.standings_cache.fetched_at;

    delete from futbeat_private.standings_cache
    where competition_id=p_alias_id;
  else
    update futbeat_private.entities
    set payload=jsonb_set(payload,'{homeTeamId}',to_jsonb(v_target),true)
    where kind='match' and payload->>'homeTeamId'=p_alias_id;

    update futbeat_private.entities
    set payload=jsonb_set(payload,'{awayTeamId}',to_jsonb(v_target),true)
    where kind='match' and payload->>'awayTeamId'=p_alias_id;

    update futbeat_private.entities
    set payload=jsonb_set(payload,'{teamId}',to_jsonb(v_target),true)
    where kind='player' and payload->>'teamId'=p_alias_id;

    insert into futbeat_private.team_squad_members(
      team_id,player_id,provider,updated_at
    )
    select v_target,player_id,provider,updated_at
    from futbeat_private.team_squad_members
    where team_id=p_alias_id
    on conflict(team_id,player_id) do update
      set provider=case
            when excluded.updated_at>=
              futbeat_private.team_squad_members.updated_at
              then excluded.provider
            else futbeat_private.team_squad_members.provider
          end,
          updated_at=greatest(
            futbeat_private.team_squad_members.updated_at,
            excluded.updated_at
          );

    delete from futbeat_private.team_squad_members
    where team_id=p_alias_id;

    insert into futbeat_private.team_detail_coverage(
      team_id,provider,fetched_at,player_count
    )
    select v_target,provider,fetched_at,player_count
    from futbeat_private.team_detail_coverage
    where team_id=p_alias_id
    on conflict(team_id) do update
      set provider=case
            when excluded.fetched_at>=
              futbeat_private.team_detail_coverage.fetched_at
              then excluded.provider
            else futbeat_private.team_detail_coverage.provider
          end,
          fetched_at=greatest(
            futbeat_private.team_detail_coverage.fetched_at,
            excluded.fetched_at
          ),
          player_count=greatest(
            futbeat_private.team_detail_coverage.player_count,
            excluded.player_count
          );

    delete from futbeat_private.team_detail_coverage
    where team_id=p_alias_id;

    update futbeat_private.canonical_events
    set payload=jsonb_set(payload,'{teamId}',to_jsonb(v_target),true)
    where payload->>'teamId'=p_alias_id;

    -- Rewrite and deduplicate any cached standings row using the team alias.
    update futbeat_private.standings_cache sc
    set table_payload=jsonb_set(
      sc.table_payload,
      '{rows}',
      coalesce((
        with normalized as (
          select
            case
              when row.value->>'teamId'=p_alias_id
                then jsonb_set(
                  row.value,'{teamId}',to_jsonb(v_target),true
                )
              else row.value
            end as payload,
            row.ordinality::integer as original_position
          from jsonb_array_elements(
            coalesce(sc.table_payload->'rows','[]'::jsonb)
          ) with ordinality row(value,ordinality)
        ),
        ranked as (
          select
            payload,
            original_position,
            row_number() over(
              partition by payload->>'teamId'
              order by
                coalesce((payload->>'played')::integer,0) desc,
                coalesce((payload->>'points')::integer,0) desc,
                original_position
            ) as rn
          from normalized
        )
        select jsonb_agg(
          payload
          order by
            coalesce((payload->>'points')::integer,0) desc,
            (
              coalesce((payload->>'gf')::integer,0)
              -coalesce((payload->>'ga')::integer,0)
            ) desc,
            coalesce((payload->>'gf')::integer,0) desc,
            original_position
        )
        from ranked
        where rn=1
      ),'[]'::jsonb),
      true
    )
    where exists(
      select 1
      from jsonb_array_elements(
        coalesce(sc.table_payload->'rows','[]'::jsonb)
      ) row
      where row->>'teamId'=p_alias_id
    );
  end if;

  perform futbeat_private.refresh_interest_aggregates();

  return jsonb_build_object(
    'kind',p_kind,
    'aliasId',p_alias_id,
    'canonicalId',v_target,
    'reason',p_reason
  );
end
$fn$;

create or replace function futbeat_private.futbeat_apply_entity_redirects_snapshot(
  p_snapshot jsonb
) returns jsonb
language sql
stable
security definer
set search_path=''
as $fn$
  with
  redirect_json as (
    select coalesce(
      jsonb_object_agg(alias_id,canonical_id order by alias_id),
      '{}'::jsonb
    ) as value
    from futbeat_private.entity_redirects
  ),
  competition_candidates as (
    select
      x.ordinality::integer as ord,
      x.item,
      coalesce(r.canonical_id,x.item->>'id') as resolved_id,
      r.alias_id is null as is_canonical
    from jsonb_array_elements(
      coalesce(p_snapshot->'competitions','[]'::jsonb)
    ) with ordinality x(item,ordinality)
    left join futbeat_private.entity_redirects r
      on r.kind='competition' and r.alias_id=x.item->>'id'
  ),
  competition_ranked as (
    select
      c.resolved_id,
      c.ord,
      case
        when c.is_canonical then c.item
        else coalesce(
          e.payload,
          jsonb_set(c.item,'{id}',to_jsonb(c.resolved_id),true)
        )
      end as payload,
      row_number() over(
        partition by c.resolved_id
        order by case when c.is_canonical then 0 else 1 end,c.ord
      ) as rn
    from competition_candidates c
    left join futbeat_private.entities e
      on e.id=c.resolved_id and e.kind='competition'
  ),
  competitions as (
    select coalesce(
      jsonb_agg(payload order by ord),
      '[]'::jsonb
    ) as value
    from competition_ranked
    where rn=1
  ),
  team_candidates as (
    select
      x.ordinality::integer as ord,
      x.item,
      coalesce(r.canonical_id,x.item->>'id') as resolved_id,
      r.alias_id is null as is_canonical
    from jsonb_array_elements(
      coalesce(p_snapshot->'teams','[]'::jsonb)
    ) with ordinality x(item,ordinality)
    left join futbeat_private.entity_redirects r
      on r.kind='team' and r.alias_id=x.item->>'id'
  ),
  team_ranked as (
    select
      t.resolved_id,
      t.ord,
      case
        when t.is_canonical then t.item
        else coalesce(
          e.payload,
          jsonb_set(t.item,'{id}',to_jsonb(t.resolved_id),true)
        )
      end as payload,
      row_number() over(
        partition by t.resolved_id
        order by case when t.is_canonical then 0 else 1 end,t.ord
      ) as rn
    from team_candidates t
    left join futbeat_private.entities e
      on e.id=t.resolved_id and e.kind='team'
  ),
  teams as (
    select coalesce(
      jsonb_agg(payload order by ord),
      '[]'::jsonb
    ) as value
    from team_ranked
    where rn=1
  ),
  matches as (
    select coalesce(
      jsonb_agg(
        jsonb_set(
          jsonb_set(
            jsonb_set(
              x.item,
              '{competitionId}',
              to_jsonb(
                futbeat_private.futbeat_resolve_entity_id(
                  'competition',x.item->>'competitionId'
                )
              ),
              true
            ),
            '{homeTeamId}',
            to_jsonb(
              futbeat_private.futbeat_resolve_entity_id(
                'team',x.item->>'homeTeamId'
              )
            ),
            true
          ),
          '{awayTeamId}',
          to_jsonb(
            futbeat_private.futbeat_resolve_entity_id(
              'team',x.item->>'awayTeamId'
            )
          ),
          true
        )
        order by x.ordinality
      ),
      '[]'::jsonb
    ) as value
    from jsonb_array_elements(
      coalesce(p_snapshot->'matches','[]'::jsonb)
    ) with ordinality x(item,ordinality)
  ),
  players as (
    select coalesce(
      jsonb_agg(
        case
          when nullif(x.item->>'teamId','') is null then x.item
          else jsonb_set(
            x.item,
            '{teamId}',
            to_jsonb(
              futbeat_private.futbeat_resolve_entity_id(
                'team',x.item->>'teamId'
              )
            ),
            true
          )
        end
        order by x.ordinality
      ),
      '[]'::jsonb
    ) as value
    from jsonb_array_elements(
      coalesce(p_snapshot->'players','[]'::jsonb)
    ) with ordinality x(item,ordinality)
  ),
  standings_candidates as (
    select
      x.ordinality::integer as ord,
      futbeat_private.futbeat_resolve_entity_id(
        'competition',x.item->>'competitionId'
      ) as competition_id,
      jsonb_set(
        x.item,
        '{competitionId}',
        to_jsonb(
          futbeat_private.futbeat_resolve_entity_id(
            'competition',x.item->>'competitionId'
          )
        ),
        true
      ) as payload
    from jsonb_array_elements(
      coalesce(p_snapshot->'standings','[]'::jsonb)
    ) with ordinality x(item,ordinality)
  ),
  standings_normalized as (
    select
      s.ord,
      s.competition_id,
      jsonb_set(
        s.payload,
        '{rows}',
        coalesce((
          select jsonb_agg(
            case
              when nullif(row.value->>'teamId','') is null then row.value
              else jsonb_set(
                row.value,
                '{teamId}',
                to_jsonb(
                  futbeat_private.futbeat_resolve_entity_id(
                    'team',row.value->>'teamId'
                  )
                ),
                true
              )
            end
            order by row.ordinality
          )
          from jsonb_array_elements(
            coalesce(s.payload->'rows','[]'::jsonb)
          ) with ordinality row(value,ordinality)
        ),'[]'::jsonb),
        true
      ) as payload
    from standings_candidates s
  ),
  standings_ranked as (
    select
      ord,
      competition_id,
      payload,
      row_number() over(
        partition by competition_id
        order by jsonb_array_length(
          coalesce(payload->'rows','[]'::jsonb)
        ) desc,ord
      ) as rn
    from standings_normalized
  ),
  standings as (
    select coalesce(
      jsonb_agg(payload order by ord),
      '[]'::jsonb
    ) as value
    from standings_ranked
    where rn=1
  )
  select
    (
      p_snapshot
      -'competitions'
      -'teams'
      -'players'
      -'matches'
      -'standings'
      -'entityRedirects'
    )
    || jsonb_build_object(
      'competitions',competitions.value,
      'teams',teams.value,
      'players',players.value,
      'matches',matches.value,
      'standings',standings.value,
      'entityRedirects',redirect_json.value
    )
  from competitions,teams,players,matches,standings,redirect_json
$fn$;

-- Provider identity resolution must never recreate a known alias.
create or replace function futbeat_private.futbeat_resolve_global_entity(
  p_provider text,
  p_kind text,
  p_external text,
  p_name text default '',
  p_country text default '',
  p_short_name text default ''
) returns text
language plpgsql
security definer
set search_path=''
as $fn$
declare
  result text;
  matched text;
  matches integer;
begin
  if p_provider not in ('sofascore','espn','goal_api')
     or p_kind not in ('competition','team','match','player')
     or nullif(p_external,'') is null
  then
    raise exception 'Invalid global provider identity';
  end if;

  select canonical_id into result
  from futbeat_private.provider_entities
  where provider=p_provider
    and kind=p_kind
    and external_id=p_external;

  if result is not null then
    return futbeat_private.futbeat_resolve_entity_id(p_kind,result);
  end if;

  if p_kind in ('competition','team') and nullif(p_name,'') is not null then
    select count(*),min(e.id)
    into matches,matched
    from futbeat_private.entities e
    where e.kind=p_kind
      and not exists(
        select 1
        from futbeat_private.entity_redirects r
        where r.alias_id=e.id and r.kind=p_kind
      )
      and (
        lower(coalesce(e.payload->>'name',''))=lower(p_name)
        or (
          nullif(p_short_name,'') is not null
          and lower(coalesce(e.payload->>'shortName',''))=lower(p_short_name)
        )
        or exists(
          select 1
          from jsonb_array_elements_text(
            coalesce(e.payload->'aliases','[]'::jsonb)
          ) a(value)
          where lower(a.value)=lower(p_name)
        )
      )
      and (
        nullif(p_country,'') is null
        or nullif(e.payload->>'country','') is null
        or lower(e.payload->>'country')=lower(p_country)
      );

    if matches=1 then
      result:=futbeat_private.futbeat_resolve_entity_id(p_kind,matched);
    end if;
  end if;

  if result is null then
    result:='fb_' || p_kind || '_' || replace(gen_random_uuid()::text,'-','');
    insert into futbeat_private.entities(id,kind,payload)
    values(
      result,
      p_kind,
      jsonb_build_object(
        'id',result,
        'name',coalesce(p_name,''),
        'country',coalesce(p_country,''),
        'shortName',coalesce(p_short_name,'')
      )
    )
    on conflict(id) do nothing;
  end if;

  insert into futbeat_private.provider_entities(
    provider,kind,external_id,canonical_id
  )
  values(p_provider,p_kind,p_external,result)
  on conflict(provider,kind,external_id)
  do update set canonical_id=excluded.canonical_id;

  return result;
end
$fn$;

-- Old entity ids in user actions resolve before persistence.
create or replace function futbeat_private.futbeat_set_push_follow(
  p_type text,
  p_id text,
  p_follow boolean
) returns void
language plpgsql
security definer
set search_path=''
as $fn$
declare
  uid uuid;
  resolved_id text;
begin
  uid:=auth.uid();
  if uid is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;

  resolved_id:=futbeat_private.futbeat_resolve_entity_id(p_type,p_id);
  if p_type not in ('team','match')
     or not exists(
       select 1 from futbeat_private.entities
       where id=resolved_id and kind=p_type
     )
  then
    raise exception 'Unknown canonical entity';
  end if;

  if p_follow then
    insert into futbeat_private.push_follows
    values(uid,p_type,resolved_id,now())
    on conflict do nothing;
  else
    delete from futbeat_private.push_follows
    where user_id=uid
      and entity_type=p_type
      and entity_id=resolved_id;
  end if;
end
$fn$;

create or replace function futbeat_private.touch_temporary_interest(
  p_type text,
  p_id text,
  p_ttl_minutes integer default 30
) returns void
language plpgsql
security definer
set search_path=''
as $fn$
declare
  uid uuid:=auth.uid();
  expiry timestamptz;
  resolved_id text;
begin
  if uid is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;

  resolved_id:=futbeat_private.futbeat_resolve_entity_id(p_type,p_id);
  if p_type not in ('team','player','competition','match')
     or not exists(
       select 1 from futbeat_private.entities
       where id=resolved_id and kind=p_type
     )
  then
    raise exception 'Unknown canonical entity';
  end if;

  expiry:=now()+make_interval(
    mins=>least(greatest(p_ttl_minutes,5),120)
  );

  insert into futbeat_private.temporary_interests
  values(uid,p_type,resolved_id,now(),expiry)
  on conflict(user_id,entity_type,entity_id) do update
  set touched_at=now(),expires_at=expiry;

  perform futbeat_private.refresh_interest_aggregates();
end
$fn$;

create or replace function futbeat_private.sync_push_follows(
  p_follows jsonb
) returns void
language plpgsql
security definer
set search_path=''
as $fn$
declare
  uid uuid;
  item jsonb;
  normalized jsonb:='[]'::jsonb;
  resolved_id text;
  entity_type text;
begin
  uid:=auth.uid();
  if uid is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;
  if jsonb_typeof(p_follows) is distinct from 'array'
     or jsonb_array_length(p_follows)>500
  then
    raise exception 'Invalid follows';
  end if;

  perform pg_advisory_xact_lock(hashtext('push-follows:'||uid::text));

  for item in select value from jsonb_array_elements(p_follows)
  loop
    entity_type:=item->>'type';
    resolved_id:=futbeat_private.futbeat_resolve_entity_id(
      entity_type,item->>'id'
    );

    if entity_type in ('team','player','competition','match')
       and exists(
         select 1 from futbeat_private.entities
         where id=resolved_id and kind=entity_type
       )
    then
      normalized:=normalized || jsonb_build_array(
        jsonb_build_object('type',entity_type,'id',resolved_id)
      );
    end if;
  end loop;

  delete from futbeat_private.push_follows f
  where f.user_id=uid
    and not exists(
      select 1
      from jsonb_array_elements(normalized) e
      where e->>'type'=f.entity_type
        and e->>'id'=f.entity_id
    );

  for item in select value from jsonb_array_elements(normalized)
  loop
    insert into futbeat_private.push_follows
    values(uid,item->>'type',item->>'id',now())
    on conflict do nothing;
  end loop;

  perform futbeat_private.refresh_interest_aggregates();
end
$fn$;

-- Read surfaces canonicalize aliases without mutating historical imports.
create or replace function public.futbeat_read_snapshot()
returns jsonb
language sql
stable
set search_path=''
as $fn$
  with latest as (
    select
      futbeat_private.futbeat_apply_entity_redirects_snapshot(snapshot)
        as snapshot,
      received_at
    from futbeat_private.imports
    order by received_at desc,job_id desc
    limit 1
  ),
  merged_standings as (
    select coalesce(jsonb_agg(item),'[]'::jsonb) as value
    from (
      select legacy.value as item
      from latest
      cross join lateral jsonb_array_elements(
        coalesce(latest.snapshot->'standings','[]'::jsonb)
      ) legacy
      where not exists(
        select 1
        from futbeat_private.standings_cache sc
        where sc.competition_id=legacy.value->>'competitionId'
      )

      union all

      select futbeat_private.futbeat_apply_provisional_standings(
        sc.table_payload,
        sc.fetched_at
      )
      from futbeat_private.standings_cache sc
      where exists(
        select 1
        from latest
        cross join lateral jsonb_array_elements(
          coalesce(latest.snapshot->'competitions','[]'::jsonb)
        ) competition
        where competition.value->>'id'=sc.competition_id
      )
    ) all_tables(item)
  )
  select
    (snapshot-'standings'-'freshness')
    || jsonb_build_object(
      'standings',merged_standings.value,
      'freshness',jsonb_build_object(
        'stale',
        coalesce((snapshot->>'updatedAt')::timestamptz,received_at)
          < now()-interval '6 hours'
      )
    )
  from latest,merged_standings
$fn$;

create or replace function public.futbeat_read_entity_detail(
  p_type text,
  p_id text
) returns jsonb
language sql
stable
security definer
set search_path=''
as $fn$
  with request as (
    select futbeat_private.futbeat_resolve_entity_id(
      p_type,p_id
    ) as resolved_id
  ),
  base as (
    select
      futbeat_private.futbeat_read_entity_detail(
        p_type,request.resolved_id
      ) as snapshot,
      request.resolved_id
    from request
  ),
  competition_ids as (
    select distinct value->>'competitionId' as id
    from base
    cross join lateral jsonb_array_elements(
      coalesce(base.snapshot->'matches','[]'::jsonb)
    )
    where nullif(value->>'competitionId','') is not null

    union

    select distinct value->>'id'
    from base
    cross join lateral jsonb_array_elements(
      coalesce(base.snapshot->'competitions','[]'::jsonb)
    )
    where nullif(value->>'id','') is not null

    union

    select resolved_id from base where p_type='competition'
  ),
  tables as (
    select coalesce(jsonb_agg(item),'[]'::jsonb) as value
    from (
      select legacy.value as item
      from base
      cross join lateral jsonb_array_elements(
        coalesce(base.snapshot->'standings','[]'::jsonb)
      ) legacy
      where legacy.value->>'competitionId' in (
        select id from competition_ids where id is not null
      )
      and not exists(
        select 1
        from futbeat_private.standings_cache sc
        where sc.competition_id=legacy.value->>'competitionId'
      )

      union all

      select futbeat_private.futbeat_apply_provisional_standings(
        sc.table_payload,
        sc.fetched_at
      )
      from futbeat_private.standings_cache sc
      where sc.competition_id in (
        select id from competition_ids where id is not null
      )
    ) selected_tables(item)
  ),
  assembled as (
    select case
      when base.snapshot is null then null
      else (base.snapshot-'standings')
        || jsonb_build_object('standings',tables.value)
    end as snapshot
    from base,tables
  )
  select case
    when snapshot is null then null
    else futbeat_private.futbeat_apply_entity_redirects_snapshot(snapshot)
  end
  from assembled
$fn$;

create or replace function public.futbeat_read_calendar_range(
  p_from_date date,
  p_to_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb
language sql
stable
security definer
set search_path=''
as $fn$
  select futbeat_private.futbeat_apply_entity_redirects_snapshot(
    futbeat_private.futbeat_read_calendar_range(
      p_from_date,p_to_date,p_timezone
    )
  )
$fn$;

-- Register only aliases with verified, unambiguous evidence.
select futbeat_private.futbeat_register_entity_redirect(
  'competition',
  'fb_comp_cr',
  'fb_competition_3e03182862764420947393642a407616',
  'TheSportsDB Liga FPD legacy id maps to current Costa Rica Primera División'
);

select futbeat_private.futbeat_register_entity_redirect(
  'competition',
  'fb_competition_0c2ab7abd95d4c08923e66d3752bfe9f',
  'fb_competition_3e03182862764420947393642a407616',
  'Obsolete GOAL seed entity for Costa Rica Primera División'
);

-- The synthetic seed external id is not a real GOAL league identity and must
-- not compete with the real provider league id in standings scheduling.
delete from futbeat_private.provider_entities
where provider='goal_api'
  and kind='competition'
  and external_id='goal_league_cr';

select futbeat_private.futbeat_register_entity_redirect(
  'team',
  'fb_team_2735d91a74b1454d98a5835fd16791c3',
  'fb_team_7b79bed52b934a9fa04bcb48a62c32cf',
  'TheSportsDB Inter de San Carlos is the same club as GOAL Inter San Carlos'
);

revoke all on function
  futbeat_private.futbeat_resolve_entity_id(text,text),
  futbeat_private.futbeat_register_entity_redirect(text,text,text,text),
  futbeat_private.futbeat_apply_entity_redirects_snapshot(jsonb)
from public,anon,authenticated;

grant execute on function
  futbeat_private.futbeat_resolve_entity_id(text,text),
  futbeat_private.futbeat_register_entity_redirect(text,text,text,text),
  futbeat_private.futbeat_apply_entity_redirects_snapshot(jsonb)
to service_role;

revoke all on function
  public.futbeat_read_snapshot(),
  public.futbeat_read_entity_detail(text,text),
  public.futbeat_read_calendar_range(date,date,text)
from public,anon,authenticated;

grant execute on function
  public.futbeat_read_snapshot(),
  public.futbeat_read_entity_detail(text,text),
  public.futbeat_read_calendar_range(date,date,text)
to service_role;

notify pgrst,'reload schema';
