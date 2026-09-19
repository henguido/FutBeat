import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const restHeaders = {
  apikey: serviceKey,
  Authorization: `Bearer ${serviceKey}`,
  "Content-Type": "application/json",
};

async function rpc(name: string, body: unknown = {}, timeoutMs = 30000) {
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: restHeaders,
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

function nonNegativeInteger(value: unknown) {
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

async function secureEqual(left: string, right: string) {
  if (!left || !right) return false;
  const [a, b] = await Promise.all([sha256Hex(left), sha256Hex(right)]);
  return a === b;
}

async function normalizeLiveFixture(fixture: Record<string, unknown>) {
  const externalMatchId = clean(fixture.apiId ?? fixture.id);
  if (!externalMatchId) throw new Error("Missing GOAL live fixture id");

  const status = goalLiveStatus(fixture);
  const minute = nonNegativeInteger(fixture.matchElapsed);
  const home = nonNegativeInteger(fixture.homeTeamScore);
  const away = nonNegativeInteger(fixture.awayTeamScore);
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

async function readGoalKey() {
  const key = await rpc("futbeat_read_goal_live_secret");
  const value = clean(key);
  if (value.length < 16) throw new Error("GOAL API key is not provisioned");
  return value;
}

async function fetchGoal(
  key: string,
  path: string,
  timeoutMs = 30000,
) {
  const response = await fetch(`https://api.goal-api.com/v1${path}`, {
    headers: {
      Authorization: `Bearer ${key}`,
      Accept: "application/json",
    },
    signal: AbortSignal.timeout(timeoutMs),
  });
  const remainingRaw = response.headers.get("x-ratelimit-remaining");
  const remaining = remainingRaw != null && /^\d+$/.test(remainingRaw)
    ? Number(remainingRaw)
    : null;
  const text = await response.text();
  let payload: Record<string, unknown>;
  try {
    payload = text ? JSON.parse(text) : {};
  } catch {
    throw new Error(`GOAL API returned non-JSON HTTP ${response.status}`);
  }
  if (!response.ok || payload.success !== true) {
    throw new Error(`GOAL API HTTP ${response.status}`);
  }
  return { payload, remaining, status: response.status };
}

async function completeFailure(
  reservationId: number,
  errorCode: string,
  metadata: Record<string, unknown>,
  providerRemaining: number | null = null,
  httpStatus: number | null = null,
) {
  try {
    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservationId,
      p_status: "FAILED",
      p_provider_remaining: providerRemaining,
      p_http_status: httpStatus,
      p_error_code: errorCode,
      p_metadata: {
        ...metadata,
        transport: "supabase-cron",
      },
    });
  } catch (error) {
    console.error(
      "provider failure completion failed",
      error instanceof Error ? error.message : "unknown",
    );
  }
}

async function syncLive() {
  const plan = await rpc("futbeat_reserve_goal_live_call", {
    p_trigger_source: "supabase-cron",
  });
  if (!plan?.allowed) {
    return {
      status: "skipped",
      reason: plan?.reason ?? "unknown",
      reservation: plan,
    };
  }

  const reservationId = Number(plan.reservationId);
  const goalKey = await readGoalKey();
  const fixtures: Record<string, unknown>[] = [];
  const seen = new Set<string>();
  let offset = 0;
  let providerRequests = 0;
  let providerTotal: number | null = null;
  let remaining: number | null = null;

  try {
    for (let page = 0; page < 10; page += 1) {
      const response = await fetchGoal(
        goalKey,
        `/fixtures/live?limit=100&offset=${offset}`,
      );
      remaining = response.remaining ?? remaining;
      providerRequests += 1;

      const data = response.payload.data;
      if (!Array.isArray(data)) {
        throw new Error("GOAL live payload data must be an array");
      }

      for (const item of data) {
        if (!item || typeof item !== "object" || Array.isArray(item)) continue;
        const fixture = item as Record<string, unknown>;
        const external = clean(fixture.apiId ?? fixture.id);
        if (!external || seen.has(external)) continue;
        seen.add(external);
        fixtures.push(fixture);
      }

      const pagination = response.payload.pagination;
      const paginationRow = pagination && typeof pagination === "object" &&
          !Array.isArray(pagination)
        ? pagination as Record<string, unknown>
        : null;
      const total = nonNegativeInteger(paginationRow?.total);
      if (total != null) providerTotal = total;
      const hasMore = paginationRow?.hasMore === true;
      if (!hasMore) break;

      const pageLimit = nonNegativeInteger(paginationRow?.limit) ?? 100;
      offset += Math.max(pageLimit, 1);
      if (page === 9) {
        throw new Error("GOAL live pagination exceeded safety limit");
      }
    }

    const linkResult = await rpc("futbeat_link_goal_live_matches", {
      p_fixtures: fixtures,
    }, 30000);

    const observations = await Promise.all(
      fixtures.map((fixture) => normalizeLiveFixture(fixture)),
    );

    const persistence = await rpc("futbeat_record_live_batch", {
      p_provider: "goal_api",
      p_received_at: new Date().toISOString(),
      p_observations: observations,
    }, 30000);

    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservationId,
      p_status: "SUCCEEDED",
      p_provider_remaining: remaining,
      p_http_status: 200,
      p_error_code: null,
      p_metadata: {
        mode: "live",
        liveMatches: observations.length,
        linkedMatches: linkResult?.linked ?? 0,
        alreadyLinkedMatches: linkResult?.alreadyLinked ?? 0,
        unmappedMatches: linkResult?.unmappedCount ?? 0,
        providerRequests,
        providerTotal: providerTotal ?? observations.length,
        insertedObservations: persistence?.insertedObservations ?? 0,
        duplicates: persistence?.duplicates ?? 0,
        transport: "supabase-cron",
        provider: "GOAL API",
      },
    });

    return {
      status: "ok",
      liveMatches: observations.length,
      linkedMatches: linkResult?.linked ?? 0,
      unmappedMatches: linkResult?.unmappedCount ?? 0,
      providerRequests,
      providerTotal,
      remaining,
    };
  } catch (error) {
    await completeFailure(
      reservationId,
      "GOAL_LIVE_FETCH_FAILED",
      {
        mode: "live",
        detail: error instanceof Error ? error.message.slice(0, 300) : "unknown",
      },
      remaining,
    );
    throw error;
  }
}

