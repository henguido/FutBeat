# Team profile completeness (#150, #111)

Club and national-team profiles: matches, lifecycle, squad and standings.
Migration: `supabase/migrations/20260929100000_team_profile_completeness.sql`.

**Scope.** This fixes the profile READ MODEL and its correctness. It pages
every match ALREADY STORED in FutBeat; it cannot show historical or future
matches that were never ingested. Per-team match coverage / ingestion is a
separate, pending piece of work (#150 stays open for it).

## Matches

- `GET /v1/team-matches?id=&bucket=live|upcoming|results&cursor=&limit=` →
  `public.futbeat_read_team_matches(team, bucket, cursor, limit)`.
- Identity is the canonical team id plus every alias redirected to it; never
  a name. Every competition is included.
- Every row goes through `match_read_model` (effective status), then
  `team_match_bucket`:
  - `live`: effective LIVE / HALFTIME / EXTRA_TIME / PENALTIES. Ascending.
  - `upcoming`: not started — future kickoff, or inside the 15-minute start
    grace while the start is reconciled. Ascending.
  - `results`: everything else — finished, postponed, cancelled,
    suspended/abandoned, and a past kickoff still reported as SCHEDULED with
    no terminal evidence ("Por confirmar"). Descending.
- The three buckets partition the team's matches: each match is in exactly
  one. Keyset pagination: `nextCursor` = `<startTime>|<matchId>`; `hasMore`.
- Nothing is invented: a stale match keeps its status and has no score.
- App sections: "En vivo" (only when a match is in play), "Próximos",
  "Resultados". The profile's own matches (entity detail, also through
  `match_read_model`) render first (cache-first) until the pages arrive.
- Indexes `entities_match_home_team_idx` / `entities_match_away_team_idx`
  (first created by 20260925060000) are restated idempotently.

## Squad

`coverage.squad.state` on the team entity detail:

| State | Meaning | App |
|---|---|---|
| AVAILABLE | players, snapshot < 7 days | players |
| STALE | players, snapshot ≥ 7 days (shown while revalidated) | players |
| PENDING | a source exists, no valid answer yet: never fetched, in flight, retrying, expired NO_DATA | "Plantilla pendiente" |
| CONFIRMED_EMPTY | the source was queried and validly answered "no squad" (NO_DATA still valid) | "Plantilla no disponible" |
| UNAVAILABLE | no usable provider source/mapping (nothing proves it is empty) | "Plantilla no disponible" |

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
- Team profile table (`teamTableCompetitionId`), deterministic: the team's
  main competition (`team.competitionId`) when its table contains the team;
  otherwise the only table containing it; several candidates and no main
  signal → no Tabla tab. Match Center keeps its exact competition + season
  table (`standings_snapshots`).

## Known limits

- Coverage: only stored matches are listed (see Scope).
- Tables stored before this migration have no position/group until their
  next refresh.
- The GOAL group field names are not verified against a captured response;
  the repeated-position check is the safety net.
