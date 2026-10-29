// Offline planning only. A GOAL LIVE sweep is global and paginated; the
// number of followers never multiplies provider request units.
export function estimateLiveBudget({ activeSeconds, intervalSeconds, pagesPerSweep = 1,
  dailyCapUnits = 400, followerCount = 0 }) {
  for (const [name, value] of Object.entries({ activeSeconds, intervalSeconds,
    pagesPerSweep, dailyCapUnits, followerCount })) {
    if (!Number.isInteger(value) || value < 0 ||
        (name !== 'activeSeconds' && name !== 'followerCount' && value === 0)) {
      throw new RangeError(`${name} must be a nonnegative integer; intervals, pages and cap must be positive`);
    }
  }
  const sweeps = Math.ceil(activeSeconds / intervalSeconds);
  const requestUnits = sweeps * pagesPerSweep;
  return Object.freeze({ sweeps, requestUnits, withinSafetyCap: requestUnits <= dailyCapUnits,
    remainingSafetyCap: Math.max(0, dailyCapUnits - requestUnits), followerCount });
}
