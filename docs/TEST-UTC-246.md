# TEST-UTC-246 — isolated test clock consolidation

## Provenance and scope

Source `fix/test-utc-clock-245@4854bb8e5d71eb7736a668b743cea24899c79f79`
is exactly one commit above `claude/reverent-dijkstra-18d10c@4dccfe5c45a9fa090f88a10f65690c1f4941793c`.
Only the first has a registered worktree, `.claude/worktrees/reverent-dijkstra-18d10c`;
the Claude-named ref is its clean ancestor, not a second implementation.
Source worktree was clean when copied. Original commit author is henguido,
with Claude Opus 5.5 co-authorship. Source branches and worktrees were not edited.
The isolated branch starts at their common base, so this can be reviewed as one
test-only commit rather than importing unrelated branch history.
Original stable patch-id: `e82d3ece309c6812240c0506425419d72cb2fdae`.
It has no competing equivalent on the ancestor ref; the final consolidated
patch intentionally differs because it shares the clock and retains timers.

The ten source paths were copied exactly before consolidation. No existing
quota expectations were weakened. `quota_utc_day_boundary.test.mjs` is unchanged.
The five relative-time suites still use noon; explicit reset tests still use
00:05. Both delegate to the same ticking test clock, preserving Date arguments,
parse/UTC and the real passage of time. Production sources are unchanged.

## Worker harness / PR #233

Local historical PR #233 head `fd21e450bc` does not change worker_harness.
Later local ref `origin/fix/live-edge-tolerance-239@8381dca9` adds `setTimeout`
to the exact context line where the UTC patch adds `Date`. Resolution keeps
**both Date and setTimeout**. No worker/Edge implementation is copied.
This is a textual compatibility resolution, not evidence that #233's current
remote HEAD or its entire worker implementation passed this branch's suite.
GitHub connector was unavailable and gh could not connect; revalidate PR #233
before publishing. Neither source branch was merged/rebased/cherry-picked.

## Validation

`npm test` uses the real outer system clock, with only the explicitly clocked
test files importing their clock. No global fake-clock environment is required
for the normal suite. `npm run check` also runs unchanged.

`node backend/test/helpers/run_utc_clock_matrix.mjs` creates isolated child
processes at 23:58, 23:59:30, 00:00, 00:03, 00:12, 01:10 and 12:00 UTC.
Each runs eight relevant files: the original five, JS/SQL clock agreement,
unchanged explicit day-boundary tests, and a test at the actual simulated time.
The latter proves yesterday's cap/remaining do not block today, today's cap
does block LIVE, and today's remaining reserve still holds. Existing tests
exercise in-flight reservation accounting and release of unused page budget.
No network/provider is used; databases are local PGlite with synthetic rows.

Results and original output: `artifacts/utc246/real-clock.log`, `matrix.json`
and one log per simulated time. A timeout/nonzero result fails the matrix;
missing results are not PASS. No remote CI is claimed.

## Observed results (2026-11-02)

- Complete normal-clock run: 1,317 tests, **1,311 PASS, 3 FAIL, 1 SKIP,
  2 TODO**, 1,480.27 seconds. Original log retained, not renamed green.
- The two HTTP failures explicitly report `EACCES` connecting to loopback;
  the persistent database test reports `PGlite is closed` in cleanup. Its
  underlying restricted-access failure is masked by cleanup, so the exact
  filesystem cause is not proven. All three fail again in a restricted focal
  run and pass unchanged with local loopback/temp-file access: **3/3 PASS**,
  48.53 seconds. No expectation changes or excluded failing tests.
- All seven simulated times: **80 PASS, 0 FAIL each (560 checks)**. The extra
  two matrix assertions were added after the full run enumerated its files;
  they are covered at all seven times, not falsely included in the 1,317 count.
- `npm run check` and `git diff --check`: PASS. No new skips/TODOs introduced.
- Source worktree still clean at final verification. No production files,
  migrations, Edge Functions, dependencies or provider calls changed.

**GO for isolated code review / preparing CI.** Not a claim of a single green
full-suite invocation or CI PASS. Before integration, revalidate current #233
HEAD (GitHub inaccessible here), retain both VM globals on the overlapping
line, and run CI in its normal loopback/filesystem-capable environment.
