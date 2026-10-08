import { createRemoteJWKSet, jwtVerify } from "npm:jose@6.1.0";
import { normalizeSofaScoreFixtures } from "../../../backend/providers/sofascore.mjs";
import { normalizeEspnFixtures } from "../../../backend/providers/espn.mjs";
import { goalFixtureScore } from "../_shared/live_events.ts";
import { runChunksWithTimeoutRetry } from "../_shared/chunked_rpc.ts";
import {
  collectGoalApiBaseIdentities,
  normalizeGoalApiFixtures,
} from "../../../backend/providers/goal_api.mjs";
import {
  collectGoalApiPlayerIdentities,
  normalizeGoalApiSquad,
} from "../../../backend/providers/goal_api_players.mjs";
import { goalStandingsShape, isGoalStandingsNoData } from "../_shared/goal_standings.ts";

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

async function secureEqual(left: string, right: string) {
  if (!left || !right) return false;
  const [a, b] = await Promise.all([sha256Hex(left), sha256Hex(right)]);
  return a === b;
}

async function authorize(request: Request) {
  const internalToken = String(
    request.headers.get("x-futbeat-cron-token") ?? "",
  ).trim();
  if (internalToken) {
    const expected = String(
      await rpc("futbeat_read_goal_live_cron_token") ?? "",
    ).trim();
    if (await secureEqual(expected, internalToken)) {
      return "supabase-cron";
    }
    throw new Error("Invalid Supabase internal token");
  }

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
    "henguido/FutBeat/.github/workflows/standings.yml@refs/heads/main",
  ]);
  if (!allowedWorkflows.has(workflow)) {
    throw new Error("Unexpected GitHub workflow");
  }
  return workflow;
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
  const { home, away } = goalFixtureScore(fixture);
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

// Arguments of futbeat_read_ingest_context for one GOAL batch: the canonical
// competitions and teams resolved for it (deduplicated) and the kickoff
// window of its fixtures (existing matches are only reused within 5 min).
function ingestContextRequest(
  events: Array<Record<string, unknown>>,
  resolved: Map<string, string>,
) {
  const competitions = new Set<string>();
  const teams = new Set<string>();
  for (const [key, canonical] of resolved) {
    if (key.startsWith("competition:")) competitions.add(canonical);
    else if (key.startsWith("team:")) teams.add(canonical);
  }
  let from = Infinity;
  let to = -Infinity;
  for (const event of events) {
    const kickoff = Date.parse(String(event?.kickoffUtc ?? ""));
    if (!Number.isFinite(kickoff)) continue;
    from = Math.min(from, kickoff);
    to = Math.max(to, kickoff);
  }
  return {
    p_competition_ids: [...competitions].sort(),
    p_team_ids: [...teams].sort(),
    p_from: Number.isFinite(from) ? new Date(from).toISOString() : null,
    p_to: Number.isFinite(to) ? new Date(to).toISOString() : null,
  };
}

// Calendar batches are ingested one UTC date at a time (resolve-base,
// read-current, normalize and store per date). Production 2026-10-07: a batch
// of three dates (~3,000 fixtures) timed out at read-current (57014). Each
// event goes to its kickoff's UTC date: futbeat_store_calendar_range removes
// the GOAL rows of a covered date that are absent from the stored snapshot,
// so every fixture of date D must be in D's snapshot. A kickoff outside the
// batch dates (or missing) goes to the nearest date (the first one); it only
// adds or updates its match there.
function calendarDateGroups(
  events: Array<Record<string, unknown>>,
  dates: string[],
) {
  const groups = new Map<string, Array<Record<string, unknown>>>(
    dates.map((date) => [date, []]),
  );
  const dayOf = (date: string) => Date.parse(`${date}T00:00:00.000Z`) / 86400000;
  for (const event of events) {
    const kickoff = Date.parse(String(event?.kickoffUtc ?? ""));
    let target = dates[0];
    if (Number.isFinite(kickoff)) {
      const date = new Date(kickoff).toISOString().slice(0, 10);
      if (groups.has(date)) {
        target = date;
      } else {
        const day = Math.floor(kickoff / 86400000);
        for (const candidate of dates) {
          if (Math.abs(dayOf(candidate) - day) < Math.abs(dayOf(target) - day)) {
            target = candidate;
          }
        }
      }
    }
    groups.get(target)!.push(event);
  }
  return groups;
}

// Production 2026-10-08 (#158/#159, v38): the date 2026-09-19 (1,477
// fixtures) hit 57014 under the API role's 8 s statement timeout at
// read-current (8.6 s) and then at store (11.0 s); 2026-09-18 (430) stored
// in 6.0 s. A date with more fixtures than this is ingested in bounded
// sub-batches (resolve-base, read-current, normalize and store each), stored
// with an empty coverage (adds/updates only, nothing deleted), and finalized
// once with futbeat_finalize_calendar_date (deletes and coverage for the
// whole date). A date at or below it keeps the single-store path.
const CALENDAR_SUB_BATCH_MAX = 300;

