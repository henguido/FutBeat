import { normalizeObservation } from '../../../backend/providers/live_observation.mjs';
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

async function authorizationKind(req: Request) {
 const legacy=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
 const secret=defaultSecret();
 if((legacy && req.headers.get("authorization")==="Bearer "+legacy) ||
    (secret && req.headers.get("apikey")===secret)) return "server";
 const token=req.headers.get("x-futbeat-scheduler");
 const url=Deno.env.get("SUPABASE_URL");
 if(!token || !url || !secret) return null;
 try { return await rpc(url,secret,"futbeat_authorize_push_scheduler",{p_token:token}) ? "cron" : null; }
 catch { return null; }
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
