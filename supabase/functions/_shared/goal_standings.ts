// GOAL standings contract (no I/O): endpoint path and the reader for the
// rows' season label. The standings SQL store (futbeat_store_goal_standings)
// already validates and canonicalizes the raw rows, so they are passed as-is.
// The season field names mirror the existing standings workflow; they are
// UNVERIFIED against a captured response. When a row carries no season, the
// database archives the table under the competition's current season.

/** Path relative to https://api.goal-api.com/v1 (the worker adds base + auth). */
export const GOAL_STANDINGS_ENDPOINT = (externalLeagueId: string) =>
  `/standings/${encodeURIComponent(externalLeagueId)}`;

/** Raw provider rows, or [] when the response has no table. */
export function goalStandingsRows(payload: unknown): unknown[] {
  const data = payload && typeof payload === 'object' && !Array.isArray(payload)
    ? (payload as Record<string, unknown>).data
    : null;
  return Array.isArray(data) ? data : [];
}

/** Season label from the first row that carries one, else ''. */
export function goalStandingsSeason(rows: unknown[]): string {
  for (const row of rows.slice(0, 1)) {
    if (!row || typeof row !== 'object') continue;
    for (const field of ['season', 'leagueSeason', 'overallLeagueSeason']) {
      const value = (row as Record<string, unknown>)[field];
      if ((typeof value === 'string' || typeof value === 'number') && String(value).trim()) {
        return String(value).trim();
      }
    }
  }
  return '';
}

