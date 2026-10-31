# MOBILE245 — local continuation of AUTONOMOUS244

Current implementation source: 87fae5451d0ed1ca18839b6e023ea9c5753058a1, based on 3977bc7 (MOBILE244).

## Verified results

- 68 focused regression cases PASS / 0 FAIL (9 seconds).
- Before changes: 48 initial cases produced 14 PASS / 34 FAIL; 20 numeric/phase cases were added later. Scope is not an identical before/after count.
- Complete Flutter suite: 1542 PASS / 0 FAIL (128 seconds), including unchanged local golden references.
- Flutter analyze: no issues (14.9 seconds), after two test-style corrections.
- No production connections, backend changes, device installation or controller changes.

## Functional fixes

1. Reject older snapshots before absorbing canonical media; reject explicit wrong-match detail IDs before UI/media/SQLite side effects. Unavailable and legacy missing-ID responses remain compatible.
2. An acknowledgement from an older account generation or older preference value cannot clear a newer local dirty flag. This is not a transactional CAS guarantee for every arbitrary storage race.
3. Render scores only as valid complete numeric pairs; accept finite nonnegative integral numeric values, including 2.0. Reuse the same validation for per-side scorer limits.
4. Navigate timeline players through explicit bounded canonical redirects, preserving raw fallback for ambiguous, missing, cyclic or presentation-only aliases. Never merge by name.
5. Reject contradictory Apertura/Clausura tables even when a generic stage is present; accept the narrow exact matching phase contract without accepting finals/subgroup ambiguity.
6. A malformed LIVE bootstrap row is not evidence of deletion of a valid local overlay. Selecting the same date preserves collapsed groups and avoids redundant calendar reads.

## Local commits

- b4867a1b: snapshot/media/detail identity acceptance.
- 108eb690: account preference acknowledgement races.
- 25621af2: scores, canonical player context, standings phase contract.
- ed962e98: partial LIVE bootstrap and same-date feed groups.
- 290baae7: analyzer-only test style.
- e1762198: stop polling only for exact passive GET/detail404 with a single v1 acknowledgement.
- 2f9002cb: new contract fixture style.
- 87fae54: CI trigger accepts its own stacked base; no tests/permissions changed.

## Final candidate

QA37 offline is being built from 87fae5451d0ed1ca18839b6e023ea9c5753058a1. Installation and physical validation are not performed. Build/hash/signature results will be recorded separately before any PASS claim.

## Boundaries and follow-up

Passive API remains a non-deployed backend candidate. No route whitelist expansion or activation is authorized. Scoped passive-404 polling is corrected and locally verified: initial acknowledged absence reduced from 5 attempts to 1; absence during refresh from 5 attempts to 2, retaining cached content. Seven new cases plus existing adapter suites: 25 PASS. Final full-suite rerun: 1549 PASS / 0 FAIL (133 seconds); analyze clean (15.1 seconds).

A32 physical verification remains NOT VERIFIED after a bounded ADB read timed out. QA123 was not modified. QA36 remains preserved; no claim that this later source is contained in that APK.

CI244 remains FAIL for inherited Linux golden comparisons: exact base attribution matched all 36 PNG files across 18 comparisons. No references, thresholds or exclusions were changed. Local green does not make the remote check green.

No persistent continuation was registered: automatic approval review rejected the requested active automation; explicit authorization is pending. This report does not claim 12 hours of execution or future unattended operation.
