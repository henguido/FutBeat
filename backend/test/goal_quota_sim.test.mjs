import test from 'node:test';
import assert from 'node:assert/strict';
import { SCENARIOS, loadFixture, simulate } from '../../scripts/audit/goal_quota_sim.mjs';

// Benchmark of migration 20261031240000 on the seven-day load taken from the ledger.
// The simulator is a model: these tests pin its direction and its guarantees, while
// the exact numbers live in the turn 244 report.

const load = loadFixture();
const run = (name, efficient) => simulate(load, { efficient, scenario: SCENARIOS[name] });
const names = Object.keys(SCENARIOS);

test('calibration: before lands near the measured week', () => {
  const before = run(names[0], false);
  const measured = Object.values(load.measured.detailByBucket).reduce((a, b) => a + b, 0);
  const ratio = before.kinds['match-detail'] / measured;
  assert.ok(ratio > .85 && ratio < 1.25, `detail ${before.kinds['match-detail']} vs ${measured}`);
  assert.equal(before.kinds['live-goal'], load.measured.liveCalls);
});

test('the same inputs give the same run', () => {
  assert.equal(run(names[0], true).total, run(names[0], true).total);
});

for (const name of names) {
  test(`after spends less and loses nothing protected: ${name}`, () => {
    const before = run(name, false);
    const after = run(name, true);
    assert.ok(after.total < before.total * .9, `${after.total} vs ${before.total}`);
    assert.ok(after.kinds['match-detail'] < before.kinds['match-detail'] * .85);
    assert.ok(after.avgRemAt18 > before.avgRemAt18);
    assert.equal(after.livePollsDenied, 0);
    assert.ok(after.resultsPriority.resolvedShare >= before.resultsPriority.resolvedShare);
    assert.ok(after.resultsFavorite.p95 <= before.resultsFavorite.p95);
    assert.ok(after.resultsAll.resolvedShare >= before.resultsAll.resolvedShare);
    assert.ok(after.resultsAll.p95 <= 60, `all finals p95 ${after.resultsAll.p95}`);
    assert.ok(after.lineupsPriority.share >= before.lineupsPriority.share);
  });
}