// Temporary, private contract discovery from an existing provider response.
// Never retain row values except bounded, numeric/UUID phase identifiers.
const shapeField = /^(?:stage|group|phase|round|overallLeague)/i;
const safeField = /^[A-Za-z][A-Za-z0-9_]{0,63}$/;
const safeId = /^(?:[0-9]{1,18}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;
// Below the SQL octet_length(shape::text) ceiling of 4096: jsonb::text can
// add spaces that are absent from JSON.stringify. Field names always win over
// ID examples, and their existing count/length bounds fit this budget alone.
const maxShapeJsonBytes = 3200;
const idFields = new Set([
  'stageId', 'stage_id', 'groupId', 'group_id',
  'phaseId', 'phase_id', 'roundId', 'round_id',
]);

export type GoalStandingsShape = {
  version: 1;
  sampledRows: number;
  fields: string[];
  ids: Record<string, string[]>;
};

export function goalStandingsShape(rows: unknown[]): GoalStandingsShape | null {
  if (!Array.isArray(rows) || rows.length < 2) return null;
  const fields = new Set<string>();
  const ids = new Map<string, Set<string>>();
  const addId = (path: string, value: unknown) => {
    const id = typeof value === 'number' && Number.isSafeInteger(value)
      ? String(value)
      : typeof value === 'string' ? value.trim() : '';
    if (!safeId.test(id)) return;
    if (!ids.has(path)) ids.set(path, new Set());
    const found = ids.get(path)!;
    if (found.size < 8) found.add(id);
  };
  for (const row of rows.slice(0, 100)) {
    if (!row || typeof row !== 'object' || Array.isArray(row)) continue;
    for (const [key, value] of Object.entries(row)) {
      if (!shapeField.test(key) || !safeField.test(key)) continue;
      if (fields.size < 32) fields.add(key);
      if (fields.has(key) && idFields.has(key)) addId(key, value);
      if (!['stage', 'group', 'phase', 'round'].includes(key.toLowerCase()) ||
          !value || typeof value !== 'object' || Array.isArray(value)) continue;
      for (const [nestedKey, nestedValue] of Object.entries(value)) {
        if (!safeField.test(nestedKey)) continue;
        const path = `${key}.${nestedKey}`;
        if (fields.size < 32) fields.add(path);
        if (fields.has(path) && nestedKey === 'id') addId(path, nestedValue);
      }
    }
  }
  if (fields.size === 0) return null;
  const shape: GoalStandingsShape = {
    version: 1,
    sampledRows: Math.min(rows.length, 100),
    fields: [...fields].sort(),
    ids: {},
  };
  const sortedIds = [...ids].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
    .map(([path, values]) => [path, [...values].sort()] as const);
  const encoder = new TextEncoder();
  // Round-robin: retain a sample from more field paths before extra examples
  // from one path. The candidate is included only if the entire serialized
  // shape remains inside the global budget; field names are never removed.
  for (let index = 0; index < 8; index++) {
    for (const [path, values] of sortedIds) {
      const value = values[index];
      if (value === undefined) continue;
      const examples = shape.ids[path] ?? (shape.ids[path] = []);
      examples.push(value);
      if (encoder.encode(JSON.stringify(shape)).length > maxShapeJsonBytes) {
        examples.pop();
        if (examples.length === 0) delete shape.ids[path];
      }
    }
  }
  return shape;
}

// ---------------------------------------------------------------------------
// Provider answer classification (#116). Pure and generic: no league id or
// name is special-cased. The standings workflow (PowerShell) mirrors these
// exact rules; backend/test/standings_coverage_no_data.test.mjs runs both
// against the same cases.
//
//   rows    -> 2xx, success=true, data array with >= 2 rows (store it)
//   no_data -> provider code STANDINGS_NOT_FOUND with HTTP 404 or 2xx, or a
//              2xx success=true with fewer than 2 rows (EMPTY_STANDINGS)
//   failed  -> everything else: no response (network/timeout), 401/403,
//              429, 5xx, any other 404 (broken endpoint / bad resource),
//              other statuses, malformed success payloads
// ---------------------------------------------------------------------------

export type GoalStandingsOutcome = {
  kind: 'rows' | 'no_data' | 'failed';
  code: string;
  httpStatus: number | null;
  message: string;
};

export const GOAL_STANDINGS_NOT_FOUND = 'STANDINGS_NOT_FOUND';
export const GOAL_STANDINGS_EMPTY = 'EMPTY_STANDINGS';

/** Provider error code from `code`, `errorCode` or `error.code`, else ''. */
export function goalProviderErrorCode(body: unknown): string {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return '';
  const record = body as Record<string, unknown>;
  const nested = record.error && typeof record.error === 'object' && !Array.isArray(record.error)
    ? (record.error as Record<string, unknown>).code
    : null;
  for (const value of [record.code, record.errorCode, nested]) {
    if (typeof value === 'string' && value.trim()) return value.trim().toUpperCase();
  }
  return '';
}

function goalProviderMessage(body: unknown): string {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return '';
  const record = body as Record<string, unknown>;
  for (const value of [record.error, record.message]) {
    if (typeof value === 'string' && value.trim()) return value.trim().slice(0, 200);
  }
  return '';
}

/** `status` 0/null = no HTTP response (network error, timeout). */
export function classifyGoalStandingsResponse(
  status: number | null,
  body: unknown,
): GoalStandingsOutcome {
  const httpStatus = Number.isInteger(status) && Number(status) >= 100 ? Number(status) : null;
  const code = goalProviderErrorCode(body);
  const message = goalProviderMessage(body);
  const out = (kind: GoalStandingsOutcome['kind'], outcomeCode: string) =>
    ({ kind, code: outcomeCode, httpStatus, message });
  if (httpStatus == null) return out('failed', 'GOAL_STANDINGS_NETWORK');
  if (httpStatus === 401 || httpStatus === 403) return out('failed', 'GOAL_STANDINGS_AUTH');
  if (httpStatus === 429) return out('failed', 'GOAL_STANDINGS_RATE_LIMITED');
  if (httpStatus >= 500) return out('failed', 'GOAL_STANDINGS_HTTP_5XX');
  const success2xx = httpStatus >= 200 && httpStatus < 300;
  if (code === GOAL_STANDINGS_NOT_FOUND && (httpStatus === 404 || success2xx)) {
    return out('no_data', GOAL_STANDINGS_NOT_FOUND);
  }
  if (!success2xx) return out('failed', `GOAL_STANDINGS_HTTP_${httpStatus}`);
  const record = body && typeof body === 'object' && !Array.isArray(body)
    ? body as Record<string, unknown>
    : null;
  if (!record || record.success !== true || !Array.isArray(record.data)) {
    return out('failed', 'GOAL_STANDINGS_INVALID_PAYLOAD');
  }
  return record.data.length >= 2
    ? out('rows', 'OK')
    : out('no_data', GOAL_STANDINGS_EMPTY);
}

/** Server-side guard for a reported NO_DATA (never trust the caller alone). */
export function isGoalStandingsNoData(status: number | null, code: string): boolean {
  const httpStatus = Number.isInteger(status) ? Number(status) : null;
  const success2xx = httpStatus != null && httpStatus >= 200 && httpStatus < 300;
  const normalized = String(code ?? '').trim().toUpperCase();
  return (normalized === GOAL_STANDINGS_NOT_FOUND && (httpStatus === 404 || success2xx)) ||
    (normalized === GOAL_STANDINGS_EMPTY && success2xx);
}
