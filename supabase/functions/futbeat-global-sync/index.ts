import {
  createSofaScoreProvider,
  normalizeSofaScoreFixtures,
} from "../../../backend/providers/sofascore.mjs";

const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const headers = {
  apikey: serviceKey,
  Authorization: `Bearer ${serviceKey}`,
  "Content-Type": "application/json",
};

const rpc = async (name: string, body: unknown = {}) => {
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(20000),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(
      `RPC ${name} failed: ${response.status}${text ? ` ${text.slice(0, 180)}` : ""}`,
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

  const bearer = request.headers
    .get("authorization")
    ?.replace(/^Bearer\s+/i, "");
  const scheduler = request.headers.get("x-futbeat-scheduler");
  const service = bearer === serviceKey;
  const cron =
    scheduler &&
    (await rpc("futbeat_authorize_push_scheduler", { p_token: scheduler }));
  if (!service && !cron) return new Response(null, { status: 403 });

  const reservation = await rpc("futbeat_reserve_provider_call", {
    p_provider: "sofascore",
    p_call_kind: "global-fixtures",
    p_trigger_source: service ? "manual" : "cron",
    p_daily_limit: 24,
    p_min_interval_seconds: 0,
    p_force: true,
  });
  if (!reservation.allowed) {
    return Response.json({ status: "skipped", reason: reservation.reason });
  }

  const dates = [-1, 0, 1].map(costaRicaDate);
  const receivedAt = new Date().toISOString();
  const started = performance.now();
  let stage = "fetch";

  try {
    const primary = createSofaScoreProvider();
    const fallback = createSofaScoreProvider({
      baseUrl: "https://www.sofascore.com/api/v1",
    });

    const rawByDate: Record<string, unknown> = {};
    const events: Record<string, unknown>[] = [];

    for (const date of dates) {
      try {
        const raw = await primary.fetchDate(date);
        rawByDate[date] = raw;
        events.push(...raw.events);
      } catch {
        const raw = await fallback.fetchDate(date);
        rawByDate[date] = raw;
        events.push(...raw.events);
      }
    }

    stage = "read-current";
    const existing = await rpc("futbeat_read_snapshot");

    stage = "normalize";
    const resolve = (
      kind: string,
      external: string,
      identity: { name?: string; country?: string; shortName?: string },
    ) =>
      rpc("futbeat_resolve_global_entity", {
        p_provider: "sofascore",
        p_kind: kind,
        p_external: external,
        p_name: identity.name ?? "",
        p_country: identity.country ?? "",
        p_short_name: identity.shortName ?? "",
      });

    const snapshot = await normalizeSofaScoreFixtures(
      events,
      resolve,
      receivedAt,
      existing,
    );

    stage = "store";
    const result = await rpc("futbeat_store_global_fixture_window", {
      p_job_id: crypto.randomUUID(),
      p_received_at: receivedAt,
      p_from_date: dates[0],
      p_to_date: dates[2],
      p_raw: { provider: "SofaScore", dates: rawByDate },
      p_snapshot: snapshot,
    });

    const durationMs = Math.round(performance.now() - started);
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
        received: events.length,
        accepted: snapshot.matches.length,
        competitions: snapshot.competitions.length,
        teams: snapshot.teams.length,
      },
    });

    return Response.json({
      status: "ok",
      dates,
      received: events.length,
      accepted: snapshot.matches.length,
      competitions: snapshot.competitions.length,
      teams: snapshot.teams.length,
      result,
    });
  } catch (error) {
    const detail =
      error instanceof Error ? error.message.slice(0, 500) : "unknown";
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
    console.error("global sync failed", stage, detail);
    return Response.json(
      { error: "Global fixture sync failed", stage, detail },
      { status: 502 },
    );
  }
});
