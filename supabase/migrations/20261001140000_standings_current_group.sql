-- Current phase of a multi-phase standings table (`currentGroup`).
--
-- Some leagues are stored with several tables for the same teams: the annual
-- aggregate (rows without `group`) plus one labelled table per phase (e.g. a
-- first and a second half of the season). The app cannot tell which phase is
-- being played from the rows alone (no per-group timestamp, no form).
--
-- Evidence used (generic, no league or phase name is special-cased): the GOAL
-- match detail of every match of the competition that started in the 21 days
-- up to the table's own fetched_at carries `stageName`. A stage names a group
-- when the group label's normalized tokens (lower case, accents folded,
-- split on non-alphanumerics) are all contained in the stage's tokens and no
-- other label of the table matches that stage. When every recent stage names
-- exactly one label and they all name the SAME one, the table carries
-- `currentGroup: <label>`. Any disagreement (parallel groups played on the
-- same days, e.g. "League A" + "League D"), a recent stage naming no label
-- (e.g. "Group Stage" next to "League A/B/C"), no evidence, or a
-- single-group table: no `currentGroup` (the app keeps its fail-closed rule).
-- Production check (2026-10-01, read-only): Primera A (unlabelled + Apertura
-- + Clausura, 19 recent details all "Clausura") -> "Clausura"; UEFA Nations
-- League (League A-D played in parallel) -> none; Concacaf Nations League
-- ("Group Stage" + "League A"/"League B") -> none.
--
-- Applied by a BEFORE trigger on standings_cache, so every writer (and the
-- standings_snapshots archive, an AFTER trigger) gets it. The hint never
-- breaks a store: any error leaves the table without it. Additive key: older
-- app versions ignore it.

create or replace function futbeat_private.standings_label_tokens(p_text text)
returns text[]
language sql
immutable
set search_path=''
as $$
  select coalesce(array_agg(distinct token), '{}'::text[])
  from regexp_split_to_table(
    translate(
      lower(coalesce(p_text, '')),
      'áàâäãåéèêëíìîïóòôöõúùûüñç',
      'aaaaaaeeeeiiiiooooouuuunc'
    ),
    '[^a-z0-9]+'
  ) token
  where token <> ''
$$;

create or replace function futbeat_private.standings_current_group(
  p_competition_id text,
  p_table jsonb,
  p_at timestamptz
) returns text
language plpgsql
stable
set search_path=''
as $$
declare
  labels text[];
  has_unlabelled boolean;
  picks text[];
begin
  if p_competition_id is null or p_at is null
     or jsonb_typeof(p_table) <> 'object'
     or jsonb_typeof(p_table->'rows') <> 'array' then
    return null;
  end if;

  select
    coalesce(array_agg(distinct btrim(r->>'group'))
      filter (where nullif(btrim(r->>'group'), '') is not null), '{}'::text[]),
    bool_or(nullif(btrim(r->>'group'), '') is null)
  into labels, has_unlabelled
  from jsonb_array_elements(p_table->'rows') r;

  -- Only a table with several groups needs a current one.
  if (cardinality(labels) + coalesce(has_unlabelled, false)::integer) < 2 then
    return null;
  end if;

  with recent as (
    select distinct futbeat_private.standings_label_tokens(c.payload->>'stageName') tokens
    from futbeat_private.entities e
    join futbeat_private.match_detail_cache c on c.match_id = e.id
    where e.kind = 'match'
      and e.payload->>'competitionId' = p_competition_id
      and nullif(btrim(c.payload->>'stageName'), '') is not null
      and e.payload->>'startTime' ~ '^\d{4}-\d{2}-\d{2}T'
      and (e.payload->>'startTime')::timestamptz <= p_at
      and (e.payload->>'startTime')::timestamptz > p_at - interval '21 days'
  ), named as (
    -- The labels each distinct recent stage names.
    select r.tokens,
      array_agg(distinct l) filter (
        where cardinality(futbeat_private.standings_label_tokens(l)) > 0
          and futbeat_private.standings_label_tokens(l) <@ r.tokens
      ) matched
    from recent r
    cross join unnest(labels) l
    group by r.tokens
  )
  -- '' for a stage that names no label or several: it disagrees.
  select array_agg(distinct
    case when cardinality(matched) = 1 then matched[1] else '' end)
  into picks
  from named;

  -- Every recent stage names the same single label.
  return case
    when cardinality(picks) = 1 and picks[1] <> '' then picks[1]
  end;
exception when others then
  return null;
end
$$;

create or replace function futbeat_private.standings_current_group_hint()
returns trigger
language plpgsql
set search_path=''
as $$
declare
  hint text;
begin
  if jsonb_typeof(new.table_payload) <> 'object' then
    return new;
  end if;
  -- Recomputed on every write: a stale hint never survives a new table.
  new.table_payload := new.table_payload - 'currentGroup';
  hint := futbeat_private.standings_current_group(
    new.competition_id, new.table_payload, new.fetched_at);
  if hint is not null then
    new.table_payload := new.table_payload
      || jsonb_build_object('currentGroup', hint);
  end if;
  return new;
end
$$;

revoke all on function futbeat_private.standings_label_tokens(text)
  from public, anon, authenticated;
revoke all on function futbeat_private.standings_current_group(text, jsonb, timestamptz)
  from public, anon, authenticated;
revoke all on function futbeat_private.standings_current_group_hint()
  from public, anon, authenticated;

drop trigger if exists standings_current_group_hint on futbeat_private.standings_cache;
create trigger standings_current_group_hint
before insert or update of table_payload, fetched_at on futbeat_private.standings_cache
for each row execute function futbeat_private.standings_current_group_hint();

-- Tables already stored with several groups get their hint now (no provider
-- calls; same payload otherwise).
update futbeat_private.standings_cache sc
set table_payload = sc.table_payload
where sc.table_payload->>'grouped' = 'true';
