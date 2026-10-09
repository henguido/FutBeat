# FutBeat v39 — staging canary runbook

Status: local preparation only. No remote operation has been executed.

Production project ref (always forbidden): `izlmruqawgagwdcsjhte`.

## Hard gate

There is no unequivocal staging project in this checkout. The linked-project
note and checked-in workflows point to production. Do not run any Supabase CLI,
SQL, Edge deploy, provider request or workflow until the owner supplies a
separate 20-character staging project ref and explicitly authorizes the canary.

Every operator command must carry: expected staging ref, concrete UTC date,
provider `goal_api`, fixture cap, statement timeout, and start/end UTC times.
Run the local guard first:

```powershell
$stagingRef = '<20-character-staging-ref>'
$date = '<YYYY-MM-DD>'
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/canary/v39-preflight.ps1 `
  -StagingProjectRef $stagingRef -Date $date -Provider goal_api `
  -MaxFixtures 2000 -StatementTimeoutSeconds 90 `
  -ManifestPath "artifacts/canary/$date-preflight.json"
```

Abort unless it reports `SAFE_LOCAL_PREFLIGHT_ONLY`, if `.temp/project-ref`
points to production, if the expected and linked refs differ, or if the
endpoint hostname does not begin with the exact staging ref.

The checked-in GitHub workflow is hard-coded to production. It must never be
used for this canary. Use a manually authorized staging invocation instead.

## Operator command templates (do not run without authorization)

The installed CLI supports explicit `--project-ref`; prefer it over an implicit
link. Start every authorized operator session with this in-memory guard:

```powershell
$productionRef = 'izlmruqawgagwdcsjhte'
$stagingRef = '<20-character-staging-ref>'
$date = '<YYYY-MM-DD>'
$provider = 'goal_api'
$maxFixtures = 2000
$statementTimeoutSeconds = 90
$startedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
if ($stagingRef -eq $productionRef -or $stagingRef -notmatch '^[a-z]{20}$') {
  throw 'REFUSED: target is production or is not an explicit project ref'
}
```

After the local preflight and independent dashboard check, the separately
authorized migration/deploy commands are:

```powershell
npx.cmd supabase db query --project-ref $stagingRef `
  --file supabase/migrations/20261008010000_calendar_date_finalize.sql

npx.cmd supabase functions deploy futbeat-global-ingest `
  --project-ref $stagingRef --no-verify-jwt

$finishedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
```

Before invoking SQL, make a canary-only copy of the read-only pack, replace its
staging ref/date literals, inspect the diff, then use `db query --project-ref
$stagingRef --file <reviewed-copy>`. Do not modify the tracked template with
credentials. The HTTP invocation must similarly build its hostname from
`$stagingRef`, carry exactly `$date`, `$provider`, `$maxFixtures` and a 90-second
timeout, and use only an authorized staging credential. Never reuse the
production workflow token or call the real provider as part of this runbook.

## Required inputs and evidence

- Authorized staging ref and staging endpoint; never infer either.
- One small date (1-300 fixtures) and one historical date near 1,477, selected
  with bounded read-only counts in staging.
- Provider/source fixed to `goal_api` / `GOAL API`.
- Approved fixture cap 2,000 and HTTP timeout 90 s.
- Backup/PITR confirmation, current Disk IO Budget and rollback owner.
- Evidence directory with preflight manifest, SQL snapshots, function version,
  UTC timestamps, sanitized logs and decision record. Never store credentials.

## Sequence (each remote phase requires owner authorization)

1. **Target verification.** Record UTC start. Compare expected ref with the
   dashboard ref, endpoint hostname, CLI link and database identity. Re-run the
   guard. Any production match is an immediate STOP.
2. **Baseline.** Use
   `supabase/manual/2026-10-08_v39_canary_read_only.sql` with the staging ref,
   small date and provider. Save counts, coverage, mappings, sessions, locks,
   WAL/IO availability and Disk IO Budget. Never reset statistics.
3. **Migration.** Apply only `20261008010000_calendar_date_finalize.sql` to the
   verified staging ref. Confirm signatures, `search_path`, revoked
   `PUBLIC/anon/authenticated` access and `service_role` execute grant.
4. **Edge v39.** Deploy `futbeat-global-ingest` from this exact worktree and
   record source SHA/diff and deployed version. Do not deploy the workflow.
   Smoke: unauthenticated request must be 403; invalid bounded payload 400.
5. **Small date.** Invoke one date only, cap at 300. Record HTTP start/end,
   duration, accepted count, stage timings, rows and coverage. Expect the
   legacy single-store path and no finalize RPC.
6. **Large baseline.** Run the read-only pack for the large date and capture
   statement/WAL/IO data if available. Confirm expected count <=2,000 before
   any provider call or ingest.
7. **Controlled partial failure.** Use an approved staging-only failure hook or
   terminate after a known sub-batch. Never corrupt payloads or alter production
   code. Expected: completed upserts may remain; coverage stays absent/old; no
   finalize deletion occurs. Record completed sub-batch sizes.
8. **Retry.** Invoke the same immutable payload/date. Expect every batch <=300,
   five batches for 1,477 fixtures, exactly one successful finalize, no
   duplicates, final coverage equal to provider count, and no missing or
   wrong-date mappings.
9. **After snapshot.** Repeat the read-only pack and bounded metrics. Record end
   UTC, elapsed total/per-batch, rows, locks, timeouts, retries and IO delta.
10. **Decision.** Two operators choose GO, HOLD or ROLLBACK. GO means the
    staging canary passed; it is not production approval.

## Metrics record

Record: ref fingerprint, function version, date/provider, fixture count,
sub-batch ordinal/count/size, read/store/finalize ms, HTTP total ms, rows,
coverage before/during/after, retries, SQLSTATE, WAL bytes delta, buffer hits/
reads/temp writes, active waits/locks and Disk IO Budget before/peak/after.
Mark unsupported metrics `UNAVAILABLE` instead of changing grants/extensions.

## Decision gates

### GO (staging only)

- Target guard passes and no production ref appears in executed commands.
- Small date succeeds without semantic change.
- Large date: each sub-batch <=300; 1,477 makes exactly five; only five-minute
  kickoff bucket boundaries are used; exactly one finalization succeeds.
- Coverage remains absent/unchanged during partial execution and equals the
  provider count only after finalize.
- Retry creates no duplicates, missing mappings or wrong-date rows.
- No statement timeout, deadlock, persistent lock wait or unbounded scan.
- Total request <90 s with 20% headroom (target <=72 s); each statement remains
  below 80% of its configured timeout.
- Disk IO Budget remains inside the owner-approved staging envelope and WAL/
  buffer deltas are measured.

### HOLD

- An owner-required IO metric is unavailable.
- Duration >72 s but <90 s, transient lock wait, unplanned retry, provider and
  coverage counts differ, telemetry is incomplete, or staging has uncontrolled
  concurrent workload.

### ROLLBACK

- Target ambiguity/production match, unauthorized write, timeout/deadlock,
  batch >300, premature/multiple coverage finalization, missing/duplicate/
  wrong-date fixtures, unexpected deletion, persistent locks, Disk IO Budget
  breach, or failed idempotent retry.

## Rollback checklist

1. Stop only the authorized staging workflow/caller; first preserve run IDs,
   logs, manifests, timestamps and sub-batch evidence.
2. Prevent new staging invocations. Do not delete partial upserts.
3. Restore Edge v38 from `21c71c2`; smoke 403/400 against the verified staging
   ref. v38 does not call the finalizer.
4. Query the date read-only. Absent/old coverage means incomplete and remains
   eligible for later retry. If coverage moved, compare counts and exact IDs
   before any separately authorized data remediation.
5. Revert `20261008010000` only after v38 is confirmed and only if the function
   is implicated. Use the reviewed manual rollback and repair migration history
   solely against the same verified staging ref.
6. Never manufacture coverage, delete partial upserts or replay the provider
   during rollback. Reconciliation requires separate authorization.
7. Repeat bounded read-only checks and record final UTC time/owner decision.

## Authorization boundaries

Separate explicit authorization is required for linking staging; applying the
migration; deploying v39 or restoring v38; invoking staging with a real
credential/provider payload; enabling/disabling a remote workflow; injecting a
partial failure; running any remote SQL, including read-only SQL; and every
rollback or migration-history repair. Production remains out of scope.