// Kickoff order; a cut only falls between 5-minute kickoff buckets (the
// match reuse key, see goal_api.mjs), so two fixtures that may resolve to
// the same match are always in the same sub-batch. Missing kickoffs first.
function calendarSubBatches(
  events: Array<Record<string, unknown>>,
  max: number,
) {
  if (events.length <= max) return [events];
  const bucketOf = (event: Record<string, unknown>) => {
    const kickoff = Date.parse(String(event?.kickoffUtc ?? ""));
    return Number.isFinite(kickoff) ? Math.floor(kickoff / 300000) : -Infinity;
  };
  const sorted = events
    .map((event, index) => ({ event, index, bucket: bucketOf(event) }))
    .sort((a, b) =>
      a.bucket === b.bucket ? a.index - b.index : a.bucket < b.bucket ? -1 : 1
    );
  const batches: Array<Array<Record<string, unknown>>> = [];
  let current: Array<Record<string, unknown>> = [];
  for (let i = 0; i < sorted.length;) {
    let j = i;
    while (j < sorted.length && sorted[j].bucket === sorted[i].bucket) j += 1;
    if (j - i > max) {
      throw new Error("kickoff bucket exceeds calendar sub-batch maximum");
    }
    if (current.length > 0 && current.length + (j - i) > max) {
      batches.push(current);
      current = [];
    }
    for (let k = i; k < j; k += 1) current.push(sorted[k].event);
    i = j;
  }
  if (current.length > 0) batches.push(current);
  return batches;
}

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
  // Each chunk is one RPC = one transaction under the API role's 8 s
  // statement timeout. Production 2026-10-06: chunks of 800, then 100, timed
  // out (57014) at stage resolve-base (new identities ~23-48 ms each, plus
  // 3-9 s spikes on the first batch after a pause). 50 per chunk, and a chunk
  // that hits 57014 is run once more (it was rolled back; the resolver is
  // idempotent; no provider call). Chunks stay in order; a second failure or
  // any other error aborts the ingest.
  const chunkSize = 50;
  await runChunksWithTimeoutRetry(items, chunkSize, async (chunk) => {
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
    return rows.length;
  }, {
    retryDelayMs: 1500,
    onRetry: (index) => console.warn(`identity chunk ${index} hit 57014; retrying once`),
  });
}


// GOAL fixtures -> canonical snapshot: resolve base identities, discover the
// matches still unknown, resolve them, then normalize. Shared by the calendar
// ingest and the team-fixtures ingest so both use one identity path.
// `existing` is either the current snapshot, or a loader called right after
// the base identities are resolved (the targeted read needs their canonical
// ids). Only competitions[], teams[] and matches[] of it are used.
type ExistingLoader = (resolved: Map<string, string>) => Promise<unknown>;

