import { createRemoteJWKSet, jwtVerify } from "npm:jose@6.1.0";
import { normalizeSofaScoreFixtures } from "../../../backend/providers/sofascore.mjs";
import { normalizeEspnFixtures } from "../../../backend/providers/espn.mjs";
import {
  collectGoalApiBaseIdentities,
  normalizeGoalApiFixtures,
} from "../../../backend/providers/goal_api.mjs";
import {
  collectGoalApiPlayerIdentities,
  normalizeGoalApiSquad,
} from "../../../backend/providers/goal_api_players.mjs";

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
  const allowedWorkflows = new Set([
    "henguido/FutBeat/.github/workflows/global-fixtures.yml@refs/heads/main",
    "henguido/FutBeat/.github/workflows/live-fixtures.yml@refs/heads/main",
  ]);
  if (!allowedWorkflows.has(workflow)) {
    throw new Error("Unexpected GitHub workflow");
  }
}

function clean(value: unknown) {
  return String(value ?? "").trim();
}

function goalLiveStatus(fixture: Record<string, unknown>) {
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

function goalLiveScore(value: unknown) {
  if (value == null || value === "") return null;
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : null;
}

async function sha256Hex(value: string) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(digest)]
    .map((item) => item.toString(16).padStart(2, "0"))
    .join("");
}

