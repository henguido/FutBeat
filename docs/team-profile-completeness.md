# Team profile completeness (#150, #111)

Club and national-team profiles: matches, lifecycle, squad and standings.
Migration: `supabase/migrations/20260929100000_team_profile_completeness.sql`.

## Matches

- `GET /v1/team-matches?id=&bucket=upcoming|results&cursor=&limit=` →
  `public.futbeat_read_team_matches(team, bucket, cursor, limit)`.
- Identity is the canonical team id plus every alias redirected to it; never
  a name. Every competition is included.
- Every row goes through `match_read_model` (effective status), then
  `team_match_bucket`:
  - `upcoming`: in play, or not started (kickoff + 15 min grace). Ascending.
  - `results`: everything else — finished, postponed, cancelled,
    suspended/abandoned, and a past kickoff still reported as SCHEDULED with
    no terminal evidence (awaiting verification). Descending.
- Keyset pagination: `nextCursor` = `<startTime>|<matchId>`; `hasMore`.
  Nothing is invented: a stale match keeps its status and has no score.
- The entity detail also applies `match_read_model` to its own matches. The
  app renders them first (cache-first) until the first page arrives.

## Squad

`coverage.squad.state` on the team entity detail:

| State | Meaning | App |
|---|---|---|
| AVAILABLE | players, snapshot < 7 days | players |
| STALE | players, snapshot ≥ 7 days (shown while revalidated) | players |
| PENDING | never fetched, in flight, retrying, expired NO_DATA | "Plantilla pendiente" |
| CONFIRMED_EMPTY | provider NO_DATA still valid, or no provider source | "Plantilla no disponible" |

Opening a team calls `futbeat_request_team_squad`: when PENDING or STALE it
upserts ONE row per canonical team in `team_squad_demands` (writes throttled
to one a minute). The existing squad planner gains tier 6 `requested`
(priority 45000, after favorites); the demand is consumed by the next
reservation attempt. Eligibility, mapping, freshness, backoff, lease and
quota are unchanged. No provider call from the API or the app.

## Standings

- The store keeps `position` and an optional `group` label (group/stage
  fields when the provider sends them), dedupes per (group, team) and keeps
  groups contiguous. `groupsResolved=false` when one group repeats a
  position (several unlabelled groups sent together).
- The provisional overlay only applies a match when both teams are in the
  same group and re-ranks inside the group.
- The entity detail carries the team entity of every standings row.
- App (`standingsGroups`): a table is not shown ("Tabla no disponible") when
  a row's team is unknown, groups are unresolved or positions repeat. Match
  Center shows the match's group; a team profile its own group; a
  competition every group as its own table. Never the "Equipo" placeholder.

## Known limits

- Tables stored before this migration have no position/group until their
  next refresh.
- The GOAL group field names are not verified against a captured response;
  the repeated-position check is the safety net.
- Profiles only contain matches that were ingested (calendar windows and
  on-demand dates); there is no per-team fixtures ingestion.
