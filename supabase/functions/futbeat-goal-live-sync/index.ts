import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { nextResultsOffset } from "../_shared/results_pagination.ts";
import {
  GOAL_PLAYER_ENDPOINTS,
  normalizeGoalPlayerProfile,
  normalizeGoalPlayerSearch,
  normalizeGoalPlayerStatistics,
} from "../_shared/goal_players.ts";
import { normalizeFixtureEvents } from "../_shared/live_events.ts";
import {
  GOAL_STANDINGS_ENDPOINT,
  goalStandingsRows,
  goalStandingsSeason,
} from "../_shared/goal_standings.ts";

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
  const events = normalizeFixtureEvents(fixture);
  const payloadHash = await sha256Hex(JSON.stringify([
    externalMatchId,
    status,
    minute,
    home,
    away,
    events.map((event) => event.eventKey),
  ]));

  return {
    externalMatchId,
    payloadHash,
    status,
    minute,
    score: { home, away },
    events,
    rawPayload: fixture,
  };
}

async function readGoalKey() {
  const key = await rpc("futbeat_read_goal_live_secret");
  const value = clean(key);
  if (value.length < 16) throw new Error("GOAL API key is not provisioned");
  return value;
}

async function readCronToken() {
  const token = clean(await rpc("futbeat_read_goal_live_cron_token"));
  if (token.length < 32) {
    throw new Error("Supabase cron token is not provisioned");
  }
  return token;
}

async function readNewsDataKey() {
  try {
    return clean(await rpc("futbeat_read_newsdata_secret"));
  } catch {
    return "";
  }
}


async function readYoutubeKey() {
  try {
    return clean(await rpc("futbeat_read_youtube_api_key"));
  } catch {
    return "";
  }
}

function normalizeSearchText(value: unknown) {
  return clean(value)
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function significantTeamTokens(value: unknown) {
  const stop = new Set([
    "club", "de", "del", "la", "el", "fc", "cf", "cd", "sc",
    "futbol", "football", "deportivo", "deportiva",
  ]);
  return normalizeSearchText(value)
    .split(/\s+/)
    .filter((token) => token.length >= 3 && !stop.has(token));
}

function titleMentionsTeam(title: string, team: unknown) {
  const normalized = normalizeSearchText(title);
  const tokens = significantTeamTokens(team);
  if (tokens.length === 0) return false;
  return tokens.some((token) => normalized.includes(token));
}

function cleanYoutubeTitle(value: unknown) {
  return clean(value)
    .replaceAll("&amp;", "&")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .slice(0, 500);
}

function newsPublishedAt(value: unknown, timezone: unknown) {
  const raw = clean(value);
  if (!raw) return "";
  const normalized =
    clean(timezone).toUpperCase() === "UTC" &&
      !/[zZ]|[+-]\d\d:?\d\d$/.test(raw)
      ? raw.replace(" ", "T") + "Z"
      : raw.replace(" ", "T");
  const parsed = new Date(normalized);
  return Number.isFinite(parsed.getTime()) ? parsed.toISOString() : "";
}

function normalizeNewsData(payload: Record<string, unknown>) {
  const rows = Array.isArray(payload.results) ? payload.results : [];
  const articles: Array<Record<string, unknown>> = [];

  for (const raw of rows) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue;
    const row = raw as Record<string, unknown>;
    if (row.duplicate === true) continue;

    const id = clean(row.article_id);
    const title = clean(row.title);
    const url = clean(row.link);
    const sourceName = clean(row.source_name ?? row.source_id);
    const publishedAt = newsPublishedAt(row.pubDate, row.pubDateTZ);

    if (
      !id ||
      !title ||
      !url.startsWith("https://") ||
      !sourceName ||
      !publishedAt
    ) {
      continue;
    }

    const sourceUrl = clean(row.source_url);
    articles.push({
      id,
      title,
      description: clean(row.description).slice(0, 2000),
      url,
      sourceName,
      sourceUrl: sourceUrl.startsWith("https://") ? sourceUrl : "",
      publishedAt,
      language: clean(row.language),
    });
  }

  return articles;
}

async function callGlobalIngest(
  token: string,
  body: Record<string, unknown>,
) {
  const response = await fetch(
    `${supabaseUrl}/functions/v1/futbeat-global-ingest`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-futbeat-cron-token": token,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(30000),
    },
  );
  const text = await response.text();
  let payload: Record<string, unknown> = {};
  try {
    payload = text ? JSON.parse(text) : {};
  } catch {
    throw new Error(
      `global ingest returned non-JSON HTTP ${response.status}`,
    );
  }
  if (!response.ok || payload.status !== "ok") {
    throw new Error(
      `global ingest failed HTTP ${response.status}`,
    );
  }
  return payload;
}

