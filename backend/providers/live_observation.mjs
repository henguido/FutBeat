async function sha256Hex(value) { const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value));return [...new Uint8Array(digest)].map(x=>x.toString(16).padStart(2,'0')).join(''); }
function mapStatus(short) {
  return ({
    TBD: "DISCOVERED",
    NS: "SCHEDULED",
    "1H": "LIVE",
    HT: "HALFTIME",
    "2H": "LIVE",
    ET: "EXTRA_TIME",
    BT: "EXTRA_TIME",
    P: "PENALTIES",
    LIVE: "LIVE",
    INT: "SUSPENDED",
    SUSP: "SUSPENDED",
    FT: "FINISHED_PENDING_VERIFICATION",
    AET: "FINISHED_PENDING_VERIFICATION",
    PEN: "FINISHED_PENDING_VERIFICATION",
    PST: "POSTPONED",
    CANC: "CANCELLED",
    ABD: "ABANDONED",
    AWD: "FINISHED_PENDING_VERIFICATION",
    WO: "FINISHED_PENDING_VERIFICATION",
  })[String(short ?? "")] ?? "UNKNOWN";
}
function mapEventType(type, detail) {
  if (type === "Goal") return detail === "Missed Penalty" ? "MISSED_PENALTY" : "GOAL";
  if (type === "Card") {
    return detail === "Red Card" || detail === "Second Yellow card" ? "RED_CARD" : "YELLOW_CARD";
  }
  if (type === "subst") return "SUBSTITUTION";
  if (type === "Var") return "VAR";
  return "OTHER";
}

function normalizeText(value) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[-_]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function trackedCompetition(item) {
  const leagueId = String(item?.league?.id ?? "");
  if (leagueId === "162" || normalizeText(item?.league?.country) === "costa rica") return "fb_comp_cr";
  return ["2", "39", "140", "253", "262"].includes(leagueId) ? "provider_mapping" : null;
}

export function isTrackedLiveFixture(item) { return trackedCompetition(item) != null; }

export async function normalizeObservation(item) {
  const fixtureId = String(item?.fixture?.id ?? "");
  if (!fixtureId) throw new Error("Missing fixture id");

  const events = [];
  for (const event of Array.isArray(item?.events) ? item.events : []) {
    const fingerprint = JSON.stringify([
      fixtureId,
      event?.time?.elapsed ?? null,
      event?.time?.extra ?? null,
      event?.team?.id ?? null,
      event?.player?.id ?? null,
      event?.assist?.id ?? null,
      event?.type ?? null,
      event?.detail ?? null,

    ]);
    const eventHash = await sha256Hex(fingerprint);
    events.push({
      eventKey: `api_football_${eventHash.slice(0, 40)}`,
      type: mapEventType(event?.type, event?.detail),
      minute: Number.isInteger(event?.time?.elapsed) ? event.time.elapsed : null,
      teamExternalId: event?.team?.id == null ? null : String(event.team.id),
      playerExternalId: event?.player?.id == null ? null : String(event.player.id),
      detail: event?.detail ?? null,
      extraMinute: Number.isInteger(event?.time?.extra) ? event.time.extra : null,
      assistExternalId: event?.assist?.id == null ? null : String(event.assist.id),
      payload: event,
    });
  }

  const status = mapStatus(item?.fixture?.status?.short);
  const minute = Number.isInteger(item?.fixture?.status?.elapsed) ? item.fixture.status.elapsed : null;
  const home = Number.isInteger(item?.goals?.home) ? item.goals.home : null;
  const away = Number.isInteger(item?.goals?.away) ? item.goals.away : null;
  const payloadHash = await sha256Hex(JSON.stringify([
    fixtureId,
    status,
    minute,
    home,
    away,
    events.map((event) => event.eventKey),
  ]));

  return {
    externalMatchId: fixtureId,
    payloadHash,
    status,
    minute,
    score: { home, away },
    startTime: item?.fixture?.date ?? null,
    competitionId: trackedCompetition(item) === "fb_comp_cr" ? "fb_comp_cr" : null,
    competitionExternalId: item?.league?.id == null ? null : String(item.league.id),
    homeTeam: {
      externalId: item?.teams?.home?.id == null ? null : String(item.teams.home.id),
      name: item?.teams?.home?.name ?? null,
    },
    awayTeam: {
      externalId: item?.teams?.away?.id == null ? null : String(item.teams.away.id),
      name: item?.teams?.away?.name ?? null,
    },
    events,
    rawPayload: item,
  };
}
