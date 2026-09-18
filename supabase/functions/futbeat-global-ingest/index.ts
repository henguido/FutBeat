import { createRemoteJWKSet, jwtVerify } from "npm:jose@6.1.0";
import { normalizeSofaScoreFixtures } from "../../../backend/providers/sofascore.mjs";
import { normalizeEspnFixtures } from "../../../backend/providers/espn.mjs";
import {
  collectGoalApiBaseIdentities,
  normalizeGoalApiFixtures,
} from "../../../backend/providers/goal_api.mjs";

const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const headers = {
  apikey: serviceKey,
  Authorization: `Bearer ${serviceKey}`,
  "Content-Type": "application/json",
};

const githubJwks = createRemoteJWKSet(
  new URL("https://token.actions.githubusercontent.com/.well-known/jwks"),
);

const rpc = async (
  name: string,
  body: unknown = {},
  timeoutMs = 20000,
) => {
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(
      `RPC ${name} failed: ${response.status}${text ? ` ${text.slice(0, 180)}` : ""}`,
    );
  }
  return text ? JSON.parse(text) : null;
};

async function authorize(request: Request) {
  const token = request.headers
    .get("authorization")
    ?.replace(/^Bearer\s+/i, "");
  if (!token) throw new Error("Missing GitHub OIDC token");

  const { payload } = await jwtVerify(token, githubJwks, {
    issuer: "https://token.actions.githubusercontent.com",
    audience: "futbeat-global-ingest",
  });

  if (payload.repository !== "henguido/FutBeat") {
    throw new Error("Unexpected GitHub repository");
  }
  if (payload.ref !== "refs/heads/main") {
    throw new Error("Unexpected GitHub ref");
  }
  if (!["schedule", "workflow_dispatch", "push"].includes(String(payload.event_name))) {
    throw new Error("Unexpected GitHub event");
  }
  const workflow = String(
    payload.workflow_ref ?? payload.job_workflow_ref ?? "",
  );
  if (
    workflow !==
    "henguido/FutBeat/.github/workflows/global-fixtures.yml@refs/heads/main"
  ) {
    throw new Error("Unexpected GitHub workflow");
  }
}

function validDate(value: unknown): value is string {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value);
}