async function fetchGoal(
  key: string,
  path: string,
  timeoutMs = 30000,
  singleCall = false,
) {
  const response = await fetch(`https://api.goal-api.com/v1${path}`, {
    redirect: singleCall ? "error" : "follow",
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
    // Keep the provider's remaining budget even on errors so the quota
    // manager never runs blind on a failing day.
    throw Object.assign(new Error(`GOAL API HTTP ${response.status}`), { remaining });
  }
  return { payload, remaining, status: response.status };
}

async function completeFailure(
  reservationId: number,
  errorCode: string,
  metadata: Record<string, unknown>,
  providerRemaining: number | null = null,
  httpStatus: number | null = null,
  safeLog = false,
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
      safeLog ? "completion unavailable"
        : error instanceof Error ? error.message : "unknown",
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
  const fixtures: Record<string, unknown>[] = [];
  const seen = new Set<string>();
  // Page budget from the central reservation (never through the protected
  // LIVE reserve nor past the live-goal cap); 10 is the historical hard max.
  const pageBudget = Math.min(Math.max(nonNegativeInteger(plan.pageBudget) ?? 10, 1), 10);
  const floor = nonNegativeInteger(plan.reserve);
  const startOffset = nonNegativeInteger(plan.startOffset) ?? 0;
  let offset = startOffset;
  let restarted = false;
  // Every attempted request counts (a failed page still spent a request).
  let providerRequests = 0;
  let providerTotal: number | null = null;
  let remaining: number | null = null;
  let paginationTruncated = false;
  let resumeOffset: number | null = null;

  try {
    const goalKey = await readGoalKey();
    for (let page = 0; page < pageBudget; page += 1) {
      providerRequests += 1;
      let response: Awaited<ReturnType<typeof fetchGoal>>;
      try {
        response = await fetchGoal(
          goalKey,
          `/fixtures/live?limit=100&offset=${offset}`,
        );
      } catch (error) {
        const errorRemaining = (error as { remaining?: unknown })?.remaining;
        if (typeof errorRemaining === "number") remaining = errorRemaining;
        throw error;
      }
      remaining = response.remaining ?? remaining;

      const data = response.payload.data;
      if (!Array.isArray(data)) {
        throw new Error("GOAL live payload data must be an array");
      }
      // A resumed offset past the (shrunk) live list: start over once.
      if (data.length === 0 && offset > 0 && !restarted) {
        restarted = true;
        offset = 0;
        continue;
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
      // Stop at the page budget or when the provider reports the protected
      // reserve: a partial batch is recorded as partial and the next poll
      // resumes here. Unread pages are never treated as evidence.
      const atFloor = floor != null && remaining != null && remaining <= floor;
      if (page + 1 >= pageBudget || atFloor) {
        paginationTruncated = true;
        resumeOffset = offset;
        break;
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

    // #120: absence from the feed is evidence only once a whole sweep (offset
    // 0 to the last page, possibly across resumed polls) was read; it only
    // queues a bounded provider re-check, never a final.
    const fromStart = startOffset === 0 || restarted;
    const reachedEnd = !paginationTruncated;
    let recovery: unknown = null;
    try {
      recovery = await rpc("futbeat_note_live_poll", {
        p_provider: "goal_api",
        p_seen: observations.map((observation) => observation.externalMatchId),
        p_from_start: fromStart,
        p_reached_end: reachedEnd,
      });
    } catch (error) {
      console.warn(
        "terminal recovery note unavailable",
        error instanceof Error ? error.message : "unknown",
      );
    }

    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservationId,
      p_status: "SUCCEEDED",
      p_provider_remaining: remaining,
      p_http_status: 200,
      p_error_code: null,
      p_metadata: {
        mode: "live",
        fromStart,
        reachedEnd,
        recovery,
        providerRequests,
        pageBudget,
        startOffset,
        paginationTruncated,
        resumeOffset,
        liveMatches: observations.length,
        linkedMatches: linkResult?.linked ?? 0,
        alreadyLinkedMatches: linkResult?.alreadyLinked ?? 0,
        unmappedMatches: linkResult?.unmappedCount ?? 0,
        providerTotal: providerTotal ?? observations.length,
        insertedObservations: persistence?.insertedObservations ?? 0,
        duplicates: persistence?.duplicates ?? 0,
        transport: "supabase-cron",
        provider: "GOAL API",
      },
    });

    return {
      status: "ok",
      paginationTruncated,
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
        // Requests already spent, including the one that failed.
        providerRequests: Math.max(providerRequests, 1),
        pageBudget,
        startOffset,
        detail: error instanceof Error ? error.message.slice(0, 300) : "unknown",
      },
      remaining,
    );
    throw error;
  }
}

async function syncOneResultsDate() {
  let plan: Record<string, unknown> | null;
  try {
    plan = await rpc("futbeat_reserve_goal_results_date", {
      p_trigger_source: "supabase-cron",
    });
  } catch (error) {
    throw Object.assign(
      error instanceof Error ? error : new Error(String(error)),
      { stage: "reserve" },
    );
  }
  if (!plan?.allowed) {
    return {
      status: "skipped",
      reason: plan?.reason ?? "unknown",
      reservation: plan,
    };
  }

  const reservationId = Number(plan.reservationId);
  const providerDate = clean(plan.date);
  const fixtures: Record<string, unknown>[] = [];
  const seen = new Set<string>();
  const receivedAt = new Date().toISOString();
  let providerRequests = 0;
  let providerTotal: number | null = null;
  let remaining: number | null = null;
  let httpStatus: number | null = null;
  // Every step of the pipeline (fetch -> link -> normalize -> record ->
  // finalize -> attempt bookkeeping -> ledger completion) can fail
  // independently; tag which one so a failure is diagnosable from the
  // sanitized ledger/log entry alone, without a second investigation pass.
  let stage = "reserve";

  try {
    stage = "validate_date";
    if (!/^\d{4}-\d{2}-\d{2}$/.test(providerDate)) {
      throw new Error("Invalid historical results date reservation");
    }
    stage = "read_key";
    const goalKey = await readGoalKey();
    let offset = 0;
    stage = "provider_fetch";
    for (let page = 0; page < 5; page += 1) {
      // Every attempted request counts (a failed page still spent one).
      providerRequests += 1;
      let response: Awaited<ReturnType<typeof fetchGoal>>;
      try {
        response = await fetchGoal(
          goalKey,
          `/results/date/${providerDate}?limit=500&offset=${offset}`,
        );
      } catch (error) {
        const errorRemaining = (error as { remaining?: unknown })?.remaining;
        if (typeof errorRemaining === "number") remaining = errorRemaining;
        throw error;
      }
      httpStatus = response.status;
      remaining = response.remaining ?? remaining;
      const data = response.payload.data;
      if (!Array.isArray(data)) {
        throw new Error("GOAL results payload data must be an array");
      }
      let added = 0;
      for (const item of data) {
        if (!item || typeof item !== "object" || Array.isArray(item)) continue;
        const fixture = item as Record<string, unknown>;
        const external = clean(fixture.apiId ?? fixture.id);
        if (!external || seen.has(external)) continue;
        seen.add(external);
        fixtures.push(fixture);
        added += 1;
      }
      const pagination = response.payload.pagination;
      const row = pagination && typeof pagination === "object" &&
          !Array.isArray(pagination)
        ? pagination as Record<string, unknown>
        : {};
      const total = nonNegativeInteger(row.total);
      if (total != null) providerTotal = total;
      // GOAL documents pagination on list endpoints, but older cached
      // responses can omit or empty the envelope. A full page at the effective
      // limit probes the next offset. Stop if the provider ignores the offset
      // and repeats the same page; explicit end and the five-page cap win.
      const nextOffset = nextResultsOffset({
        pagination: pagination as Record<string, unknown> | null | undefined,
        rowCount: data.length,
        added,
        currentOffset: offset,
      });
      if (nextOffset == null) break;
      offset = nextOffset;
      if (page === 4) throw new Error("GOAL results pagination exceeded safety limit");
    }

    stage = "link";
    const linkResult = await rpc("futbeat_link_goal_live_matches", {
      p_fixtures: fixtures,
    }, 30000);
    stage = "normalize";
    const observations = await Promise.all(fixtures.map(normalizeLiveFixture));
    stage = "record";
    const persistence = await rpc("futbeat_record_live_batch", {
      p_provider: "goal_api",
      p_received_at: receivedAt,
      p_observations: observations,
    }, 30000);
    stage = "finalize";
    const finalized = await rpc("futbeat_finalize_goal_results_date", {
      p_provider_date: providerDate,
      p_received_at: receivedAt,
    }, 30000);
    stage = "complete_attempt";
    const unmatchedCount = Number(linkResult?.unmappedCount ?? 0);
    await rpc("futbeat_complete_results_date_attempt", {
      p_provider_date: providerDate,
      p_outcome: finalized?.resultsComplete === true ? "SUCCEEDED" : "PARTIAL",
      p_result_count: observations.length,
      p_unmatched_count: Number.isFinite(unmatchedCount) ? unmatchedCount : 0,
    });

    stage = "complete_call";
    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservationId,
      p_status: "SUCCEEDED",
      p_provider_remaining: remaining,
      p_http_status: httpStatus ?? 200,
      p_error_code: null,
      p_metadata: {
        mode: "results-date",
        date: providerDate,
        providerRequests,
        providerTotal: providerTotal ?? observations.length,
        results: observations.length,
        linkedMatches: linkResult?.linked ?? 0,
        alreadyLinkedMatches: linkResult?.alreadyLinked ?? 0,
        unmappedMatches: linkResult?.unmappedCount ?? 0,
        insertedObservations: persistence?.insertedObservations ?? 0,
        duplicates: persistence?.duplicates ?? 0,
        resultsComplete: finalized?.resultsComplete ?? false,
        unresolved: finalized?.unresolved ?? null,
        transport: "supabase-cron",
        provider: "GOAL API",
      },
    });
    return {
      status: "ok",
      date: providerDate,
      results: observations.length,
      providerRequests,
      providerTotal,
      remaining,
      finalized,
    };
  } catch (error) {
    if (/^\d{4}-\d{2}-\d{2}$/.test(providerDate)) {
      try {
        await rpc("futbeat_complete_results_date_attempt", {
          p_provider_date: providerDate,
          p_outcome: "FAILED",
          p_result_count: fixtures.length,
          p_unmatched_count: 0,
        });
      } catch (_) {
        // Provider-call failure remains primary; attempt bookkeeping retries later.
      }
    }
    // Sanitized: the failing stage name and a truncated (300 char) error
    // message reach the ledger and, via the thrown error below, the
    // results-only response (truncated further, to 200 chars, there). The
    // GOAL key never appears in any message here. An RPC failure's message
    // may echo up to 180 chars of that RPC's own PostgREST error text
    // (rpc(), earlier in this file) -- useful for diagnosis, and none of
    // the RPCs in this pipeline handle secrets, but it is not purely a
    // fixed stage label.
    await completeFailure(
      reservationId,
      "GOAL_RESULTS_DATE_FETCH_FAILED",
      {
        mode: "results-date",
        date: providerDate,
        providerRequests,
        stage,
        detail: error instanceof Error ? error.message.slice(0, 300) : "unknown",
      },
      remaining,
      httpStatus,
    );
    throw Object.assign(
      error instanceof Error ? error : new Error(String(error)),
      { stage },
    );
  }
}

