// DEPRECATED (legacy, unscheduled). This API-Football path predates the
// Provider Hub: it uses the old reservations and the name-based identity
// resolver. No cron calls it (20260918194000 / 20260925071000 unschedule
// every legacy job). It is superseded by futbeat-provider-hub-sync (#102
// Phase 1B) and must not be scheduled again; removal is a separate cleanup.
import { createApiFootballProvider, normalizeApiFootballFixtures } from "../../../backend/providers/api_football.mjs";

const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const apiKey = Deno.env.get("FUTBEAT_API_FOOTBALL_KEY")!;
const headers = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" };
const rpc = async (name: string, body: unknown) => {
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, { method: "POST", headers, body: JSON.stringify(body), signal: AbortSignal.timeout(15000) });
  const text = await response.text();
  if (!response.ok) throw new Error(`RPC ${name} failed: ${response.status}${text ? ` ${text.slice(0, 160)}` : ""}`);
  return text ? JSON.parse(text) : null;
};
function costaRicaDate(offsetDays = 0) {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Costa_Rica", year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date());
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

  let input: { window?: string; force?: boolean } = {};
  try { input = await request.json(); } catch { }
  const window = input.window ?? "today";
  const offsets: Record<string, number> = { yesterday: -1, today: 0, tomorrow: 1 };
  if (!(window in offsets)) return Response.json({ error: "Invalid fixture window" }, { status: 400 });

  const force = input.force === true && Boolean(service || cron);
  const reservation = force
    ? await rpc("futbeat_reserve_provider_call", {
        p_provider: "api_football",
        p_call_kind: `fixtures-date-${window}`,
        p_trigger_source: service ? "manual" : "cron",
        p_daily_limit: 95,
        p_min_interval_seconds: 0,
        p_force: true,
      })
    : await rpc("futbeat_reserve_fixture_call", {
        p_trigger_source: service ? "manual" : "cron",
        p_window: window,
      });
  if (!reservation.allowed) return Response.json({ status: "skipped", reason: reservation.reason });

  const date = costaRicaDate(offsets[window]);
  const receivedAt = new Date().toISOString();
  let stage = "fetch";
  const started = performance.now();
  try {
    // API-Football already returns the complete date in one aggregated call.
    // Keep every valid fixture instead of discarding competitions here. Ranking
    // belongs in the client: favorites and local/important competitions go first,
    // while the rest of the day's matches remain visible below.
    const raw = await createApiFootballProvider({ apiKey }).fetchFixturesDate({ date });
    stage = "normalize";
    const resolve = (kind: string, external: string) => rpc("futbeat_resolve_country_entity", { p_provider: "api_football", p_kind: kind, p_external: external });
    const snapshot = await normalizeApiFootballFixtures(raw, resolve, receivedAt);
    stage = "store";
    const result = await rpc("futbeat_store_fixture_window", { p_job_id: crypto.randomUUID(), p_received_at: receivedAt, p_from_date: date, p_to_date: date, p_raw: raw, p_snapshot: snapshot });
    const durationMs = Math.round(performance.now() - started);
    const competitions = [...new Set(raw.response.map((item: { league?: { name?: string } }) => item.league?.name).filter(Boolean))];
    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservation.reservationId, p_status: "SUCCEEDED", p_provider_remaining: null, p_http_status: 200, p_error_code: null,
      p_metadata: { stage: "complete", window, date, force, durationMs, endpoint: "fixtures_by_date", params: { date, timezone: "America/Costa_Rica" }, errors: [], received: raw.results, accepted: raw.results, competitions },
    });
    return Response.json({ status: "ok", window, date, force, received: raw.results, accepted: raw.results, competitions, result });
  } catch (error) {
    const detail = error instanceof Error ? error.message.slice(0, 320) : "unknown";
    const diagnostics = error && typeof error === "object" && "details" in error ? (error as { details: Record<string, unknown> }).details : {};
    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservation.reservationId, p_status: "FAILED", p_provider_remaining: null,
      p_http_status: diagnostics.httpStatus ?? null, p_error_code: "FIXTURE_SYNC_FAILED",
      p_metadata: { stage, window, force, detail, ...diagnostics, durationMs: diagnostics.durationMs ?? Math.round(performance.now() - started) },
    });
    console.error("fixture sync failed", detail);
    return Response.json({ error: "Fixture sync failed", stage, detail, diagnostics }, { status: 502 });
  }
});
