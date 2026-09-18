import {
  fetchSofaScoreSchedule,
  normalizeSofaScoreSchedule,
} from "../../../backend/providers/sofascore.mjs";

const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const headers = {
  apikey: serviceKey,
  Authorization: `Bearer ${serviceKey}`,
  "Content-Type": "application/json",
};

const rpc = async (name: string, body: unknown) => {
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(20000),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(
      `RPC ${name} failed: ${response.status}${text ? ` ${text.slice(0, 200)}` : ""}`,
    );
  }
  return text ? JSON.parse(text) : null;
};

function costaRicaDate(offsetDays = 0) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Costa_Rica",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date());
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const noonUtc = new Date(
    `${values.year}-${values.month}-${values.day}T12:00:00Z`,
  );
  noonUtc.setUTCDate(noonUtc.getUTCDate() + offsetDays);
  return noonUtc.toISOString().slice(0, 10);
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });

  const bearer = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  const scheduler = request.headers.get("x-futbeat-scheduler");
  const service = bearer === serviceKey;
  const cron = scheduler &&
    await rpc("futbeat_authorize_push_scheduler", { p_token: scheduler });
  if (!service && !cron) return new Response(null, { status: 403 });

  const reservation = await rpc("futbeat_reserve_provider_call", {
    p_provider: "sofascore",
    p_call_kind: "global-three-day",
    p_trigger_source: service ? "manual" : "cron",
    p_daily_limit: 48,
    p_min_interval_seconds: 1800,
    // The generic quota ledger's tracked-window rule is Costa-Rica specific.
    // Only this authenticated server-side worker may bypass that window check.
    p_force: true,
  });

  if (!reservation.allowed) {
    return Response.json({ status: "skipped", reason: reservation.reason });
  }

  const dates = [-1, 0, 1].map(costaRicaDate);
  let stage = "fetch";
  const started = performance.now();

  try {
    const raw = await fetchSofaScoreSchedule({ dates });

    stage = "normalize";
    const receivedAt = new Date().toISOString();

    const resolveEntity = (
      kind: string,
      external: string,
      identity: { name: string; country?: string; shortName?: string },
    ) =>
      rpc("futbeat_resolve_global_entity", {
        p_provider: "sofascore",
        p_kind: kind,
        p_external: external,
        p_name: identity.name,
        p_country: identity.country ?? "",
        p_short_name: identity.shortName ?? "",
      });

    const resolveMatch = (
      external: string,
      identity: { homeTeamId: string; awayTeamId: string; startTime: string },
    ) =>
      rpc("futbeat_resolve_global_match", {
        p_provider: "sofascore",
        p_external: external,
        p_home_team: identity.homeTeamId,
        p_away_team: identity.awayTeamId,
        p_start_time: identity.startTime,
      });

    const snapshot = await normalizeSofaScoreSchedule(
      raw,
      { resolveEntity, resolveMatch },
      receivedAt,
    );

    stage = "store";
    const result = await rpc("futbeat_store_global_fixture_window", {
      p_job_id: crypto.randomUUID(),
      p_received_at: receivedAt,
      p_from_date: dates[0],
      p_to_date: dates[dates.length - 1],
      p_raw: raw,
      p_snapshot: snapshot,
    });

    const durationMs = Math.round(performance.now() - started);
    const competitionCount = snapshot.competitions.length;

    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservation.reservationId,
      p_status: "SUCCEEDED",
      p_provider_remaining: null,
      p_http_status: 200,
      p_error_code: null,
      p_metadata: {
        stage: "complete",
        dates,
        durationMs,
        received: raw.results,
        accepted: snapshot.matches.length,
        competitions: competitionCount,
      },
    });

    return Response.json({
      status: "ok",
      dates,
      received: raw.results,
      accepted: snapshot.matches.length,
      competitions: competitionCount,
      result,
    });
  } catch (error) {
    const detail = error instanceof Error
      ? error.message.slice(0, 400)
      : "unknown";

    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservation.reservationId,
      p_status: "FAILED",
      p_provider_remaining: null,
      p_http_status: null,
      p_error_code: "GLOBAL_SYNC_FAILED",
      p_metadata: {
        stage,
        detail,
        durationMs: Math.round(performance.now() - started),
      },
    });

    console.error("global sync failed", detail);
    return Response.json(
      { error: "Global sync failed", stage, detail },
      { status: 502 },
    );
  }
});
