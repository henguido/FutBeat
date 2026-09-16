import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const CRON_TOKEN_SHA256 = "4272322ea3b2da61f5dbef7546569b6a3f4806c586dff1f515ed64fd8415636b";

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

async function sha256Hex(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function authorizationKind(req: Request) {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const auth = req.headers.get("authorization") ?? "";
  const secret = defaultSecret();
  const apikey = req.headers.get("apikey") ?? "";
  if ((legacy && auth === `Bearer ${legacy}`) || (secret && apikey === secret)) return "server";

  const cronToken = req.headers.get("x-futbeat-cron-token") ?? "";
  if (cronToken && await sha256Hex(cronToken) === CRON_TOKEN_SHA256) return "cron";
  return null;
}

async function rpc(supabaseUrl: string, secret: string, name: string, body: unknown) {
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: secret,
      accept: "application/json",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error(`RPC ${name} failed`);
  return await response.json();
}

function remainingAsInteger(value: string | null) {
  if (value == null || !/^\d+$/.test(value)) return null;
  return Number(value);
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

function normalizeText(value: unknown) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[-_]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function trackedCompetition(item: any) {
  return normalizeText(item?.league?.country) === "costa rica" ? "fb_comp_cr" : null;
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
    startTime: item?.fixture?.date ?? null,
    competitionId: trackedCompetition(item),
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

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  const authKind = await authorizationKind(req);
  if (!authKind) return json(403, { error: "Forbidden" });

  const apiKey = Deno.env.get("FUTBEAT_API_FOOTBALL_KEY");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const secret = defaultSecret();
  if (!apiKey) return json(503, { error: "Provider not configured" });
  if (!supabaseUrl || !secret) return json(503, { error: "Persistence not configured" });

  let requestBody: Record<string, unknown> = {};
  try {
    const text = await req.text();
    if (text.trim()) requestBody = JSON.parse(text);
  } catch {
    return json(400, { error: "Invalid JSON body" });
  }

  const isCron = authKind === "cron";
  const triggerSource = isCron ? "cron" : String(requestBody.trigger ?? "manual").slice(0, 40);
  let reservationId: number | null = null;

  try {
    const reservation = await rpc(supabaseUrl, secret, "futbeat_reserve_provider_call", {
      p_provider: "api_football",
      p_call_kind: "live",
      p_trigger_source: triggerSource,
      p_daily_limit: isCron ? 95 : 100,
      p_min_interval_seconds: 120,
      p_force: !isCron,
    });

    if (!reservation?.allowed) {
      return json(200, {
        provider: "api_football",
        ok: true,
        skipped: true,
        reason: reservation?.reason ?? "quota_guard",
        quota: reservation,
        checkedAt: new Date().toISOString(),
      });
    }

    reservationId = Number(reservation.reservationId);
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
    const remainingNumber = remainingAsInteger(remaining);
    const payload = await upstream.json();

    if (!upstream.ok) {
      await rpc(supabaseUrl, secret, "futbeat_complete_provider_call", {
        p_reservation_id: reservationId,
        p_status: "FAILED",
        p_provider_remaining: remainingNumber,
        p_http_status: upstream.status,
        p_error_code: `API_FOOTBALL_HTTP_${upstream.status}`,
        p_metadata: {},
      });
      return json(502, { error: `API-Football HTTP ${upstream.status}`, remaining });
    }

    if (!payload || !Array.isArray(payload.response)) {
      await rpc(supabaseUrl, secret, "futbeat_complete_provider_call", {
        p_reservation_id: reservationId,
        p_status: "FAILED",
        p_provider_remaining: remainingNumber,
        p_http_status: upstream.status,
        p_error_code: "INVALID_PROVIDER_RESPONSE",
        p_metadata: {},
      });
      return json(502, { error: "Invalid provider response", remaining });
    }

    const normalized = await Promise.all(payload.response.map(normalizeObservation));
    const observations = normalized.filter((item) => item.competitionId != null);
    const persistence = await rpc(supabaseUrl, secret, "futbeat_record_live_batch", {
      p_provider: "api_football",
      p_received_at: checkedAt,
      p_observations: observations,
    });

    await rpc(supabaseUrl, secret, "futbeat_complete_provider_call", {
      p_reservation_id: reservationId,
      p_status: "SUCCEEDED",
      p_provider_remaining: remainingNumber,
      p_http_status: upstream.status,
      p_error_code: null,
      p_metadata: {
        liveMatches: normalized.length,
        trackedMatches: observations.length,
        insertedObservations: persistence?.insertedObservations ?? 0,
        duplicates: persistence?.duplicates ?? 0,
      },
    });

    return json(200, {
      provider: "api_football",
      ok: true,
      liveMatches: normalized.length,
      trackedMatches: observations.length,
      remaining,
      checkedAt,
      quota: reservation,
      persistence,
    });
  } catch {
    if (reservationId != null) {
      try {
        await rpc(supabaseUrl, secret, "futbeat_complete_provider_call", {
          p_reservation_id: reservationId,
          p_status: "FAILED",
          p_provider_remaining: null,
          p_http_status: null,
          p_error_code: "WORKER_FAILURE",
          p_metadata: {},
        });
      } catch {
        // Best effort: never expose internal persistence errors to the caller.
      }
    }
    return json(502, { error: "Provider request failed" });
  }
});