function nextDate(value: string) {
  const date = new Date(`${value}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + 1);
  return date.toISOString().slice(0, 10);
}

function withinCostaRicaWindow(
  event: Record<string, unknown>,
  dates: string[],
) {
  const kickoff = String(event.kickoffUtc ?? "");
  const instant = Date.parse(kickoff);
  if (!Number.isFinite(instant)) return false;

  const start = Date.parse(`${dates[0]}T06:00:00Z`);
  const end = Date.parse(`${nextDate(dates[2])}T06:00:00Z`);
  return instant >= start && instant < end;
}

const entityKey = (kind: string, external: string) => `${kind}:${external}`;

function addResolvedRows(
  target: Map<string, string>,
  rows: unknown,
) {
  if (!Array.isArray(rows)) throw new Error("Invalid batch resolver response");

  for (const row of rows) {
    if (!row || typeof row !== "object" || Array.isArray(row)) {
      throw new Error("Invalid batch resolver row");
    }
    const item = row as Record<string, unknown>;
    const kind = String(item.entity_kind ?? "");
    const external = String(item.external_id ?? "");
    const canonical = String(item.canonical_id ?? "");
    if (!kind || !external || !canonical) {
      throw new Error("Incomplete batch resolver row");
    }
    target.set(entityKey(kind, external), canonical);
  }
}

function localResolver(resolved: Map<string, string>) {
  return async (kind: string, external: string) => {
    const canonical = resolved.get(entityKey(kind, external));
    if (!canonical) {
      throw new Error(`Missing canonical identity for ${kind}:${external}`);
    }
    return canonical;
  };
}

async function resolveIdentityItems(
  provider: string,
  items: Array<Record<string, unknown>>,
  target: Map<string, string>,
) {
  const chunkSize = 800;
  for (let offset = 0; offset < items.length; offset += chunkSize) {
    const chunk = items.slice(offset, offset + chunkSize);
    const rows = await rpc(
      "futbeat_resolve_global_entities",
      {
        p_provider: provider,
        p_items: chunk,
      },
      60000,
    );
    if (!Array.isArray(rows) || rows.length !== chunk.length) {
      throw new Error(
        `Incomplete batch resolver response: ${Array.isArray(rows) ? rows.length : 0}/${chunk.length}`,
      );
    }
    addResolvedRows(target, rows);
  }
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });

  try {
    await authorize(request);
  } catch (error) {
    console.error(
      "global ingest authorization rejected",
      error instanceof Error ? error.message : "unknown",
    );
    return Response.json({ error: "Forbidden" }, { status: 403 });
  }

  let input: {
    source?: string;
    dates?: unknown[];
    events?: unknown[];
  };
  try {
    input = await request.json();
  } catch {
    return Response.json({ error: "Invalid JSON" }, { status: 400 });
  }

  if (
    !["SofaScore", "ESPN", "GOAL API"].includes(input.source ?? "") ||
    !Array.isArray(input.dates) ||
    input.dates.length !== 3 ||
    !input.dates.every(validDate) ||
    !Array.isArray(input.events)
  ) {
    return Response.json({ error: "Invalid global fixture payload" }, {
      status: 400,
    });
  }

  const dates = [...input.dates].sort() as string[];
  let events = input.events.filter(
    (event): event is Record<string, unknown> =>
      Boolean(event && typeof event === "object" && !Array.isArray(event)),
  );
  if (events.length !== input.events.length) {
    return Response.json({ error: "Invalid event item" }, { status: 400 });
  }

  if (input.source === "GOAL API") {
    events = events.filter((event) => withinCostaRicaWindow(event, dates));
  }

  const provider = input.source === "ESPN"
    ? "espn"
    : input.source === "GOAL API"
    ? "goal_api"
    : "sofascore";

  const reservation = await rpc("futbeat_reserve_provider_call", {
    p_provider: provider,
    p_call_kind: "global-ingest",
    p_trigger_source: "github-actions",
    p_daily_limit: 24,
    p_min_interval_seconds: 0,
    p_force: true,
  });
  if (!reservation.allowed) {
    return Response.json({ status: "skipped", reason: reservation.reason });
  }

  const receivedAt = new Date().toISOString();
  const started = performance.now();
  let stage = "read-current";
  let resolvedBase = 0;
  let resolvedMatches = 0;

  try {
    const existing = await rpc("futbeat_read_snapshot");

    let snapshot;
    if (input.source === "GOAL API") {
      const resolved = new Map<string, string>();

      stage = "resolve-base";
      const baseIdentities = collectGoalApiBaseIdentities(events);
      await resolveIdentityItems(
        provider,
        baseIdentities,
        resolved,
      );
      resolvedBase = resolved.size;

      stage = "discover-matches";
      const pendingMatches = new Map<string, {
        kind: string;
        external: string;
        name: string;
        country: string;
        shortName: string;
      }>();
      const temporaryIds = new Map<string, string>();
      let sequence = 0;

      const discoveryResolver = async (
        kind: string,
        external: string,
        identity: { name?: string; country?: string; shortName?: string },
      ) => {
        if (kind !== "match") {
          const canonical = resolved.get(entityKey(kind, external));
          if (!canonical) {
            throw new Error(`Missing base canonical identity for ${kind}:${external}`);
          }
          return canonical;
        }

        const key = entityKey(kind, external);
        if (!pendingMatches.has(key)) {
          pendingMatches.set(key, {
            kind,
            external,
            name: identity.name ?? "",
            country: identity.country ?? "",
            shortName: identity.shortName ?? "",
          });
        }
        if (!temporaryIds.has(key)) {
          sequence += 1;
          temporaryIds.set(key, `fb_match_pending_${sequence}`);
        }
        return temporaryIds.get(key)!;
      };

      await normalizeGoalApiFixtures(
        events,
        discoveryResolver,
        receivedAt,
        existing,
      );

      stage = "resolve-matches";
      const matchIdentities = [...pendingMatches.values()];
      await resolveIdentityItems(
        provider,
        matchIdentities,
        resolved,
      );
      resolvedMatches = matchIdentities.length;

      stage = "normalize";
      snapshot = await normalizeGoalApiFixtures(
        events,
        localResolver(resolved),
        receivedAt,
        existing,
      );
    } else {
      stage = "normalize";
      const resolve = (
        kind: string,
        external: string,
        identity: { name?: string; country?: string; shortName?: string },
      ) =>
        rpc("futbeat_resolve_global_entity", {
          p_provider: provider,
          p_kind: kind,
          p_external: external,
          p_name: identity.name ?? "",
          p_country: identity.country ?? "",
          p_short_name: identity.shortName ?? "",
        });

      snapshot = input.source === "ESPN"
        ? await normalizeEspnFixtures(events, resolve, receivedAt, existing)
        : await normalizeSofaScoreFixtures(events, resolve, receivedAt, existing);
    }

    stage = "store";
    const result = await rpc(
      "futbeat_store_global_fixture_window",
      {
        p_job_id: crypto.randomUUID(),
        p_received_at: receivedAt,
        p_from_date: dates[0],
        p_to_date: dates[2],
        p_raw: {
          provider: input.source,
          transport: "GitHub Actions OIDC",
          dates,
          events,
        },
        p_snapshot: snapshot,
      },
      60000,
    );

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
        resolvedBase,
        resolvedMatches,
        transport: "github-actions-oidc",
        provider: input.source,
      },
    });

    return Response.json({
      status: "ok",
      dates,
      received: events.length,
      accepted: snapshot.matches.length,
      competitions: snapshot.competitions.length,
      teams: snapshot.teams.length,
      resolvedBase,
      resolvedMatches,
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
      p_error_code: "GLOBAL_INGEST_FAILED",
      p_metadata: {
        stage,
        detail,
        durationMs: Math.round(performance.now() - started),
        resolvedBase,
        resolvedMatches,
        transport: "github-actions-oidc",
      },
    });
    console.error("global ingest failed", stage, detail);
    return Response.json(
      { error: "Global fixture ingest failed", stage, detail },
      { status: 502 },
    );
  }
});
