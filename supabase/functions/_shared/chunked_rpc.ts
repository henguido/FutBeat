// Chunked RPC runner with one bounded retry for a statement timeout.
//
// Production 2026-10-06 (runs 37406254844, 37408426862): resolving a hot
// ingest's identities failed with Postgres 57014 (statement timeout, 8 s
// for the API role). New identities cost ~23-48 ms each, and the first
// batch after a pause showed 3-9 s spikes with no lock wait. A chunk is one
// RPC = one transaction: a timeout rolls the whole chunk back and the
// resolver is idempotent, so running the SAME chunk once more is safe and
// costs no provider call. Chunks run strictly in order; a second timeout,
// or any other error, aborts (the caller fails the ingest, nothing global
// is retried).

export const STATEMENT_TIMEOUT_CODE = "57014";

/** True only for a PostgREST error whose Postgres code is 57014. */
export function isStatementTimeout(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error ?? "");
  return /"code"\s*:\s*"57014"/.test(message);
}

export class ChunkFailedError extends Error {
  readonly chunkIndex: number;
  readonly offset: number;
  readonly size: number;
  readonly attempts: number;
  readonly cause: unknown;

  constructor(
    chunkIndex: number,
    offset: number,
    size: number,
    attempts: number,
    cause: unknown,
  ) {
    super(
      `Chunk ${chunkIndex} (items ${offset}-${offset + size - 1}) failed after ${attempts} attempt(s): ${
        cause instanceof Error ? cause.message.slice(0, 200) : String(cause).slice(0, 200)
      }`,
    );
    this.name = "ChunkFailedError";
    this.chunkIndex = chunkIndex;
    this.offset = offset;
    this.size = size;
    this.attempts = attempts;
    this.cause = cause;
  }
}

export async function runChunksWithTimeoutRetry<T, R>(
  items: T[],
  chunkSize: number,
  call: (chunk: T[], chunkIndex: number) => Promise<R>,
  options: {
    retryDelayMs?: number;
    sleep?: (ms: number) => Promise<void>;
    onRetry?: (chunkIndex: number) => void;
  } = {},
): Promise<R[]> {
  if (!Number.isInteger(chunkSize) || chunkSize < 1) {
    throw new Error("Invalid chunk size");
  }
  const delay = Math.max(0, Math.min(options.retryDelayMs ?? 1500, 5000));
  const sleep = options.sleep ??
    ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const results: R[] = [];
  for (let offset = 0, index = 0; offset < items.length; offset += chunkSize, index += 1) {
    const chunk = items.slice(offset, offset + chunkSize);
    try {
      results.push(await call(chunk, index));
    } catch (first) {
      if (!isStatementTimeout(first)) {
        throw new ChunkFailedError(index, offset, chunk.length, 1, first);
      }
      options.onRetry?.(index);
      await sleep(delay);
      try {
        results.push(await call(chunk, index));
      } catch (second) {
        throw new ChunkFailedError(index, offset, chunk.length, 2, second);
      }
    }
  }
  return results;
}
