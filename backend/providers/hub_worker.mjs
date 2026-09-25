import { RequestBudget } from './core/provider.mjs';
import { ProviderRole, providerDescriptors } from './core/hub.mjs';
import { RoutingReason, routeWork } from './core/routing.mjs';
import { dedupeCanonicalEvents } from './core/matching.mjs';
import { apiFootballFixtureObservation, classifyApiFootballError } from './api_football.mjs';

// Provider Hub secondary worker (#102 Phase 1B): one selective, exact-fixture
// call for one canonical match. The ONLY secondary-provider execution path
// (the legacy futbeat-live-sync / futbeat-fixtures-sync are superseded).
//
// Order, always: validate -> read-only status/preview -> routeWork ->
// strict mapping -> (dryRun stops here: zero provider HTTP, zero ledger,
// zero writes) -> secret present -> persistent hub reservation ->
// ONE provider request -> ledger completion -> event dedup -> reconciled
// secondary observation. No retries, no loops. GOAL is never touched.

export const executableProviders = Object.freeze(['api_football']);
export const workerDataTypes = Object.freeze(['live', 'events', 'fixtures', 'match_detail']);
const secondaryReasons = new Set([
  RoutingReason.highInterestLive,
  RoutingReason.primaryStale,
  RoutingReason.primaryIncomplete,
  RoutingReason.finalReconciliation,
  RoutingReason.coverageGap,
  RoutingReason.controlledComparison,
]);
const allowedKeys = new Set(['provider', 'reason', 'dataType', 'matchId', 'dryRun']);

export class WorkerInputError extends Error {}

/** Strict, bounded input. dryRun defaults to true; only `false` executes. */
export function parseWorkerInput(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new WorkerInputError('Body must be an object');
  for (const key of Object.keys(body)) if (!allowedKeys.has(key)) throw new WorkerInputError(`Unknown field: ${key}`);
  const provider = String(body.provider ?? '');
  if (!/^[a-z0-9_]{2,40}$/.test(provider)) throw new WorkerInputError('Invalid provider');
  const reason = String(body.reason ?? '');
  if (!Object.values(RoutingReason).includes(reason)) throw new WorkerInputError('Invalid reason');
  const dataType = String(body.dataType ?? '');
  if (!workerDataTypes.includes(dataType)) throw new WorkerInputError('Invalid dataType');
  const matchId = String(body.matchId ?? '');
  if (!/^fb_match_[A-Za-z0-9_-]{1,120}$/.test(matchId)) throw new WorkerInputError('Invalid matchId');
  if (body.dryRun !== undefined && typeof body.dryRun !== 'boolean') throw new WorkerInputError('dryRun must be boolean');
  return { provider, reason, dataType, matchId, dryRun: body.dryRun !== false };
}

function routingState(status, target, decision) {
  return (status?.providers ?? [])
    .filter((p) => providerDescriptors[p.provider])
    .map((p) => ({
      descriptor: providerDescriptors[p.provider],
      config: { enabled: p.enabled === true, role: p.role, priority: p.priority },
      health: p.health,
      quota: p.provider === target ? { allowed: decision?.allowed === true, reason: decision?.reason ?? null } : { allowed: true },
    }));
}

/**
 * @param input parsed worker input
 * @param deps {rpc(name, args), readApiKey(), createProvider({apiKey, budget}), clock}
 */
