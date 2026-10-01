// Pure GOAL LIVE event normalizer, shared by futbeat-goal-live-sync and node
// tests; no I/O here.

function clean(value: unknown) {
  return String(value ?? "").trim();
}

/**
 * Provider minute text -> {minute, extraMinute}. "18" -> 18/null,
 * "45+2" -> 45/2, "90+5'" -> 90/5; anything else -> null/null. Added time
 * is kept separately, never folded into the minute.
 */
export function parseEventMinute(value: unknown) {
  const match = clean(value).match(/^(\d+)\s*(?:\+\s*(\d+))?/);
  return {
    minute: match ? Number(match[1]) : null,
    extraMinute: match?.[2] != null ? Number(match[2]) : null,
  };
}

/** Provider score text after the event ("2 - 1") -> {home, away} or null. */
export function parseScoreAfter(value: unknown) {
  const match = clean(value).match(/^(\d+)\s*[-:]\s*(\d+)$/);
  return match ? { home: Number(match[1]), away: Number(match[2]) } : null;
}

/** A provider score value: a non-negative integer (number or digit text). */
function goalScoreValue(value: unknown) {
  if (typeof value === "number") {
    return Number.isInteger(value) && value >= 0 && value <= 999 ? value : null;
  }
  if (typeof value !== "string" || !/^\s*\d{1,3}\s*$/.test(value)) return null;
  return Number(value);
}

function goalScorePair(fixture: Record<string, unknown>, suffix: string) {
  const home = goalScoreValue(fixture[`homeTeam${suffix}`]);
  const away = goalScoreValue(fixture[`awayTeam${suffix}`]);
  return home == null || away == null ? null : { home, away };
}

/**
 * AFTER_PEN: the running total exceeds FT + ET by (k,0) or (0,k), k in
 * {1,2}, and the complete, non-tied penalty score is won by that side.
 */
function isShootoutBonus(
  fixture: Record<string, unknown>,
  live: { home: number; away: number },
  total: { home: number; away: number },
) {
  const pens = goalScorePair(fixture, "PenaltyScore");
  if (!pens) return false;
  const dh = live.home - total.home;
  const da = live.away - total.away;
  return (dh >= 1 && dh <= 2 && da === 0 && pens.home > pens.away) ||
    (dh === 0 && da >= 1 && da <= 2 && pens.away > pens.home);
}

const GOAL_TERMINAL = new Set(["FINISHED", "AFTER_ET", "AFTER_PEN", "AWARDED"]);

/**
 * THE score of a GOAL fixture, for every FutBeat writer (live list, match
 * detail, results, calendar ingest; the database mirrors it in
 * futbeat_private.goal_fixture_score). Measured on stored GOAL answers:
 *   * homeTeamScore / awayTeamScore: the running total, extra time included,
 *     penalties excluded. The only score while the match is not over.
 *   * homeTeamFtScore / awayTeamFtScore: regulation (90') score, filled at
 *     the end of regulation; ExtraScore: goals in extra time only;
 *     PenaltyScore: the shoot-out, never part of the score.
 *   * After the match GOAL sometimes RESETS the running total to 0-0 while
 *     FtScore / HalftimeScore keep the real result.
 * Terminal answers (FINISHED, AFTER_ET, AFTER_PEN, AWARDED):
 *   * with a complete FtScore the result is FT + ExtraScore. ExtraScore is
 *     required after extra time (AFTER_ET / AFTER_PEN) and taken as 0
 *     otherwise. A running total equal to it, absent, or reset to 0-0
 *     agrees; any other running total is incoherent -> no score;
 *   * without FtScore the running total is used (AFTER_PEN: unknown);
 *   * AFTER_PEN: GOAL adds a +1/+2 bonus for the shoot-out WINNER to the
 *     running total (production audit, 117 answers). A running total of
 *     FT + ET plus (k,0) / (0,k), k in {1,2}, agrees when the penalty
 *     score is complete, not tied and won by that same side; any other
 *     excess is incoherent -> no score;
 *   * a result below the half-time score is impossible -> no score.
 * Not terminal: the running total. Unknown or incoherent: {null, null},
 * never a guess (an absent score never replaces a stored one).
 */
