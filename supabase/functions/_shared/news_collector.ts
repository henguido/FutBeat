// News collector v2 (#104): one bounded unit of work per call.
//
// mode "currents": the highest-interest subject due (central interests,
//   never one query per user) -> one Currents search.
// mode "rss": the next enabled publisher feed due -> one conditional GET
//   (ETag / Last-Modified; 304 writes nothing but the feed state).
//
// Everything is injected (rpc, fetch, key) so Node tests run it with
// fixtures. dryRun (the default) only reports what would run: no provider
// request, no reservation, no write. A provider or feed that is disabled in
// news_provider_config / news_feeds plans nothing.

import {
  assignClusters,
  normalizeCurrents,
  normalizeFeed,
  prepareArticle,
  type ClusterCandidate,
  type PreparedArticle,
  type ProviderPolicy,
  type RawArticle,
  type SourcePolicy,
  type TagCandidate,
} from "./news_pipeline.ts";

export type Rpc = (name: string, body?: Record<string, unknown>) => Promise<unknown>;
export type Fetch = (url: string, init: RequestInit) => Promise<Response>;

export interface CollectorInput {
  mode: "currents" | "rss";
  dryRun: boolean;
}

export interface CollectorDeps {
  rpc: Rpc;
  fetch: Fetch;
  currentsKey?: string;
  now?: () => Date;
}

const CURRENTS_SEARCH = "https://api.currentsapi.services/v1/search";
const MAX_FEED_BYTES = 2_000_000;

export class CollectorInputError extends Error {}

export function parseCollectorInput(body: unknown): CollectorInput {
  const row = body && typeof body === "object" && !Array.isArray(body)
    ? body as Record<string, unknown>
    : {};
  const extra = Object.keys(row).filter((k) => k !== "mode" && k !== "dryRun");
  if (extra.length) throw new CollectorInputError("Unknown fields");
  if (row.mode !== "currents" && row.mode !== "rss") throw new CollectorInputError("Invalid mode");
  if (row.dryRun !== undefined && typeof row.dryRun !== "boolean") {
    throw new CollectorInputError("Invalid dryRun");
  }
  return { mode: row.mode, dryRun: row.dryRun !== false };
}

async function context(rpc: Rpc, provider: string) {
  const policies = await rpc("futbeat_news_policies", { p_provider: provider }) as {
    provider: (ProviderPolicy & { enabled: boolean }) | null;
    sources: SourcePolicy[];
  };
  const candidates = (await rpc("futbeat_news_tagging_dictionary", { p_limit: 3000 }) ?? []) as TagCandidate[];
  return { policies, candidates };
}

async function storePrepared(
  rpc: Rpc,
  provider: string,
  prepared: PreparedArticle[],
  subject: { type: string; id: string } | null,
) {
  const recent = (await rpc("futbeat_news_recent_fingerprints", { p_hours: 72 }) ?? []) as ClusterCandidate[];
  const clusters = assignClusters(prepared, recent);
  return await rpc("futbeat_store_news_batch_v2", {
    p_provider: provider,
    p_received_at: new Date().toISOString(),
    p_articles: prepared.map((a) => ({ ...a, clusterId: clusters.get(a.id) })),
    p_subject_type: subject?.type ?? null,
    p_subject_id: subject?.id ?? null,
  }) as Record<string, number>;
}

function prepareAll(
  raws: RawArticle[],
  policies: { provider: ProviderPolicy; sources: SourcePolicy[] },
  candidates: TagCandidate[],
  now: Date,
) {
  return raws
    .map((raw) => prepareArticle(raw, { provider: policies.provider, sources: policies.sources, candidates, now }))
    .filter((a): a is PreparedArticle => a !== null);
}

async function complete(
  rpc: Rpc,
  id: number,
  status: string,
  http: number | null,
  result: Record<string, unknown>,
  error: string | null,
) {
  await rpc("futbeat_complete_news_call", {
    p_reservation_id: id,
    p_status: status,
    p_http_status: http,
    p_result: result,
    p_error_code: error,
  });
}

async function runCurrents(input: CollectorInput, deps: CollectorDeps) {
  const plan = (await deps.rpc("futbeat_news_query_plan", { p_provider: "currents", p_limit: 1 }) ?? []) as Array<
    { subjectType: string; subjectId: string; query: string }
  >;
  if (!plan.length) return { status: "skipped", reason: "nothing_due_or_disabled" };
  const subject = plan[0];
  if (input.dryRun) return { status: "dry_run", subject };
  const key = (deps.currentsKey ?? "").trim();
  if (key.length < 10) return { status: "skipped", reason: "provider_not_configured" };
  const reservation = await deps.rpc("futbeat_reserve_news_call", {
    p_provider: "currents",
    p_target: `${subject.subjectType}:${subject.subjectId}`,
  }) as { allowed: boolean; reason?: string; reservationId?: number };
  if (!reservation?.allowed) return { status: "skipped", reason: reservation?.reason ?? "unknown" };
  const id = Number(reservation.reservationId);
  let http: number | null = null;
  try {
    const url = new URL(CURRENTS_SEARCH);
    url.searchParams.set("keywords", `"${subject.query.slice(0, 90)}"`);
    url.searchParams.set("language", "es");
    // The key travels in a header, never in a URL that could be logged.
    const response = await deps.fetch(url.toString(), {
      headers: { Accept: "application/json", Authorization: key },
      signal: AbortSignal.timeout(20000),
    });
    http = response.status;
    if (!response.ok) throw new Error(`HTTP_${response.status}`);
    const payload = await response.json();
    const { policies, candidates } = await context(deps.rpc, "currents");
    const provider = policies.provider;
    if (!provider) throw new Error("NO_POLICY");
    const prepared = prepareAll(
      normalizeCurrents(payload),
      { provider, sources: policies.sources },
      candidates,
      deps.now?.() ?? new Date(),
    );
    const stored = await storePrepared(deps.rpc, "currents", prepared, { type: subject.subjectType, id: subject.subjectId });
    await complete(deps.rpc, id, "SUCCEEDED", http, stored, null);
    return { status: "ok", subject, ...stored };
  } catch (error) {
    const code = error instanceof Error ? error.message.slice(0, 60) : "UNKNOWN";
    await complete(deps.rpc, id, "FAILED", http, {}, code);
    return { status: "failed", error: code };
  }
}