export async function runProviderHubWork(input, deps) {
  const clock = deps.clock ?? (() => new Date());
  const base = { provider: input.provider, matchId: input.matchId, reason: input.reason, dataType: input.dataType, dryRun: input.dryRun };
  if (!executableProviders.includes(input.provider)) {
    const known = providerDescriptors[input.provider];
    return { ...base, status: 'rejected', why: known ? 'provider_not_executable' : 'unknown_provider', providerCalls: 0 };
  }

  const [status, preview] = await Promise.all([
    deps.rpc('futbeat_provider_hub_status', {}),
    deps.rpc('futbeat_provider_hub_preview', { p_provider: input.provider, p_match_id: input.matchId }),
  ]);
  if (!preview?.matchFound) return { ...base, status: 'rejected', why: 'unknown_match', providerCalls: 0 };

  // Routing (single source: backend/providers/core/routing.mjs).
  const routing = routeWork(
    { dataType: input.dataType, reason: input.reason, interest: {}, entityType: 'match', entityId: input.matchId },
    routingState(status, input.provider, preview.decision),
  );
  const selected = routing.candidates.find((c) => c.provider === input.provider);
  const summary = {
    candidates: routing.candidates.map((c) => c.provider),
    rejected: routing.rejected,
    quota: preview.decision,
    mapping: preview.mapping,
  };
  if (!selected || selected.role !== ProviderRole.secondary || !secondaryReasons.has(input.reason)) {
    const rejection = routing.rejected.find((r) => r.provider === input.provider)?.reason ?? 'not_selected';
    return { ...base, status: 'skipped', why: rejection, routing: summary, providerCalls: 0 };
  }

  // Identity: an exact, strictly mapped provider fixture or nothing.
  if (preview.mapping?.state !== 'MAPPED' || !preview.mapping.externalMatchId) {
    return { ...base, status: preview.mapping?.state === 'AMBIGUOUS' ? 'ambiguous' : 'unmapped', routing: summary, providerCalls: 0 };
  }
  const externalMatchId = preview.mapping.externalMatchId;
  const plan = { endpoint: '/fixtures', params: { id: externalMatchId }, requestUnits: 1 };
  if (input.dryRun) return { ...base, status: 'dry_run', plan, routing: summary, providerCalls: 0 };

  // Execution. The secret is checked before any reservation is spent.
  const apiKey = await deps.readApiKey();
  if (typeof apiKey !== 'string' || apiKey.trim().length < 8) {
    return { ...base, status: 'skipped', why: 'missing_secret', routing: summary, providerCalls: 0 };
  }
  const reservation = await deps.rpc('futbeat_reserve_provider_hub_call', {
    p_provider: input.provider,
    p_call_kind: 'fixture',
    p_trigger_source: 'provider-hub-worker',
    p_units: 1,
    p_metadata: { matchId: input.matchId, externalMatchId, reason: input.reason, dataType: input.dataType },
  });
  if (!reservation?.allowed) {
    return { ...base, status: 'skipped', why: reservation?.reason ?? 'quota_denied', routing: summary, providerCalls: 0 };
  }
  const reservationId = reservation.reservationId;
  // Local defence only; the persistent hub budget above is authoritative.
  const provider = deps.createProvider({
    apiKey,
    budget: new RequestBudget({ provider: input.provider, dailyLimit: 1, perMinuteLimit: 1 }),
  });

  let result;
  const started = Date.now();
  try {
    result = await provider.fetchFixture({ fixtureId: externalMatchId });
  } catch (error) {
    const code = classifyApiFootballError(error);
    await deps.rpc('futbeat_complete_provider_call', {
      p_reservation_id: reservationId,
      p_status: 'FAILED',
      p_provider_remaining: error?.details?.providerRemaining ?? null,
      p_http_status: validHttp(error?.details?.httpStatus),
      p_error_code: code,
      p_metadata: { mode: 'provider-hub', durationMs: error?.details?.durationMs ?? Date.now() - started, retry: false },
    });
    return { ...base, status: 'failed', errorCode: code, retry: false, routing: summary, providerCalls: 1 };
  }

  const items = result.envelope.response;
  const item = items.length === 1 && String(items[0]?.fixture?.id ?? '') === externalMatchId ? items[0] : null;
  let observation = null;
  try {
    if (item) observation = apiFootballFixtureObservation(item, clock().toISOString());
  } catch {
    observation = null;
  }
  await deps.rpc('futbeat_complete_provider_call', {
    p_reservation_id: reservationId,
    p_status: observation ? 'SUCCEEDED' : 'FAILED',
    p_provider_remaining: result.providerRemaining,
    p_http_status: validHttp(result.httpStatus),
    p_error_code: observation ? null : 'API_FOOTBALL_INVALID_PAYLOAD',
    p_metadata: { mode: 'provider-hub', durationMs: result.durationMs, providerStatus: observation?.providerStatus ?? null },
  });
  if (!observation) {
    return { ...base, status: 'failed', errorCode: 'API_FOOTBALL_INVALID_PAYLOAD', retry: false, routing: summary, providerCalls: 1 };
  }

  // Events: canonical ids only; an unmapped player stays null (never created).
  const playerIds = [...new Set(observation.events.flatMap((e) =>
    [e.playerExternalId, e.inPlayerExternalId, e.outPlayerExternalId]).filter(Boolean))];
  const players = playerIds.length === 0 ? {} : await deps.rpc('futbeat_resolve_provider_entities_strict', {
    p_provider: input.provider, p_kind: 'player', p_external_ids: playerIds,
  }) ?? {};
  const match = preview.match;
  const teamOf = (side) => (side === 'home' ? match.homeTeamId : side === 'away' ? match.awayTeamId : null);
  const secondaryEvents = observation.events.map((e) => ({
    matchId: match.id,
    type: e.type,
    teamId: teamOf(e.side),
    minute: e.minute,
    extraMinute: e.extraMinute,
    playerId: e.playerExternalId ? players[e.playerExternalId] ?? null : null,
    inPlayerId: e.inPlayerExternalId ? players[e.inPlayerExternalId] ?? null : null,
    outPlayerId: e.outPlayerExternalId ? players[e.outPlayerExternalId] ?? null : null,
    provenance: e.provenance,
  }));
  const goalEvents = (match.events ?? []).map((e) => ({
    matchId: match.id,
    type: e.type,
    teamId: e.teamId ?? null,
    minute: Number.isInteger(e.minute) ? e.minute : null,
    extraMinute: Number.isInteger(e.extraMinute) ? e.extraMinute : null,
    playerId: e.playerId ?? null,
    provenance: { provider: 'goal_api', eventId: e.id ?? null },
  }));
  const merged = dedupeCanonicalEvents([...goalEvents, ...secondaryEvents]);
  const secondaryOnly = merged.filter((e) => e.provenance.every((p) => p.provider !== 'goal_api'));
  const eventReconciliation = {
    goalEvents: goalEvents.length,
    secondaryEvents: secondaryEvents.length,
    canonicalEvents: merged.length,
    confirmedByBoth: merged.filter((e) => e.provenance.some((p) => p.provider === 'goal_api')
      && e.provenance.some((p) => p.provider === input.provider)).length,
    secondaryOnly: secondaryOnly.map(({ provenance, ...event }) => ({ ...event, provenance })),
  };

  const recorded = await deps.rpc('futbeat_record_secondary_observation', {
    p_provider: input.provider,
    p_match_id: match.id,
    p_observation: { ...observation, events: secondaryEvents, eventReconciliation },
  });
  return {
    ...base,
    status: 'ok',
    externalMatchId,
    providerRemaining: result.providerRemaining,
    reconciliation: recorded,
    events: { ...eventReconciliation, secondaryOnly: eventReconciliation.secondaryOnly.length },
    routing: summary,
    providerCalls: 1,
  };
}

function validHttp(value) {
  return Number.isInteger(value) && value >= 100 && value <= 599 ? value : null;
}
