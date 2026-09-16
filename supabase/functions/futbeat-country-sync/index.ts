import { fetchCostaRica, normalize } from "../../../backend/providers/thesportsdb.mjs";

const url = Deno.env.get("SUPABASE_URL")!;
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const headers = { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" };
const rpc = async (name: string, body: unknown) => {
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: "POST", headers, body: JSON.stringify(body), signal: AbortSignal.timeout(15000),
  });
  if (!response.ok) throw new Error(`RPC ${name} failed: ${response.status}`);
  return await response.json();
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });
  const bearer = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  const scheduler = request.headers.get("x-futbeat-scheduler");
  const service = bearer === key;
  const cron = scheduler && await rpc("futbeat_authorize_push_scheduler", { p_token: scheduler });
  if (!service && !cron) return new Response(null, { status: 403 });
  const reservation = await rpc("futbeat_reserve_provider_call", {
    p_provider: "thesportsdb", p_call_kind: "country-base-five-requests",
    p_trigger_source: service ? "manual" : "cron", p_daily_limit: 2,
    p_min_interval_seconds: 3600, p_force: true,
  });
  if (!reservation.allowed) return Response.json({ status: "skipped", reason: reservation.reason });
  const receivedAt = new Date().toISOString();
  let stage = "fetch";
  try {
    const raw = await fetchCostaRica();
    stage = "normalize";
    const resolve = (kind: string, external: string) => rpc("futbeat_resolve_country_entity", {
      p_provider: "thesportsdb", p_kind: kind, p_external: external,
    });
    const snapshot = await normalize(raw, resolve, receivedAt);
    stage = "store";
    const result = await rpc("futbeat_store_country_snapshot", {
      p_job_id: crypto.randomUUID(), p_received_at: receivedAt, p_raw: raw, p_snapshot: snapshot,
    });
    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservation.reservationId, p_status: "SUCCEEDED",
      p_provider_remaining: null, p_http_status: 200, p_error_code: null, p_metadata: { country: "CR" },
    });
    return Response.json({ status: "ok", result });
  } catch (error) {
    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservation.reservationId, p_status: "FAILED",
      p_provider_remaining: null, p_http_status: null, p_error_code: "COUNTRY_SYNC_FAILED", p_metadata: { country: "CR" },
    });
    console.error("country sync failed", error instanceof Error ? error.message : "unknown");
    return Response.json({
      error: "Country sync failed", stage,
      detail: error instanceof Error ? error.message.slice(0, 160) : "unknown",
    }, { status: 502 });
  }
});