async function readLimited(response: Response): Promise<string> {
  const reader = response.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_FEED_BYTES) {
      await reader.cancel();
      throw new Error("FEED_TOO_LARGE");
    }
    chunks.push(value);
  }
  const all = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    all.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(all);
}

async function runRss(input: CollectorInput, deps: CollectorDeps) {
  const feed = await deps.rpc("futbeat_news_feed_due") as
    | { id: string; provider: string; url: string; sourceName: string; sourceDomain: string; etag?: string; lastModified?: string }
    | null;
  if (!feed) return { status: "skipped", reason: "nothing_due_or_disabled" };
  if (input.dryRun) return { status: "dry_run", feed: { id: feed.id, url: feed.url } };
  const reservation = await deps.rpc("futbeat_reserve_news_call", {
    p_provider: feed.provider,
    p_target: `feed:${feed.id}`,
  }) as { allowed: boolean; reason?: string; reservationId?: number };
  if (!reservation?.allowed) return { status: "skipped", reason: reservation?.reason ?? "unknown" };
  const id = Number(reservation.reservationId);
  let http: number | null = null;
  try {
    const headers: Record<string, string> = {
      Accept: "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8",
      "User-Agent": "FutBeatNewsCollector/2 (+link-out headlines)",
    };
    if (feed.etag) headers["If-None-Match"] = feed.etag;
    if (feed.lastModified) headers["If-Modified-Since"] = feed.lastModified;
    const response = await deps.fetch(feed.url, { headers, redirect: "follow", signal: AbortSignal.timeout(20000) });
    http = response.status;
    if (response.status === 304) {
      await complete(deps.rpc, id, "NOT_MODIFIED", http, { items: 0, inserted: 0, updated: 0, unchanged: 0 }, null);
      await deps.rpc("futbeat_news_feed_result", {
        p_feed_id: feed.id, p_ok: true, p_etag: null, p_last_modified: null, p_status: "NOT_MODIFIED",
      });
      return { status: "not_modified", feed: feed.id };
    }
    if (!response.ok) throw new Error(`HTTP_${response.status}`);
    const type = response.headers.get("content-type") ?? "";
    if (type && !/xml|rss|atom/i.test(type)) throw new Error("NOT_A_FEED");
    const xml = await readLimited(response);
    const { policies, candidates } = await context(deps.rpc, feed.provider);
    const provider = policies.provider;
    if (!provider) throw new Error("NO_POLICY");
    const raws = normalizeFeed(xml, {
      provider: feed.provider,
      sourceName: feed.sourceName,
      sourceUrl: `https://${feed.sourceDomain}`,
    })
      // A feed speaks only for its own publisher domain.
      .filter((raw) => {
        try {
          const host = new URL(raw.url).hostname.toLowerCase();
          return host === feed.sourceDomain || host.endsWith("." + feed.sourceDomain);
        } catch {
          return false;
        }
      });
    const prepared = prepareAll(raws, { provider, sources: policies.sources }, candidates, deps.now?.() ?? new Date());
    const stored = await storePrepared(deps.rpc, feed.provider, prepared, null);
    await complete(deps.rpc, id, "SUCCEEDED", http, stored, null);
    await deps.rpc("futbeat_news_feed_result", {
      p_feed_id: feed.id,
      p_ok: true,
      p_etag: response.headers.get("etag"),
      p_last_modified: response.headers.get("last-modified"),
      p_status: "OK",
    });
    return { status: "ok", feed: feed.id, ...stored };
  } catch (error) {
    const code = error instanceof Error ? error.message.slice(0, 60) : "UNKNOWN";
    await complete(deps.rpc, id, "FAILED", http, {}, code);
    await deps.rpc("futbeat_news_feed_result", {
      p_feed_id: feed.id, p_ok: false, p_etag: null, p_last_modified: null, p_status: code,
    });
    return { status: "failed", feed: feed.id, error: code };
  }
}

export function runNewsCollector(input: CollectorInput, deps: CollectorDeps) {
  return input.mode === "currents" ? runCurrents(input, deps) : runRss(input, deps);
}
