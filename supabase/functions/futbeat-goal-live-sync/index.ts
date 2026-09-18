import { createRemoteJWKSet, jwtVerify } from "npm:jose@6.1.0";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });

const githubJwks = createRemoteJWKSet(
  new URL("https://token.actions.githubusercontent.com/.well-known/jwks"),
);

function defaultSecret() {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    return typeof keys.default === "string" ? keys.default : "";
  } catch {
    return "";
  }
}

async function rpc(
  supabaseUrl: string,
  secret: string,
  name: string,
  body: unknown = {},
) {
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
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`RPC ${name} failed: ${response.status}`);
  }
  return text ? JSON.parse(text) : null;
}

async function authorizeGithub(req: Request) {
  const token = req.headers
    .get("authorization")
    ?.replace(/^Bearer\s+/i, "");
  if (!token) return false;

  try {
    const { payload } = await jwtVerify(token, githubJwks, {
      issuer: "https://token.actions.githubusercontent.com",
      audience: "futbeat-goal-live-sync",
    });
    if (payload.repository !== "henguido/FutBeat") return false;
    if (payload.ref !== "refs/heads/main") return false;
    if (!["schedule", "workflow_dispatch", "push"].includes(
      String(payload.event_name),
    )) return false;
    const workflow = String(
      payload.workflow_ref ?? payload.job_workflow_ref ?? "",
    );
    return workflow ===
      "henguido/FutBeat/.github/workflows/global-fixtures.yml@refs/heads/main";
  } catch {
    return false;
  }
}

async function authorizeScheduler(req: Request) {
  const secret = defaultSecret();
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (
    (legacy && req.headers.get("authorization") === `Bearer ${legacy}`) ||
    (secret && req.headers.get("apikey") === secret)
  ) {
    return "server";
  }

  const token = req.headers.get("x-futbeat-scheduler");
  const url = Deno.env.get("SUPABASE_URL");
  if (!token || !url || !secret) return null;
  try {
    return await rpc(
        url,
        secret,
        "futbeat_authorize_push_scheduler",
        { p_token: token },
      )
      ? "cron"
      : null;
  } catch {
    return null;
  }
}

async function sha256Hex(value: string) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(digest)]
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
}

function clean(value: unknown) {
  return String(value ?? "").trim();
}

function statusOf(fixture: Record<string, unknown>) {
  const status = clean(fixture.matchStatus).toUpperCase();
  const period = clean(fixture.matchPeriod).toUpperCase();

  if (status === "POSTPONED") return "POSTPONED";
  if (status === "CANCELLED") return "CANCELLED";
  if (status === "SUSPENDED") return "SUSPENDED";
  if (status === "ABANDONED") return "ABANDONED";
  if (status === "HALF_TIME" || period === "HALF_TIME") return "HALFTIME";
  if (status === "LIVE") {
    if (period === "EXTRA_TIME") return "EXTRA_TIME";
    if (period === "PENALTIES") return "PENALTIES";
    return "LIVE";
  }
  if (["FINISHED", "AFTER_ET", "AFTER_PEN", "AWARDED"].includes(status)) {
    return "FINISHED_PENDING_VERIFICATION";
  }
  return "SCHEDULED";
}

function score(value: unknown) {
  if (value == null || value === "") return null;
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : null;
}

async function normalizeFixture(fixture: Record<string, unknown>) {
  const externalMatchId = clean(fixture.apiId ?? fixture.id);
  if (!externalMatchId) throw new Error("Missing GOAL API fixture id");

  const status = statusOf(fixture);
  const elapsed = Number(fixture.matchElapsed);
  const minute = Number.isInteger(elapsed) && elapsed >= 0 ? elapsed : null;
  const home = score(fixture.homeTeamScore);
  const away = score(fixture.awayTeamScore);
  const payloadHash = await sha256Hex(JSON.stringify([
    externalMatchId,
    status,
    minute,
    home,
    away,
  ]));

  return {
    externalMatchId,
    payloadHash,
    status,
    minute,
    score: { home, away },
    events: [],
    rawPayload: fixture,
  };
}

