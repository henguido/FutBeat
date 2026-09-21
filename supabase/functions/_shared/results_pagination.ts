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
