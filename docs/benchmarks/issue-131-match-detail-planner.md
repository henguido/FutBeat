# Issue #131 — Match Detail planner scale benchmark

## Scope and safety

This benchmark runs only against an ephemeral in-memory PGlite database. It
applies the repository migrations and creates generic synthetic records. It
does not read production data, credentials or environment variables, call a
provider, deploy an Edge Function, or apply a remote migration.

The effective target is **8 seconds**: Supabase `service_role` has no explicit
default of its own and therefore inherits the PostgREST `authenticator` timeout
of 8 seconds when unset. The harness also sets `statement_timeout = '8s'`
inside every measured transaction.

Run:

```text
node backend/bench/match_detail_planner_scale.mjs
```

## Current call path

`public.futbeat_enqueue_stale_live_detail()` calls
`futbeat_private.enqueue_stale_interested_match_detail()`. The latter locks the
single `detail_planner_state` row (`FOR UPDATE SKIP LOCKED`), enforces the
minimum planning interval, and calls
`futbeat_private.plan_match_detail_coverage(null)`.

The planner:

1. takes the advisory transaction lock `futbeat-match-detail-enqueue`;
2. removes expired requests via `match_detail_requests_due_idx`;
3. removes no-longer-due non-user requests;
4. classifies active background depth and updates hysteresis state;
5. reads the indexed calendar window `[now - 7 days, now + 24 hours]`;
6. assigns temporal/status buckets and filters settled/backoff/in-flight rows;
7. sorts by bucket, editorial relevance, kickoff distance and canonical id;
8. limits the candidate pool to 400;
9. loops until the small urgent/background admission limits are filled;
10. applies per-match and per-bucket quota checks and inserts idempotently.

Relevant tables are `calendar_matches`, `entities`, `provider_entities`,
`live_match_updates`, `match_detail_requests`, `match_detail_cache`,
`match_detail_coverage`, `provider_call_ledger`, `detail_planner_state`,
`match_detail_queue_log`, `temporary_interests` and
`live_terminal_recovery`.

Relevant indexes include `calendar_matches_start_time_idx`, the primary keys
of entities/cache/coverage/requests/live updates, the
`provider_entities_canonical_id_idx`, `match_detail_requests_due_idx`,
`provider_call_ledger_provider_reserved_idx`,
`match_detail_queue_log_at_idx`, and the partial
`live_terminal_recovery_due_idx`.

## Synthetic distribution

Every scale contains a deterministic mixture rather than repeated identical
rows:

- 5% LIVE, split between fresh and stale observations;
- 5% pending result verification;
- 30% scheduled within the next 24 hours;
- 30% finished in the recent seven-day window;
- 20% older history and 10% cancelled;
- detail cache on 50%, coverage state on 80–90%, including AVAILABLE,
  NO_DATA, UNKNOWN, retry backoff and partial sections;
- request rows on roughly 8%, mixing active/expired and user/background;
- temporary interests on roughly 3%;
- terminal recovery on 5%, mixing pending/resolved/exhausted/cancelled;
- provider ledger history on 4%, with canonical mappings for every match.

At 25k this produces 25,000 matches, 2,083 request rows, 22,500 coverage
rows, 1,250 recovery rows and 757 temporary interests.

## Root cause

Before the fix, PostgreSQL inlined both candidate CTEs. Although the final
query had `LIMIT 400`, it first evaluated `match_detail_status()` and
`match_detail_bucket()` repeatedly across the whole time window. At 10k,
`EXPLAIN (ANALYZE, BUFFERS)` showed 6,999 window rows, 4,767 rows reaching the
sort/join tail, ~465,914 shared-buffer hits, and ~3.93 seconds in candidate
selection alone. The complete 25k RPC used ~1.21 million buffer hits and
~9.89 seconds.

The fix materializes the narrow window/profile stages, joins the indexed live
read model directly, calculates status/bucket once, and carries kickoff and
competition id forward instead of joining `entities` again. Quota, retry,
priority, queue, lock and output semantics are unchanged.

## Results

Each cell is the median in milliseconds from four rollback-isolated runs; the
first run is retained as a cold-ish sample and subsequent runs are warm-cache.

| Scale | Route | Before | After | Max after | Margin vs 8s |
|---:|---|---:|---:|---:|---:|
| 1k | planner | 416.80 | 111.21 | 142.50 | 56.1x |
| 1k | enqueue | 417.23 | 115.17 | 123.20 | 64.9x |
| 1k | public RPC | 393.34 | 110.75 | 114.50 | 69.9x |
| 5k | planner | 1,993.26 | 522.89 | 530.02 | 15.1x |
| 5k | enqueue | 1,946.32 | 564.11 | 573.68 | 13.9x |
| 5k | public RPC | 1,951.73 | 564.59 | 567.76 | 14.1x |
| 10k | planner | 4,041.64 | 998.65 | 1,018.81 | 7.9x |
| 10k | enqueue | 3,978.73 | 1,079.54 | 1,090.36 | 7.3x |
| 10k | public RPC | 3,955.00 | 1,094.50 | 1,109.13 | 7.2x |
| 25k | planner | 9,762.85 | 2,440.85 | 2,444.80 | 3.3x |
| 25k | enqueue | 9,827.27 | 2,718.16 | 2,719.70 | 2.9x |
| 25k | public RPC | 9,904.00 | 2,723.51 | 2,731.95 | 2.9x |

The final 25k `EXPLAIN (ANALYZE, BUFFERS)` for the public RPC completed in
~2.69 seconds with ~331,889 shared-buffer hits, no reads, no temporary spill,
and one output row. The synthetic workload is 14.7× the 1,700 stale rows seen
in the incident evidence and the complete RPC remains below the enforced 8s
timeout.

## CI regression guard

`backend/test/match_detail_planner_scale.test.mjs` verifies the structural
bound and runs the mixed 5k workload under the 8s statement timeout. Its bound
is deliberately the actual database timeout, not a fragile sub-second
hardware assertion. The manual benchmark retains the 10k/25k evidence.
