# Overnight: player data + UI (local only)

Branch: `overnight/player-data-ui` (local, **not pushed**). Base: `main` @ `d538684`.
Scope rules respected: no production, no remote Supabase, no GOAL/provider
calls, no deploy, no APK, no push/PR, no destructive git commands.

## Initial state

- `main` @ `d538684` with uncommitted Player Profile work (5 files).
- Checksums (SHA-256, first 16) before branching: `entity_screen.dart`
  AC47BFB66EE1FD75, `team_profile.dart` 89DF8BD9AE915F61, `player_profile.dart`
  24127D8388D3B0AB, `profile_widgets.dart` B7CABAF23DBEC912,
  `player_profile_test.dart` A44E61FE38BB8712.
- Branch created with `git switch -c` (working tree preserved, checksum verified).

## Blocks

| Block | Result | Commit |
| --- | --- | --- |
| A Player Profile | Finished; dead generic team/player code removed from `entity_screen.dart` | `f7898c5` |
| B End-to-end audit | 3 read-only audits (lineups/photos, statistics, player/team data); findings fixed below | — |
| C Lineups | Object lineups no longer wiped; every harvested type renders; e2e test to Flutter; no refetch on re-entry | `eb25041` |
| D Statistics | Half-time rows never shown as totals; object/team-keyed shapes; kept on poorer refresh; e2e | `eb25041` |
| E Player data | Optional squad facts (height, foot, minutes, starts) stored when sent; key contract test | `d53e78a` |
| F Team / Plantilla | Club move drops the old club's number/position/stats (fix in `eb25041`); 40-player e2e test | `7cc714a` |
| G Search | Multi-word typos ("keilor navas") via per-word guard; apostrophe names ("ngolo"); matrix test | `66843b6` |
| H Metrics | Read-only `backend/diagnostics/coverage_report.sql` + test + `docs/coverage-diagnostics.md` | `4c26842` |
| I CI flake | Deterministic perf guard (operation counts); mutation-checked | `6cf903d` |
| — Midnight flake | 4 live tests failed 00:00–00:30 Costa Rica; day now derived from kickoff | `ad7de10` |
| — Orphan match | One match with a missing team/competition no longer breaks a profile/day | `a95a297` |
| J Visual QA | Temporary 320/360 captures (Match Center lineup + stats, GOAL-only and empty player); deleted | — |

## Findings and decisions

1. **Detail wipe (major).** `store_match_detail_before_media` only counted
   ARRAY lineups/statistics, so GOAL's object shapes counted as 0 and a later
   `[]`/`{hasLineups:false}`/`null` replaced them → "Sin alineaciones".
   Now: lineups counted by `lineup_rows` (both shapes), statistics by non-null
   values (`detail_statistics_count`); the stored section is kept only when the
   newer one is empty. Migration `20260923020000`.
2. **Lineup type spellings.** SQL harvest accepted `start%`/`sub%`, the edge
   renderer only exact strings → harvested players with `type:'starting'` were
   not rendered. Normalizers moved to `supabase/functions/_shared/match_detail.ts`
   (pure, node-testable), same prefixes as SQL.
3. **Statistics halves.** Rows labelled `1st`/`2nd` without full-time rows were
   shown with the last half as the match value. Now only full-match rows; half-only
   data → "Sin estadísticas". Empty rows dropped, missing side shows "—".
4. **Squad transfers.** A squad for a new club kept the old club's shirt number,
   position and season numbers. The new wrapper drops unsupplied
   club-level fields only on a real move (injury stays: it is player-level);
   same-club refreshes are unchanged.
5. **Re-entry refetch.** Match detail/context were refetched on every visit.
   Settled data is kept 60 s (`matchCacheRetention`); failed/empty reads still retry.
   Trade-off: re-entering a live match within 60 s shows detail up to 60 s old
   (live score/status still come from realtime updates).
