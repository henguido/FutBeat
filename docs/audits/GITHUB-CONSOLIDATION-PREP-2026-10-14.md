# FutBeat — GitHub consolidation preparation 37

Date: 2026-10-14. Scope: Git hygiene and documentation only. No production,
Supabase, workflow, migration, Edge Function, push, PR or merge operation.

## Verified baseline

- `main` on GitHub is `b1c8deacdd7fc2e9730d5261281621ba8403637c`,
  checked through a read-only GitHub API request. No fetch changed local refs.
- The primary checkout remains on `fix/calendar-day-subbatches` at
  `66915869b3c91476b3a8ace723c7d43b4b509217`, with unrelated untracked
  `.claude/`, `CLAUDE.md`, `CONTROL_FUTBEAT_NIGHT_SHIFT.md`, `artifacts/`,
  `docs/audits/`, `scripts/audit/`, `sites/`, `skills-lock.json` and an identity
  test. None was edited or deleted.
- The pre-existing inventory contained 55 worktrees. This isolated worktree
  makes 56, with 50 distinct HEADs and 215 distinct commits reachable from
  those HEADs but not from the verified `main` commit. Four worktrees have
  tracked local edits: Android candidate, stale-match audit, v39 validation,
  and one Claude lineup-panel worktree. The count does not imply that all 215
  commits are independent, approved or suitable for integration.
- The Android candidate `6dda155` does not descend from `main`. Its tree differs
  from `main` in backend migrations, functions and a workflow as well as mobile
  code. It must not be made the first consolidation PR by a direct branch PR.
- The reference `GITHUB-CONSOLIDATION-AUDIT-36` was not found as a local file in
  the checked project or visualization paths; this report independently
  reconstructs the baseline above. Any conclusions unique to audit 36 need
  comparison when that report is available.

## First PR proposal — Git hygiene only

Branch: `codex/github-consolidation-prep-37`, created directly from the
verified local `b1c8dea` object without fetch, merge, rebase or cherry-pick.
The proposed PR should contain exactly this report and `.gitignore`:

- Ignore agent-managed `.claude/` directories and generated `graphify-out/`.
- Ignore APK/AAB/APKS/IDSIG binaries, which belong in controlled release
  storage rather than Git.
- Ignore narrow editor/recovery suffixes (`.tmp`, `.temp`, `.swp`, `.swo`,
  `.orig`, `.rej`).
- Retain existing rules for environment files, local Android signing,
  keystores, build outputs, logs and dependencies.

No currently tracked file matches any newly added pattern. Existing tracked
files stay tracked regardless of ignore rules; this check protects future
legitimate additions as well. Do **not** blanket-ignore `artifacts/`, `sites/`,
`docs/audits/`, `sources/`, `CLAUDE.md` or `skills-lock.json` without a separate
ownership/content review. Some may be real project deliverables. The ignore
proposal does not delete or move anything already present locally.

Before a PR, confirm only the two intended paths changed; run `git diff
--check`, `git check-ignore` on representative synthetic paths, and a tracked
file collision scan. CI `contracts` and `mobile` should run on the eventual PR.
Because the diff is documentation/ignore-only, no Flutter or backend runtime
test is required for this preparation. Recheck GitHub `main` immediately
before PR creation; if it moved, review the PR base and diff again. Do not
enable automerge.

## Protected integration order

1. Review the two-file hygiene PR independently. It has no migration or
   release dependency and must not include local untracked material.
2. Reconcile the production-deployed O1, M1-B, HOL21, Fairness27 and M2
   lineages against `main` and each other in a separate backend plan. Their
   deployment status is owner-reported, not verified here; preserve migration
   ordering, schema history, cron and worker behavior. No backend commit from
   those branches should enter `main` merely because its code is deployed.
3. Rebuild mobile changes on the reconciled base in another isolated worktree,
   comparing patch equivalence and current tests. Keep Android `6dda155`, its
   ignored signing/AdMob configuration and Claude's worktree untouched.
4. Only after backend and mobile PR review, consider release packaging and
   physical QA. No AAB or production change is authorized by this plan.

## Graphify without a backend merge

The local `graphify` CLI is installed, but this repository has no tracked
Graphify configuration or `graphify-out/` output. Do not run it against the
dirty primary checkout: it could inspect ignored keystores, local configs or
Claude worktrees. For an updated code graph, first create a temporary,
tracked-files-only export of the exact reviewed commit (for example with
`git archive`), scan that export for secrets, then run Graphify there with no
remote publishing. Keep `graphify-out/` outside the PR and review the graph
for accidental private content before sharing it. A graph of `main` can be
updated independently of still-unmerged backend work; label it clearly with
the source commit. To visualize a pending backend branch, use a separate
sanitized export and label it as unmerged, never as production truth.

## Decision

**GO for review of a two-file Git-hygiene PR**, conditional on the final
diff/CI and a fresh base check. **NO-GO for push/PR now by this task**, for
direct Android candidate integration, or for any backend migration merge.
