import { createRemoteJWKSet, jwtVerify } from "npm:jose@6.2.12";
import { normalizeSofaScoreSchedule } from "../../../backend/providers/sofascore.mjs";

const PROJECT_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ISSUER = "https://token.actions.githubusercontent.com";
const AUDIENCE = "futbeat-global-ingest";
const EXPECTED_REPOSITORY = "henguido/FutBeat";
const EXPECTED_REPOSITORY_ID = "1372177190";
const EXPECTED_REF = "refs/heads/main";
const EXPECTED_WORKFLOW_REF =
  "henguido/FutBeat/.github/workflows/global-schedule.yml@refs/heads/main";
const JWKS = createRemoteJWKSet(
  new URL("https://token.actions.githubusercontent.com/.well-known/jwks"),
);

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function defaultSecret() {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    if (typeof keys.default === "string" && keys.default) return keys.default;
  } catch {
    // Fall through to legacy server key while the project transitions.
  }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}

async function authorizeGitHub(req: Request) {
  const header = req.headers.get("authorization") ?? "";
  const token = header.replace(/^Bearer\s+/i, "");
  if (!token || token === header) return null;

  try {
    const { payload } = await jwtVerify(token, JWKS, {
      issuer: ISSUER,
      audience: AUDIENCE,
    });

    const event = String(payload.event_name ?? "");
    if (
      payload.repository !== EXPECTED_REPOSITORY ||
      String(payload.repository_id ?? "") !== EXPECTED_REPOSITORY_ID ||
      payload.ref !== EXPECTED_REF ||
      payload.workflow_ref !== EXPECTED_WORKFLOW_REF ||
      !["schedule", "workflow_dispatch"].includes(event)
    ) {
      return null;
    }

    return {
      event,
      runId: String(payload.run_id ?? ""),
      runNumber: String(payload.run_number ?? ""),
      actor: String(payload.actor ?? ""),
      sha: String(payload.sha ?? ""),
    };
  } catch {
    return null;
  }
}

async function rpc(secret: string, name: string, body: unknown) {
  if (!PROJECT_URL || !secret) throw new Error("Persistence not configured");
  const response = await fetch(`${PROJECT_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: secret,
      "content-type": "application/json",
      accept: "application/json",
    },
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
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  const github = await authorizeGitHub(req);
  if (!github) return json(403, { error: "Forbidden" });

  const secret = defaultSecret();
  if (!secret || !PROJECT_URL) {
    return json(503, { error: "Persistence not configured" });
  }

  let raw: {
    provider?: string;
    days?: Array<{ date?: string; endpoint?: string; events?: unknown[] }>;
    results?: number;
  };
  try {
    raw = await req.json();
  } catch {
    return json(400, { error: "Invalid JSON body" });
  }

  if (
    raw?.provider !== "SofaScore" ||
    !Array.isArray(raw.days) ||
    raw.days.length < 1 ||
    raw.days.some(
      (day) =>
        !/^\d{4}-\d{2}-\d{2}$/.test(String(day?.date ?? "")) ||
        !Array.isArray(day?.events),
    )
  ) {
    return json(400, { error: "Invalid global schedule payload" });
  }

  const dates = raw.days.map((day) => String(day.date)).sort();
  const receivedAt = new Date().toISOString();
  let reservationId: number | null = null;
  let stage = "reserve";
  const started = performance.now();

  try {
    const reservation = await rpc(secret, "futbeat_reserve_provider_call", {
      p_provider: "sofascore",
      p_call_kind: "global-three-day-github",
      p_trigger_source: `github-${github.event}`,
      p_daily_limit: 48,
      p_min_interval_seconds: 1800,
      p_force: true,
    });

    if (!reservation?.allowed) {
      return json(200, {
        status: "skipped",
        reason: reservation?.reason ?? "quota_guard",
        quota: reservation,
      });
    }
    reservationId = Number(reservation.reservationId);

    stage = "normalize";
    const resolveEntity = (
      kind: string,
      external: string,
      identity: { name: string; country?: string; shortName?: string },
    ) =>
      rpc(secret, "futbeat_resolve_global_entity", {
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
      rpc(secret, "futbeat_resolve_global_match", {
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
    const result = await rpc(secret, "futbeat_store_global_fixture_window", {
      p_job_id: crypto.randomUUID(),
      p_received_at: receivedAt,
      p_from_date: dates[0],
      p_to_date: dates[dates.length - 1],
      p_raw: raw,
      p_snapshot: snapshot,
    });

    await rpc(secret, "futbeat_complete_provider_call", {
      p_reservation_id: reservationId,
      p_status: "SUCCEEDED",
      p_provider_remaining: null,
      p_http_status: 200,
      p_error_code: null,
      p_metadata: {
        source: "github_oidc",
        event: github.event,
        runId: github.runId,
        runNumber: github.runNumber,
        sha: github.sha,
        dates,
        received: Number(raw.results ?? 0),
        accepted: snapshot.matches.length,
        competitions: snapshot.competitions.length,
        durationMs: Math.round(performance.now() - started),
      },
    });

    return json(200, {
      status: "ok",
      dates,
      received: Number(raw.results ?? 0),
      accepted: snapshot.matches.length,
      competitions: snapshot.competitions.length,
      result,
    });
  } catch (error) {
    const detail = error instanceof Error ? error.message.slice(0, 360) : "unknown";
    if (reservationId != null) {
      try {
        await rpc(secret, "futbeat_complete_provider_call", {
          p_reservation_id: reservationId,
          p_status: "FAILED",
          p_provider_remaining: null,
          p_http_status: null,
          p_error_code: "GLOBAL_INGEST_FAILED",
          p_metadata: {
            source: "github_oidc",
            event: github.event,
            runId: github.runId,
            stage,
            detail,
            durationMs: Math.round(performance.now() - started),
          },
        });
      } catch {
        // Do not mask the original ingestion failure.
      }
    }
    console.error("global ingest failed", stage, detail);
    return json(502, { error: "Global ingest failed", stage });
  }
});