async function normalizeGoalLiveFixture(fixture: Record<string, unknown>) {
  const externalMatchId = clean(fixture.apiId ?? fixture.id);
  if (!externalMatchId) throw new Error("Missing GOAL API live fixture id");

  const status = goalLiveStatus(fixture);
  const elapsed = Number(fixture.matchElapsed);
  const minute = Number.isInteger(elapsed) && elapsed >= 0 ? elapsed : null;
  const home = goalLiveScore(fixture.homeTeamScore);
  const away = goalLiveScore(fixture.awayTeamScore);
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

function mergeById(...lists: unknown[]) {
  const merged = new Map<string, Record<string, unknown>>();
  for (const list of lists) {
    if (!Array.isArray(list)) continue;
    for (const item of list) {
      if (!item || typeof item !== "object" || Array.isArray(item)) continue;
      const row = item as Record<string, unknown>;
      const id = String(row.id ?? "");
      if (id) merged.set(id, row);
    }
  }
  return [...merged.values()];
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
    action?: string;
    source?: string;
    mode?: string;
    dates?: unknown[];
    coverage?: unknown[];
    events?: unknown[];
    fromDate?: string;
    toDate?: string;
    limit?: number;
    teamId?: string;
    externalTeamId?: string;
    providerRemaining?: number | null;
    players?: unknown;
    reservationId?: number;
    errorCode?: string;
    httpStatus?: number | null;
  };
  try {
    input = await request.json();
  } catch {
    return Response.json({ error: "Invalid JSON" }, { status: 400 });
  }

  if (input.action === "live-plan") {
    try {
      const reservation = await rpc("futbeat_reserve_goal_live_call", {
        p_trigger_source: "github-actions",
      });
      return Response.json({
        status: reservation?.allowed ? "ok" : "skipped",
        reservation,
      });
    } catch (error) {
      console.error(
        "GOAL live reservation failed",
        error instanceof Error ? error.message : "unknown",
      );
      return Response.json({ error: "GOAL live plan unavailable" }, {
        status: 502,
      });
    }
  }

  if (input.action === "live-fail") {
    if (
      !Number.isInteger(input.reservationId) ||
      Number(input.reservationId) < 1
    ) {
      return Response.json({ error: "Invalid live reservation" }, {
        status: 400,
      });
    }

    try {
      await rpc("futbeat_complete_provider_call", {
        p_reservation_id: input.reservationId,
        p_status: "FAILED",
        p_provider_remaining: input.providerRemaining ?? null,
        p_http_status: input.httpStatus ?? null,
        p_error_code: clean(input.errorCode || "GOAL_LIVE_FETCH_FAILED").slice(0, 80),
        p_metadata: {
          mode: "live",
          transport: "github-actions-oidc",
        },
      });
      return Response.json({ status: "ok" });
    } catch {
      return Response.json({ error: "GOAL live failure not recorded" }, {
        status: 502,
      });
    }
  }

  if (input.action === "live-ingest") {
    if (
      !Number.isInteger(input.reservationId) ||
      Number(input.reservationId) < 1 ||
      !Array.isArray(input.events) ||
      (
        input.providerRemaining != null &&
        (!Number.isInteger(input.providerRemaining) ||
          input.providerRemaining < 0)
      )
    ) {
      return Response.json({ error: "Invalid GOAL live payload" }, {
        status: 400,
      });
    }

    const receivedAt = new Date().toISOString();
    const started = performance.now();

    try {
      const observations = await Promise.all(
        input.events.map((item) => {
          if (!item || typeof item !== "object" || Array.isArray(item)) {
            throw new Error("Invalid GOAL live fixture");
          }
          return normalizeGoalLiveFixture(item as Record<string, unknown>);
        }),
      );

      const persistence = await rpc("futbeat_record_live_batch", {
        p_provider: "goal_api",
        p_received_at: receivedAt,
        p_observations: observations,
      }, 30000);

      await rpc("futbeat_complete_provider_call", {
        p_reservation_id: input.reservationId,
        p_status: "SUCCEEDED",
        p_provider_remaining: input.providerRemaining ?? null,
        p_http_status: 200,
        p_error_code: null,
        p_metadata: {
          mode: "live",
          liveMatches: observations.length,
          insertedObservations: persistence?.insertedObservations ?? 0,
          duplicates: persistence?.duplicates ?? 0,
          durationMs: Math.round(performance.now() - started),
          transport: "github-actions-oidc",
          provider: "GOAL API",
        },
      });

      return Response.json({
        status: "ok",
        provider: "GOAL API",
        liveMatches: observations.length,
        persistence,
      });
    } catch (error) {
      const detail =
        error instanceof Error ? error.message.slice(0, 500) : "unknown";
      try {
        await rpc("futbeat_complete_provider_call", {
          p_reservation_id: input.reservationId,
          p_status: "FAILED",
          p_provider_remaining: input.providerRemaining ?? null,
          p_http_status: null,
          p_error_code: "GOAL_LIVE_INGEST_FAILED",
          p_metadata: {
            mode: "live",
            detail,
            durationMs: Math.round(performance.now() - started),
            transport: "github-actions-oidc",
          },
        });
      } catch {
        // Preserve the original ingestion error.
      }
      console.error("GOAL live ingest failed", detail);
      return Response.json(
        { error: "GOAL live ingest failed", detail },
        { status: 502 },
      );
    }
  }

  if (input.action === "squad-plan") {
    if (
      !Number.isInteger(input.limit) ||
      Number(input.limit) < 1 ||
      Number(input.limit) > 25
    ) {
      return Response.json({ error: "Invalid squad plan request" }, {
        status: 400,
      });
    }

    try {
      const teams = await rpc("futbeat_team_squad_plan", {
        p_limit: input.limit,
      });
      return Response.json({
        status: "ok",
        teams: Array.isArray(teams) ? teams : [],
      });
    } catch (error) {
      console.error(
        "squad plan failed",
        error instanceof Error ? error.message : "unknown",
      );
      return Response.json({ error: "Squad plan unavailable" }, {
        status: 502,
      });
    }
  }

  if (input.action === "squad-ingest") {
    if (
      typeof input.teamId !== "string" ||
      !input.teamId.startsWith("fb_team_") ||
      typeof input.externalTeamId !== "string" ||
      input.externalTeamId.trim().length < 1 ||
      (
        input.providerRemaining != null &&
        (!Number.isInteger(input.providerRemaining) || input.providerRemaining < 0)
      ) ||
      input.players == null
    ) {
      return Response.json({ error: "Invalid squad payload" }, {
        status: 400,
      });
    }

    const reservation = await rpc("futbeat_reserve_provider_call", {
      p_provider: "goal_api",
      p_call_kind: "team-squad-ingest",
      p_trigger_source: "github-actions",
      p_daily_limit: 16,
      p_min_interval_seconds: 0,
      p_force: true,
    });
    if (!reservation.allowed) {
      return Response.json({ status: "skipped", reason: reservation.reason });
    }

    const receivedAt = new Date().toISOString();
    const started = performance.now();
    let stage = "resolve-players";

    try {
      const identities = collectGoalApiPlayerIdentities(input.players);
      const resolved = new Map<string, string>();
      await resolveIdentityItems("goal_api", identities, resolved);

      stage = "normalize-players";
      const players = await normalizeGoalApiSquad(
        input.players,
        input.teamId,
        localResolver(resolved),
        receivedAt,
      );

      stage = "store-squad";
      const result = await rpc("futbeat_store_team_squad", {
        p_team_id: input.teamId,
        p_provider: "goal_api",
        p_received_at: receivedAt,
        p_players: players,
      }, 30000);

      const durationMs = Math.round(performance.now() - started);
      await rpc("futbeat_complete_provider_call", {
        p_reservation_id: reservation.reservationId,
        p_status: "SUCCEEDED",
        p_provider_remaining: input.providerRemaining ?? null,
        p_http_status: 200,
        p_error_code: null,
        p_metadata: {
          stage: "complete",
          mode: "team-squad",
          teamId: input.teamId,
          externalTeamId: input.externalTeamId,
          players: players.length,
          durationMs,
          transport: "github-actions-oidc",
          provider: "GOAL API",
        },
      });

      return Response.json({
        status: "ok",
        teamId: input.teamId,
        externalTeamId: input.externalTeamId,
        players: players.length,
        result,
      });
    } catch (error) {
      const detail =
        error instanceof Error ? error.message.slice(0, 500) : "unknown";
      try {
        await rpc("futbeat_complete_provider_call", {
          p_reservation_id: reservation.reservationId,
          p_status: "FAILED",
          p_provider_remaining: input.providerRemaining ?? null,
          p_http_status: null,
          p_error_code: "SQUAD_INGEST_FAILED",
          p_metadata: {
            stage,
            detail,
            mode: "team-squad",
            teamId: input.teamId,
            externalTeamId: input.externalTeamId,
            durationMs: Math.round(performance.now() - started),
            transport: "github-actions-oidc",
          },
        });
      } catch {
        // Preserve the original ingestion error.
      }
      console.error("squad ingest failed", stage, detail);
      return Response.json(
        { error: "Squad ingest failed", stage, detail },
        { status: 502 },
      );
    }
  }

  if (input.action === "calendar-plan") {
    if (
      !validDate(input.fromDate) ||
      !validDate(input.toDate) ||
      !Number.isInteger(input.limit) ||
      Number(input.limit) < 1 ||
      Number(input.limit) > 90
    ) {
      return Response.json({ error: "Invalid calendar plan request" }, {
        status: 400,
      });
    }

    try {
      const dates = await rpc("futbeat_calendar_missing_provider_dates", {
        p_provider: "goal_api",
        p_from_date: input.fromDate,
        p_to_date: input.toDate,
        p_limit: input.limit,
      });
      return Response.json({
        status: "ok",
        dates: Array.isArray(dates) ? dates : [],
      });
    } catch (error) {
      console.error(
        "calendar plan failed",
        error instanceof Error ? error.message : "unknown",
      );
      return Response.json({ error: "Calendar plan unavailable" }, {
        status: 502,
      });
    }
  }

  const mode = input.mode === "calendar" ? "calendar" : "hot";
  const validDateCount = Array.isArray(input.dates) &&
    input.dates.every(validDate) &&
    (
      (mode === "hot" && input.dates.length === 3) ||
      (mode === "calendar" && input.dates.length >= 1 && input.dates.length <= 31)
    );

  if (
    !["SofaScore", "ESPN", "GOAL API"].includes(input.source ?? "") ||
    !validDateCount ||
    !Array.isArray(input.events) ||
    (mode === "calendar" && input.source !== "GOAL API") ||
    (
      mode === "calendar" &&
      (
        !Array.isArray(input.coverage) ||
        input.coverage.length !== input.dates!.length
      )
    )
  ) {
    return Response.json({ error: "Invalid global fixture payload" }, {
      status: 400,
    });
  }

  const dates = [...input.dates!].sort() as string[];
  let events = input.events.filter(
    (event): event is Record<string, unknown> =>
      Boolean(event && typeof event === "object" && !Array.isArray(event)),
  );
  if (events.length !== input.events.length) {
    return Response.json({ error: "Invalid event item" }, { status: 400 });
  }

  if (input.source === "GOAL API" && mode === "hot") {
    events = events.filter((event) => withinCostaRicaWindow(event, dates));
  }

  const coverage = mode === "calendar"
    ? (input.coverage ?? []).filter(
      (item): item is Record<string, unknown> =>
        Boolean(item && typeof item === "object" && !Array.isArray(item)),
    )
    : [];
  if (mode === "calendar" && coverage.length !== input.coverage!.length) {
    return Response.json({ error: "Invalid calendar coverage item" }, {
      status: 400,
    });
  }

  const provider = input.source === "ESPN"
    ? "espn"
    : input.source === "GOAL API"
    ? "goal_api"
    : "sofascore";

  const reservation = await rpc("futbeat_reserve_provider_call", {
    p_provider: provider,
    p_call_kind: mode === "calendar" ? "calendar-ingest" : "global-ingest",
    p_trigger_source: "github-actions",
    p_daily_limit: mode === "calendar" ? 64 : 24,
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
    const baseExisting = await rpc("futbeat_read_snapshot");
    let existing = baseExisting;

    if (mode === "calendar") {
      const daySnapshots = [];
      for (const date of dates) {
        daySnapshots.push(
          await rpc("futbeat_read_calendar_range", {
            p_from_date: date,
            p_to_date: date,
            p_timezone: "UTC",
          }),
        );
      }
      existing = {
        ...baseExisting,
        competitions: mergeById(
          baseExisting?.competitions,
          ...daySnapshots.map((snapshot) => snapshot?.competitions),
        ),
        teams: mergeById(
          baseExisting?.teams,
          ...daySnapshots.map((snapshot) => snapshot?.teams),
        ),
        matches: mergeById(
          baseExisting?.matches,
          ...daySnapshots.map((snapshot) => snapshot?.matches),
        ),
      };
    }

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
    const result = mode === "calendar"
      ? await rpc(
        "futbeat_store_calendar_range",
        {
          p_provider: provider,
          p_received_at: receivedAt,
          p_coverage: coverage,
          p_snapshot: snapshot,
        },
        60000,
      )
      : await rpc(
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
        mode,
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
      mode,
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
        mode,
      },
    });
    console.error("global ingest failed", stage, detail);
    return Response.json(
      { error: "Global fixture ingest failed", stage, detail },
      { status: 502 },
    );
  }
});
