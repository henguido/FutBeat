import { dataPriority } from '../../interest/strategy.mjs';
import { ProviderHealth, ProviderRole } from './hub.mjs';

// Provider routing (#102 Phase 1A). Pure: returns ordered candidates and the
// reason every provider was selected or rejected. It never executes network.
//
// Rules:
//   * GOAL (PRIMARY) serves BASE_LIVE and stays first for every reason; the
//     base LIVE coverage of a match never depends on interest.
//   * A SECONDARY provider never replaces the primary: it may only be an
//     additional candidate for the secondary reasons below, and only when
//     enabled, capable, healthy enough and within its quota.
//   * An INTEGRATION provider is never an operational candidate.
//   * Interest (backend/interest/strategy.mjs) raises the priority of the
//     secondary work (depth/freshness), never the visibility of fixtures.

export const RoutingReason = Object.freeze({
  baseLive: 'BASE_LIVE',
  highInterestLive: 'HIGH_INTEREST_LIVE',
  primaryStale: 'PRIMARY_STALE',
  primaryIncomplete: 'PRIMARY_INCOMPLETE',
  finalReconciliation: 'FINAL_RECONCILIATION',
  coverageGap: 'COVERAGE_GAP',
  controlledComparison: 'CONTROLLED_COMPARISON',
});

const secondaryReasons = new Set([
  RoutingReason.highInterestLive,
  RoutingReason.primaryStale,
  RoutingReason.primaryIncomplete,
  RoutingReason.finalReconciliation,
  RoutingReason.coverageGap,
  RoutingReason.controlledComparison,
]);

/** Provider capability needed per data type. */
export const capabilityFor = Object.freeze({
  live: 'liveScores',
  fixtures: 'fixtures',
  events: 'events',
  match_detail: 'events',
  lineups: 'lineups',
  statistics: 'statistics',
  standings: 'standings',
  players: 'players',
});

export const RejectionReason = Object.freeze({
  disabled: 'DISABLED',
  integrationOnly: 'INTEGRATION_ONLY',
  missingCapability: 'MISSING_CAPABILITY',
  unhealthy: 'UNHEALTHY',
  quotaExhausted: 'QUOTA_EXHAUSTED',
  notSecondaryReason: 'REASON_NOT_ALLOWED_FOR_SECONDARY',
});

// A secondary is only worth a call while healthy (or not yet observed); the
// primary is never dropped for health: base LIVE coverage must keep a
// candidate (its own worker and quota manager handle failures/backoff).
const secondaryHealthy = new Set([ProviderHealth.healthy, ProviderHealth.unseen]);

/**
 * @param workItem {dataType, reason, interest: {explicitFollowers, temporaryUsers,
 *   selectedCountryUsers, detectedCountryUsers}, entityType, entityId}
 * @param providers [{descriptor, config: {enabled, role, priority}, health,
 *   quota: {allowed, reason}}]
 * @returns {candidates: [{provider, role, priority, score}], rejected: [{provider, reason}], priority}
 */
export function routeWork(workItem, providers) {
  const reason = workItem.reason ?? RoutingReason.baseLive;
  if (!Object.values(RoutingReason).includes(reason)) throw new Error(`Unknown routing reason: ${reason}`);
  const capability = capabilityFor[workItem.dataType];
  if (!capability) throw new Error(`Unknown data type: ${workItem.dataType}`);
  const interest = dataPriority(workItem.interest ?? {}, workItem.dataType);
  const candidates = [];
  const rejected = [];

  for (const provider of providers) {
    const id = provider.descriptor.id;
    const role = provider.config?.role;
    const reject = (why) => rejected.push({ provider: id, reason: why });
    if (!provider.config?.enabled) { reject(RejectionReason.disabled); continue; }
    if (role === ProviderRole.integration) { reject(RejectionReason.integrationOnly); continue; }
    if (!provider.descriptor.capabilities.includes(capability)) { reject(RejectionReason.missingCapability); continue; }
    if (role === ProviderRole.secondary && !secondaryReasons.has(reason)) {
      reject(RejectionReason.notSecondaryReason);
      continue;
    }
    if (role !== ProviderRole.primary && !secondaryHealthy.has(provider.health)) {
      reject(RejectionReason.unhealthy);
      continue;
    }
    if (provider.quota && provider.quota.allowed === false) { reject(RejectionReason.quotaExhausted); continue; }
    candidates.push({
      provider: id,
      role,
      priority: provider.config.priority ?? 99,
      // Secondary work is ordered by interest; the primary is always first.
      score: role === ProviderRole.primary ? Number.MAX_SAFE_INTEGER : interest.score,
    });
  }

  candidates.sort((a, b) => {
    const rank = (c) => (c.role === ProviderRole.primary ? 0 : 1);
    return rank(a) - rank(b) || b.score - a.score || a.priority - b.priority || a.provider.localeCompare(b.provider);
  });
  return { reason, capability, priority: interest, candidates, rejected };
}

/**
 * Order work items (e.g. match-detail refreshes) for a secondary provider by
 * interest: temporary Match Center interest raises detail/lineups/statistics/
 * events. Unfollowed matches keep their base LIVE coverage (primary routing
 * above does not depend on this).
 */
export function orderSecondaryWork(items) {
  return [...items]
    .map((item) => ({ item, priority: dataPriority(item.interest ?? {}, item.dataType) }))
    .sort((a, b) => b.priority.score - a.priority.score || String(a.item.entityId).localeCompare(String(b.item.entityId)))
    .map(({ item, priority }) => ({ ...item, priority }));
}
