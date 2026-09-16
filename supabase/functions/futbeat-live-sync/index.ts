import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), {
  status,
  headers: {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  },
});

function defaultSecret() {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    return typeof keys.default === "string" ? keys.default : "";
  } catch {
    return "";
  }
}

function authorized(req: Request) {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const auth = req.headers.get("authorization") ?? "";
  const secret = defaultSecret();
  const apikey = req.headers.get("apikey") ?? "";
  return (legacy && auth === `Bearer ${legacy}`) || (secret && apikey === secret);
}

async function sha256Hex(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function mapStatus(short: unknown) {
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
  } as Record<string, string>)[String(short ?? "")] ?? "UNKNOWN";
}

function mapEventType(type: unknown, detail: unknown) {
  if (type === "Goal") return detail === "Missed Penalty" ? "MISSED_PENALTY" : "GOAL";
  if (type === "Card") {
    return detail === "Red Card" || detail === "Second Yellow card" ? "RED_CARD" : "YELLOW_CARD";
  }
  if (type === "subst") return "SUBSTITUTION";
  if (type === "Var") return "VAR";
  return "OTHER";
}

async function normalizeObservation(item: any) {
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
      event?.comments ?? null,
    ]);
    const eventHash = await sha256Hex(fingerprint);
    events.push({
      eventKey: `api_football_${eventHash.slice(0, 40)}`,
      type: mapEventType(event?.type, event?.detail),
      minute: Number.isInteger(event?.time?.elapsed) ? event.time.elapsed : null,
      teamExternalId: event?.team?.id == null ? null : String(event.team.id),
      playerExternalId: event?.player?.id == null ? null : String(event.player.id),
      detail: event?.detail ?? null,
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
    events,
    rawPayload: item,
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });
  if (!authorized(req)) return json(403, { error: "Forbidden" });

  const apiKey = Deno.env.get("FUTBEAT_API_FOOTBALL_KEY");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const secret = defaultSecret();
  if (!apiKey) return json(503, { error: "Provider not configured" });
  if (!supabaseUrl || !secret) return json(503, { error: "Persistence not configured" });

  try {
    const checkedAt = new Date().toISOString();
    const upstream = await fetch("https://v3.football.api-sports.io/fixtures?live=all", {
      method: "GET",
      headers: {
        "x-apisports-key": apiKey,
        accept: "application/json",
      },
      signal: AbortSignal.timeout(15000),
    });

    const remaining = upstream.headers.get("x-ratelimit-requests-remaining");
    const payload = await upstream.json();
    if (!upstream.ok) return json(502, { error: `API-Football HTTP ${upstream.status}`, remaining });
    if (!payload || !Array.isArray(payload.response)) {
      return json(502, { error: "Invalid provider response", remaining });
    }

    const observations = await Promise.all(payload.response.map(normalizeObservation));
    const persisted = await fetch(`${supabaseUrl}/rest/v1/rpc/futbeat_record_live_batch`, {
      method: "POST",
      headers: {
        apikey: secret,
        accept: "application/json",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        p_provider: "api_football",
        p_received_at: checkedAt,
        p_observations: observations,
      }),
      signal: AbortSignal.timeout(10000),
    });

    if (!persisted.ok) return json(503, { error: "Live persistence failed", remaining });
    const persistence = await persisted.json();

    return json(200, {
      provider: "api_football",
      ok: true,
      liveMatches: observations.length,
      remaining,
      checkedAt,
      persistence,
    });
  } catch {
    return json(502, { error: "Provider request failed" });
  }
});