async function normalizeGoalBatch(
  provider: string,
  events: Array<Record<string, unknown>>,
  existingOrLoader: unknown | ExistingLoader,
  receivedAt: string,
  onStage: (stage: string) => void,
) {
  let resolvedBase = 0;
  let resolvedMatches = 0;
  let snapshot;
  const resolved = new Map<string, string>();

  onStage("resolve-base");
  const baseIdentities = collectGoalApiBaseIdentities(events);
  await resolveIdentityItems(
    provider,
    baseIdentities,
    resolved,
  );
  resolvedBase = resolved.size;

  let existing = existingOrLoader;
  if (typeof existingOrLoader === "function") {
    onStage("read-current");
    existing = await (existingOrLoader as ExistingLoader)(resolved);
  }

  onStage("discover-matches");
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

  onStage("resolve-matches");
  const matchIdentities = [...pendingMatches.values()];
  await resolveIdentityItems(
    provider,
    matchIdentities,
    resolved,
  );
  resolvedMatches = matchIdentities.length;

  onStage("normalize");
  snapshot = await normalizeGoalApiFixtures(
    events,
    localResolver(resolved),
    receivedAt,
    existing,
  );
  return { snapshot, resolvedBase, resolvedMatches };
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });

  let authorizedWorkflow = "";
  try {
    authorizedWorkflow = await authorize(request);
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
    requestedOnly?: boolean;
    reserve?: number;
    teamId?: string;
    externalTeamId?: string;
    providerRemaining?: number | null;
    providerRequests?: number;
    providerTotal?: number | null;
    players?: unknown;
    reservationId?: number;
    reservationIds?: unknown[];
    externalTeamIds?: unknown[];
    complete?: boolean;
    errorCode?: string;
    providerCode?: string;
    httpStatus?: number | null;
    matchId?: string;
    externalMatchId?: string;
    detail?: unknown;
    competitionId?: string;
    externalLeagueId?: string;
    season?: string;
    rows?: unknown;
    goalApiKey?: string;
  };
  try {
    input = await request.json();
  } catch {
    return Response.json({ error: "Invalid JSON" }, { status: 400 });
  }

  if (
    authorizedWorkflow === "supabase-cron" &&
    input.action !== "squad-ingest" &&
    input.action !== "team-fixtures-ingest"
  ) {
    return Response.json({ error: "Forbidden" }, { status: 403 });
  }

  if (input.action === "goal-live-secret-provision") {
    if (
      authorizedWorkflow !==
        "henguido/FutBeat/.github/workflows/live-fixtures.yml@refs/heads/main"
    ) {
      return Response.json({ error: "Forbidden" }, { status: 403 });
    }

    const secret = typeof input.goalApiKey === "string"
      ? input.goalApiKey.trim()
      : "";
    if (secret.length < 16 || secret.length > 1024) {
      return Response.json({ error: "Invalid GOAL API key" }, { status: 400 });
    }

    try {
      const status = await rpc("futbeat_store_goal_live_secret", {
        p_secret: secret,
      });
      return Response.json({ status: "ok", transport: status });
    } catch (error) {
      console.error(
        "GOAL live secret provisioning failed",
        error instanceof Error ? error.message : "unknown",
      );
      return Response.json({ error: "GOAL live provisioning failed" }, {
        status: 502,
      });
    }
  }

  if (input.action === "global-quota-plan") {
    const reserve = input.reserve ?? 350;
    if (!Number.isInteger(reserve) || reserve < 50 || reserve > 900) {
      return Response.json({ error: "Invalid GOAL quota reserve" }, {
        status: 400,
      });
    }

    try {
      const plan = await rpc("futbeat_goal_low_priority_plan", {
        p_reserve: reserve,
      });
      return Response.json({
        status: plan?.allowed ? "ok" : "skipped",
        plan,
      });
    } catch (error) {
      console.error(
        "GOAL low-priority quota plan failed",
        error instanceof Error ? error.message : "unknown",
      );
      return Response.json({ error: "GOAL quota plan unavailable" }, {
        status: 502,
      });
    }
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
      const linkResult = await rpc("futbeat_link_goal_live_matches", {
        p_fixtures: input.events,
      }, 30000);

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
          linkedMatches: linkResult?.linked ?? 0,
          alreadyLinkedMatches: linkResult?.alreadyLinked ?? 0,
          unmappedMatches: linkResult?.unmappedCount ?? 0,
          providerRequests: input.providerRequests ?? 1,
          providerTotal: input.providerTotal ?? observations.length,
          insertedObservations: persistence?.insertedObservations ?? 0,
          duplicates: persistence?.duplicates ?? 0,
          durationMs: Math.round(performance.now() - started),
          transport: authorizedWorkflow === "supabase-cron"
            ? "supabase-cron"
            : "github-actions-oidc",
          provider: "GOAL API",
        },
      });

      return Response.json({
        status: "ok",
        provider: "GOAL API",
        liveMatches: observations.length,
        linkedMatches: linkResult?.linked ?? 0,
        alreadyLinkedMatches: linkResult?.alreadyLinked ?? 0,
        unmappedMatches: linkResult?.unmappedCount ?? 0,
        providerRequests: input.providerRequests ?? 1,
        providerTotal: input.providerTotal ?? observations.length,
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
            transport: authorizedWorkflow === "supabase-cron"
              ? "supabase-cron"
              : "github-actions-oidc",
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

  if (input.action === "match-detail-plan") {
    try {
      const reservation = await rpc("futbeat_reserve_match_detail_call", {
        p_trigger_source: "github-actions",
      });
      return Response.json({
        status: reservation?.allowed ? "ok" : "skipped",
        reservation,
      });
    } catch (error) {
      console.error(
        "match detail reservation failed",
        error instanceof Error ? error.message : "unknown",
      );
      return Response.json({ error: "Match detail plan unavailable" }, {
        status: 502,
      });
    }
  }

  if (input.action === "match-detail-fail") {
    if (
      !Number.isInteger(input.reservationId) ||
      Number(input.reservationId) < 1
    ) {
      return Response.json({ error: "Invalid match detail reservation" }, {
        status: 400,
      });
    }

    try {
      await rpc("futbeat_complete_provider_call", {
        p_reservation_id: input.reservationId,
        p_status: "FAILED",
        p_provider_remaining: input.providerRemaining ?? null,
        p_http_status: input.httpStatus ?? null,
        p_error_code: clean(
          input.errorCode || "GOAL_MATCH_DETAIL_FETCH_FAILED",
        ).slice(0, 80),
        p_metadata: {
          mode: "match-detail",
          matchId: input.matchId ?? null,
          externalMatchId: input.externalMatchId ?? null,
          transport: "github-actions-oidc",
        },
      });
      return Response.json({ status: "ok" });
    } catch {
      return Response.json({ error: "Match detail failure not recorded" }, {
        status: 502,
      });
    }
  }

  if (input.action === "match-detail-ingest") {
    if (
      !Number.isInteger(input.reservationId) ||
      Number(input.reservationId) < 1 ||
      typeof input.matchId !== "string" ||
      !input.matchId.startsWith("fb_match_") ||
      typeof input.externalMatchId !== "string" ||
      input.externalMatchId.trim().length < 1 ||
      !input.detail ||
      typeof input.detail !== "object" ||
      Array.isArray(input.detail) ||
      (
        input.providerRemaining != null &&
        (!Number.isInteger(input.providerRemaining) ||
          input.providerRemaining < 0)
      )
    ) {
      return Response.json({ error: "Invalid match detail payload" }, {
        status: 400,
      });
    }

    const fetchedAt = new Date().toISOString();
    const started = performance.now();
    try {
      const stored = await rpc("futbeat_store_match_detail", {
        p_match_id: input.matchId,
        p_external_match_id: input.externalMatchId,
        p_fetched_at: fetchedAt,
        p_payload: input.detail,
      }, 30000);

      await rpc("futbeat_complete_provider_call", {
        p_reservation_id: input.reservationId,
        p_status: "SUCCEEDED",
        p_provider_remaining: input.providerRemaining ?? null,
        p_http_status: 200,
        p_error_code: null,
        p_metadata: {
          mode: "match-detail",
          matchId: input.matchId,
          externalMatchId: input.externalMatchId,
          durationMs: Math.round(performance.now() - started),
          transport: "github-actions-oidc",
          provider: "GOAL API",
        },
      });

      return Response.json({
        status: "ok",
        matchId: input.matchId,
        externalMatchId: input.externalMatchId,
        detail: stored,
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
          p_error_code: "GOAL_MATCH_DETAIL_INGEST_FAILED",
          p_metadata: {
            mode: "match-detail",
            matchId: input.matchId,
            externalMatchId: input.externalMatchId,
            detail,
            durationMs: Math.round(performance.now() - started),
            transport: "github-actions-oidc",
          },
        });
      } catch {
        // Preserve the original ingestion error.
      }
      console.error("match detail ingest failed", detail);
      return Response.json(
        { error: "Match detail ingest failed", detail },
        { status: 502 },
      );
    }
  }

  if (input.action === "standings-plan") {
    try {
      const reservation = await rpc("futbeat_reserve_goal_standings_call", {
        p_trigger_source: "github-actions",
      });
      return Response.json({
        status: reservation?.allowed ? "ok" : "skipped",
        reservation,
      });
    } catch (error) {
      console.error(
        "standings plan failed",
        error instanceof Error ? error.message : "unknown",
      );
      return Response.json({ error: "Standings plan unavailable" }, {
        status: 502,
      });
    }
  }

  if (input.action === "standings-fail") {
    if (
      !Number.isInteger(input.reservationId) ||
      Number(input.reservationId) < 1
    ) {
      return Response.json({ error: "Invalid standings reservation" }, {
        status: 400,
      });
    }

    try {
      await rpc("futbeat_complete_provider_call", {
        p_reservation_id: input.reservationId,
        p_status: "FAILED",
        p_provider_remaining: input.providerRemaining ?? null,
        p_http_status: input.httpStatus ?? null,
        p_error_code: clean(
          input.errorCode || "GOAL_STANDINGS_FETCH_FAILED",
        ).slice(0, 80),
        p_metadata: {
          mode: "standings",
          competitionId: input.competitionId ?? null,
          externalLeagueId: input.externalLeagueId ?? null,
          providerCode: typeof input.providerCode === "string"
            ? clean(input.providerCode).slice(0, 80) || null
            : null,
          transport: "github-actions-oidc",
        },
      });
      return Response.json({ status: "ok" });
    } catch {
      return Response.json({ error: "Standings failure not recorded" }, {
        status: 502,
      });
    }
  }

  // #116: the provider answered that this league has no standings. Recorded
  // as a successful call with a bounded negative cache (coverage lane only);
  // the server re-checks the classification, so a real failure can never be
  // reported as "no data".
  if (input.action === "standings-no-data") {
    const httpStatus = input.httpStatus ?? null;
    const providerCode = typeof input.providerCode === "string"
      ? clean(input.providerCode).slice(0, 80)
      : "";
    if (
      !Number.isInteger(input.reservationId) ||
      Number(input.reservationId) < 1 ||
      typeof input.competitionId !== "string" ||
      !input.competitionId.startsWith("fb_comp") ||
      (httpStatus != null && !Number.isInteger(httpStatus)) ||
      !isGoalStandingsNoData(httpStatus, providerCode) ||
      (
        input.providerRemaining != null &&
        (!Number.isInteger(input.providerRemaining) ||
          input.providerRemaining < 0)
      )
    ) {
      return Response.json({ error: "Invalid standings no-data report" }, {
        status: 400,
      });
    }
    try {
      const result = await rpc("futbeat_record_standings_no_data", {
        p_reservation_id: input.reservationId,
        p_http_status: httpStatus,
        p_provider_code: providerCode,
        p_provider_remaining: input.providerRemaining ?? null,
        p_competition_id: input.competitionId,
      });
      return Response.json({ ...result, status: "no_data" });
    } catch (error) {
      console.error(
        "standings no-data record failed",
        error instanceof Error ? error.message.slice(0, 300) : "unknown",
      );
      return Response.json({ error: "Standings no-data not recorded" }, {
        status: 502,
      });
    }
  }

  if (input.action === "standings-ingest") {
    if (
      !Number.isInteger(input.reservationId) ||
      Number(input.reservationId) < 1 ||
      typeof input.competitionId !== "string" ||
      !input.competitionId.startsWith("fb_comp") ||
      typeof input.externalLeagueId !== "string" ||
      input.externalLeagueId.trim().length < 1 ||
      !Array.isArray(input.rows) ||
      input.rows.length < 2 ||
      (
        input.providerRemaining != null &&
        (!Number.isInteger(input.providerRemaining) ||
          input.providerRemaining < 0)
      )
    ) {
      return Response.json({ error: "Invalid standings payload" }, {
        status: 400,
      });
    }

    const receivedAt = new Date().toISOString();
    const started = performance.now();

    try {
      const result = await rpc("futbeat_store_goal_standings", {
        p_competition_id: input.competitionId,
        p_external_league_id: input.externalLeagueId,
        p_received_at: receivedAt,
        p_season: typeof input.season === "string" ? input.season : "",
        p_rows: input.rows,
      }, 30000);

      const shape = goalStandingsShape(input.rows);
      if (shape) {
        try {
          await rpc("futbeat_record_goal_standings_shape", {
            p_competition_id: input.competitionId,
            p_source: "scheduled",
            p_shape: shape,
          }, 3000);
        } catch {
          // Observability must not fail a successfully stored standings table.
          console.warn("standings shape capture unavailable");
        }
      }

      await rpc("futbeat_complete_provider_call", {
        p_reservation_id: input.reservationId,
        p_status: "SUCCEEDED",
        p_provider_remaining: input.providerRemaining ?? null,
        p_http_status: 200,
        p_error_code: null,
        p_metadata: {
          mode: "standings",
          competitionId: input.competitionId,
          externalLeagueId: input.externalLeagueId,
          rows: result?.rows ?? input.rows.length,
          durationMs: Math.round(performance.now() - started),
          transport: "github-actions-oidc",
          provider: "GOAL API",
        },
      });

      return Response.json({
        status: "ok",
        competitionId: input.competitionId,
        externalLeagueId: input.externalLeagueId,
        rows: result?.rows ?? input.rows.length,
        result,
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
          p_error_code: "GOAL_STANDINGS_INGEST_FAILED",
          p_metadata: {
            mode: "standings",
            competitionId: input.competitionId,
            externalLeagueId: input.externalLeagueId,
            detail,
            durationMs: Math.round(performance.now() - started),
            transport: "github-actions-oidc",
          },
        });
      } catch {
        // Preserve the original ingestion error.
      }
      console.error("standings ingest failed", detail);
      return Response.json(
        { error: "Standings ingest failed", detail },
        { status: 502 },
      );
    }
  }

  if (input.action === "squad-reserve") {
    if (
      typeof input.teamId !== "string" ||
      !input.teamId.startsWith("fb_team_") ||
      typeof input.externalTeamId !== "string" ||
      input.externalTeamId.trim().length < 1
    ) {
      return Response.json({ error: "Invalid squad reservation" }, {
        status: 400,
      });
    }

    try {
      const reservation = await rpc("futbeat_reserve_goal_squad_call", {
        p_team_id: input.teamId,
        p_external_team_id: input.externalTeamId,
        p_trigger_source: "github-actions",
      });
      return Response.json({
        status: reservation?.allowed ? "ok" : "skipped",
        reservation,
      });
    } catch (error) {
      console.error(
        "squad reservation failed",
        error instanceof Error ? error.message : "unknown",
      );
      return Response.json({ error: "Squad reservation unavailable" }, {
        status: 502,
      });
    }
  }

  if (input.action === "squad-fail") {
    if (
      !Number.isInteger(input.reservationId) ||
      Number(input.reservationId) < 1
    ) {
      return Response.json({ error: "Invalid squad reservation" }, {
        status: 400,
      });
    }

    try {
      await rpc("futbeat_complete_provider_call", {
        p_reservation_id: input.reservationId,
        p_status: "FAILED",
        p_provider_remaining: input.providerRemaining ?? null,
        p_http_status: input.httpStatus ?? null,
        p_error_code: clean(
          input.errorCode || "GOAL_SQUAD_FETCH_FAILED",
        ).slice(0, 80),
        p_metadata: {
          mode: "team-squad",
          stage: "provider-fetch",
          teamId: input.teamId ?? null,
          externalTeamId: input.externalTeamId ?? null,
          transport: "github-actions-oidc",
        },
      });
      return Response.json({ status: "ok" });
    } catch {
      return Response.json({ error: "Squad failure not recorded" }, {
        status: 502,
      });
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

  if (input.action === "team-fixtures-ingest") {
    const reservationIds = Array.isArray(input.reservationIds)
      ? input.reservationIds
      : [];
    const externalIds = Array.isArray(input.externalTeamIds)
      ? input.externalTeamIds
      : [];
    if (
      typeof input.teamId !== "string" ||
      !input.teamId.startsWith("fb_team_") ||
      !validDate(input.fromDate) ||
      !validDate(input.toDate) ||
      String(input.fromDate) > String(input.toDate) ||
      typeof input.complete !== "boolean" ||
      !Array.isArray(input.events) ||
      input.events.length > 900 ||
      reservationIds.length < 1 ||
      reservationIds.length > 9 ||
      !reservationIds.every((id) => Number.isInteger(id) && Number(id) > 0) ||
      externalIds.length < 1 ||
      externalIds.length > 3 ||
      !externalIds.every((id) => typeof id === "string" && id.trim().length > 0) ||
      (
        input.providerRemaining != null &&
        (!Number.isInteger(input.providerRemaining) || input.providerRemaining < 0)
      )
    ) {
      return Response.json({ error: "Invalid team fixtures payload" }, {
        status: 400,
      });
    }
    const events = input.events.filter(
      (event): event is Record<string, unknown> =>
        Boolean(event && typeof event === "object" && !Array.isArray(event)),
    );
    if (events.length !== input.events.length) {
      return Response.json({ error: "Invalid event item" }, { status: 400 });
    }

    const receivedAt = new Date().toISOString();
    const started = performance.now();
    let stage = "read-current";
    const complete = async (status: "SUCCEEDED" | "FAILED", metadata: Record<string, unknown>) => {
      for (const id of reservationIds) {
        await rpc("futbeat_complete_provider_call", {
          p_reservation_id: Number(id),
          p_status: status,
          p_provider_remaining: input.providerRemaining ?? null,
          p_http_status: status === "SUCCEEDED" ? 200 : null,
          p_error_code: status === "SUCCEEDED" ? null : "TEAM_FIXTURES_INGEST_FAILED",
          p_metadata: {
            ...metadata,
            mode: "team-fixtures",
            teamId: input.teamId,
            durationMs: Math.round(performance.now() - started),
            transport: authorizedWorkflow === "supabase-cron"
              ? "supabase-cron"
              : "github-actions-oidc",
            provider: "GOAL API",
          },
        });
      }
    };

    try {
      // Distinct raw provider items: the same fixture seen through two GOAL
      // identities is one item; an item without an id cannot be one of them.
      const externalFixtureIds = [...new Set(events
        .map((event) => String(event.apiId ?? event.id ?? "").trim())
        .filter(Boolean))];
      const rawDistinct = externalFixtureIds.length +
        events.filter((event) => !String(event.apiId ?? event.id ?? "").trim()).length;

      // Canonical matches that exist BEFORE resolution (resolution creates
      // the unknown ones): GOAL-mapped fixtures ...
      const known = await rpc("futbeat_known_goal_fixtures", {
        p_external_ids: externalFixtureIds,
      });
      const preexisting = new Set<string>(
        Array.isArray(known) ? known.map((id) => String(id)) : [],
      );

      // Existing matches of the team: an already-known fixture (same teams,
      // same kickoff) keeps its canonical id even without a GOAL mapping.
      const existing = await rpc("futbeat_read_entity_detail", {
        p_type: "team",
        p_id: input.teamId,
      });
      // ... and matches already stored without a GOAL mapping, which the
      // normalizer reuses by (home, away, kickoff) from this same snapshot.
      for (const match of Array.isArray(existing?.matches) ? existing.matches : []) {
        if (match && typeof match.id === "string") preexisting.add(match.id);
      }
      const normalized = await normalizeGoalBatch(
        "goal_api",
        events,
        existing,
        receivedAt,
        (next) => {
          stage = next;
        },
      );
      const snapshot = normalized.snapshot;
      const ids = (snapshot.matches as Array<{ id: string }>).map((m) => m.id);

      const existingCount = ids.filter((id) => preexisting.has(id)).length;

      // Raw items that did not normalize are an unknown contract, never an
      // empty answer: nothing accepted from a non-empty answer is a failure
      // (the SQL completion refuses NO_DATA and backs off) and fewer
      // accepted than raw never completes the window.
      const normalizationFailed = rawDistinct > 0 && ids.length === 0;
      const windowComplete = input.complete && ids.length >= rawDistinct;

      stage = "store";
      // Empty coverage: no calendar day is marked as covered and nothing
      // outside this answer is removed. Same canonical merge as the calendar.
      const result = ids.length === 0 ? null : await rpc("futbeat_store_calendar_range", {
        p_provider: "goal_api",
        p_received_at: receivedAt,
        p_coverage: [],
        p_snapshot: snapshot,
      }, 60000);

      stage = "complete-coverage";
      const coverage = await rpc("futbeat_complete_team_fixtures", {
        p_team_id: input.teamId,
        p_from: input.fromDate,
        p_to: input.toDate,
        p_complete: windowComplete,
        p_raw: rawDistinct,
        p_received: ids.length,
        p_new: ids.length - existingCount,
        p_existing: existingCount,
      });

      await complete("SUCCEEDED", {
        stage: "complete",
        received: events.length,
        accepted: ids.length,
        rawDistinct,
        newMatches: ids.length - existingCount,
        existingMatches: existingCount,
        windowComplete,
        normalizationFailed,
      });

      return Response.json({
        status: "ok",
        teamId: input.teamId,
        received: events.length,
        rawDistinct,
        windowComplete,
        normalizationFailed,
        accepted: ids.length,
        newMatches: ids.length - existingCount,
        existingMatches: existingCount,
        coverage,
        result,
      });
    } catch (error) {
      const detail =
        error instanceof Error ? error.message.slice(0, 300) : "unknown";
      try {
        await complete("FAILED", { stage, detail });
      } catch {
        // Preserve the original ingestion error.
      }
      console.error("team fixtures ingest failed", stage, detail);
      return Response.json(
        { error: "Team fixtures ingest failed", stage },
        { status: 502 },
      );
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

    if (
      !Number.isInteger(input.reservationId) ||
      Number(input.reservationId) < 1
    ) {
      return Response.json({ error: "Missing squad reservation" }, {
        status: 400,
      });
    }

    const reservation = {
      reservationId: Number(input.reservationId),
    };
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
          transport: authorizedWorkflow === "supabase-cron"
            ? "supabase-cron"
            : "github-actions-oidc",
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
            transport: authorizedWorkflow === "supabase-cron"
              ? "supabase-cron"
              : "github-actions-oidc",
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
      (input.requestedOnly !== true &&
        (!validDate(input.fromDate) || !validDate(input.toDate))) ||
      !Number.isInteger(input.limit) ||
      Number(input.limit) < 1 ||
      Number(input.limit) > 90
    ) {
      return Response.json({ error: "Invalid calendar plan request" }, {
        status: 400,
      });
    }

    try {
      const dates = input.requestedOnly === true
        ? await rpc("futbeat_requested_calendar_dates", {
          p_limit: input.limit,
        })
        : await rpc("futbeat_calendar_missing_provider_dates", {
          p_provider: "goal_api",
          p_from_date: input.fromDate,
          p_to_date: input.toDate,
          p_limit: input.limit,
        });
      return Response.json({
        status: "ok",
        mode: input.requestedOnly === true ? "requested" : "background",
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
  // Each date is stored with its own coverage item: they must match the dates.
  if (
    mode === "calendar" &&
    coverage.map((item) => String(item.date ?? "")).sort().join() !== dates.join()
  ) {
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
  // Observability: milliseconds spent in each stage (ledger metadata).
  const stageMs: Record<string, number> = {};
  let stageStarted = performance.now();
  const setStage = (next: string) => {
    const now = performance.now();
    stageMs[stage] = Math.round((stageMs[stage] ?? 0) + now - stageStarted);
    stage = next;
    stageStarted = now;
  };
  const closeStage = () => setStage(stage);
  let resolvedBase = 0;
  let resolvedMatches = 0;
  // Calendar mode: stage times per date, the date in progress and the dates
  // already stored (each date is committed by its own store call).
  const stageMsByDate: Record<string, Record<string, number>> = {};
  let currentDate: string | null = null;
  const storedDates: string[] = [];
  let closeDateStage = () => {};
  // Large dates (see CALENDAR_SUB_BATCH_MAX): stage times per sub-batch, the
  // sub-batch in progress and how many of the current date are stored.
  const stageMsBySubBatch: Record<string, Array<Record<string, number>>> = {};
  let currentSubBatch: number | null = null;
  let storedSubBatches = 0;

  try {
    // GOAL: only the existing competitions/teams/matches of this batch
    // (futbeat_read_ingest_context), read after resolve-base. The full
    // snapshot read (3.8 MB, 5.6-7.8 s) timed out the ingest in production.
    // Other sources keep the full snapshot.
    const readExisting = async (
      batch: Array<Record<string, unknown>>,
      resolved?: Map<string, string>,
    ) => {
      if (input.source !== "GOAL API") return await rpc("futbeat_read_snapshot");
      return await rpc("futbeat_read_ingest_context", ingestContextRequest(batch, resolved!), 30000);
    };
    const baseExisting = input.source === "GOAL API" ? null : await readExisting(events);
    let existing: unknown = baseExisting;

    if (mode === "calendar") {
      setStage("read-calendar");
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
      existing = (base: Record<string, unknown> | null) => ({
        ...base,
        competitions: mergeById(
          base?.competitions,
          ...daySnapshots.map((snapshot) => snapshot?.competitions),
        ),
        teams: mergeById(
          base?.teams,
          ...daySnapshots.map((snapshot) => snapshot?.teams),
        ),
        matches: mergeById(
          base?.matches,
          ...daySnapshots.map((snapshot) => snapshot?.matches),
        ),
      });
    }
    const withCalendar = (base: unknown) =>
      typeof existing === "function"
        ? (existing as (b: unknown) => unknown)(base)
        : base;

    if (mode === "calendar") {
      // GOAL only (validated above). One full ingest per UTC date, in date
      // order; existing = that date's targeted context + the calendar days
      // read above (a fixture only reuses a match of its own 5-minute bucket,
      // which never crosses a UTC date).
      const groups = calendarDateGroups(events, dates);
      // One date per call when the batch holds a large date: the workflow
      // sends up to three dates under a 90 s client timeout, and one large
      // date in sub-batches already takes ~40-50 s. The first date is
      // ingested; the others are returned as deferredDates (no store, no
      // coverage), so the calendar plan picks them again on a later run.
      const oneDatePerCall = [...groups.values()].some(
        (list) => list.length > CALENDAR_SUB_BATCH_MAX,
      );
      const deferredDates: string[] = [];
      const competitionIds = new Set<string>();
      const teamIds = new Set<string>();
      const byDate: unknown[] = [];
      let accepted = 0;
      for (const [date, dateEvents] of groups) {
        if (oneDatePerCall && storedDates.length > 0) {
          deferredDates.push(date);
          continue;
        }
        currentDate = date;
        const dateMs: Record<string, number> = {};
        stageMsByDate[date] = dateMs;
        let dateStage = "";
        let dateStageStarted = performance.now();
        let subMs: Record<string, number> | null = null;
        const setDateStage = (next: string) => {
          const now = performance.now();
          if (dateStage) {
            const spent = now - dateStageStarted;
            dateMs[dateStage] = Math.round((dateMs[dateStage] ?? 0) + spent);
            if (subMs) {
              subMs[dateStage] = Math.round((subMs[dateStage] ?? 0) + spent);
            }
          }
          dateStage = next;
          dateStageStarted = now;
        };
        closeDateStage = () => setDateStage("");
        const onStage = (next: string) => {
          setStage(next);
          setDateStage(next);
        };
        const dateCoverage = coverage.filter((item) => String(item.date) === date);
        const subBatches = calendarSubBatches(dateEvents, CALENDAR_SUB_BATCH_MAX);
        currentSubBatch = null;
        storedSubBatches = 0;

        if (subBatches.length <= 1) {
          const normalized = await normalizeGoalBatch(
            provider,
            dateEvents,
            async (resolved: Map<string, string>) =>
              withCalendar(await readExisting(dateEvents, resolved)),
            receivedAt,
            onStage,
          );
          resolvedBase += normalized.resolvedBase;
          resolvedMatches += normalized.resolvedMatches;

          onStage("store");
          byDate.push(
            await rpc(
              "futbeat_store_calendar_range",
              {
                p_provider: provider,
                p_received_at: receivedAt,
                p_coverage: dateCoverage,
                p_snapshot: normalized.snapshot,
              },
              60000,
            ),
          );
          accepted += normalized.snapshot.matches.length;
          for (const item of normalized.snapshot.competitions) competitionIds.add(item.id);
          for (const item of normalized.snapshot.teams) teamIds.add(item.id);
        } else {
          // Sub-batches: each one adds/updates its own matches (empty
          // coverage: nothing deleted, the date not marked covered). Only
          // when every sub-batch is stored, one finalize applies the date's
          // deletes and coverage against ALL its match ids. A failure halfway
          // leaves the date uncovered (planned again) and deletes nothing.
          const dateMatchIds = new Set<string>();
          const subRecords: Array<Record<string, number>> = [];
          stageMsBySubBatch[date] = subRecords;
          for (const [index, subEvents] of subBatches.entries()) {
            currentSubBatch = index;
            subMs = { fixtures: subEvents.length };
            subRecords.push(subMs);
            const normalized = await normalizeGoalBatch(
              provider,
              subEvents,
              async (resolved: Map<string, string>) =>
                withCalendar(await readExisting(subEvents, resolved)),
              receivedAt,
              onStage,
            );
            resolvedBase += normalized.resolvedBase;
            resolvedMatches += normalized.resolvedMatches;

            onStage("store");
            await rpc(
              "futbeat_store_calendar_range",
              {
                p_provider: provider,
                p_received_at: receivedAt,
                p_coverage: [],
                p_snapshot: normalized.snapshot,
              },
              60000,
            );
            setDateStage("");
            subMs = null;
            storedSubBatches = index + 1;
            for (const item of normalized.snapshot.matches) dateMatchIds.add(item.id);
            for (const item of normalized.snapshot.competitions) competitionIds.add(item.id);
            for (const item of normalized.snapshot.teams) teamIds.add(item.id);
          }
          currentSubBatch = null;

          onStage("finalize");
          byDate.push(
            await rpc(
              "futbeat_finalize_calendar_date",
              {
                p_provider: provider,
                p_received_at: receivedAt,
                p_date: date,
                p_count: Number(dateCoverage[0]?.count ?? 0),
                p_match_ids: [...dateMatchIds].sort(),
              },
              60000,
            ),
          );
          accepted += dateMatchIds.size;
        }
        closeDateStage();
        closeDateStage = () => {};
        storedDates.push(date);
      }
      currentDate = null;

      const durationMs = Math.round(performance.now() - started);
      await rpc("futbeat_complete_provider_call", {
        p_reservation_id: reservation.reservationId,
        p_status: "SUCCEEDED",
        p_provider_remaining: input.providerRemaining ?? null,
        p_http_status: 200,
        p_error_code: null,
        p_metadata: {
          stage: "complete",
          dates,
          durationMs,
          received: events.length,
          accepted,
          competitions: competitionIds.size,
          teams: teamIds.size,
          resolvedBase,
          resolvedMatches,
          stageMs: (closeStage(), stageMs),
          stageMsByDate,
          ...(Object.keys(stageMsBySubBatch).length > 0 ? { stageMsBySubBatch } : {}),
          ...(deferredDates.length > 0 ? { deferredDates } : {}),
          transport: "github-actions-oidc",
          provider: input.source,
          mode,
        },
      });

      return Response.json({
        status: "ok",
        dates,
        received: events.length,
        accepted,
        competitions: competitionIds.size,
        teams: teamIds.size,
        resolvedBase,
        resolvedMatches,
        mode,
        result: { matches: accepted, coveredDates: storedDates.length, byDate },
        ...(deferredDates.length > 0 ? { deferredDates } : {}),
      });
    }

    let snapshot;
    if (input.source === "GOAL API") {
      const normalized = await normalizeGoalBatch(
        provider,
        events,
        async (resolved: Map<string, string>) => withCalendar(await readExisting(events, resolved)),
        receivedAt,
        (next) => {
          setStage(next);
        },
      );
      snapshot = normalized.snapshot;
      resolvedBase = normalized.resolvedBase;
      resolvedMatches = normalized.resolvedMatches;
    } else {
      setStage("normalize");
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
        ? await normalizeEspnFixtures(events, resolve, receivedAt, withCalendar(baseExisting))
        : await normalizeSofaScoreFixtures(events, resolve, receivedAt, withCalendar(baseExisting));
    }

    setStage("store");
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
      p_provider_remaining:
        input.source === "GOAL API" ? input.providerRemaining ?? null : null,
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
        stageMs: (closeStage(), stageMs),
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
    closeDateStage();
    // Calendar: the failed date and the dates stored before it (complete).
    // A large date also names the failed sub-batch and how many of its
    // sub-batches were stored (adds/updates only; the date stays uncovered).
    const calendarProgress = mode === "calendar"
      ? {
        stageMsByDate,
        failedDate: currentDate,
        storedDates,
        ...(Object.keys(stageMsBySubBatch).length > 0
          ? { stageMsBySubBatch }
          : {}),
        ...(currentSubBatch !== null
          ? { failedSubBatch: currentSubBatch, storedSubBatches }
          : {}),
      }
      : {};
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
        stageMs: (closeStage(), stageMs),
        ...calendarProgress,
        transport: "github-actions-oidc",
        mode,
      },
    });
    console.error("global ingest failed", stage, detail);
    return Response.json(
      { error: "Global fixture ingest failed", stage, detail, ...calendarProgress },
      { status: 502 },
    );
  }
});
