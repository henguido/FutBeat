// Cross-provider fixture matching and event dedup (#102 Phase 1A). Pure and
// conservative: canonical ids only (never names); ambiguity is never
// resolved arbitrarily; two observations are better than one wrong merge.

/** Kickoff tolerance between providers (mirrors provider_hub_config default). */
export const DEFAULT_KICKOFF_TOLERANCE_MINUTES = 10;

export const FixtureMatch = Object.freeze({
  matched: 'MATCHED',
  ambiguous: 'AMBIGUOUS',
  unmapped: 'UNMAPPED',
});

/** Format-only season normalization (same rules as SQL normalize_season). */
export function normalizeSeason(value) {
  const raw = String(value ?? '').trim().toLowerCase();
  if (!raw) return '';
  const pair = /^(\d{4})\s*[/\-_]\s*(\d{2}|\d{4})$/.exec(raw);
  if (pair) {
    const first = Number(pair[1]);
    let second = pair[2].length === 2 ? Math.floor(first / 100) * 100 + Number(pair[2]) : Number(pair[2]);
    if (second < first) second += 100;
    return `${first}-${second}`;
  }
  return raw.replace(/\s+/g, ' ');
}

const contradicts = (a, b, normalize = (v) => String(v ?? '').trim().toLowerCase()) => {
  const left = normalize(a);
  const right = normalize(b);
  return left !== '' && right !== '' && left !== right;
};

/**
 * @param fixture {provider, externalMatchId, canonicalCompetitionId,
 *   canonicalHomeTeamId, canonicalAwayTeamId, startTime, season, round,
 *   orientationSwapped?: true only with real provider evidence}
 * @param candidates [{matchId, competitionId, homeTeamId, awayTeamId,
 *   startTime, season?, round?}] canonical matches
 */
export function matchFixture(fixture, candidates, { toleranceMinutes = DEFAULT_KICKOFF_TOLERANCE_MINUTES } = {}) {
  const { canonicalCompetitionId: comp, canonicalHomeTeamId: home, canonicalAwayTeamId: away } = fixture;
  if (!comp || !home || !away || home === away) {
    return { status: FixtureMatch.unmapped, reason: 'unmapped_identity', candidates: [] };
  }
  const kickoff = Date.parse(fixture.startTime);
  if (!Number.isFinite(kickoff)) return { status: FixtureMatch.unmapped, reason: 'invalid_kickoff', candidates: [] };
  const [expectedHome, expectedAway] = fixture.orientationSwapped === true ? [away, home] : [home, away];
  const tolerance = toleranceMinutes * 60000;
  const found = candidates.filter((c) =>
    c.competitionId === comp &&
    c.homeTeamId === expectedHome &&
    c.awayTeamId === expectedAway &&
    Math.abs(Date.parse(c.startTime) - kickoff) <= tolerance &&
    // Absence never blocks; a clear contradiction rejects.
    !contradicts(fixture.season, c.season, normalizeSeason) &&
    !contradicts(fixture.round, c.round));
  if (found.length === 1) {
    return { status: FixtureMatch.matched, canonicalMatchId: found[0].matchId, candidates: [found[0].matchId] };
  }
  if (found.length > 1) {
    return { status: FixtureMatch.ambiguous, reason: 'multiple_candidates', candidates: found.map((c) => c.matchId) };
  }
  return { status: FixtureMatch.unmapped, reason: 'no_candidate', candidates: [] };
}

// ---------------------------------------------------------------------------
// Event dedup. Events here are canonical-resolved observations:
//   {matchId, type, teamId?, minute, extraMinute?, playerId?,
//    inPlayerId?, outPlayerId?, scoreAfter?: {home, away},
//    provenance: {provider, eventId}}
// The provider event id is provenance only, never the canonical identity.
// ---------------------------------------------------------------------------

/** Minute rule: |(minute + extra) - (minute' + extra')| <= 1 (45 vs 45+1 ok). */
export const EVENT_MINUTE_TOLERANCE = 1;

const effectiveMinute = (event) => (Number.isInteger(event.minute) ? event.minute + (event.extraMinute ?? 0) : null);

/** Coarse key to group candidate duplicates (never an identity by itself). */
export function canonicalEventFingerprint(event) {
  return [event.matchId, event.type, event.teamId ?? '-', effectiveMinute(event) ?? '-'].join('|');
}

const bothKnown = (a, b) => a != null && a !== '' && b != null && b !== '';
const sameScore = (a, b) => a?.home === b?.home && a?.away === b?.away;

/**
 * Whether two observations are the same real event. Requires the same match
 * and type, a compatible minute, no contradiction (team, players, score
 * after the event) and at least one positive corroboration beyond
 * type + minute (same team, same player(s) or same score after the event).
 */
export function matchCanonicalEvent(a, b) {
  if (!a || !b || a.matchId !== b.matchId || a.type !== b.type) return false;
  const minuteA = effectiveMinute(a);
  const minuteB = effectiveMinute(b);
  if (minuteA === null || minuteB === null || Math.abs(minuteA - minuteB) > EVENT_MINUTE_TOLERANCE) return false;
  let corroborated = false;
  if (bothKnown(a.teamId, b.teamId)) {
    if (a.teamId !== b.teamId) return false;
    corroborated = true;
  }
  if (a.type === 'SUBSTITUTION') {
    for (const key of ['inPlayerId', 'outPlayerId']) {
      if (bothKnown(a[key], b[key])) {
        if (a[key] !== b[key]) return false;
        corroborated = true;
      }
    }
  } else if (bothKnown(a.playerId, b.playerId)) {
    if (a.playerId !== b.playerId) return false;
    corroborated = true;
  }
  if (a.type === 'GOAL' && a.scoreAfter && b.scoreAfter) {
    if (!sameScore(a.scoreAfter, b.scoreAfter)) return false;
    corroborated = true;
  }
  return corroborated;
}

/**
 * Groups observations into canonical events. Observations of the same
 * provider are never merged with each other (a provider reports each event
 * once); `providerOrder` decides which observation represents a group.
 */
export function dedupeCanonicalEvents(events, { providerOrder = ['goal_api', 'api_football', 'sportmonks'] } = {}) {
  const rank = (event) => {
    const index = providerOrder.indexOf(event.provenance?.provider);
    return index < 0 ? providerOrder.length : index;
  };
  const groups = [];
  for (const event of [...events].sort((x, y) => rank(x) - rank(y))) {
    const group = groups.find((g) =>
      !g.observations.some((o) => o.provenance?.provider === event.provenance?.provider) &&
      g.observations.every((o) => matchCanonicalEvent(o, event)));
    if (group) group.observations.push(event);
    else groups.push({ event, observations: [event] });
  }
  return groups.map((g) => ({
    ...g.event,
    provenance: g.observations.map((o) => o.provenance),
  }));
}
