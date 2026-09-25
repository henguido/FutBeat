# Match Center preview: recent form + head-to-head (#99 phase 2)

A separate DB-only read model, so `futbeat_read_match_context` stays light:
`GET /v1/match-preview?id=<fb_match_…>` → `public.futbeat_read_match_preview`
(service-only). It never registers demand, wakes the worker or calls a
provider.

## Rules (canonical ids only, never names)

- **Form**: per side, up to 5 terminal matches (`FINISHED_PENDING_VERIFICATION`
  / `VERIFIED`) kicked off before the **target's** kickoff (not `now()`), within
  365 days. `state`: `available` (5), `partial` (1–4), `none` (0).
- **Result** (`team_match_result` / Flutter `teamMatchResult`): WIN / DRAW /
  LOSS from the team's side, only with a complete score.
- **H2H**: up to 5 terminal meetings of exactly the two team ids, both
  orientations, any competition, before the target's kickoff. `state`:
  `available` / `none`; `summary` from the target home team's perspective.
- Each match appears once in `matches` (no events, lineups or statistics),
  plus the `teams` and `competitions` it references. Typically a few KB.

## Indexes

`entities_match_home_team_idx` and `entities_match_away_team_idx`: partial
expression indexes on `payload->>'homeTeamId'` / `'awayTeamId'` where
`kind='match'` (same shape as `entities_match_competition_idx`). "Matches of
team X" is a BitmapOr of two index lookups; a team has at most a few hundred
stored matches, sorted by kickoff in memory.

## Mobile

- `matchPreviewProvider`: loaded after the match context, never blocks the
  header or tabs, one read per open (no polling, no automatic retry; tab
  switches and context refreshes do not re-read it). Retained 1 minute like
  the context.
- Tabs: Previa · Estadísticas · Alineación · Tabla · Cara a cara (5, fixed).
- Previa: "Forma reciente" (oldest → newest, left to right, so each row ends
  with the latest result) and the two sides' rows of the already loaded
  table ("Posición en la tabla", or "Tabla de la temporada" for a finished
  match). No empty events card before kickoff.
- Cara a cara: summary of "Últimos enfrentamientos registrados" and up to 5
  meetings; empty → "Sin enfrentamientos previos registrados" (never "never
  played"); failure → quiet message with a manual "Reintentar".
