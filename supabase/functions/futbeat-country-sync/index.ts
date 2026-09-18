import { fetchCostaRica, normalize } from "../../../backend/providers/thesportsdb.mjs";
import {
  fetchCentralAmericaCup,
  normalizeCentralAmericaCup,
} from "../../../backend/providers/central_america_cup.mjs";

const url = Deno.env.get("SUPABASE_URL")!;
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const headers = { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" };
const rpc = async (name: string, body: unknown) => {
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: "POST", headers, body: JSON.stringify(body), signal: AbortSignal.timeout(15000),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`RPC ${name} failed: ${response.status}${text ? ` ${text.slice(0, 160)}` : ""}`);
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`RPC ${name} returned invalid JSON`);
  }
};

function mergeSnapshots(country: any, cup: any, receivedAt: string) {
  const competitions = new Map(country.competitions.map((item: any) => [item.id, item]));
  for (const item of cup.competitions) competitions.set(item.id, item);

  const teams = new Map(country.teams.map((item: any) => [item.id, item]));
  for (const item of cup.teams) {
    const existing: any = teams.get(item.id);
    if (!existing) {
      teams.set(item.id, item);
      continue;
    }
    teams.set(item.id, {
      ...item,
      ...existing,
      media: existing.media ?? item.media ?? null,
      aliases: [...new Set([...(existing.aliases ?? []), ...(item.aliases ?? [])])],
    });
  }

  const matches = new Map(country.matches.map((item: any) => [item.id, item]));
  for (const item of cup.matches) matches.set(item.id, item);

  return {
    ...country,
    updatedAt: receivedAt,
    coverage: {
      source: "TheSportsDB",
      partial: true,
      live: false,
      developmentOnly: true,
      description: "Costa Rica + Copa Centroamericana desde TheSportsDB",
      sources: ["TheSportsDB"],
    },
    competitions: [...competitions.values()],
    teams: [...teams.values()],
    matches: [...matches.values()],
  };
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });
  const bearer = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  const scheduler = request.headers.get("x-futbeat-scheduler");
  const service = bearer === key;
  const cron = scheduler && await rpc("futbeat_authorize_push_scheduler", { p_token: scheduler });
  if (!service && !cron) return new Response(null, { status: 403 });
  const reservation = await rpc("futbeat_reserve_provider_call", {
    p_provider: "thesportsdb", p_call_kind: "country-plus-regional-cup",
    p_trigger_source: service ? "manual" : "cron", p_daily_limit: 10,
    p_min_interval_seconds: 3600, p_force: true,
  });
  if (!reservation.allowed) return Response.json({ status: "skipped", reason: reservation.reason });
  const receivedAt = new Date().toISOString();
  let stage = "fetch";
  let stageStarted = performance.now();
  const stages: Record<string, number> = {};
  let endpointDiagnostics: unknown;
  try {
    const [raw, cupRaw] = await Promise.all([
      fetchCostaRica(),
      fetchCentralAmericaCup(),
    ]);
    stages.fetchMs = Math.round(performance.now() - stageStarted);
    endpointDiagnostics = raw._fetch?.endpoints;
    stage = "normalize";
    stageStarted = performance.now();
    const resolve = (kind: string, external: string) => rpc("futbeat_resolve_country_entity", {
      p_provider: "thesportsdb", p_kind: kind, p_external: external,
    });
    const [countrySnapshot, cupSnapshot] = await Promise.all([
      normalize(raw, resolve, receivedAt),
      normalizeCentralAmericaCup(cupRaw, resolve, receivedAt),
    ]);
    const snapshot = mergeSnapshots(countrySnapshot, cupSnapshot, receivedAt);
    stages.normalizeMs = Math.round(performance.now() - stageStarted);
    stage = "store";
    stageStarted = performance.now();
    const result = await rpc("futbeat_store_country_snapshot", {
      p_job_id: crypto.randomUUID(),
      p_received_at: receivedAt,
      p_raw: { country: raw, centralAmericaCup: cupRaw },
      p_snapshot: snapshot,
    });
    stages.storeMs = Math.round(performance.now() - stageStarted);
    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservation.reservationId, p_status: "SUCCEEDED",
      p_provider_remaining: null, p_http_status: 200, p_error_code: null,
      p_metadata: {
        country: "CR", stage: "complete", stages,
        endpoints: endpointDiagnostics,
        capabilities: snapshot.coverage?.capabilities,
        centralAmericaCupMatches: cupSnapshot.matches.length,
      },
    });
    return Response.json({
      status: "ok", result, stages,
      centralAmericaCupMatches: cupSnapshot.matches.length,
      endpoints: endpointDiagnostics,
    });
  } catch (error) {
    const detail = error instanceof Error ? error.message.slice(0, 320) : "unknown";
    const endpoints = error && typeof error === "object" && "diagnostics" in error
      ? (error as { diagnostics: unknown }).diagnostics : endpointDiagnostics;
    stages[`${stage}Ms`] = Math.round(performance.now() - stageStarted);
    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservation.reservationId, p_status: "FAILED",
      p_provider_remaining: null, p_http_status: null, p_error_code: "COUNTRY_SYNC_FAILED",
      p_metadata: { country: "CR", stage, stages, detail, endpoints },
    });
    console.error("country sync failed", error instanceof Error ? error.message : "unknown");
    return Response.json({
      error: "Country sync failed", stage,
      detail, stages, endpoints,
    }, { status: 502 });
  }
});
