import { createProviderDescriptor } from './provider.mjs';
import { apiFootballDescriptor } from '../api_football.mjs';
import { sportmonksDescriptor } from '../sportmonks.mjs';

// Provider Hub registry, roles and health (#102 Phase 1A). Pure: no network,
// no database. The persistent state lives in provider_hub_config and
// provider_call_ledger (see 20260925070000_provider_hub_phase1a.sql); this
// module mirrors its rules so routing can be tested in isolation.

export const ProviderRole = Object.freeze({
  primary: 'PRIMARY',
  secondary: 'SECONDARY',
  integration: 'INTEGRATION',
});

export const ProviderHealth = Object.freeze({
  disabled: 'DISABLED',
  unseen: 'UNSEEN',
  healthy: 'HEALTHY',
  degraded: 'DEGRADED',
  unavailable: 'UNAVAILABLE',
});

/** GOAL is the production LIVE primary; its worker is unchanged. */
export const goalApiDescriptor = createProviderDescriptor({
  id: 'goal_api',
  source: 'GOAL API',
  capabilities: ['fixtures', 'liveScores', 'events', 'lineups', 'statistics', 'standings', 'players'],
  developmentOnly: false,
  live: true,
});

export const providerDescriptors = Object.freeze({
  goal_api: goalApiDescriptor,
  api_football: apiFootballDescriptor,
  sportmonks: sportmonksDescriptor,
});

/** Initial Provider Hub config (mirrors the migration seed). */
export const defaultProviderHubConfig = Object.freeze({
  goal_api: Object.freeze({ enabled: true, role: 'PRIMARY', developmentOnly: false, priority: 1, dailyBudget: null, minuteBudget: null }),
  api_football: Object.freeze({ enabled: false, role: 'SECONDARY', developmentOnly: true, priority: 2, dailyBudget: 100, minuteBudget: 10 }),
  // No invented contractual limit: without a budget it can never reserve.
  sportmonks: Object.freeze({ enabled: false, role: 'INTEGRATION', developmentOnly: true, priority: 3, dailyBudget: null, minuteBudget: null }),
});

export const healthRules = Object.freeze({
  /** Consecutive failed completions that make a provider UNAVAILABLE. */
  unavailableStreak: 3,
  /** Failure share of the last 24 h completions that makes it DEGRADED. */
  degradedFailureRate: 0.2,
  /** p95 latency (ms) that makes it DEGRADED. */
  degradedP95Ms: 10000,
});

/**
 * Deterministic health from config + ledger stats (last 24 h):
 *   DISABLED     enabled=false
 *   UNSEEN       enabled, no completed call in the window
 *   UNAVAILABLE  last completion failed with 401/403 (auth), or the last
 *                `unavailableStreak` completions all failed
 *   DEGRADED     failure share >= degradedFailureRate, or p95 >= degradedP95Ms
 *   HEALTHY      otherwise
 * Never based on a provider's name.
 */
export function providerHealth(config, stats = {}) {
  if (!config?.enabled) return ProviderHealth.disabled;
  const completed = (stats.successCount ?? 0) + (stats.failedCount ?? 0);
  if (completed === 0) return ProviderHealth.unseen;
  if ([401, 403].includes(stats.lastFailureHttpStatus) && stats.lastCompletionFailed) return ProviderHealth.unavailable;
  if ((stats.failureStreak ?? 0) >= healthRules.unavailableStreak) return ProviderHealth.unavailable;
  if ((stats.failedCount ?? 0) / completed >= healthRules.degradedFailureRate) return ProviderHealth.degraded;
  if ((stats.p95LatencyMs ?? 0) >= healthRules.degradedP95Ms) return ProviderHealth.degraded;
  return ProviderHealth.healthy;
}