function remainingAsInteger(value: string | null) {
  if (value == null || !/^\d+$/.test(value)) return null;
  return Number(value);
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  let body: Record<string, unknown> = {};
  try {
    const text = await req.text();
    if (text.trim()) body = JSON.parse(text);
  } catch {
    return json(400, { error: "Invalid JSON body" });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const secret = defaultSecret();
  if (!supabaseUrl || !secret) {
    return json(503, { error: "Persistence not configured" });
  }

  if (body.action === "configure") {
    if (!(await authorizeGithub(req))) {
      return json(403, { error: "Forbidden" });
    }
    const goalApiKey = typeof body.goalApiKey === "string"
      ? body.goalApiKey.trim()
      : "";
    if (goalApiKey.length < 20) {
      return json(400, { error: "Invalid GOAL API key" });
    }
    await rpc(
      supabaseUrl,
      secret,
      "futbeat_store_goal_api_live_key",
      { p_secret: goalApiKey },
    );
    return json(200, { ok: true, configured: true });
  }

  const authKind = await authorizeScheduler(req);
  if (!authKind) return json(403, { error: "Forbidden" });

  const triggerSource = authKind === "cron"
    ? "cron"
    : clean(body.trigger || "manual").slice(0, 40);

  let reservationId: number | null = null;
  try {
    const reservation = await rpc(
      supabaseUrl,
      secret,
      "futbeat_reserve_goal_live_call",
      { p_trigger_source: triggerSource },
    );

    if (!reservation?.allowed) {
      return json(200, {
        provider: "goal_api",
        ok: true,
        skipped: true,
        reason: reservation?.reason ?? "quota_guard",
        quota: reservation,
        checkedAt: new Date().toISOString(),
      });
    }

    reservationId = Number(reservation.reservationId);
    const apiKey = await rpc(
      supabaseUrl,
      secret,
      "futbeat_read_goal_api_live_key",
      {},
    );
    if (typeof apiKey !== "string" || apiKey.length < 20) {
      throw new Error("GOAL API live key is not configured");
    }

    const checkedAt = new Date().toISOString();
    const upstream = await fetch(
      "https://api.goal-api.com/v1/fixtures/live",
      {
        headers: {
          Authorization: `Bearer ${apiKey}`,
          Accept: "application/json",
        },
        signal: AbortSignal.timeout(15000),
      },
    );

    const remaining = remainingAsInteger(
      upstream.headers.get("x-ratelimit-remaining"),
    );
    const payload = await upstream.json();

    if (!upstream.ok) {
      await rpc(supabaseUrl, secret, "futbeat_complete_provider_call", {
        p_reservation_id: reservationId,
        p_status: "FAILED",
        p_provider_remaining: remaining,
        p_http_status: upstream.status,
        p_error_code: `GOAL_API_HTTP_${upstream.status}`,
        p_metadata: { mode: "live" },
      });
      return json(502, {
        error: `GOAL API HTTP ${upstream.status}`,
        remaining,
      });
    }

    if (!payload || !Array.isArray(payload.data)) {
      await rpc(supabaseUrl, secret, "futbeat_complete_provider_call", {
        p_reservation_id: reservationId,
        p_status: "FAILED",
        p_provider_remaining: remaining,
        p_http_status: upstream.status,
        p_error_code: "INVALID_GOAL_LIVE_RESPONSE",
        p_metadata: { mode: "live" },
      });
      return json(502, { error: "Invalid GOAL API live response" });
    }

    const observations = await Promise.all(
      payload.data.map((item: unknown) =>
        normalizeFixture(item as Record<string, unknown>)
      ),
    );

    const persistence = await rpc(
      supabaseUrl,
      secret,
      "futbeat_record_live_batch",
      {
        p_provider: "goal_api",
        p_received_at: checkedAt,
        p_observations: observations,
      },
    );

    await rpc(supabaseUrl, secret, "futbeat_complete_provider_call", {
      p_reservation_id: reservationId,
      p_status: "SUCCEEDED",
      p_provider_remaining: remaining,
      p_http_status: upstream.status,
      p_error_code: null,
      p_metadata: {
        mode: "live",
        liveMatches: observations.length,
        insertedObservations: persistence?.insertedObservations ?? 0,
        duplicates: persistence?.duplicates ?? 0,
      },
    });

    return json(200, {
      provider: "goal_api",
      ok: true,
      liveMatches: observations.length,
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
          p_error_code: "GOAL_LIVE_WORKER_FAILURE",
          p_metadata: { mode: "live" },
        });
      } catch {
        // Preserve the original worker error.
      }
    }
    return json(502, { error: "GOAL live sync failed" });
  }
});
