# Live terminal recovery (#120)

## Problem

A finished match could keep showing LIVE / EN VIVO (or fall back to a
pre-match look) because FutBeat never received its terminal state.

`live_match_state` is fed only by `/fixtures/live` polls and by detail
fetches. Proven gaps in code:

- `syncLive` persisted only what the feed returned; a match that dropped out
  of `/fixtures/live` before one FT observation was captured produced no
  signal at all.
- Results-by-date reconciliation only covers provider dates **before** UTC
  today (every 2 h, 6 h recheck gap), so "today" finals are not covered.
- After LIVE evidence ages out the detail planner files the match as
  `recent_hot`: one post-match fetch at kickoff + 2 h, otherwise only missing
  sections. While the feed still says LIVE, the live bucket is capped
  (`plannerMaxLiveFetches`) and refreshes every 30 min only in comfortable
  quota bands.
- The read model dropped ABANDONED / SUSPENDED evidence from observations and
  detail (only finals or fresh LIVE counted).

The clock is never used to declare a final.

## Fix (migration `20260926100000_live_terminal_recovery.sql`)

- `futbeat_note_live_poll(provider, seen, from_start, reached_end)` — called
  by the worker after each persisted live poll.
  - A **sweep** is offset 0 → last page, possibly across polls (a poll
    truncated by the page budget / reserve is resumed by the next one). Seen
    ids are unioned per sweep (`live_poll_sweep`, max `liveSweepMaxMinutes`
    20); absence is evaluated only when a sweep finishes. A resumed tail
    without its start, or an expired sweep, never counts.
  - LIVE-family matches (mapped, seen in the last
    `terminalRecoveryWindowHours`, not effectively terminal, not already
    tracked) absent from a finished sweep → recovery row `absent_from_live`.
  - Matches still LIVE in the feed `overdueLiveMinutes` (150) after kickoff →
    recovery row `overdue_live` (provider stuck at 90').
  - An absent match that reappears → row `CANCELLED` (`reappeared`).
- `futbeat_reserve_terminal_recovery_call` — served first by
  `syncOneMatchDetail`: one `/fixtures/{id}` call under the protected
  `results` quota class and the `match-detail` kind cap, per-match inflight
  lock, backoff 1 min → 2, 4, 8, 16, 30 min, max
  `terminalRecoveryMaxAttempts` (6) then `EXHAUSTED`; a row that can no
  longer be served expires after the window.
- The fetched detail goes through the normal pipeline
  (`futbeat_store_match_detail` + `futbeat_record_live_batch`), so a provider
  FINISHED becomes FINISHED_PENDING_VERIFICATION + FULL_TIME via the existing
  code. `futbeat_complete_terminal_recovery` stores the raw provider status
  and settles the row once the match is effectively terminal.
- Read model: the newest in-play stop from the provider (ABANDONED,
  SUSPENDED) replaces an older LIVE; finals still outrank all. The newest
  row is chosen first and a LIVE one only counts while fresh, so an older
  SUSPENDED never outlives a later LIVE that went silent. Evidence older
  than the kickoff stays ignored. POSTPONED / CANCELLED stay with the results
  reconciliation (it checks reschedule provenance); a recovery fetch that gets
  one of them just stops retrying (`provider_postponed` / `provider_cancelled`).

Cost: at most 6 detail calls per affected match, only for matches that
actually lost their LIVE feed or overran; no mobile calls, no new cron.
Recovery calls are ledgered with `bucket='recovery'`, `source='recovery'`;
the detail planner counts them as their own phase, so they never consume the
per-match post-match budget.

Tuning keys (`provider_quota_policy.freshness`, defaults in code):
`terminalRecoveryWindowHours` 6, `overdueLiveMinutes` 150,
`terminalRecoveryFirstDelaySeconds` 60, `terminalRecoveryMaxAttempts` 6.

Mobile (0aa7bf6 + follow-up): a LIVE overlay received more than 15 min ago
(device clock, receipt time — immune to device/server skew) no longer
overrides the canonical snapshot, and Match Center re-reads the canonical
context on a finite schedule while the shown match is LIVE but silent.

## Known residual risks

- ABANDONED from any source is terminal (`is_terminal_match_status`): later
  LIVE observations for the same fixture id and kickoff are suppressed. A
  fixture replayed with a new kickoff is safe (evidence before kickoff is
  ignored).
- If a live poll lands while a recovery detail call for a match still in
  the feed is running, the detail's older `fetchedAt` hits the existing
  "Stale live batch" guard and that attempt is recorded as failed (the
  detail itself is stored). Pre-existing behaviour of every detail fetch;
  the next attempt retries.
- `liveDataStale` (Match Center re-read trigger) still compares device time
  with the server's `liveChangedAt`; a badly skewed device only costs the
  bounded 5 re-reads per open.

## Diagnosis in production (read-only)

Not run during development. To confirm which path left a QA match LIVE
(replace `:match_id` with its canonical id):

```sql
select status,minute,home_score,away_score,first_seen_at,last_seen_at
from futbeat_private.live_match_state where canonical_match_id=:match_id;

select status,minute,received_at from futbeat_private.provider_observations
where canonical_match_id=:match_id order by received_at desc limit 10;

select fetched_at,payload->>'matchStatus' status,payload->>'matchPeriod' period
from futbeat_private.match_detail_cache where match_id=:match_id;

select event_type,first_seen_at from futbeat_private.canonical_events
where match_id=:match_id and event_type='FULL_TIME';

select reserved_at,call_kind,metadata->>'bucket' bucket,metadata->>'source' source
from futbeat_private.provider_call_ledger
where metadata->>'matchId'=:match_id order by reserved_at desc limit 20;
```

- `last_seen_at` frozen shortly after the real end and no FT anywhere →
  dropped out of the feed (`absent_from_live`).
- `last_seen_at` keeps advancing with LIVE and minute ≈ 90 → provider kept
  it LIVE (`overdue_live`).
- `match_detail_cache` has an unexpected `matchStatus` → GOAL vocabulary
  gap; after deploy `futbeat_terminal_recovery_status()` lists exhausted rows
  with their `lastProviderStatus`.

## Deploy (not done)

Apply the migration manually (no `db push`), then deploy
`futbeat-goal-live-sync`. The worker tolerates the migration being absent
(recovery RPC errors are logged and skipped), but the migration should go
first.
