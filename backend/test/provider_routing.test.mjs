import test from 'node:test';
import assert from 'node:assert/strict';
import { ProviderHealth, defaultProviderHubConfig, providerDescriptors } from '../providers/core/hub.mjs';
import { RejectionReason, RoutingReason, orderSecondaryWork, routeWork } from '../providers/core/routing.mjs';

// Provider routing (#102 Phase 1A): pure decisions, no network. GOAL is the
// primary; API-Football only ever an extra secondary; Sportmonks never
// operational in 1A.

const state = (id, over = {}) => ({
  descriptor: providerDescriptors[id],
  config: { ...defaultProviderHubConfig[id], ...(over.config ?? {}) },
  health: over.health ?? (defaultProviderHubConfig[id].enabled || over.config?.enabled ? ProviderHealth.healthy : ProviderHealth.disabled),
  quota: over.quota ?? { allowed: true },
});
const defaults = () => [state('goal_api'), state('api_football'), state('sportmonks')];
const enabledSecondary = (over = {}) => state('api_football', { config: { enabled: true }, ...over });
const ids = (result) => result.candidates.map((c) => c.provider);
const rejectedReason = (result, id) => result.rejected.find((r) => r.provider === id)?.reason;
const none = { explicitFollowers: 0, temporaryUsers: 0, selectedCountryUsers: 0, detectedCountryUsers: 0 };

test('1. healthy GOAL primary: BASE_LIVE is GOAL only', () => {
  const r = routeWork({ dataType: 'live', reason: RoutingReason.baseLive, interest: none }, defaults());
  assert.deepEqual(ids(r), ['goal_api']);
});

test('2/3. with the Phase 1A config API-Football and Sportmonks are never executable', () => {
  for (const reason of Object.values(RoutingReason)) {
    const r = routeWork({ dataType: 'events', reason, interest: { ...none, explicitFollowers: 50 } }, defaults());
    assert.deepEqual(ids(r), ['goal_api'], reason);
    assert.equal(rejectedReason(r, 'api_football'), RejectionReason.disabled);
    assert.equal(rejectedReason(r, 'sportmonks'), RejectionReason.disabled);
  }
  // Even enabled, an INTEGRATION provider is not operational.
  const r = routeWork({ dataType: 'live', reason: RoutingReason.controlledComparison, interest: none },
    [state('goal_api'), state('sportmonks', { config: { enabled: true, dailyBudget: 10 } })]);
  assert.equal(rejectedReason(r, 'sportmonks'), RejectionReason.integrationOnly);
});

test('4. high-interest LIVE with a (synthetic) enabled API-Football: GOAL first, API-Football second', () => {
  const r = routeWork({ dataType: 'live', reason: RoutingReason.highInterestLive, interest: { ...none, explicitFollowers: 20 } },
    [enabledSecondary(), state('goal_api'), state('sportmonks')]);
  assert.deepEqual(ids(r), ['goal_api', 'api_football']);
  assert.equal(r.candidates[1].role, 'SECONDARY');
});

test('5. primary stale/incomplete: API-Football may be the extra candidate; base LIVE never uses it', () => {
  for (const reason of [RoutingReason.primaryStale, RoutingReason.primaryIncomplete, RoutingReason.finalReconciliation, RoutingReason.coverageGap]) {
    assert.deepEqual(ids(routeWork({ dataType: 'events', reason, interest: none }, [state('goal_api'), enabledSecondary()])),
      ['goal_api', 'api_football'], reason);
  }
  const base = routeWork({ dataType: 'live', reason: RoutingReason.baseLive, interest: none }, [state('goal_api'), enabledSecondary()]);
  assert.deepEqual(ids(base), ['goal_api']);
  assert.equal(rejectedReason(base, 'api_football'), RejectionReason.notSecondaryReason);
});

test('6. an unhealthy secondary is omitted; the primary is never dropped for health', () => {
  for (const health of [ProviderHealth.unavailable, ProviderHealth.degraded]) {
    const r = routeWork({ dataType: 'live', reason: RoutingReason.primaryStale, interest: none },
      [state('goal_api', { health: ProviderHealth.degraded }), enabledSecondary({ health })]);
    assert.deepEqual(ids(r), ['goal_api'], health);
    assert.equal(rejectedReason(r, 'api_football'), RejectionReason.unhealthy);
  }
});

test('7. a secondary without quota is omitted', () => {
  const r = routeWork({ dataType: 'live', reason: RoutingReason.primaryStale, interest: none },
    [state('goal_api'), enabledSecondary({ quota: { allowed: false, reason: 'provider_daily_budget' } })]);
  assert.deepEqual(ids(r), ['goal_api']);
  assert.equal(rejectedReason(r, 'api_football'), RejectionReason.quotaExhausted);
});

test('8. a provider without the capability is omitted', () => {
  const r = routeWork({ dataType: 'lineups', reason: RoutingReason.primaryIncomplete, interest: none },
    [state('goal_api'), enabledSecondary(), state('sportmonks', { config: { enabled: true, role: 'SECONDARY', dailyBudget: 10 } })]);
  assert.deepEqual(ids(r), ['goal_api', 'api_football']);
  assert.equal(rejectedReason(r, 'sportmonks'), RejectionReason.missingCapability, 'Sportmonks declares no lineups');
  assert.throws(() => routeWork({ dataType: 'weather', reason: RoutingReason.baseLive }, defaults()), /Unknown data type/);
});

test('9. temporary Match Center interest raises secondary detail priority (strategy.mjs)', () => {
  const quiet = routeWork({ dataType: 'match_detail', reason: RoutingReason.primaryIncomplete, interest: none },
    [state('goal_api'), enabledSecondary()]);
  const open = routeWork({ dataType: 'match_detail', reason: RoutingReason.primaryIncomplete, interest: { ...none, temporaryUsers: 3 } },
    [state('goal_api'), enabledSecondary()]);
  assert.ok(open.priority.score > quiet.priority.score);
  assert.equal(open.priority.depth, 'TEMPORARY');
  const ordered = orderSecondaryWork([
    { entityId: 'fb_match_quiet', dataType: 'match_detail', interest: none },
    { entityId: 'fb_match_open', dataType: 'match_detail', interest: { ...none, temporaryUsers: 1 } },
    { entityId: 'fb_match_feed', dataType: 'feed', interest: { ...none, temporaryUsers: 1 } },
  ]);
  assert.deepEqual(ordered.map((o) => o.entityId), ['fb_match_open', 'fb_match_feed', 'fb_match_quiet']);
});

test('10. a match without interest still gets its GOAL base LIVE coverage', () => {
  const r = routeWork({ dataType: 'live', reason: RoutingReason.baseLive, interest: none }, [state('goal_api'), enabledSecondary()]);
  assert.deepEqual(ids(r), ['goal_api']);
  const outage = routeWork({ dataType: 'live', reason: RoutingReason.baseLive, interest: none },
    [state('goal_api', { health: ProviderHealth.unavailable }), enabledSecondary()]);
  assert.deepEqual(ids(outage), ['goal_api'], 'API-Football never replaces the base in Phase 1');
});
