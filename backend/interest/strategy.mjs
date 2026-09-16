export const InterestDepth = Object.freeze({ base: 'BASE', deep: 'DEEP', temporary: 'TEMPORARY' });
const weights = Object.freeze({ favorite: 1000000, selectedCountry: 100000, detectedCountry: 10000, temporary: 1000, global: 1 });

export function interestPriority(signal) {
  if (signal.explicitFollowers > 0) return { score: weights.favorite + signal.explicitFollowers, depth: InterestDepth.deep };
  if (signal.selectedCountryUsers > 0) return { score: weights.selectedCountry + signal.selectedCountryUsers, depth: InterestDepth.base };
  if (signal.detectedCountryUsers > 0) return { score: weights.detectedCountry + signal.detectedCountryUsers, depth: InterestDepth.base };
  if (signal.temporaryUsers > 0) return { score: weights.temporary + signal.temporaryUsers, depth: InterestDepth.temporary };
  return { score: weights.global, depth: InterestDepth.base };
}

export function dataPriority(signal, dataType = 'feed') {
  const base = interestPriority(signal);
  if (signal.temporaryUsers > 0 && ['match_detail', 'lineups', 'statistics', 'events'].includes(dataType)) {
    return { score: Math.max(base.score, weights.favorite - 1 + signal.temporaryUsers), depth: InterestDepth.temporary };
  }
  return base;
}

export function aggregateWork(signals) {
  const work = new Map();
  for (const signal of signals) {
    const key = `${signal.entityType}:${signal.entityId}`;
    const current = work.get(key) ?? { entityType: signal.entityType, entityId: signal.entityId, explicitFollowers: 0, temporaryUsers: 0, selectedCountryUsers: 0, detectedCountryUsers: 0 };
    for (const field of ['explicitFollowers', 'temporaryUsers', 'selectedCountryUsers', 'detectedCountryUsers']) current[field] += signal[field] ?? 0;
    work.set(key, current);
  }
  return [...work.values()].map((signal) => ({ ...signal, ...interestPriority(signal) }));
}
