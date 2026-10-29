import test from 'node:test';
import assert from 'node:assert/strict';
import { estimateLiveBudget } from '../notifications/live_budget.mjs';

test('central LIVE sweep cost is independent of followers', () => {
  const base = { activeSeconds: 6 * 3600, intervalSeconds: 300, pagesPerSweep: 1 };
  assert.equal(estimateLiveBudget({ ...base, followerCount: 1 }).requestUnits,
    estimateLiveBudget({ ...base, followerCount: 100_000 }).requestUnits);
  assert.equal(estimateLiveBudget({ ...base, followerCount: 100_000 }).requestUnits, 72);
});

test('pagination and interval spend the explicit safety cap', () => {
  assert.deepEqual(estimateLiveBudget({ activeSeconds: 6 * 3600, intervalSeconds: 300,
    pagesPerSweep: 5, dailyCapUnits: 400 }).requestUnits, 360);
  assert.equal(estimateLiveBudget({ activeSeconds: 6 * 3600, intervalSeconds: 120,
    pagesPerSweep: 5, dailyCapUnits: 400 }).withinSafetyCap, false);
});

test('invalid budgets fail closed', () => {
  assert.throws(() => estimateLiveBudget({ activeSeconds: 10, intervalSeconds: 0 }));
  assert.throws(() => estimateLiveBudget({ activeSeconds: 10, intervalSeconds: 5, pagesPerSweep: -1 }));
});