async function syncOneMatchDetail() {
  try {
    await rpc("futbeat_enqueue_stale_live_detail");
  } catch (error) {
    console.warn(
      "stale LIVE detail enqueue unavailable",
      error instanceof Error ? error.message : "unknown",
    );
  }

  // #120: a match that left the LIVE feed without a terminal state is
  // re-checked first (bounded attempts, protected 'results' class).
  let recovery: Record<string, unknown> | null = null;
  try {
    const reserved = await rpc("futbeat_reserve_terminal_recovery_call", {
      p_trigger_source: "supabase-cron",
    });
    if (reserved?.allowed) recovery = reserved;
  } catch (error) {
    console.warn(
      "terminal recovery reservation unavailable",
      error instanceof Error ? error.message : "unknown",
    );
  }

  const plan = recovery ?? await rpc("futbeat_reserve_match_detail_call", {
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
  const matchId = clean(plan.matchId);
  const externalMatchId = clean(plan.externalMatchId);
  let remaining: number | null = null;

  try {
    const goalKey = await readGoalKey();
    const response = await fetchGoal(
      goalKey,
      `/fixtures/${encodeURIComponent(externalMatchId)}`,
    );
    remaining = response.remaining;
    const detail = response.payload.data;
    if (detail == null || typeof detail !== "object") {
      throw new Error("GOAL match detail payload is invalid");
    }

    const detailRecord = detail as Record<string, unknown>;
    const lineupRows = Array.isArray(detailRecord.lineups)
      ? detailRecord.lineups
      : [];
    const playerItems = [...new Map(
      lineupRows
        .map((value) => value && typeof value === "object"
          ? value as Record<string, unknown>
          : {})
        .filter((row) => {
          const type = clean(row.type).toLowerCase();
          return type.startsWith("start") || type.startsWith("sub");
        })
        .map((row) => {
          const external = clean(row.playerId) || clean(row.playerKey);
          return [external, {
            kind: "player",
            external,
            name: clean(row.lineupPlayer) || clean(row.playerName),
          }] as const;
        })
        .filter(([external]) => external),
    ).values()];
    if (playerItems.length > 0) {
      await rpc("futbeat_resolve_global_entities", {
        p_provider: "goal_api",
        p_items: playerItems,
      }, 30000);
    }

    const fetchedAt = new Date().toISOString();
    const stored = await rpc("futbeat_store_match_detail", {
      p_match_id: matchId,
      p_external_match_id: externalMatchId,
      p_fetched_at: fetchedAt,
      p_payload: detail,
    }, 30000);

    const liveObservation = await normalizeLiveFixture(
      detail as Record<string, unknown>,
    );
    if ([
      "LIVE",
      "HALFTIME",
      "EXTRA_TIME",
      "PENALTIES",
      "FINISHED_PENDING_VERIFICATION",
      "POSTPONED",
      "CANCELLED",
      "SUSPENDED",
      "ABANDONED",
    ].includes(liveObservation.status)) {
      await rpc("futbeat_record_live_batch", {
        p_provider: "goal_api",
        p_received_at: fetchedAt,
        p_observations: [liveObservation],
      }, 30000);
    }

    let recovered: unknown = null;
    if (recovery) {
      try {
        recovered = await rpc("futbeat_complete_terminal_recovery", {
          p_external_match_id: externalMatchId,
          p_provider_status: clean(detailRecord.matchStatus).toUpperCase(),
        });
      } catch (error) {
        // The provider call succeeded; the row settles on the next reserve.
        console.warn(
          "terminal recovery completion unavailable",
          error instanceof Error ? error.message : "unknown",
        );
      }
    }

    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservationId,
      p_status: "SUCCEEDED",
      p_provider_remaining: remaining,
      p_http_status: 200,
      p_error_code: null,
      p_metadata: {
        mode: "match-detail",
        ...(recovery
          ? {
            recovery: recovery.reason,
            providerStatus: clean(detailRecord.matchStatus).toUpperCase(),
            recovered,
          }
          : {}),
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
    const reported = (error as { remaining?: unknown })?.remaining;
    if (typeof reported === "number") remaining = reported;
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

function httpStatusOf(error: unknown) {
  const match = (error instanceof Error ? error.message : "").match(/HTTP (\d{3})/);
  return match ? Number(match[1]) : null;
}

// Player discovery/hydration on user demand. Each iteration reserves exactly
// one provider call through the central quota manager (search first, then
// profile, then season statistics) and stores only what GOAL returned.
async function syncPlayerDemand(maxCalls = 2) {
  const results: Record<string, unknown>[] = [];
  let goalKey = "";
  for (let i = 0; i < maxCalls; i++) {
    const plan = await rpc("futbeat_reserve_player_call", {
      p_trigger_source: "supabase-cron",
    });
    if (!plan?.allowed) {
      results.push({ status: "skipped", reason: plan?.reason ?? "unknown" });
      break;
    }
    const reservationId = Number(plan.reservationId);
    const kind = clean(plan.kind);
    let remaining: number | null = null;
    try {
      goalKey ||= await readGoalKey();
      if (kind === "player-search") {
        const response = await fetchGoal(
          goalKey,
          GOAL_PLAYER_ENDPOINTS.search(clean(plan.query)),
          30000,
          true,
        );
        remaining = response.remaining;
        const stored = await rpc("futbeat_store_player_search_result", {
          p_reservation_id: reservationId,
          p_players: normalizeGoalPlayerSearch(response.payload),
          p_provider_remaining: remaining,
        });
        results.push({ status: "ok", kind, ...stored });
      } else if (kind === "player-profile" || kind === "player-stats") {
        const external = clean(plan.externalPlayerId);
        const response = await fetchGoal(
          goalKey,
          kind === "player-profile"
            ? GOAL_PLAYER_ENDPOINTS.profile(external)
            : GOAL_PLAYER_ENDPOINTS.statistics(external),
          30000,
          true,
        );
        remaining = response.remaining;
        const stored = kind === "player-profile"
          ? await rpc("futbeat_store_player_profile", {
            p_reservation_id: reservationId,
            p_profile: normalizeGoalPlayerProfile(response.payload) ?? {},
            p_provider_remaining: remaining,
          })
          : await rpc("futbeat_store_player_stats", {
            p_reservation_id: reservationId,
            p_stats: normalizeGoalPlayerStatistics(response.payload),
            p_provider_remaining: remaining,
          });
        results.push({ status: "ok", kind, ...stored });
      } else {
        throw new Error("Unknown player reservation kind");
      }
    } catch (error) {
      const reported = (error as { remaining?: unknown })?.remaining;
      if (typeof reported === "number") remaining = reported;
      try {
        await rpc("futbeat_fail_player_call", {
          p_reservation_id: reservationId,
          p_kind: kind,
          p_http_status: httpStatusOf(error),
          p_error_code: "GOAL_PLAYER_FETCH_FAILED",
          p_provider_remaining: remaining,
        });
      } catch {
        console.error("player failure completion failed");
      }
      results.push({ status: "failed", kind, httpStatus: httpStatusOf(error) });
    }
  }
  return results;
}

// Standings a user is waiting for: exactly one (competition, season) per
// reservation, stored through the existing standings store (which archives
// it under its exact season) and completed with demand bookkeeping.
async function syncStandingsDemand() {
  const plan = await rpc("futbeat_reserve_standings_demand_call", {
    p_trigger_source: "supabase-cron",
  });
  if (!plan?.allowed) {
    return { status: "skipped", reason: plan?.reason ?? "unknown" };
  }
  const reservationId = Number(plan.reservationId);
  let remaining: number | null = null;
  try {
    const goalKey = await readGoalKey();
    const response = await fetchGoal(
      goalKey,
      GOAL_STANDINGS_ENDPOINT(clean(plan.externalLeagueId)),
      30000,
      true,
    );
    remaining = response.remaining;
    const rows = goalStandingsRows(response.payload);
    if (rows.length >= 2) {
      await rpc("futbeat_store_goal_standings", {
        p_competition_id: clean(plan.competitionId),
        p_external_league_id: clean(plan.externalLeagueId),
        p_received_at: new Date().toISOString(),
        p_season: goalStandingsSeason(rows),
        p_rows: rows,
      }, 30000);
    }
    const completed = await rpc("futbeat_complete_standings_call", {
      p_reservation_id: reservationId,
      p_succeeded: true,
      p_http_status: 200,
      p_provider_remaining: remaining,
    });
    return { status: "ok", rows: rows.length, demand: completed?.status ?? null };
  } catch (error) {
    const reported = (error as { remaining?: unknown })?.remaining;
    if (typeof reported === "number") remaining = reported;
    try {
      await rpc("futbeat_complete_standings_call", {
        p_reservation_id: reservationId,
        p_succeeded: false,
        p_http_status: httpStatusOf(error),
        p_provider_remaining: remaining,
      });
    } catch {
      console.error("standings failure completion failed");
    }
    return { status: "failed", httpStatus: httpStatusOf(error) };
  }
}

// Keeps calendar snapshots materialized (DB-only, no provider calls): plan
// once, then build ONE snapshot per RPC so every build is its own short
// transaction (no lock held across builds), within a batch and time budget.
async function syncCalendarWarm() {
  const plan = await rpc("futbeat_plan_calendar_snapshots", {}) as Record<
    string,
    unknown
  >;
  const batch = Math.max(0, Math.min(Number(plan?.batch ?? 4), 20));
  const deadline = Date.now() + Math.max(0, Number(plan?.budgetMs ?? 20000));
  const built: unknown[] = [];
  for (let i = 0; i < batch && Date.now() < deadline; i++) {
    const result = await rpc("futbeat_build_next_calendar_snapshot", {}) as
      | Record<string, unknown>
      | null;
    if (!result || result.status === "idle") break;
    built.push(result);
  }
  return { ...plan, built };
}

// User demand lane: match detail first (a Match Center is open), then player
// discovery/hydration. Woken by the database right after demand is recorded
// and also run by the per-minute cron, so a lost wake-up only adds latency.
async function syncDemand() {
  const detail: unknown[] = [];
  // Up to three details per run (per-minute cron + debounced wake-ups); the
  // central quota manager still decides every one.
  for (let i = 0; i < 3; i++) {
    try {
      const result = await syncOneMatchDetail() as Record<string, unknown>;
      detail.push(result);
      if (result?.status !== "ok") break;
    } catch (error) {
      console.error(
        "GOAL demand detail sync failed",
        error instanceof Error ? error.message : "unknown",
      );
      detail.push({ status: "failed" });
      break;
    }
  }
  let players: unknown;
  try {
    players = await syncPlayerDemand();
  } catch (error) {
    console.error(
      "GOAL player demand sync failed",
      error instanceof Error ? error.message : "unknown",
    );
    players = { status: "failed" };
  }
  let standings: unknown;
  try {
    standings = await syncStandingsDemand();
  } catch (error) {
    console.error(
      "GOAL standings demand sync failed",
      error instanceof Error ? error.message : "unknown",
    );
    standings = { status: "failed" };
  }
  let calendar: unknown;
  try {
    calendar = await syncCalendarWarm();
  } catch (error) {
    console.error(
      "calendar warm failed",
      error instanceof Error ? error.message : "unknown",
    );
    calendar = { status: "failed" };
  }
  return { detail, players, standings, calendar };
}

type SquadAttempt = {
  candidate: Record<string, unknown> | null;
  reservation: { allowed: boolean; reason: string | null } | null;
  providerCalls: 0 | 1;
};

async function syncOneSquad(attempt?: SquadAttempt) {
  const plan = await rpc("futbeat_team_squad_plan", { p_limit: 1 });
  if (!Array.isArray(plan) || plan.length === 0) {
    return { status: "skipped", reason: "no_squad_due" };
  }

  const row = plan[0] as Record<string, unknown>;
  const teamId = clean(row.teamId);
  const externalTeamId = clean(row.externalTeamId);
  if (!teamId.startsWith("fb_team_") || !externalTeamId) {
    throw new Error("Invalid squad plan row");
  }
  if (attempt) {
    attempt.candidate = {
      teamId,
      externalTeamId,
      priorityTier: row.priorityTier ?? null,
      reason: row.reason ?? null,
    };
  }

  const reservation = await rpc("futbeat_reserve_goal_squad_call", {
    p_team_id: teamId,
    p_external_team_id: externalTeamId,
    p_trigger_source: "supabase-cron",
  });
  if (attempt) {
    attempt.reservation = {
      allowed: reservation?.allowed === true,
      reason: reservation?.reason ?? null,
    };
  }
  if (!reservation?.allowed) {
    return {
      status: "skipped",
      reason: reservation?.reason ?? "unknown",
      reservation,
    };
  }

  const reservationId = Number(reservation.reservationId);
  let remaining: number | null = null;

  try {
    const goalKey = await readGoalKey();
    // Count attempts, including network failures. No retry or next candidate.
    if (attempt) attempt.providerCalls = 1;
    const response = await fetchGoal(
      goalKey,
      `/teams/${encodeURIComponent(externalTeamId)}/players`,
      30000,
      attempt != null,
    );
    remaining = response.remaining;
    if (
      response.payload.data == null ||
      typeof response.payload.data !== "object"
    ) {
      throw new Error("GOAL squad payload is invalid");
    }

    const cronToken = await readCronToken();
    const ingested = await callGlobalIngest(cronToken, {
      action: "squad-ingest",
      reservationId,
      teamId,
      externalTeamId,
      providerRemaining: remaining,
      players: response.payload,
    });

    return {
      status: "ok",
      teamId,
      externalTeamId,
      players: Number(ingested.players ?? 0),
      remaining,
    };
  } catch (error) {
    await completeFailure(
      reservationId,
      "GOAL_SQUAD_FETCH_FAILED",
      {
        mode: "team-squad",
        teamId,
        externalTeamId,
        detail: attempt ? "Squad fetch or ingest failed"
          : error instanceof Error ? error.message.slice(0, 300) : "unknown",
      },
      remaining,
      error instanceof Error
        ? Number(error.message.match(/^GOAL API (?:returned non-JSON )?HTTP (\d{3})$/)?.[1]) || null
        : null,
      attempt != null,
    );
    throw error;
  }
}

async function syncSquadOnly() {
  const attempt: SquadAttempt = {
    candidate: null,
    reservation: null,
    providerCalls: 0,
  };
  try {
    // Same planner/reservation/transport/ingest as cron; only reporting differs.
    const squad = await syncOneSquad(attempt);
    return {
      trigger: "squad-only",
      status: squad.status,
      ...attempt,
      allowed: attempt.reservation?.allowed ?? false,
      result: {
        success: squad.status === "ok",
        ...("players" in squad ? { players: squad.players } : {}),
        ...("reason" in squad ? { reason: squad.reason } : {}),
      },
    };
  } catch {
    // Do not expose provider/RPC text, credentials or request headers.
    return {
      trigger: "squad-only",
      status: "failed",
      ...attempt,
      allowed: attempt.reservation?.allowed ?? false,
      result: { success: false, error: "GOAL_SQUAD_SYNC_FAILED" },
    };
  }
}

async function syncOneNews() {
  const newsKey = await readNewsDataKey();
  if (newsKey.length < 10) {
    return { status: "skipped", reason: "news_provider_not_configured" };
  }

  const plan = await rpc("futbeat_news_plan", { p_limit: 1 });
  if (!Array.isArray(plan) || plan.length === 0) {
    return { status: "skipped", reason: "no_news_due" };
  }

  const row = plan[0] as Record<string, unknown>;
  const subjectType = clean(row.subjectType);
  const subjectId = clean(row.subjectId);
  const query = clean(row.query).slice(0, 100);
  if (
    !["team", "player", "competition"].includes(subjectType) ||
    !subjectId.startsWith("fb_") ||
    !query
  ) {
    throw new Error("Invalid news plan row");
  }

  const reservation = await rpc("futbeat_reserve_newsdata_call", {
    p_subject_type: subjectType,
    p_subject_id: subjectId,
    p_query: query,
    p_trigger_source: "supabase-cron",
  });
  if (!reservation?.allowed) {
    return {
      status: "skipped",
      reason: reservation?.reason ?? "unknown",
      reservation,
    };
  }

  const reservationId = Number(reservation.reservationId);
  try {
    const url = new URL("https://newsdata.io/api/1/latest");
    url.searchParams.set("apikey", newsKey);
    url.searchParams.set("q", `"${query}"`);
    url.searchParams.set("category", "sports");
    url.searchParams.set("language", "es,en");

    const response = await fetch(url, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(30000),
    });
    const text = await response.text();
    let payload: Record<string, unknown> = {};
    try {
      payload = text ? JSON.parse(text) : {};
    } catch {
      throw new Error(`NewsData returned non-JSON HTTP ${response.status}`);
    }

    if (!response.ok || clean(payload.status).toLowerCase() !== "success") {
      throw new Error(`NewsData HTTP ${response.status}`);
    }

    const articles = normalizeNewsData(payload);
    const stored = await rpc("futbeat_store_news_batch", {
      p_subject_type: subjectType,
      p_subject_id: subjectId,
      p_received_at: new Date().toISOString(),
      p_query: query,
      p_articles: articles,
    }, 30000);

    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservationId,
      p_status: "SUCCEEDED",
      p_provider_remaining: null,
      p_http_status: 200,
      p_error_code: null,
      p_metadata: {
        mode: "news",
        subjectType,
        subjectId,
        query,
        articles: Number(stored?.articles ?? articles.length),
        transport: "supabase-cron",
        provider: "NewsData.io",
      },
    });

    return {
      status: "ok",
      subjectType,
      subjectId,
      articles: Number(stored?.articles ?? articles.length),
    };
  } catch (error) {
    await completeFailure(
      reservationId,
      "NEWSDATA_FETCH_FAILED",
      {
        mode: "news",
        subjectType,
        subjectId,
        detail: error instanceof Error ? error.message.slice(0, 240) : "unknown",
      },
      null,
    );
    throw error;
  }
}

async function syncOnePostMatchVideo() {
  const youtubeKey = await readYoutubeKey();
  if (youtubeKey.length < 20) {
    return { status: "skipped", reason: "youtube_provider_not_configured" };
  }

  const plan = await rpc("futbeat_video_plan", { p_limit: 1 });
  if (!Array.isArray(plan) || plan.length === 0) {
    return { status: "skipped", reason: "no_video_due" };
  }

  const row = plan[0] as Record<string, unknown>;
  const matchId = clean(row.matchId);
  const channelId = clean(row.channelId);
  const channelName = clean(row.channelName);
  const query = clean(row.query);
  const homeName = clean(row.homeName);
  const awayName = clean(row.awayName);
  const publishedAfter = clean(row.publishedAfter);
  const publishedBefore = clean(row.publishedBefore);

  if (
    !matchId.startsWith("fb_match_") ||
    !/^UC[A-Za-z0-9_-]{22}$/.test(channelId) ||
    !query ||
    !homeName ||
    !awayName ||
    !publishedAfter ||
    !publishedBefore
  ) {
    throw new Error("Invalid post-match video plan");
  }

  const reservation = await rpc("futbeat_reserve_youtube_search_call", {
    p_match_id: matchId,
    p_channel_id: channelId,
    p_trigger_source: "supabase-cron",
  });
  if (!reservation?.allowed) {
    return {
      status: "skipped",
      reason: reservation?.reason ?? "unknown",
      reservation,
    };
  }

  const reservationId = Number(reservation.reservationId);
  let httpStatus: number | null = null;

  try {
    const url = new URL("https://www.googleapis.com/youtube/v3/search");
    url.searchParams.set("part", "snippet");
    url.searchParams.set("type", "video");
    url.searchParams.set("maxResults", "10");
    url.searchParams.set("order", "date");
    url.searchParams.set("channelId", channelId);
    url.searchParams.set("q", query);
    url.searchParams.set("publishedAfter", publishedAfter);
    url.searchParams.set("publishedBefore", publishedBefore);
    url.searchParams.set("safeSearch", "strict");
    url.searchParams.set("videoEmbeddable", "true");
    url.searchParams.set("key", youtubeKey);

    const response = await fetch(url, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(20000),
    });
    httpStatus = response.status;
    const payload = await response.json().catch(() => null) as
      | Record<string, unknown>
      | null;

    if (!response.ok || payload == null) {
      throw new Error(`YouTube search HTTP ${response.status}`);
    }

    const items = Array.isArray(payload.items) ? payload.items : [];
    let selected: Record<string, unknown> | null = null;

    for (const raw of items) {
      if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue;
      const item = raw as Record<string, unknown>;
      const id = item.id && typeof item.id === "object"
        ? item.id as Record<string, unknown>
        : {};
      const snippet = item.snippet && typeof item.snippet === "object"
        ? item.snippet as Record<string, unknown>
        : {};
      const videoId = clean(id.videoId);
      const itemChannelId = clean(snippet.channelId);
      const title = cleanYoutubeTitle(snippet.title);
      const publishedAt = clean(snippet.publishedAt);

      if (
        !/^[A-Za-z0-9_-]{11}$/.test(videoId) ||
        itemChannelId !== channelId ||
        !title ||
        !publishedAt ||
        !titleMentionsTeam(title, homeName) ||
        !titleMentionsTeam(title, awayName)
      ) {
        continue;
      }

      selected = {
        videoId,
        channelId,
        channelName: clean(snippet.channelTitle) || channelName,
        title,
        publishedAt,
      };
      break;
    }

    const stored = await rpc("futbeat_store_youtube_search_result", {
      p_match_id: matchId,
      p_channel_id: channelId,
      p_fetched_at: new Date().toISOString(),
      p_video: selected,
    });

    await rpc("futbeat_complete_provider_call", {
      p_reservation_id: reservationId,
      p_status: "SUCCEEDED",
      p_provider_remaining: null,
      p_http_status: httpStatus,
      p_error_code: null,
      p_metadata: {
        mode: "post-match-video",
        provider: "YouTube Data API",
        matchId,
        channelId,
        channelName,
        stored: selected == null ? 0 : 1,
        transport: "supabase-cron",
      },
    });

    return {
      status: "ok",
      matchId,
      channelId,
      stored: selected == null ? 0 : 1,
      result: stored,
    };
  } catch (error) {
    await completeFailure(
      reservationId,
      "YOUTUBE_VIDEO_SEARCH_FAILED",
      {
        mode: "post-match-video",
        matchId,
        channelId,
        detail: error instanceof Error ? error.message.slice(0, 240) : "unknown",
      },
      null,
      httpStatus,
    );
    throw error;
  }
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });

  try {
    const expected = await readCronToken();
    const supplied = clean(request.headers.get("x-futbeat-cron-token"));
    if (!(await secureEqual(expected, supplied))) {
      return Response.json({ error: "Forbidden" }, { status: 403 });
    }

    const body = await request.json().catch(() => ({})) as Record<string, unknown>;
    const trigger = clean(body.trigger).toLowerCase();
    if (trigger === "squad-only") {
      // This mode accepts no team, provider URL, quota or planner overrides.
      if (Object.keys(body).some((key) => key !== "trigger")) {
        return Response.json({ error: "squad-only accepts only trigger" }, {
          status: 400,
        });
      }
      return Response.json(await syncSquadOnly());
    }
    if (trigger === "results-only") {
      try {
        const results = await syncOneResultsDate();
        return Response.json({ status: "ok", results });
      } catch (error) {
        const stage = error && typeof error === "object" && "stage" in error
          ? clean((error as { stage?: unknown }).stage)
          : "unknown";
        // Safe by construction: `stage` is one of this function's own fixed
        // labels and `detail` is a truncated Error.message, never the GOAL
        // key, a raw provider payload, or a raw RPC response body.
        const detail = error instanceof Error
          ? error.message.slice(0, 200)
          : "unknown";
        console.error("GOAL results-only sync failed", stage, detail);
        return Response.json({
          status: "ok",
          results: { status: "failed", stage: stage || "unknown", detail },
        });
      }
    }
    if (trigger === "calendar") {
      // DB-only calendar snapshot builds (woken by a large cold date).
      if (Object.keys(body).some((key) => key !== "trigger")) {
        return Response.json({ error: "calendar accepts only trigger" }, {
          status: 400,
        });
      }
      try {
        return Response.json({ status: "ok", calendar: await syncCalendarWarm() });
      } catch (error) {
        console.error(
          "calendar lane failed",
          error instanceof Error ? error.message.slice(0, 200) : "unknown",
        );
        return Response.json({ status: "ok", calendar: { status: "failed" } });
      }
    }
    if (trigger === "detail-only" || trigger === "demand") {
      if (Object.keys(body).some((key) => key !== "trigger")) {
        return Response.json({ error: `${trigger} accepts only trigger` }, {
          status: 400,
        });
      }
      return Response.json({ status: "ok", ...(await syncDemand()) });
    }

    let live: unknown;
    let detail: unknown;
    let squad: unknown;
    let news: unknown;
    let video: unknown;

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

    try {
      squad = await syncOneSquad();
    } catch (error) {
      console.error(
        "GOAL squad sync failed",
        error instanceof Error ? error.message : "unknown",
      );
      squad = { status: "failed" };
    }

    try {
      news = await syncOneNews();
    } catch (error) {
      console.error(
        "NewsData sync failed",
        error instanceof Error ? error.message : "unknown",
      );
      news = { status: "failed" };
    }

    try {
      video = await syncOnePostMatchVideo();
    } catch (error) {
      console.error(
        "YouTube post-match video sync failed",
        error instanceof Error ? error.message : "unknown",
      );
      video = { status: "failed" };
    }

    return Response.json({ status: "ok", live, detail, squad, news, video });
  } catch (error) {
    console.error(
      "supabase GOAL live sync rejected",
      error instanceof Error ? error.message : "unknown",
    );
    return Response.json({ error: "LIVE sync unavailable" }, { status: 502 });
  }
});