6. **Search.** Multi-word fuzzy threshold 0.65 → 0.5 + per-word guard (every
   query word must resemble a term word). Improves recall and precision
   ("maximiliano ruiz" no longer returns "Maximiliano Lopez"). Teams and
   competitions unchanged (existing regression test).
7. **CI flake root cause.** ~95% of the timed section was `expect(set, set)` in
   `package:matcher` (O(n²)), not app code. Replaced by O(n) checks, a
   deterministic read-count scaling guard (n log n vs n²; mutation made it fail
   with ratio 62 vs limit 24) and one warm-median wall-clock guard (50 ms).
8. **GOAL fields.** The squad mapper only kept a fixed list. Added height, foot,
   minutes, starts — **unverified that GOAL sends them** (no sample payload in
   repo); absent values stay absent.
9. Player `country` created by identity resolution is `""` when unknown; the app
   already treats blank as missing (documented in test, not changed).

## Final review (independent read-only agent)

No blockers. Fixed from the review:
- (major) Lineups/statistics: the stored section is now kept ONLY when the newer
  response is empty. A shorter non-empty correction always wins (the first
  version kept the longer one forever, which could freeze stale data).
- (minor) `injured` is player-level: no longer stripped on a club move.
- (minor) Multi-word search guard evaluated per term (similarity and guard from
  the same name/alias); prefix check no longer uses LIKE (no `%`/`_` leniency).
- (minor) Retention comment corrected: the 60 s window starts when data loads.

Accepted / documented, not changed:
- Two squads stored with the same `receivedAt` containing the same player could
  strip each other's club facts (not verified that the pipeline does this).
- Orphan matches are dropped silently (previously the whole snapshot failed);
  `team()` does not follow redirects, so a redirected id drops the match.
- Array statistics with only per-half rows now show "Sin estadísticas"
  (intended: never show a half as the match total).

## Tests

- New backend: `player_search_matrix`, `match_detail_normalizers`,
  `match_detail_e2e` (+ fixture `apps/mobile/test/fixtures/match_detail_object_lineup.json`),
  `player_profile_fields`, `team_squad_detail`, `coverage_report`.
- New Flutter: `match_detail_e2e_test.dart` (renders the backend fixture; empty
  states; request count on leave/re-enter), orphan-match test in `domain_test.dart`,
  deterministic perf tests in `matches_feed_test.dart`.
- Final numbers: see "Final validation" below.

## Needs production / Work later (not done tonight)

1. Apply migrations `20260923010000_player_search_typo_guard.sql` and
   `20260923020000_preserve_detail_sections_and_club_moves.sql` (after the
   earlier pending ones up to `20260922235500`).
2. Deploy `futbeat-api` edge function (now imports `_shared/match_detail.ts`);
   run `deno check` there — not available locally.
3. Run `backend/diagnostics/coverage_report.sql` read-only before/after deploy.
4. Confirm with one real GOAL squad response whether height/foot/minutes/starts
   exist and their spelling; capture a real `/fixtures/{id}` payload as fixture
   (statistics `half` values unverified).
5. Rebuild the app to ship the Flutter changes.

## Risks

- Stored detail that is already wiped in production cannot be restored by the
  migration; it needs a new detail fetch (provider quota).
- Squad move wrapper strips fields only when the new squad observation is newer
  and the player is actually in it; older observations are ignored.
- Edge function not type-checked with Deno locally.

## Final validation (2026-09-23, local)

- Backend `npm test`: **340/340** pass (was 320 at start; +20 new tests).
- Flutter `flutter test`: **166/166** pass (was 160; +8 new, −1 test of the
  removed `PlayerProfileFacts`, and the old 5 s perf test replaced by 3).
- `flutter analyze`: no issues. `git diff --check`: clean.
- No flakes observed in these runs. The midnight flake was found and fixed; the
  CI feed perf flake is now deterministic.
- Temporary visual captures and the capture test were deleted.
