// Match summary contract v1: deterministic, versioned, facts-first.
//
// Same principles as the app's PlayerMatchSummary: only real data, an
// absent event is not evidence of zero, nothing is derived or guessed.
//   * Final wording only for VERIFIED; FINISHED_PENDING_VERIFICATION is a
//     provisional result.
//   * A goal is attributed only from a rich provider event (never from a
//     synthetic "score changed" goal) and only when the side's rich goal
//     events add up exactly to its score; otherwise no scorer is named.
//   * Own goals and penalties only when the event says so explicitly.
//   * Assists only in a VERIFIED final, from the event's assistPlayerId.
//   * Statistics are not summarized in v1.
// Every sentence lists the fact ids it rests on; every omission is stated.
// Same input + same generatorVersion => byte-identical output.

export const SUMMARY_CONTRACT = "futbeat.match-summary";
export const SUMMARY_CONTRACT_VERSION = 1;
export const SUMMARY_GENERATOR_VERSION = "1.0.0";

export type SummaryPhase =
  | "PRE_MATCH"
  | "LIVE"
  | "FINAL"
  | "FINAL_PROVISIONAL"
  | "CALLED_OFF"
  | "UNKNOWN";

export interface SummaryEvent {
  id?: string;
  type?: string;
  minute?: number | null;
  extraMinute?: number | null;
  teamId?: string | null;
  playerId?: string | null;
  playerName?: string | null;
  assistPlayerId?: string | null;
  ownGoal?: boolean;
  detail?: string | null;
  synthetic?: boolean;
  retracted?: boolean;
}

export interface SummaryInput {
  match: {
    id: string;
    status: string;
    startTime: string;
    competitionId?: string | null;
    homeTeamId: string;
    awayTeamId: string;
    score?: { home?: unknown; away?: unknown } | null;
    periods?: { penalties?: { home?: unknown; away?: unknown } | null } | null;
    events?: SummaryEvent[];
  };
  teams: Record<string, { name?: string | null }>;
  players?: Record<string, { name?: string | null }>;
  competition?: { name?: string | null } | null;
  timeZone?: string;
}

export interface SummaryFact {
  id: string;
  kind: "score" | "goal" | "red_card" | "shootout" | "kickoff" | "status";
  [key: string]: unknown;
}

export interface SummaryParagraph {
  kind: "result" | "goals" | "red_cards" | "shootout" | "context";
  text: string;
  facts: string[];
}

export interface MatchSummary {
  contract: typeof SUMMARY_CONTRACT;
  contractVersion: typeof SUMMARY_CONTRACT_VERSION;
  generatorVersion: string;
  locale: "es";
  matchId: string;
  phase: SummaryPhase;
  headline: string;
  paragraphs: SummaryParagraph[];
  facts: SummaryFact[];
  omissions: Array<{ code: string; detail?: string }>;
  fingerprint: { significant: string; input: string };
}

const LIVE = new Set(["LIVE", "HALFTIME", "EXTRA_TIME", "PENALTIES"]);
const CALLED_OFF: Record<string, string> = {
  POSTPONED: "postergado",
  CANCELLED: "cancelado",
  ABANDONED: "abandonado",
  SUSPENDED: "suspendido",
};

export function summaryPhase(status: string): SummaryPhase {
  if (status === "VERIFIED") return "FINAL";
  if (status === "FINISHED_PENDING_VERIFICATION") return "FINAL_PROVISIONAL";
  if (LIVE.has(status)) return "LIVE";
  if (status in CALLED_OFF) return "CALLED_OFF";
  if (["SCHEDULED", "PRE_MATCH", "DISCOVERED"].includes(status)) return "PRE_MATCH";
  return "UNKNOWN";
}

// FNV-1a 64-bit (same as news_pipeline): synchronous and portable.
export function summaryHash(value: string): string {
  let hash = 0xcbf29ce484222325n;
  for (const byte of new TextEncoder().encode(value)) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash.toString(16).padStart(16, "0");
}

