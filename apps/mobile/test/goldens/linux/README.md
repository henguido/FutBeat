# Reviewed Linux baselines — MOBILE253

These 18 files are host-rasterizer baselines, not a UI redesign or a tolerance.
The original Windows references in the parent directory are unchanged.

Evidence before adding them:

- #235, source57b9851b, run41247542032: 11 failing visual test cases.
- #243, source5d3e6df7, run41484558676: 1563 PASS, the same11 visual failures.
- All36 test/master PNGs are byte-identical between those runs. Their existing
  master bytes also match the original references in this repository.
- Flutter3.47.4 and bundled font/lock inputs are unchanged. Side-by-side review
  and pixel diagnostics confirm inherited platform rendering differences;
  they do not identify a new application regression or claim a particular
  native font library as the proven cause.
- Source/provenance hashes are in provenance.json. Source artifacts are GitHub
  `flutter-golden-failures` artifacts on the runs above; local comparison is
  artifacts/mobile253/linux-parent-comparison.json (EXACT_RENDER_MATCH).

Only these reviewed keys select Linux baselines via support/platform_goldens.dart.
Every other golden retains its original reference. All use Flutter's default
exact comparator: no thresholds, masks, continue-on-error or skipped tests.
Missing Linux references fail; the helper never silently falls back. A regression
test proves that changing just one pixel fails. New renderer/reference changes
require evidence and review; CI never generates or updates references.

These are synthetic test screenshots, not physical Galaxy A32 QA evidence.