export function goalFixtureScore(fixture: Record<string, unknown>) {
  const none = { home: null as number | null, away: null as number | null };
  const live = goalScorePair(fixture, "Score");
  const status = String(fixture.matchStatus ?? "").trim().toUpperCase();
  if (!GOAL_TERMINAL.has(status)) return live ?? none;
  const regulation = goalScorePair(fixture, "FtScore");
  // After penalties the running total carries a shoot-out bonus: without
  // the regulation score the result is unknown.
  if (status === "AFTER_PEN" && !regulation) return none;
  let result = live;
  if (regulation) {
    const extra = goalScorePair(fixture, "ExtraScore") ??
      (status === "AFTER_ET" || status === "AFTER_PEN"
        ? null
        : { home: 0, away: 0 });
    if (!extra) return none;
    const total = {
      home: regulation.home + extra.home,
      away: regulation.away + extra.away,
    };
    const reset = live != null && live.home === 0 && live.away === 0;
    if (
      live != null && !reset &&
      (live.home !== total.home || live.away !== total.away) &&
      !(status === "AFTER_PEN" && isShootoutBonus(fixture, live, total))
    ) {
      return none;
    }
    result = total;
  }
  if (!result) return none;
  const halftime = goalScorePair(fixture, "HalftimeScore");
  if (halftime && (result.home < halftime.home || result.away < halftime.away)) {
    return none;
  }
  return result;
}

const FNV64_OFFSET = 0xcbf29ce484222325n;
const FNV64_PRIME = 0x100000001b3n;
const FNV64_MASK = 0xffffffffffffffffn;

/**
 * Standard 64-bit FNV-1a over the UTF-8 bytes (BigInt); sync and
 * deterministic: the same signature always yields the same 16 hex digits.
 */
export function fallbackSignatureHash(value: string) {
  let hash = FNV64_OFFSET;
  for (const byte of new TextEncoder().encode(value)) {
    hash = ((hash ^ BigInt(byte)) * FNV64_PRIME) & FNV64_MASK;
  }
  return hash.toString(16).padStart(16, "0");
}

/**
 * Identity of every GOAL event row: every stable piece of evidence (never
 * timestamps or the raw row) plus the occurrence of that signature in the
 * payload, in payload order. Two genuinely indistinguishable rows are two
 * keys (:1, :2); the same payload always yields the same keys, and a later
 * extra occurrence only adds :n without renaming earlier ones.
 *
 * GOAL row ids are NOT identities: measured on production live_events
 * (2026-10-01), GOAL re-issues a fresh events[] / cards[] / substitutions[]
 * id for every row on every answer (the same goal was seen under 28 ids in
 * one match). Keying by that id made every answer a "new" event (one more
 * row per event and per poll, duplicated scorers). The id is kept as
 * providerEventId for audit only. Consequence: a content correction (scorer,
 * minute, team) is retract + add, never an in-place update (the database
 * pairs both as a correction: one push).
 */
function fallbackKey(parts: unknown[], seen: Map<string, number>) {
  const signature = JSON.stringify(parts.map((part) => part ?? null));
  const occurrence = (seen.get(signature) ?? 0) + 1;
  seen.set(signature, occurrence);
  return `fallback:${fallbackSignatureHash(signature)}:${occurrence}`;
}

function asRows(value: unknown) {
  return Array.isArray(value)
    ? value.filter((item): item is Record<string, unknown> =>
      item != null && typeof item === "object" && !Array.isArray(item)
    )
    : [];
}

/**
 * Event sections the provider answered as a complete list (present as an
 * array, possibly empty). Only these may retract previously stored rows
 * (snapshot-replace); an absent / null / non-array section never retracts.
 */
export const LIVE_EVENT_SECTIONS = ["events", "cards", "substitutions"] as const;

export function fixtureEventSections(fixture: Record<string, unknown>) {
  return LIVE_EVENT_SECTIONS.filter((section) =>
    Array.isArray(fixture?.[section])
  );
}

/**
 * Own-goal marker. UNVERIFIED provider shape: no captured GOAL sample shows
 * how an own goal is encoded. Accepted markers: a boolean isOwnGoal/ownGoal
 * flag, or a provider type mentioning OWN as a word ("own goal",
 * "OWN_GOAL", "goal-own"; never "KNOWN"/"DOWN").
 */
export function isOwnGoalRow(row: Record<string, unknown>) {
  if (row.isOwnGoal === true || row.ownGoal === true) return true;
  return /(^|[^A-Z])OWN/.test(clean(row.type).toUpperCase());
}

/**
 * Stable text of the normalized event content (never the raw row, which may
 * carry volatile fields): part of the observation payload hash, so a
 * content correction with the same ids and the same score is a new
 * observation instead of a dropped duplicate.
 */
export function liveEventsContentSignature(
  events: Array<Record<string, unknown>>,
  sections: readonly string[] = [],
) {
  return JSON.stringify([
    [...sections],
    events.map((event) => [
      event.eventKey ?? null,
      event.type ?? null,
      event.minute ?? null,
      event.extraMinute ?? null,
      event.teamExternalId ?? null,
      event.playerExternalId ?? null,
      event.assistExternalId ?? null,
      event.scoreAfter ?? null,
      event.ownGoal === true,
      clean((event.payload as Record<string, unknown> | undefined)?.type),
      clean((event.payload as Record<string, unknown> | undefined)?.card),
      clean((event.payload as Record<string, unknown> | undefined)?.info),
    ]),
  ]);
}