async function syncOneMatchDetail() {
  const plan = await rpc("futbeat_reserve_match_detail_call", {
    p_trigger_source: "supabase-cron",
  });
  if (!plan?.allowed) {
    return {
      status: "skipped",
      reason: plan?.reason ?? "unknown",
      reservation: plan,
    };
  }

  const reservationId = Number(plan.reservationId);
  const goalKey = await readGoalKey();
  const matchId = clean(plan.matchId);
  const externalMatchId = clean(plan.externalMatchId);
  let remaining: number | null = null;

  try {
    const response = await fetchGoal(
      goalKey,
      `/fixtures/${encodeURIComponent(externalMatchId)}`,
    );
    remaining = response.remaining;
    const detail = response.payload.data;
    if (detail == null || typeof detail !== "object") {
      throw new Error("GOAL match detail payload is invalid");
    }

    const stored = await rpc("futbeat_store_match_detail", {
      p_match_id: matchId,
      p_external_match_id: externalMatchId,
      p_fetched_at: new Date().toISOString(),
      p_payload: detail,
    }, 30000);

    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservationId,
      p_status: "SUCCEEDED",
      p_provider_remaining: remaining,
      p_http_status: 200,
      p_error_code: null,
      p_metadata: {
        mode: "match-detail",
        matchId,
        externalMatchId,
        transport: "supabase-cron",
        provider: "GOAL API",
      },
    });

    return {
      status: "ok",
      matchId,
      externalMatchId,
      remaining,
      stored,
    };
  } catch (error) {
    await completeFailure(
      reservationId,
      "GOAL_MATCH_DETAIL_FETCH_FAILED",
      {
        mode: "match-detail",
        matchId,
        externalMatchId,
        detail: error instanceof Error ? error.message.slice(0, 300) : "unknown",
      },
      remaining,
    );
    throw error;
  }
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });

  try {
    const expected = clean(await rpc("futbeat_read_goal_live_cron_token"));
    const supplied = clean(request.headers.get("x-futbeat-cron-token"));
    if (!(await secureEqual(expected, supplied))) {
      return Response.json({ error: "Forbidden" }, { status: 403 });
    }

    let live: unknown;
    let detail: unknown;

    try {
      live = await syncLive();
    } catch (error) {
      console.error(
        "GOAL live sync failed",
        error instanceof Error ? error.message : "unknown",
      );
      live = { status: "failed" };
    }

    try {
      detail = await syncOneMatchDetail();
    } catch (error) {
      console.error(
        "GOAL match detail sync failed",
        error instanceof Error ? error.message : "unknown",
      );
      detail = { status: "failed" };
    }

    return Response.json({ status: "ok", live, detail });
  } catch (error) {
    console.error(
      "supabase GOAL live sync rejected",
      error instanceof Error ? error.message : "unknown",
    );
    return Response.json({ error: "LIVE sync unavailable" }, { status: 502 });
  }
});
