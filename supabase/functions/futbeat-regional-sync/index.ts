import {
  fetchCentralAmericaCup,
  normalizeCentralAmericaCup,
} from "../../../backend/providers/central_america_cup.mjs";

const url = Deno.env.get("SUPABASE_URL")!;
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const headers = {
  apikey: key,
  Authorization: `Bearer ${key}`,
  "Content-Type": "application/json",
};

const rpc = async (name: string, body: unknown) => {
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(15000),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`RPC ${name} failed: ${response.status}${text ? ` ${text.slice(0, 160)}` : ""}`);
  }
  return text ? JSON.parse(text) : null;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });

  const bearer = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  const scheduler = request.headers.get("x-futbeat-scheduler");
  const service = bearer === key;
  const cron = scheduler && await rpc("futbeat_authorize_push_scheduler", {
    p_token: scheduler,
  });
  if (!service && !cron) return new Response(null, { status: 403 });

  const reservation = await rpc("futbeat_reserve_provider_call", {
    p_provider: "thesportsdb",
    p_call_kind: "central-america-cup",
    p_trigger_source: service ? "manual" : "cron",
    p_daily_limit: 10,
    p_min_interval_seconds: 3600,
    p_force: true,
  });
  if (!reservation.allowed) {
    return Response.json({ status: "skipped", reason: reservation.reason });
  }

  const receivedAt = new Date().toISOString();
  try {
    const raw = await fetchCentralAmericaCup();
    const resolve = (kind: string, external: string) => rpc(
      "futbeat_resolve_country_entity",
      { p_provider: "thesportsdb", p_kind: kind, p_external: external },
    );
    const cup = await normalizeCentralAmericaCup(raw, resolve, receivedAt);
    const current = await rpc("futbeat_read_snapshot", {});

    const snapshot = {
      schemaVersion: 1,
      demo: false,
      updatedAt: receivedAt,
      coverage: {
        source: "TheSportsDB + API-Football",
        partial: true,
        live: false,
        developmentOnly: true,
        description: "Cobertura compartida con fallback regional de TheSportsDB",
        sources: ["TheSportsDB", "API-Football"],
      },
      competitions: cup.competitions,
      teams: cup.teams,
      matches: cup.matches,
      players: current?.players ?? [],
      standings: current?.standings ?? [],
      news: current?.news ?? [],
      transfers: current?.transfers ?? [],
    };

    const result = await rpc("futbeat_store_country_snapshot", {
      p_job_id: crypto.randomUUID(),
      p_received_at: receivedAt,
      p_raw: { centralAmericaCup: raw },
      p_snapshot: snapshot,
    });

    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservation.reservationId,
      p_status: "SUCCEEDED",
      p_provider_remaining: null,
      p_http_status: 200,
      p_error_code: null,
      p_metadata: {
        competition: "CONCACAF Central American Cup",
        matches: cup.matches.length,
      },
    });

    return Response.json({
      status: "ok",
      competition: cup.competitions[0]?.name ?? "Central American Cup",
      matches: cup.matches.length,
      result,
    });
  } catch (error) {
    const detail = error instanceof Error ? error.message.slice(0, 320) : "unknown";
    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservation.reservationId,
      p_status: "FAILED",
      p_provider_remaining: null,
      p_http_status: null,
      p_error_code: "REGIONAL_SYNC_FAILED",
      p_metadata: { detail },
    });
    return Response.json({ error: "Regional sync failed", detail }, { status: 502 });
  }
});