export function normalizeFixtureEvents(fixture: Record<string, unknown>) {
  const homeTeam = fixture.homeTeam && typeof fixture.homeTeam === "object"
    ? fixture.homeTeam as Record<string, unknown>
    : {};
  const awayTeam = fixture.awayTeam && typeof fixture.awayTeam === "object"
    ? fixture.awayTeam as Record<string, unknown>
    : {};
  const homeTeamId = clean(homeTeam.id ?? fixture.homeTeamId);
  const awayTeamId = clean(awayTeam.id ?? fixture.awayTeamId);
  const events: Array<Record<string, unknown>> = [];
  const seen = new Map<string, number>();

  for (const row of asRows(fixture.events)) {
    const providerType = clean(row.type).toUpperCase();
    const type = providerType.includes("MISSED") && providerType.includes("PENAL")
      ? "MISSED_PENALTY"
      : providerType.includes("VAR")
      ? "VAR"
      : providerType.includes("GOAL")
      ? "GOAL"
      : "OTHER";
    if (type === "OTHER") continue;

    const homePlayer = clean(row.homeScorerId);
    const awayPlayer = clean(row.awayScorerId);
    const playerTeamExternalId = homePlayer
      ? homeTeamId
      : awayPlayer
      ? awayTeamId
      : "";
    // UNVERIFIED: an own goal is assumed to be listed under the side of the
    // player who scored it; the goal is credited to the other (benefiting)
    // team, the player keeps their identity.
    const ownGoal = type === "GOAL" && isOwnGoalRow(row);
    const teamExternalId = ownGoal
      ? (homePlayer ? awayTeamId : awayPlayer ? homeTeamId : "")
      : playerTeamExternalId;
    const playerExternalId = homePlayer || awayPlayer;
    const assistExternalId = clean(row.homeAssistId ?? row.awayAssistId);
    const { minute, extraMinute } = parseEventMinute(row.time);
    const scoreAfter = parseScoreAfter(row.score);
    const eventKey = fallbackKey([
      type, minute, extraMinute, teamExternalId, playerExternalId,
      assistExternalId, scoreAfter && `${scoreAfter.home}-${scoreAfter.away}`,
      providerType,
    ], seen);

    events.push({
      eventKey,
      providerEventId: clean(row.id) || null,
      type,
      minute,
      extraMinute,
      teamExternalId: teamExternalId || null,
      playerExternalId: playerExternalId || null,
      assistExternalId: assistExternalId || null,
      scoreAfter,
      ...(ownGoal
        ? { ownGoal: true, playerTeamExternalId: playerTeamExternalId || null }
        : {}),
      section: "events",
      payload: row,
    });
  }

  for (const row of asRows(fixture.cards)) {
    const card = clean(row.card).toLowerCase();
    const type = card.includes("red") ? "RED_CARD" : "YELLOW_CARD";
    const homePlayer = clean(row.homePlayerId);
    const awayPlayer = clean(row.awayPlayerId);
    const teamExternalId = homePlayer ? homeTeamId : awayPlayer ? awayTeamId : "";
    const playerExternalId = homePlayer || awayPlayer;
    const { minute, extraMinute } = parseEventMinute(row.time);
    const eventKey = fallbackKey([
      type, minute, extraMinute, teamExternalId, playerExternalId, card,
    ], seen);

    events.push({
      eventKey,
      providerEventId: clean(row.id) || null,
      type,
      minute,
      extraMinute,
      teamExternalId: teamExternalId || null,
      playerExternalId: playerExternalId || null,
      section: "cards",
      payload: row,
    });
  }

  for (const row of asRows(fixture.substitutions)) {
    const side = clean(row.team).toLowerCase();
    const ids = clean(row.substitutionPlayerId)
      .split("|")
      .map((value) => value.trim())
      .filter(Boolean);
    const teamExternalId = side === "home"
      ? homeTeamId
      : side === "away"
      ? awayTeamId
      : "";
    const { minute, extraMinute } = parseEventMinute(row.time);
    const eventKey = fallbackKey([
      "SUBSTITUTION", minute, extraMinute, teamExternalId, ids[0], ids[1],
      clean(row.substitution),
    ], seen);

    events.push({
      eventKey,
      providerEventId: clean(row.id) || null,
      type: "SUBSTITUTION",
      minute,
      extraMinute,
      teamExternalId: teamExternalId || null,
      playerExternalId: ids[0] || null,
      assistExternalId: ids[1] || null,
      section: "substitutions",
      payload: row,
    });
  }

  return events;
}