/** JSON with object keys sorted: a stable serialization for hashing. */
export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${
      Object.keys(value as Record<string, unknown>).sort()
        .filter((k) => (value as Record<string, unknown>)[k] !== undefined)
        .map((k) => `${JSON.stringify(k)}:${canonicalJson((value as Record<string, unknown>)[k])}`)
        .join(",")
    }}`;
  }
  return JSON.stringify(value ?? null);
}

const score = (value: unknown) =>
  typeof value === "number" && Number.isInteger(value) && value >= 0 && value <= 99 ? value : null;

const minuteText = (minute: number, extra?: number | null) =>
  extra && extra > 0 ? `${minute}+${extra}′` : `${minute}′`;

function name(value: unknown): string | null {
  const text = typeof value === "string" ? value.replace(/\s+/g, " ").trim() : "";
  return text.length ? text.slice(0, 80) : null;
}

/** "A", "A y B", "A, B y C" */
function joinEs(items: string[]): string {
  if (items.length <= 1) return items.join("");
  return `${items.slice(0, -1).join(", ")} y ${items[items.length - 1]}`;
}

function kickoffText(iso: string, timeZone: string): string | null {
  const date = new Date(iso);
  if (!Number.isFinite(date.getTime())) return null;
  try {
    const parts = new Intl.DateTimeFormat("es-CR", {
      timeZone,
      weekday: "long",
      day: "numeric",
      month: "long",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    }).formatToParts(date);
    const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
    return `${get("weekday")} ${get("day")} de ${get("month")}, ${get("hour")}:${get("minute")}`;
  } catch {
    return null;
  }
}

interface GoalFact extends SummaryFact {
  kind: "goal";
  side: "home" | "away";
  minute: number;
  extraMinute: number | null;
  playerId: string | null;
  playerName: string | null;
  ownGoal: boolean;
  penalty: boolean;
  assistPlayerId: string | null;
  assistName: string | null;
}

function isPenalty(detail: unknown): boolean {
  const text = typeof detail === "string" ? detail.toLowerCase() : "";
  return /\bpenal(ty|ti)?\b|\bpenalti\b|\bpenalty\b/.test(text) && !/fall|miss|errad/.test(text);
}

export function buildMatchSummary(input: SummaryInput): MatchSummary {
  const m = input.match;
  const tz = input.timeZone ?? "America/Costa_Rica";
  const phase = summaryPhase(m.status);
  const homeName = name(input.teams[m.homeTeamId]?.name) ?? "Local";
  const awayName = name(input.teams[m.awayTeamId]?.name) ?? "Visitante";
  const playerName = (id: string | null | undefined, fallback?: unknown) =>
    (id ? name(input.players?.[id]?.name) : null) ?? name(fallback);
  const facts: SummaryFact[] = [];
  const paragraphs: SummaryParagraph[] = [];
  const omissions: Array<{ code: string; detail?: string }> = [];

  const home = score(m.score?.home);
  const away = score(m.score?.away);
  const hasScore = home !== null && away !== null;
  const played = phase === "FINAL" || phase === "FINAL_PROVISIONAL" || phase === "LIVE";

  // Rich, side-resolved events only.
  const rich = (m.events ?? [])
    .filter((e) => e && e.synthetic !== true && e.retracted !== true)
    .filter((e) => typeof e.minute === "number" && Number.isInteger(e.minute) && e.minute >= 0)
    .map((e) => ({ ...e, side: e.teamId === m.homeTeamId ? "home" : e.teamId === m.awayTeamId ? "away" : null }))
    .filter((e): e is typeof e & { side: "home" | "away" } => e.side !== null)
    .sort((a, b) =>
      (a.minute! - b.minute!) || ((a.extraMinute ?? 0) - (b.extraMinute ?? 0)) ||
      String(a.id ?? "").localeCompare(String(b.id ?? ""))
    );

  // ---- Result -----------------------------------------------------------
  let headline: string;
  if (played && hasScore) {
    facts.push({ id: "score", kind: "score", home, away, provisional: phase !== "FINAL" });
    headline = `${homeName} ${home}-${away} ${awayName}`;
    const pens = m.periods?.penalties;
    const ph = score(pens?.home), pa = score(pens?.away);
    let result: string;
    if (phase === "LIVE") {
      result = `En juego: ${homeName} ${home}-${away} ${awayName}.`;
    } else if (home === away) {
      result = `${homeName} y ${awayName} empataron ${home}-${away}.`;
    } else {
      const [w, l, ws, ls] = home! > away! ? [homeName, awayName, home, away] : [awayName, homeName, away, home];
      result = `${w} venció ${ws}-${ls} a ${l}.`;
    }
    if (phase === "FINAL_PROVISIONAL") result = `Resultado provisional: ${result}`;
    const competition = name(input.competition?.name);
    if (competition) result += ` ${competition}.`;
    paragraphs.push({ kind: "result", text: result, facts: ["score"] });
    if (phase !== "LIVE" && ph !== null && pa !== null && ph !== pa && home === away) {
      facts.push({ id: "shootout", kind: "shootout", home: ph, away: pa });
      const winner = ph > pa ? homeName : awayName;
      paragraphs.push({
        kind: "shootout",
        text: `${winner} ganó en la tanda de penales (${Math.max(ph, pa)}-${Math.min(ph, pa)}).`,
        facts: ["shootout"],
      });
    }
  } else if (phase === "PRE_MATCH") {
    headline = `${homeName} vs. ${awayName}`;
    const when = kickoffText(m.startTime, tz);
    facts.push({ id: "kickoff", kind: "kickoff", startTime: m.startTime, timeZone: tz });
    const competition = name(input.competition?.name);
    paragraphs.push({
      kind: "context",
      text: `${homeName} recibe a ${awayName}${when ? ` el ${when}` : ""}${competition ? ` (${competition})` : ""}.`,
      facts: ["kickoff"],
    });
  } else if (phase === "CALLED_OFF") {
    headline = `${homeName} vs. ${awayName}`;
    facts.push({ id: "status", kind: "status", status: m.status });
    paragraphs.push({
      kind: "context",
      text: `El partido entre ${homeName} y ${awayName} fue ${CALLED_OFF[m.status]}.`,
      facts: ["status"],
    });
  } else {
    headline = `${homeName} vs. ${awayName}`;
    if (played) omissions.push({ code: "score_unavailable" });
  }

  // ---- Goals --------------------------------------------------------------
  if (played && hasScore && home! + away! > 0) {
    const goals = rich.filter((e) => e.type === "GOAL");
    const perSide = { home: goals.filter((g) => g.side === "home").length, away: goals.filter((g) => g.side === "away").length };
    if (perSide.home !== home || perSide.away !== away) {
      omissions.push({
        code: "scorers_unverified",
        detail: `goal events ${perSide.home}-${perSide.away} vs score ${home}-${away}`,
      });
    } else {
      const assistsAllowed = phase === "FINAL";
      let assistsHeld = false;
      const goalFacts: GoalFact[] = goals.map((g, i) => {
        const own = g.ownGoal === true;
        const scorer = g.playerId || name(g.playerName) ? playerName(g.playerId, g.playerName) : null;
        const assistName = !own && g.assistPlayerId ? playerName(g.assistPlayerId) : null;
        if (!assistsAllowed && assistName) assistsHeld = true;
        return {
          id: `goal-${i + 1}`,
          kind: "goal",
          side: g.side,
          minute: g.minute!,
          extraMinute: g.extraMinute ?? null,
          playerId: g.playerId ?? null,
          playerName: scorer,
          ownGoal: own,
          penalty: !own && isPenalty(g.detail),
          assistPlayerId: assistsAllowed && assistName ? g.assistPlayerId ?? null : null,
          assistName: assistsAllowed ? assistName : null,
        };
      });
      facts.push(...goalFacts);
      if (assistsHeld) omissions.push({ code: "assists_pending_verification" });
      for (const side of ["home", "away"] as const) {
        const own = goalFacts.filter((g) => g.side === side);
        if (!own.length) continue;
        const parts = own.map((g) => {
          const when = minuteText(g.minute, g.extraMinute);
          if (!g.playerName) return `gol sin autor confirmado (${when})`;
          if (g.ownGoal) return `${g.playerName} en propia puerta (${when})`;
          const tags = [when, g.penalty ? "penal" : null, g.assistName ? `asistencia de ${g.assistName}` : null]
            .filter(Boolean).join(", ");
          return `${g.playerName} (${tags})`;
        });
        paragraphs.push({
          kind: "goals",
          text: `Goles de ${side === "home" ? homeName : awayName}: ${joinEs(parts)}.`,
          facts: own.map((g) => g.id),
        });
      }
    }
  }

  // ---- Red cards -----------------------------------------------------------
  if (played) {
    const reds = rich.filter((e) => e.type === "RED_CARD" && (e.playerId || name(e.playerName)))
      .map((e, i) => ({
        id: `red-${i + 1}`,
        kind: "red_card" as const,
        side: e.side,
        minute: e.minute!,
        extraMinute: e.extraMinute ?? null,
        playerId: e.playerId ?? null,
        playerName: playerName(e.playerId, e.playerName),
      }))
      .filter((r) => r.playerName);
    if (reds.length) {
      facts.push(...reds);
      paragraphs.push({
        kind: "red_cards",
        text: `Expulsado${reds.length > 1 ? "s" : ""}: ${
          joinEs(reds.map((r) => `${r.playerName} (${r.side === "home" ? homeName : awayName}, ${minuteText(r.minute, r.extraMinute)})`))
        }.`,
        facts: reds.map((r) => r.id),
      });
    }
    omissions.push({ code: "statistics_not_summarized" });
  }

  const significant = summaryHash(canonicalJson({
    generator: SUMMARY_GENERATOR_VERSION,
    phase,
    headline,
    facts,
    paragraphs: paragraphs.map((p) => p.text),
  }));
  const inputHash = summaryHash(canonicalJson(input));
  return {
    contract: SUMMARY_CONTRACT,
    contractVersion: SUMMARY_CONTRACT_VERSION,
    generatorVersion: SUMMARY_GENERATOR_VERSION,
    locale: "es",
    matchId: m.id,
    phase,
    headline,
    paragraphs,
    facts,
    omissions,
    fingerprint: { significant, input: inputHash },
  };
}
