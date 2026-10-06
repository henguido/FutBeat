# Lineup History Data Contract

## Purpose

This contract supplies verified historical lineups to the Flutter app. The app does not fetch, infer, or predict this data. A future repository adapter will map the backend response into the pure `LineupHistoryEntry` model.

An empty result means that the section stays hidden. Missing coverage must not be represented as a confirmed empty history unless the backend can prove it.

## Response scope

The response must be scoped to one canonical team and ordered newest first. Five recent matches are sufficient for V1. Every record must describe an observed lineup for that team, not a generated probable XI.

## Required entry fields

| Field | Type | Rule |
|---|---|---|
| `matchId` | string | Canonical FutBeat match ID. |
| `teamId` | string | Canonical ID of the lineup's team. |
| `opponent.id` | string | Canonical opponent ID. |
| `opponent.name` | string | Display name at response time. |
| `kickoff` | ISO-8601 UTC | Must include an offset or `Z`. |
| `competition` | string | Display name; no inferred competition. |
| `homeAway` | `home` or `away` | Perspective of `teamId`. |
| `result` | nullable string | Verified score/result label; null when absent. |
| `formation` | nullable string | Provider formation; null when absent. |
| `starters` | array | May be empty when coverage is partial. |
| `substitutes` | array | May be empty. |
| `coach` | nullable string | Observed coach for that match. |
| `captainPlayerId` | nullable string | Must refer to a listed canonical player. |
| `substitutions` | array | Observed substitutions only. |
| `lineupStatus` | enum | `unknown`, `predicted`, `provisional`, `confirmed`. |

## Player fields

Each starter, substitute, and substitution participant needs:

- `id`: canonical player ID when resolved; nullable while unresolved;
- `name`: required non-empty display name;
- optional `shirtNumber`;
- optional provider `position`;
- optional observed `minutes`;
- optional `rating`.

Missing IDs must not be synthesized from names. The mobile summarizer uses a normalized name only as a local deduplication fallback and never persists it as identity.

## Substitution fields

- `playerOut`;
- `playerIn`;
- optional observed `minute`.

The backend must not infer a substitution from minutes alone.

## Status semantics

- `unknown`: default and mandatory fallback.
- `predicted`: explicitly predicted by the source; never treated as official.
- `provisional`: explicitly provisional provider data.
- `confirmed`: only when the upstream provider explicitly confirms the lineup.

Existing match-detail data must not automatically map to `confirmed`. The adapter must preserve `unknown` unless explicit evidence is present.

## Ordering, limits, and partial coverage

- Return newest first with deterministic `matchId` tie-breaking.
- Prefer at most five recent entries per team for the preview surface.
- Preserve missing optional fields as null or empty arrays.
- Do not insert placeholder players, formations, minutes, coaches or captains.
- Duplicate players within one lineup should be rejected or deduplicated by canonical ID before delivery.
- Include a separate coverage state in the future transport contract if the backend needs to distinguish pending, unavailable and confirmed-empty data.

## Mobile integration seam

Flutter currently exposes `lineupHistoryProvider(matchId, teamId)`, which returns an empty immutable list and performs no I/O. The future repository can populate this seam after mapping its DTO through a `LineupHistoryAdapter`. `LineupHistorySection` renders only non-empty lists.
