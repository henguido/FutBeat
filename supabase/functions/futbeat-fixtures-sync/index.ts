import { createApiFootballProvider, normalizeApiFootballFixtures } from "../../../backend/providers/api_football.mjs";

const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const apiKey = Deno.env.get("FUTBEAT_API_FOOTBALL_KEY")!;
const headers = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" };
const supportedLeagueIds = new Set(["2", "39", "140", "253", "262"]);

const rpc = async (name: string, body: unknown) => {
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: "POST", headers, body: JSON.stringify(body), signal: AbortSignal.timeout(15000),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`RPC ${name} failed: ${response.status}${text ? ` ${text.slice(0, 160)}` : ""}`);
  return text ? JSON.parse(text) : null;
};

function costaRicaDate(offsetDays = 0) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Costa_Rica", year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(new Date());
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const noonUtc = new Date(`${values.year}-${values.month}-${values.day}T12:00:00Z`);
  noonUtc.setUTCDate(noonUtc.getUTCDate() + offsetDays);
  return noonUtc.toISOString().slice(0, 10);
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });
  const bearer = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  const scheduler = request.headers.get("x-futbeat-scheduler");
  const service = bearer === serviceKey;
  const cron = scheduler && await rpc("futbeat_authorize_push_scheduler", { p_token: scheduler });
  if (!service && !cron) return new Response(null, { status: 403 });
  if (!apiKey) return Response.json({ error: "Provider is not configured" }, { status: 503 });

  const reservation = await rpc("futbeat_reserve_fixture_call", {
    p_trigger_source: service ? "manual" : "cron",
  });
  if (!reservation.allowed) return Response.json({ status: "skipped", reason: reservation.reason });

  const from = costaRicaDate(-1), to = costaRicaDate(1), receivedAt = new Date().toISOString();
  let stage = "fetch";
  const started = performance.now();
  try {
    const provider = createApiFootballProvider({ apiKey });
    const raw = await provider.fetchFixturesWindow({ from, to });
    const filtered = { ...raw, response: raw.response.filter((item: { league?: { id?: number } }) =>
      supportedLeagueIds.has(String(item.league?.id ?? ""))) };
    filtered.results = filtered.response.length;
    stage = "normalize";
    const resolve = (kind: string, external: string) => rpc("futbeat_resolve_country_entity", {
      p_provider: "api_football", p_kind: kind, p_external: external,
    });
    const snapshot = await normalizeApiFootballFixtures(filtered, resolve, receivedAt);
    stage = "store";
    const result = await rpc("futbeat_store_fixture_window", {
      p_job_id: crypto.randomUUID(), p_received_at: receivedAt,
      p_from_date: from, p_to_date: to, p_raw: filtered, p_snapshot: snapshot,
    });
    const durationMs = Math.round(performance.now() - started);
    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservation.reservationId, p_status: "SUCCEEDED",
      p_provider_remaining: null, p_http_status: 200, p_error_code: null,
      p_metadata: { stage: "complete", from, to, durationMs, received: raw.results, accepted: filtered.results },
    });
    return Response.json({ status: "ok", from, to, received: raw.results, accepted: filtered.results, result });
  } catch (error) {
    const detail = error instanceof Error ? error.message.slice(0, 320) : "unknown";
    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservation.reservationId, p_status: "FAILED",
      p_provider_remaining: null, p_http_status: null, p_error_code: "FIXTURE_SYNC_FAILED",
      p_metadata: { stage, from, to, detail, durationMs: Math.round(performance.now() - started) },
    });
    console.error("fixture sync failed", detail);
    return Response.json({ error: "Fixture sync failed", stage, detail }, { status: 502 });
  }
});
