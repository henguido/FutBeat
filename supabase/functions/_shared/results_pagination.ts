export type ResultsPagination = Record<string, unknown> | null | undefined;

function nonNegativePageInteger(value: unknown): number | null {
  if (value == null || value === "" || typeof value === "boolean") return null;
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : null;
}

export function nextResultsOffset(input: {
  pagination: ResultsPagination;
  rowCount: number;
  added: number;
  currentOffset: number;
  requestedLimit?: number;
}): number | null {
  const row = input.pagination && typeof input.pagination === "object" &&
      !Array.isArray(input.pagination) ? input.pagination : {};
  const requestedLimit = input.requestedLimit ?? 500;
  const effectiveLimit = nonNegativePageInteger(row.limit) || requestedLimit;
  const total = nonNegativePageInteger(row.total);
  if (row.hasMore === false) return null;
  const hasMore = row.hasMore === true ||
    (total != null && input.currentOffset + input.rowCount < total) ||
    (total == null && input.rowCount >= effectiveLimit);
  if (!hasMore) return null;
  if (input.rowCount === 0 || input.added === 0) {
    throw new Error("GOAL results pagination cannot make progress");
  }
  return input.currentOffset + input.rowCount;
}

// BE-239: /fixtures/live never reported a second page in 21 days while up to
// 445 matches were in play, so a full page is never proof of the end. Only a
// short page or an empty probe is. A page with nothing new means the provider
// ignored the offset: stop, and the sweep stays unproven.
export function nextLivePage(input: {
  pagination: ResultsPagination;
  rowCount: number;
  added: number;
  currentOffset: number;
  requestedLimit?: number;
}): { next: number | null; stalled: boolean } {
  if (input.rowCount === 0) return { next: null, stalled: false };
  if (input.added === 0) return { next: null, stalled: true };
  const row = input.pagination && typeof input.pagination === "object" &&
      !Array.isArray(input.pagination) ? input.pagination : {};
  const effectiveLimit = nonNegativePageInteger(row.limit) ||
    (input.requestedLimit ?? 100);
  const total = nonNegativePageInteger(row.total);
  const end = input.currentOffset + input.rowCount;
  const hasMore = row.hasMore === true || (total != null && end < total) ||
    input.rowCount >= effectiveLimit;
  return { next: hasMore ? end : null, stalled: false };
}

// BE-244: GOAL refreshes clockUpdatedAt about once a minute (6 h of production:
// p95 75 s, max 231 s, LIVE and HALF_TIME). 15 minutes spans three polls, so an
// old clock is already a multi-poll signal. Only reported: it changes no state.
const LIVE_CLOCK_STALE_SECONDS = 900;

export function liveFeedFreshness(clocks: unknown[], nowMs: number) {
  const ages = clocks
    .map((clock) => Date.parse(String(clock ?? "")))
    .filter((parsed) => Number.isFinite(parsed))
    .map((parsed) => Math.max(0, Math.floor((nowMs - parsed) / 1000)));
  const newest = ages.length ? Math.min(...ages) : null;
  return {
    inPlayClocks: ages.length,
    staleClocks: ages.filter((age) => age >= LIVE_CLOCK_STALE_SECONDS).length,
    newestClockAgeSeconds: newest,
    stale: newest != null && newest >= LIVE_CLOCK_STALE_SECONDS,
  };
}
